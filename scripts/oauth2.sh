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
	api_error_msg=$(echo ${resp} | jq --raw-output '.error.message' ./data/token.json)
	if [ ! -z $access_token ] && [ "${access_token}" != "null" ]; then
		color_print "GREEN" "Get OneDrive access tokens successfully"
	elif [ ! -z $api_error_msg ]; then
		color_print "BROWN" ${api_error_msg}
	fi
}

# refresh tokens in case of expiry by default
# param: not required, if $1="test", it is testing the exipiration of refresh_token
refresh_oauth2_tokens() {
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

		access_token=$(echo ${resp} | jq --raw-output '.access_token')
		refresh_token=$(echo ${resp} | jq --raw-output '.refresh_token')
		error=$(echo ${resp} | jq --raw-output '.error.message' ./data/token.json)
		if [ ! -z $access_token ]; then
			echo ${resp} | jq '.' > ./data/token.json
			color_print "GREEN" "Refresh API tokens successfully, your token is still valid."				
		elif [ ! -z ${error} ]; then
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
	if [ -f ./data/token.json ]; then
		access_token=$(jq --raw-output '.access_token' ./data/token.json)
		refresh_token=$(jq --raw-output '.refresh_token' ./data/token.json)
		if [ ! -z $access_token ] && [ ! -z $refresh_token ]; then 
			color_print "GREEN" "Found an existing refresh token, start to test its availability..."
			refresh_oauth2_tokens "test"
		fi		
		if [ -z $error ] || [ "$error" = "null" ]; then
			need_re_assign=false
		else 
			color_print "GREEN" "The existing refresh token is still valid"
		fi 
	fi

	if [ ${need_re_assign} = true ]; then
		get_oauth2_auth_code  
		redeem_oauth2_tokens
	else		
		( refresh_oauth2_tokens ) &  # update tokens in subshell
	fi	
}