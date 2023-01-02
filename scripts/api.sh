#!/bin/sh

send_api_request() {
	# if $(echo ${query} | grep -q -v "uploadSession"); then
	# 	query="${query} -H 'Authorization: Bearer ${access_token}'"	
	# fi
	echo $query
	query="${query} -H 'Authorization: Bearer ${access_token}'"	
	resp=`eval $query` # | jq  --raw-output '.error.message'`
	# echo $resp
	api_error_message=$(echo ${resp} | jq --raw-output '.error.message')	
	if [ ! -z "${api_error_message}" ] && [ "${api_error_message}" != "null" ]; then
		error=$api_error_message
		write_log $@ "$api_error_message"
		echo $api_error_message
	else
		error=''
		color_print "GREEN" "Success: $*"
	fi
}

get_my_drive() {	
	query='curl -s -k -L -X GET '${DRIVE_BASE_URI}
	send_api_request "get_my_drive"	
	echo $resp | jq '.quota' > ./data/drive_status.json 
	drive_id=$(echo $resp | jq '.id')
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

# param: item_id
get_drive_item() {
	query="curl -s -k -L -X GET '${DRIVE_BASE_URI}/items/$1'"
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
	query="curl -s -k -L -X PUT '${DRIVE_BASE_URI}/root:/${upload_path}:/createUploadSession'"
	query="${query} -H 'Content-Type: application/json' --data-raw "${json_data}
	send_api_request "create_upload_session" $1

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

		curl -s -k -L -X DELETE ${upload_url}  # delete session after upload
	fi
}

# https://learn.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createuploadsession?view=odsp-graph-online
# param: $1=sd_file_path, $2=file_size
upload_large_file_by_chunks() {
	local file_name=$(parse_file_name $1)
	local file_parent=$(parse_file_parent $1)
	local json_data="'{\"item\":{\"@name.conflictBehavior\":\"replace\",\"name\":\"${file_name}\"}}'"
	
	local upload_path=${video_root_folder}/${file_parent}/${file_name}
	query="curl -s -k -L -X PUT '${DRIVE_BASE_URI}/root:/${upload_path}:/createUploadSession'"
	query="${query} -H 'Content-Type: application/json' --data-raw "${json_data}
	send_api_request "create_upload_session" $1

	echo "upload_large_file_by_chunks" $2
	if [ -z "${error}" ] || [ "${error}" = "null" ]; then 
		local upload_url=$(echo ${resp} | jq --raw-output '.uploadUrl')	
		local chunk_index=0; chunk_size=4194304
		local range_start=0; range_end=0; range_length=0

		while [ $((${chunk_index}*${chunk_size})) -lt $2 ]; do
			range_start=$((${chunk_index}*${chunk_size}))
			range_end=$((${range_start}+${chunk_size}-1))

			if [ ${range_end} -gt $2 ]; then
				range_end=$(($2-1))
			fi
			range_length=$((${range_end}-${range_start}+1))

			echo $chunk_index $chunk_size
			echo $range_start $range_end
			echo $range_length			

			dd if="$1" count=1 skip=${chunk_index} bs=${chunk_size} 2> /dev/null |
			curl -s -k -L -X PUT ${upload_url} \
			--data-binary "${filename}"@- \
			-H "Transfer-Encoding: chunked" \
			-H "Content-Length: ${range_length}" \
			-H "Content-Range: bytes ${range_start}-${range_end}/${2}" \
			-o /dev/null  
			# > /dev/null 2>&1

			# there is 2 errors warning here:
			# 1. a session url error after the last chunk is transimitted
			# {"error":{"code":"itemNotFound","message":"The upload session was not found"}}
			# 2. curl: option --data-binary: out of memory
			# can not be fixed and redircted to null curl
			# but file transmission still work

			chunk_index=$((${chunk_index}+1))
		done 

		curl -s -k -L -X DELETE ${upload_url}  # delete session after upload
	fi
}