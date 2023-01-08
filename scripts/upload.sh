#!/bin/sh

# check local video files states and determine upload
# save last upload file information for reboot check

manage_video_uploads() {
	local idle_transfer_mode=$(jq --raw-output '.enable_idle_transfer' config.json)
	local camera_idled=false
	
	color_print "GREEN" "\nStart to check camera video and image files for uploading..."
	if [ "${idle_transfer_mode}" = true ]; then
		color_print "BROWN" "You've enabled the idle transfer mode, files upload are likely to be delayed."
		color_print "GREEN" "Disable it by changing 'enable_idle_transfer' key value to 'false' in your config.json."
	fi 

	upload_start_ts=$(date +%s) 
	while [ 1 ]; do
		manage_space_auto_clean

		if [ "${idle_transfer_mode}" = true ]; then
			camera_idled=$(check_camera_idle_status)
		fi

		if [ "${idle_transfer_mode}" != true ] || [ ${camera_idled} = true ]; then
			local file=$(get_one_file_to_upload)
			if [ ! -z "${file}" ] && [ -f ${file} ]; then 
				echo "Start to upload ${file}"
				upload_one_file ${file}		
				process_log_file
				sleep 10 # send file every 10s
			else 
				echo "All files were uploaded, wait for a new recorded video or picture file."
				sleep 60 # check after one minute
			fi 			
		fi
	done
}

manage_space_auto_clean() {
	if [ $(get_elipsed_minutes ${upload_start_ts}) -ge 30 ]; then
		get_drive_status
		check_drive_free_space # do the auto-clean here
		upload_start_ts=$(date +%s)
	fi
}

