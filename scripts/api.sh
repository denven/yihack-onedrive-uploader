#!/bin/sh

# param: $1="--retry" is a case for query once more when last query fails
send_api_request() {
	query="${query} -H 'Authorization: Bearer ${access_token}'"	
	resp=`eval $query` 
	# echo -e "$query \n $resp"
	# when the subshell process renews tokens and makes previous token deprecated, the above query will fail
	# parse error: Invalid numeric literal at line 1, column 10 (jq has issue and throws an error here)
	api_error_code=$(echo "${resp}" | jq --raw-output '.error.code')
	api_error_message=$(echo "${resp}" | jq --raw-output '.error.message')	
	if [ ! -z "${api_error_message}" ] && [ "${api_error_message}" != "null" ]; then
		error=$api_error_message
		write_log "$@, Error: $api_error_message, Code: ${api_error_code}"
		if [ "${api_error_code}" = "InvalidAuthenticationToken" ] && [ $1 != "--retry" ]; then 
			write_log "Token invalid or expired, start to renew the tokens..."
			refresh_oauth2_tokens "--onetime" 	# renew directly instead read from token.json		
			send_api_request "--retry" $@
		fi 
	else
		error=''
		color_print "GREEN" "Success: $*"
	fi
}

get_drive_status() {	
	query='curl -s -k -L -X GET '${DRIVE_BASE_URI}
	send_api_request "get_drive_status"	
	drive_id=$(echo $resp | jq -r '.id')
}

# this function is called by subshell process
check_drive_space() {
	# using export token variables can pass variable from parent process to child process, but cannot pass back from a child process
	oauth2_read_tokens  # get the latest token first in case of token data expired in subshell
	query='curl -s -k -L -X GET '${DRIVE_BASE_URI}
	send_api_request "check_drive_space"	
}

list_my_drives() {
	query='curl -s -k -L -X GET "https://graph.microsoft.com/v1.0/me/drives"'
	send_api_request "list_my_drives"
}

# create a folder under onedrive root path
# params: p$1=folder_name
create_folder() {
	local json_data="'{\"name\": \"$1\", \"folder\": {}}'"
	query="curl -s -k -L -X POST ${DRIVE_BASE_URI}/items/root/children"
	query="${query} -H 'Content-Type: application/json' --data-raw "${json_data}
	send_api_request "create_folder" $@
}

# param: item_id
delete_drive_item() {
	query="curl -s -k -L -X DELETE '${DRIVE_BASE_URI}/items/$1'"
	send_api_request "delete_drive_item" $@
}

