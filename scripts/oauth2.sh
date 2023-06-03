#!/bin/sh

# Tell the user to get authorization code manually because curl cannot follow the redirection url after user is signed-in
get_oauth2_auth_code() {
	local auth_endpoint="https://login.microsoftonline.com/${tenant_id}/oauth2/v2.0/authorize"
	# resp_scope="scope=Files.ReadWrite.All User.Read"
	local client_id="client_id=${client_id}"
	local scope="scope=https://graph.microsoft.com/.default%20offline_access"
	local resp_type="response_type=code"
	local authorizatoin_url="${auth_endpoint}?${client_id}&${scope}&${resp_type}"

	color_print "GREEN" "Copy the URL below to get an one-time API authorization code in your browser:" 
	color_print "BG_RED" "${authorizatoin_url}\n"

	color_print "GREEN" "Copy the authorization code from your browser and paste it below (hit Enter to continue):"
	while [ 1 ]; do
		read auth_code 
		if [ ! -z "$auth_code" ]; then 
			color_print "GREEN" "Using your authorization code to get an access token ..."
			break
		fi
	done 
}

# read application credentials from config.json
oauth2_read_configs() {
	grant_type=$(jq --raw-output '.grant_type' config.json)
	client_id=$(jq --raw-output '.client_id' config.json)
	client_secret=$(jq --raw-output '.client_secret' config.json)
	tenant_id=$(jq --raw-output '.tenant_id' config.json)
	# scope=$(jq --raw-output '.scope' config.json)  # not required for authorization_code grant type

	if [ -z $client_id ] || [ -z $client_secret ] || [ -z $grant_type ]; then
		color_print "BROWN" "You've missed configuration items in config.json, the client_id, client_secret and grant_type are all required, please fill in them and try again."
		exit 1
	fi 

	if [ -z "${tenant_id}" ] || [ "${tenant_id}" = "null" ]; then 
		tenant_id="consumers"  # personal account
	fi
}

# redeem the tokens and save it to file
# https://learn.microsoft.com/en-us/azure/active-directory/develop/active-directory-configurable-token-lifetimes
# The default lifetime of an access token is variable, default lifetime is random between 60-90 minutes (75 minutes on average)
# The default lifetime of an refresh token is valid for 14 days and maximum lifetime is 90 days.
redeem_oauth2_tokens() {
	curl -s -k -L -X POST "https://login.microsoftonline.com/${tenant_id}/oauth2/v2.0/token" \
	-H 'Content-Type: application/x-www-form-urlencoded' \
	--data-urlencode "grant_type=${grant_type}" \
	--data-urlencode "client_id=${client_id}" \
	--data-urlencode "client_secret=${client_secret}" \
	--data-urlencode "code=${auth_code}" \
	| jq '.' > ./data/token.json	

	access_token=$(jq --raw-output '.access_token' ./data/token.json)
	refresh_token=$(jq --raw-output '.refresh_token' ./data/token.json)
	api_error_msg=$(echo ${resp} | jq --raw-output '.error')
	if [ ! -z $access_token ] && [ "${access_token}" != "null" ]; then
		# backup for check new configuration
		cp ./config.json ./data/config.bak
		color_print "GREEN" "Get OneDrive access tokens successfully"
		enable_auto_start
	else 
		error_desc=$(echo ${resp} | jq --raw-output '.error_description')
		color_print "BROWN" ${api_error_msg}, ${error_desc}
	fi
}

