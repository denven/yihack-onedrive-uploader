#!/bin/sh

# check local video files states and determine upload
# save last upload file information for reboot check

manage_video_uploads() {
	local idle_transfer_mode=$(jq --raw-output '.idle_transfer' config.json)
	local camera_idled=false
	echo '${idle_transfer_mode}' ${idle_transfer_mode}

	echo -e "\n\nStart to check video and image files for upload..."

	while [ 1 ]; do
		if [ "${idle_transfer_mode}" = true ] ; then
			camera_idled=$(check_camera_idle_status)
		fi

		if [ "${idle_transfer_mode}" != true ] || [ ${camera_idled} = true ]; then
			local file=$(get_one_file_to_upload)
			if [ ! -z "${file}" ] && [ -f ${file} ]; then 
				echo "Start to upload ${file}"
				upload_one_file ${file}
			else 
				echo "All files are uploaded, wait for a new available one."
			fi 
		fi

		sleep 10
	done
}

# param: optional, when $1 is passed, it is the first-time check
check_drive_free_space() {
	if [ $# -eq 0 ]; then 
	 	get_my_drive  # check periodically by default
	fi

	local used=$(echo ${resp} | jq '.quota.used')
	local remaining=$(echo ${resp} | jq '.quota.remaining')
	local total=$(echo ${resp} | jq '.quota.total')

	echo  $((remaining*100/total))  $((100 - ${auto_clean_threshold}))
	if [ $((remaining*100/total)) -lt $((100 - ${auto_clean_threshold})) ]; then 
		remove_earliest_folders
	fi

	if [ $# -gt 0 ]; then 
		local used_ratio=$(get_percentage ${used} ${total})
	 	color_print "GREEN" "Your have used ${used_ratio} of your storage space, with $((remaining/1024/1024/1024))GB free. check './drive_status.json' to see your drive quota details."
	fi	
}


remove_earliest_folders() {
	echo "remove_earliest_folders"
}


check_camera_idle_status() {
	local size_1=$(get_file_size "/tmp/sd/record/tmp.mp4.tmp")
	sleep 10
	local size_2=$(get_file_size "/tmp/sd/record/tmp.mp4.tmp")
	if [ ${size_1} -eq ${size_2} ]; then
		echo true
	else 
		echo false
	fi
}

# get the earlist file which has not been uploaded yet
# no param, return file full path or empty
get_one_file_to_upload() {
	local file
	if [ ! -f ./data/last_upload.json ]; then 
		build_media_file_index	# build file index when there is no upload history record
		file=$(cat ./data/files.index | awk 'FNR <= 1')
	else 
		local last_uploaded=$(jq --raw-output '.file_path' ./data/last_upload.json) 
		echo "found last_upload.json" $last_uploaded >> debug

		if [ ! -f "${last_uploaded}" ]; then 
			build_media_file_index ${last_uploaded}  # when last uploaded file has been deleted
			file=$(cat ./data/files.index | awk 'FNR <= 1')
		else 
			echo "check next file by last_upload.json" ${last_uploaded} >> debug
			file=$(get_next_file ${last_uploaded}) # last uploaded file still exists		
		fi 
	fi 
	echo ${file}
}

# find many files will take several seconds
# param: optional, $1=filename
build_media_file_index() {
	if [ $# -eq 0 ]; then
		find /tmp/sd/record -maxdepth 2 -type f \( -iname \*.jpg -o -iname \*.mp4 \) > ./data/files.index  
	else
		local last_uploaded_file_ts=$(get_file_created_timestamp $1)
		local current_time_ts=$(date +%s)
		local eclipsed_mins=$(((${current_time_ts}-${last_uploaded_file_ts})/60))

		find /tmp/sd/record -maxdepth 2 -type f \( -iname \*.jpg -o -iname \*.mp4 \) \
		-mmin -${eclipsed_mins} > ./data/files.index  
	fi 
	using_fileindex=true
}

# note that the data command is from busybox
# param: $1=file_full_path, like /tmp/sd/record/2022Y11M12D15H/07M20S40.mp4
get_file_created_timestamp(){
	local uniq_name=$(parse_file_uniq_name $1)
  	YYYYMMDD=$(echo ${uniq_name} | cut -c 1-4)-$(echo ${uniq_name} | cut -c 6-7)-$(echo ${uniq_name} | cut -c 9-10)
  	hhmmss=$(echo ${uniq_name}  | cut -c 12-13):$(echo ${uniq_name} | cut -c 15-16):$(echo ${uniq_name} | cut -c 18-19)

  	rfc_fmt_date="${YYYYMMDD} ${hhmmss}"
	echo "rfc_fmt_date" $rfc_fmt_date >> debug
  	echo $(date -d "${rfc_fmt_date}" +%s)
}

# param: $1=file_full_path
# return: 2022Y11M12D15H
parse_file_parent() {
	# e.g: /tmp/sd/record/2022Y11M12D15H/07M20S40.mp4
	echo $1 | grep -oE "[0-9]{4}Y[0-9]{2}M[0-9]{2}D[0-9]{2}H"
}

# param: $1=file_full_path
# return: 07M20S40.mp4 
parse_file_name() {
	# e.g: /tmp/sd/record/2022Y11M12D15H/07M20S40.mp4
	echo $1 | grep -oE "[0-9]{2}M[0-9]{2}S[0-9]{2}.*"
}

# param: $1=file_full_path
# return: 2022Y11M12D15H07M20S40
parse_file_uniq_name() {
	# e.g: /tmp/sd/record/2022Y11M12D15H/07M20S40.mp4
	echo $1 | sed 's/\/tmp\/sd\/record\///' | sed 's/\///' | sed 's/\..*$//'
}

# param: $1=folder_name
get_folder_files() {
	ls /tmp/sd/record/$1/ # not giving full path
	# ls /tmp/sd/record/$1/ | awk '{OFS="\n"; $1=$1}1'
	# find /tmp/sd/record/$1/ -type d -maxdepth 1 # providing full file path
}

get_record_folders() {
	ls -d /tmp/sd/record/*/
	#  find /tmp/sd/record/ -type d -maxdepth 1
}

# param: $1=last_uploaded_file_full_path
# return: last_uploaded_file_full_path
get_next_file() {
	local next_file

	# search file from index first to save time (simple way)
	if ${using_fileindex}; then 
		next_file=$(cat ./data/files.index | grep -A1 ${last_uploaded} | grep -v ${last_uploaded})
	fi 

	# get next file from current or next newer folder (by hourly-named folder)
	if [ ${using_fileindex} = false ] || [ -z "${next_file}" ]; then 
		using_fileindex=false 
		local file_name=$(parse_file_name ${last_uploaded})
		local file_parent=$(parse_file_parent ${last_uploaded})

		# check if next file in the same folder
		next_file=$(find /tmp/sd/record/${file_parent} -type f | grep -A1 ${last_uploaded} | grep -v ${last_uploaded})

		# check newer file from another newer folder
		if [ -z "${next_file}" ]; then
			local next_folder=$(get_next_folder ${file_parent})
			if [ ! -z "${next_folder}" ]; then 
				next_file=$(find folderpath -type f | awk 'FNR <= 1')	
			fi		
		fi 
	fi 
	echo ${next_file} >> debug
	echo ${next_file}
}

# param: $1=current_folder_name, like 2022Y11M12D15H
# return: hourly-named folder name, like 2022Y11M12D16H
get_next_folder() {
	ls -d 202* | sed 's/\s+/\n/g' | grep -A1 $1 | grep -v $1
}

# param: $1=sd_video_file_path
upload_one_file() {
	local file_size=$(get_file_size $1)
	if [ ${file_size} -lt $((4*1024*1024)) ]; then
		upload_small_file $1
	else
		echo "$file_size:"  $file_size >> debug
		upload_large_file $1 ${file_size}
	fi

	if [ -z "${error}" ] || [ "${error}" = "null" ]; then 
		update_file_upload_data $1 
	fi
}

# param: file_path which is just uploaded to onedrive
update_file_upload_data() {
	echo '{ "file_path": "", "upload_time": "", "timestamp": "" }' | jq \
	--arg file "$1" \
	--arg date "$(date)" \
	--arg utcts "$(date +%s)" \
	'.file_path |= $file | .upload_time |= $date | .timestamp |= $utcts' \
	> ./data/last_upload.json
}

# check_camera_idle_status