# param: $1=item_id, $2="details"
get_drive_items() {
	query="curl -s -k -L -X GET '${DRIVE_BASE_URI}/items/$1'" # query item only
	if [ $# -gt 1 ]; then
		query="curl -s -k -L -X GET '${DRIVE_BASE_URI}/items/$1/children?select=id,name,size&top=2&orderby=lastModifiedDateTime'"	
		# query=${query}"children?select=id,name,size&top=2&orderby=lastModifiedDateTime'"	
	fi 
	send_api_request "get_drive_item" $@
}


# Note: no need to create its parent folder on onedirve before the upload.

# when file_size <= 4MB
# param: $1=sd_file_path
upload_small_file() {
	local file_name=$(parse_file_name $1)
	local file_parent=$(parse_file_parent $1)
	local target_path=${video_root_folder}/${file_parent}/${file_name}

	query="curl -s -k -L -X PUT '${DRIVE_BASE_URI}/items/root:/${target_path}:/content'"	
	query="${query} --upload-file $1"
	send_api_request "upload_small_file" $1
}

# upload large files (4-60MB) with an upload session, no file splitting right now
# issue: when a file is large, the camera memory is not enough and results in camera reboot
# param: $1=sd_file_path, $2=file_size
upload_large_file() {
	local file_name=$(parse_file_name $1)
	local file_parent=$(parse_file_parent $1)
	local json_data="'{\"item\":{\"@name.conflictBehavior\":\"replace\",\"name\":\"${file_name}\"}}'"
	
	local upload_path=${video_root_folder}/${file_parent}/${file_name}
	query="curl -s -k -L -X POST '${DRIVE_BASE_URI}/root:/${upload_path}:/createUploadSession'"
	query="${query} -H 'Content-Type: application/json' --data-raw "${json_data}
	send_api_request "create_upload_session" $1

	color_print "GREEN" "upload_large_file $1, $(get_human_readble_size ${file_size})"
	if [ -z "${error}" ] || [ "${error}" = "null" ]; then 
		local upload_url=$(echo ${resp} | jq --raw-output '.uploadUrl')	
		# local content_range="bytes 0-$((${file_size}-1))"
		# query="curl -L -X PUT ${upload_url} --data \"${file_name}\"=@\"$2\""  #--upload-file $2 if for single file
		# query="${query} -H 'Content-Length: ${file_size}'"
		# query="${query} -H 'Content-Range: ${content_range}/${file_size}'"
		# send_api_request "upload_large_file" $1 $2  

		# the query string cannot be expanded by eval or $() because upload_url contains single quote
		# we use curl command directly here, hide the output json
		curl -s -k -L -X PUT ${upload_url} \
		--data-binary "${filename}"@"$1" \
		-H "Content-Length: ${2}" \
		-H "Content-Range: bytes 0-$((${2}-1))/${2}" \
		> /dev/null

		# there are 2 errors warning here when use PUT instead of POST (-T):
		# 1. a session url error after the last chunk is transimitted
		# {"error":{"code":"itemNotFound","message":"The upload session was not found"}}
		# 2. curl: option --data-binary: out of memory
		# can not be fixed and redircted to null curl
		# but file transmission still work

		# session will be automatically cleaned up by onedrive after it is expired
		# curl -s -k -L -X DELETE ${upload_url}  # delete session when abortion
	fi
}

# https://learn.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createuploadsession?view=odsp-graph-online
# https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/errors?view=odsp-graph-online
# param: $1=sd_file_path, $2=file_size
upload_large_file_by_chunks() {
	local file_name=$(parse_file_name $1)
	local file_parent=$(parse_file_parent $1)
	local json_data="'{\"item\":{\"@name.conflictBehavior\":\"replace\",\"name\":\"${file_name}\"}}'"
	
	local upload_path=${video_root_folder}/${file_parent}/${file_name}
	query="curl -s -k -L -X POST '${DRIVE_BASE_URI}/root:/${upload_path}:/createUploadSession'"
	query="${query} -H 'Content-Type: application/json' --data-raw "${json_data}
	send_api_request "create_upload_session" $1
	color_print "GREEN" "upload_large_file_by_chunks $1, $(get_human_readble_size ${file_size})"

	local retry_count=0; local retry_max=10 # for chunk(fragment) re-transmission
	if [ -z "${error}" ] || [ "${error}" = "null" ]; then 
		local upload_url=$(echo ${resp} | jq --raw-output '.uploadUrl')	

		# Note: from the docs, size of each chunk MUST be a multiple of 320 KiB (327,680 bytes)
		# Since the most of the mp4 file size is less than 12MB, setting chunk size to 5.625M
		# will let a large file be transfered in only 2 chunks	
		# 320KB*18 = 327680*18 = 5898240 = 5.625M (most files can be done by 2 chunks, higher CPU spike)
		# 320KB*12 = 327680*12 = 3932160 = 3.932M (most files can be done by 3 chunks, lower cpu spike and better)
		local chunk_index=0; chunk_size=$((327680*12))  # moderate cpu spike
		local range_start=0; range_end=0; range_length=0

		local status_code=200 # used to check chunk send error and retry(re-transmission)
		local api_response=''; error_code=''
		local whole_file_retry=false
		while [ $((${chunk_index}*${chunk_size})) -lt $2 ] && [ ${retry_count} -lt ${retry_max} ]; do
			range_start=$((${chunk_index}*${chunk_size}))
			range_end=$((${range_start}+${chunk_size}-1))

			if [ ${range_end} -gt $2 ]; then
				range_end=$(($2-1))
			fi
			range_length=$((${range_end}-${range_start}+1))

			# do not use dd to copy file data as curl's input, output it to a tmp file instead
			# dd if="$1" count=1 skip=${chunk_index} bs=${chunk_size} 2> /dev/null | \
			# -H "Transfer-Encoding: chunked" \
			echo "$(date +"%F %H:%M:%S") upload chunk: ${chunk_index}, length: ${range_length}, bytes: ${range_start}-${range_end}"

			# by writing data to tmp file for curl to read, the chance of upload success increases
			if [ ${retry_count} -eq 0 ]; then 
				dd if="$1" of="./data/chunk_data" count=1 skip=${chunk_index} bs=${chunk_size} 2> /dev/null 
			fi 
			api_response=$(
				curl -s -k -L -X PUT "${upload_url}" \
				--data-binary @"./data/chunk_data" \
				--write-out %{http_code} \
				--max-time 15 \
				-H "Content-Type: application/octet-stream" \
				-H "Accept: application/json; odata.metadata=none" \
				-H "Content-Length: ${range_length}" \
				-H "Content-Range: bytes ${range_start}-${range_end}/${2}" \
				# -o /dev/null \
				# > /dev/null 2>&1
			)

			parse_upload_response "${api_response}" # get status_code and error_code
			
			# for status code 416, it indicates the specified byte range is invalid or unavailable
			# however, the error code fragmentOverlap can be tolerant since the fragment will be discareded
			# or be used to overwrite the previous one from my test experience, it wont break the file
			if [ \( "${status_code}" == "416" -a "${error_code}" == "fragmentOverlap" \) -o \
			   \( ${status_code} -ge 200 -a ${status_code} -lt 205 \) ]; then 
				chunk_index=$((${chunk_index}+1))
				retry_count=0				
			else 
				retry_count=$((${retry_count}+1))
				if [ ${status_code} = "000" ]; then
					status_code="${status_code}"
					echo "A re-transmission is required due to status_code: ${status_code}, reason: timeout."
				else
					echo "A re-transmission is required due to status_code: ${status_code}"
				fi 				
			fi			
			# sleep 1
		done 

		curl -s -k -L -X DELETE "${upload_url}"  # delete session after upload

		if [ ${status_code} -eq 200 ] || [ ${status_code} -eq 201 ]; then
			color_print "GREEN" "Success: upload_large_file_by_chunks $1"
		else 
			if [ ${upload_retry} = false ]; then
				upload_retry=true
				color_print "BROWN" "Failed: upload_large_file_by_chunks $1, status_code: ${status_code}, try another time."
			else 
				color_print "BROWN" "Failed: upload_large_file_by_chunks $1, status_code: ${status_code}, retry failed."
				echo `date +"%F %H:%M:%S"`: $1 >> ./log/upload_failed.history			
			fi 
		fi
	else 
		color_print "BROWN" "Failed: ${error}"
	fi
}  

# $1 is curl's output data
parse_upload_response() {	
	local resp_json=''
	if [ ${#1} -gt 3 ]; then
		status_code=${1: -3}
		resp_json=${1:: -3}
		if [ ${status_code} -ge 400 ]; then 
			error_code=$(echo ${resp_json} | jq -r '.error.innererror.code')
		else 
			error_code=''
		fi
	else 
		status_code=$1
	fi 
}


# do one time re-transimission of the whole file
upload_large_file_by_chunks_r() {
	local upload_retry=false
	upload_large_file_by_chunks $1 $2
	if [ ${upload_retry} = true ]; then 
		upload_large_file_by_chunks $1 $2
	fi 
}


# Try to get a walk around of OneDrive resumable API which is not very reliable when sending file larger than 4MB: too many timeout, and the speed is very slow.
# One way is to split the mp4 file into fragments less than 4MB and send them separately by OneDrive small file upload API. 
# However, the separate fragment file cannot be played without a right tool (like ffmpeg) to split or merge.
# Spliting video file takes time, and on OneDrive there will be more small files as well. 
# Thus, this way is not very ideal.
upload_large_file_by_fragments() {
	local file_name=$(parse_file_name $1)
	local file_parent=$(parse_file_parent $1)

	local fragment_path=""; fragment_name=""
	local chunk_index=0; chunk_size=$((4*1024*1024))  # max is 4MB
	local range_start=0; range_end=0; range_length=0

	while [ $((${chunk_index}*${chunk_size})) -lt $2 ]; do
		range_start=$((${chunk_index}*${chunk_size}))
		range_end=$((${range_start}+${chunk_size}-1))
		if [ ${range_end} -gt $2 ]; then
			range_end=$(($2-1))
		fi
		range_length=$((${range_end}-${range_start}+1))

		# here, the filename and path matters
		echo "upload chunk: ${chunk_index}, length: ${range_length}, bytes: ${range_start}-${range_end} "

		fragment_name=$(echo ${file_name} | sed "s/\./_$((chunk_index+1))\./g")
		fragment_path=${video_root_folder}/${file_parent}/${fragment_name}

		# using command dd to split mp4 file to fragments without encoding (the fragment cannot be played)				
		dd if="$1" of="./data/${fragment_name}" count=1 skip=${chunk_index} bs=${chunk_size} 2> /dev/null
		query="curl -s -k -L -X PUT '${DRIVE_BASE_URI}/items/root:/${fragment_path}:/content'"	
		query="${query} --upload-file ./data/${fragment_name}"
		send_api_request "\tupload_file_fragment" ${fragment_name}

		chunk_index=$((${chunk_index}+1))		
		sleep 1
	done 

	color_print "GREEN" "Success: upload_large_file_by_fragments $1"	
}  