# param: optional, when $1 is passed, it is the first-time check
check_drive_free_space() {
	local used=$(echo ${resp} | jq '.quota.used')
	local remaining=$(echo ${resp} | jq '.quota.remaining')
	local total=$(echo ${resp} | jq '.quota.total')

	local used_ratio=$(get_percentage ${used} ${total})
	local free_ratio=$(get_percentage ${remaining} ${total})

	local need_auto_clean=$(evaluate_auto_clean ${free_ratio} ${auto_clean_threshold})
	if [ ${need_auto_clean} -eq 1 ] && [ $# -eq 0 ]; then
		color_print "BROWN" "Your storage usage ${used_ratio} exceeds the specified threshold ${auto_clean_threshold}%, auto-clean started..."
		remove_earliest_folder
	fi

	if [ $# -gt 0 ]; then 
		local remain_gb=$(echo ${remaining} | awk '{printf "%.2f", $1/(1024*1024)}')
	 	color_print "GREEN" "You have used ${used_ratio} of your storage space, with ${remain_gb}GB(${free_ratio}) space remaining."
		color_print "GREEN" "Check './drive_status.json' to see your drive quota details."
	fi	
}

# Remove one folder to release space.
# Note that: This is a simple but non-aggressive auto clean solution to release space. 
# 1. each time the uploader will remove the OLDEST uploaded folder ONLY, in order to keep more files still in OneDive
# 2. the uploader will keep at least one folder to save the latest uploaded files
# This means the auto-clean will be ignored when there is only one folder remaining in the root upload directory.
# For massive or latest data clean, the user should release their space manually.
remove_earliest_folder() {
	local folder_name=""
	for item_key in $(get_earliest_folder ${video_root_folder_id}); do 
		if [ ${#item_key} -eq 14 ]; then 
			folder_name=${item_key}
			echo "Start to delete folder ${folder_name}"			
		elif [ ${#item_key} -gt 14 ]; then  			
			delete_drive_item ${item_key}
			if [ -z "${error}" ] || [ "${error}" = "null" ]; then 
				write_log "Deleted folder ${item_key}"
				echo `date`": ${folder_name}" >> ./log/deletion.history
			fi 
		else
			echo "You have only one folder remain in your root upload folder, auto-clean is ignored."			
		fi 
	done 
}

get_earliest_folder() {
	get_drive_items $1 "-list" > /dev/null
	local folders_cnt=$(echo $resp | jq '.value | length')
	if [ ${folders_cnt} -gt 1 ]; then 
		echo $resp | jq --raw-output '.value | .[0].name, .[0].id'
	else
		echo "Ignored"
	fi 
}

check_camera_idle_status() {
	local idled=false
	if [ -f "/tmp/sd/record/tmp.mp4.tmp" ]; then
		local size_1=$(get_file_size "/tmp/sd/record/tmp.mp4.tmp")
		sleep 10
		local size_2=$(get_file_size "/tmp/sd/record/tmp.mp4.tmp")
		if [ ${size_1} -eq ${size_2} ]; then
			idled=true
		fi
	else
		sleep 10
		if [ -f "/tmp/sd/record/tmp.mp4.tmp" ]; then 
			idled=true
		fi 
	fi
	echo ${idled}
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
		echo "found last_upload.json" $last_uploaded >> ./log/debug

		if [ ! -f "${last_uploaded}" ]; then 
			build_media_file_index ${last_uploaded}  # when last uploaded file has been deleted
			file=$(cat ./data/files.index | awk 'FNR <= 1')
		else 
			echo "check next file by last_upload.json" ${last_uploaded} >> ./log/debug
			file=$(get_next_file ${last_uploaded}) # last uploaded file still exists		
		fi 
	fi 
	echo ${file}
}

# find many files will take several seconds
# param: optional, $1=filename
build_media_file_index() {
	if [ $# -eq 0 ]; then
		find /tmp/sd/record -maxdepth 2 -type f \( -iname \*.jpg -o -iname \*.mp4 \) \
		| xargs ls -1rt > ./data/files.index  
	else
		local last_uploaded_file_ts=$(get_file_created_timestamp $1)
		# local current_time_ts=$(date +%s)
		# local eclipsed_mins=$(((${current_time_ts}-${last_uploaded_file_ts})/60))		
		local eclipsed_mins=$(get_elipsed_minutes ${last_uploaded_file_ts})

		find /tmp/sd/record -maxdepth 2 -type f \( -iname \*.jpg -o -iname \*.mp4 \) \
		-mmin -${eclipsed_mins} | xargs ls -1rt > ./data/files.index  
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
	if [ "${using_fileindex}" = false ] || [ -z "${next_file}" ]; then 
		using_fileindex=false 
		local file_name=$(parse_file_name ${last_uploaded})
		local file_parent=$(parse_file_parent ${last_uploaded})

		# check if there is a newer file in the same folder
		next_file=$(ls -l /tmp/sd/record/${file_parent} | grep -A1 ${file_name} | awk '{print $9}' | grep -v ${file_name})

		# check newer file from another newer folder
		if [ -z "${next_file}" ]; then
			local next_folder=$(get_next_folder ${file_parent})
			if [ ! -z "${next_folder}" ]; then 
				next_file=$(find ${next_folder} -type f | awk 'FNR <= 1')	
			fi		
		else
			next_file="/tmp/sd/record/${file_parent}/${next_file}"
		fi 
	fi 
	echo ${next_file} >> ./log/debug
	echo ${next_file}
}

# param: $1=current_folder_name, like 2022Y11M12D15H
# return: hourly-named folder name, like 2022Y11M12D16H
get_next_folder() {
	ls -d /tmp/sd/record/202* | sed 's/\s+/\n/g' | grep -A1 $1 | grep -v $1
}

# param: $1=sd_video_file_path
upload_one_file() {
	local file_size=$(get_file_size $1)
	if [ ${file_size} -lt $((4*1024*1024)) ]; then
		upload_small_file $1
	else
		upload_large_file_by_chunks $1 ${file_size}
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
	echo `date`: $1 >> ./log/upload.history
}