# periodically refresh tokens in subshell process in case of expiry by default (this way is abandoned)
# the execution time interval is 30 minutes (the lifetime of access token is 60-75 minutes)
# param: not required, if $1="--test" or "--onetime", it refresh access token once only
refresh_oauth2_tokens() {
	local error=''; local resp=''
	while [ 1 ] ; do
		if [ "$#" -lt 1 ]; then
			sleep $((30*60)) # renew tokens every 30 minutes
		fi	
		error=''	
		resp=$(
			curl -s -k -L -X POST "https://login.microsoftonline.com/${tenant_id}/oauth2/v2.0/token " \
			-H 'Content-Type: application/x-www-form-urlencoded' \
			--data-urlencode 'grant_type=refresh_token' \
			--data-urlencode "client_id=${client_id}" \
			--data-urlencode "client_secret=${client_secret}" \
			--data-urlencode "refresh_token=${refresh_token}")

		local access_token_tmp=$(echo ${resp} | jq --raw-output '.access_token')
		local refresh_token_tmp=$(echo ${resp} | jq --raw-output '.refresh_token')		
		if [ ! -z $access_token ] && [ "${access_token}" != "null" ]; then
			access_token=${access_token_tmp}  # save the new tokens (they may not change)
			refresh_token=${refresh_token_tmp}							
			echo ${resp} | jq '.' > ./data/token.json			
			color_print "GREEN" "Refresh API tokens successfully, your token is still valid."	
			write_log "Refresh API tokens successfully, your token is still valid."	
		else
			api_error_msg=$(echo ${resp} | jq --raw-output '.error')
			error_desc=$(echo ${resp} | jq --raw-output '.error_description')
			color_print "BROWN" ${api_error_msg}, ${error_desc}
			color_print "BROWN" "Refresh API tokens failed, your may need to start over the configuration again if this error persists when the token is expired."
			write_log ${error}
			break
		fi

		if [ "$#" -ge 1 ]; then
			break  # test completed
		fi
	done 
}

manage_oauth2_tokens() {
	local need_re_assign=true  # re-assign the tokens or not

	oauth2_read_configs	

	if [ -f ./data/config.bak ]; then
		local bak_client_id=$(jq --raw-output '.client_id' ./data/config.bak)
		local bak_client_secret=$(jq --raw-output '.client_secret' ./data/config.bak)
		local bak_tenant_id=$(jq --raw-output '.tenant_id' ./data/config.bak)

		if [ "${client_id}" != "${bak_client_id}" ] || [ "${client_secret}" != "${bak_client_secret}" ] || [ "${tenant_id}" != "${bak_tenant_id}" ]; then 
			color_print "B_BROWN" "You've changed the API credential data, a new authorization code should be granted..."
		elif [ -f ./data/token.json ]; then
			access_token=$(jq --raw-output '.access_token' ./data/token.json)
			refresh_token=$(jq --raw-output '.refresh_token' ./data/token.json)
			if [ $access_token = "null" ] || [ $refresh_token = "null" ]; then
				color_print "BROWN" "Cannot find tokens from ./data/token.json, file may be corrupted, re-authorization of OneDrive access is required..."
				write_log "Token file is corrupted, re-authorization of OneDrive access is required"
				need_re_assign=true 
			elif [ ! -z $access_token ] && [ ! -z $refresh_token ]; then 
				color_print "GREEN" "Found an existing refresh token, start to test its availability..."
				refresh_oauth2_tokens "--test"
				if [ -z $error ] || [ "$error" = "null" ]; then
					need_re_assign=false
					color_print "GREEN" "The existing refresh token is still valid"
				fi 				
			fi		
		fi
	fi

	if [ ${need_re_assign} = true ]; then
		get_oauth2_auth_code  
		redeem_oauth2_tokens
	#else		
	#	( refresh_oauth2_tokens ) &  # update tokens in subshell
	fi	
} 


# read application credentials from config.json
oauth2_read_tokens() {
	if [ -f ./data/token.json ]; then
		access_token=$(jq --raw-output '.access_token' ./data/token.json)
		refresh_token=$(jq --raw-output '.refresh_token' ./data/token.json)
	else 
		refresh_oauth2_tokens "--onetime"
	fi
}

# param: $1=minutes
refresh_token_by_minutes() {		
	local eclipsed_mins=$(get_elipsed_minutes ${app_token_timer})
	if [ ${eclipsed_mins} -ge $1 ]; then 
		refresh_oauth2_tokens "--onetime"
		app_token_timer=$(date +%s)
	fi
}