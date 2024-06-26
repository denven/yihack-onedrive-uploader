#!/bin/sh

# check local video files states and determine upload
# save last upload file information for reboot check

manage_video_uploads() {
	# do the auto clean in a subshell when this feature is enabled
	if [ "${auto_clean_threshold}" -ge 50 ] && [ "${auto_clean_threshold}" -lt 100 ]; then 
		( manage_drive_auto_clean ) &  
		sleep 2
	fi 

	local idle_transfer_mode=$(jq --raw-output '.enable_idle_transfer' config.json)
	local camera_idled=false

	color_print "GREEN" "Start to check camera video and image files for uploading..."
	if [ "${idle_transfer_mode}" = true ]; then
		color_print "BROWN" "You've enabled the idle transfer mode, files upload are likely to be delayed."
		color_print "GREEN" "Disable it by changing 'enable_idle_transfer' key value to 'false' in your config.json."
	fi 	

	using_fileindex=false	
	no_available_files=true
	# the main loop of files upload 
	while [ 1 ]; do		
		if [ "${idle_transfer_mode}" = true ]; then
			camera_idled=$(check_camera_idle_status)
		fi

		refresh_token_by_minutes 30 # when the token has been refreshed, update it in this process
		# upload file, check and do auto-clean
		if [ "${idle_transfer_mode}" != true ] || [ ${camera_idled} = true ]; then
			local file=$(get_one_file_to_upload)
			if [ ! -z "${file}" ] && [ -f ${file} ]; then 
				echo "$(date +"%F %H:%M:%S") Start to upload ${file}"							
				upload_one_file ${file}
				process_log_file
				# sleep 2 # send file every 2s					
			else 
				echo "All files were uploaded, wait for a new recorded video or image file."
				no_available_files=true
				sleep 60 # check after one minute
			fi 
		fi
	done
}

# periodically check and do drive auto-clean in subshell process
# the execution time interval is ten minutes
manage_drive_auto_clean() {
	local used; local total; local used_ratio
	local need_auto_clean; local clean_started=false
	local only_one_folder_remaining=false

	write_log "Start the auto-clean monitor..."
	color_print "GREEN" "\nStart the auto-clean monitor..."
	while [ 1 ]; do 
		check_drive_space
		used=$(echo ${resp} | jq -r '.quota.used')
		remaining=$(echo ${resp} | jq -r '.quota.remaining')
		total=$(echo ${resp} | jq -r '.quota.total')
		
		# avoid out of range error for large number comparision
		if [ ! -z ${total} ] && [ $((total/(1024*1024*1024))) -gt 0 ]; then 
			used_ratio=$(get_percent ${used} ${total})
			free_ratio=$(get_percent ${remaining} ${total})
		else 
			sleep $((1*60))  # avoid unnecessary clean
			continue
		fi 

		local need_auto_clean=$(evaluate_auto_clean ${used_ratio} ${auto_clean_threshold})

		if [ ${need_auto_clean} -eq 1 ] && [ ${only_one_folder_remaining} = false ]; then
			clean_started=true
			# it seems in sub shell, get_percent will return value with a trailing % charater
			color_print "BROWN" "Your storage usage ${used_ratio} has exceeded your specified threshold ${auto_clean_threshold}%, start auto-clean..."
			# remove_earliest_folder # set $auto_clean_done to true when done (call this when all video folders are put inside root upload directory)
			delete_earliest_folder # for video file folders are oganized into multiple levels 
		else 
			if [ ${need_auto_clean} -eq 0 ] && [ ${clean_started} = true ]; then
				clean_started=false # clean is completed
				color_print "B_GREEN" "Bravo! Auto-clean is done, you currently have ${free_ratio} free storage space."
			elif [ ${only_one_folder_remaining} = true ]; then
				only_one_folder_remaining=false
				color_print "BROWN" "You have only one folder remain in your root upload directory, auto-clean is ignored."
			fi 
			sleep $((10*60)) # check auto-clean every 10 minutes after clean task is done		
		fi		
	done 
}

# Remove ONE folder to release space.
# Note that: This is a simple but non-aggressive auto clean solution to release space. 
# 1. each time the uploader will remove the OLDEST uploaded folders ONLY;
# 2. the uploader will keep at least one folder to ensure the latest uploaded files are not deleted;
# This means the auto-clean will be ignored when there is only one folder remaining in the root upload directory.
# For massive or latest data clean, the user should delete their folder(s) and files manually.
remove_earliest_folder() {
	local folder_to_delete=""
	for item_key in $(get_earliest_folder ${video_root_folder_id}); do 
		if [ ${#item_key} -eq 14 ]; then 
			folder_to_delete=${item_key}  # print the folder name to delete
			echo "Start to delete folder ${folder_to_delete}"			
		elif [ ${#item_key} -gt 14 ]; then  			
			delete_drive_item ${item_key} # delete by the folder id
			if [ -z "${error}" ] || [ "${error}" = "null" ]; then 
				# write_log "Deleted folder ${item_key}"
				echo `date +"%F %H:%M:%S"`": /${video_root_folder}/${folder_to_delete}" >> ./log/deletion.history
			fi 
		else	
			only_one_folder_remaining=true	
			break	
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


# delete folder and save deletion record with its path, the sub-folders and files will be deleted as well.
# params: $1--folder_id, $2---folder_path
delete_one_folder() {
	delete_drive_item $1 # delete by the folder id
	if [ -z "${error}" ] || [ "${error}" = "null" ]; then 
		echo `date +"%F %H:%M:%S"`": $2" >> ./log/deletion.history
	fi 
}

# delete the empty or earliest folder by checking the 3-level folders
# 1st level: months (202304), 2nd level: days (20230426), 3rd level: hours (2023Y04M05D07H)
delete_earliest_folder() {
	local folder_level=1
	local level_folder_cnt=0
	local folder_id="" folder_path="" folder_name=""
	local month_name="" day_name="" hour_name="" folder_path=""
	local month_count=0

	local cur_path_id=${video_root_folder_id}
	while [ $folder_level -le 3 ]; do
		get_drive_items ${cur_path_id} "-list" > /dev/null
		level_folder_cnt=$(echo $resp | jq '.value | length')
		
		if [ $level_folder_cnt -gt 0 ]; then			
			folder_id=$(echo $resp | jq --raw-output '.value | .[0].id')
			folder_name=$(echo $resp | jq --raw-output '.value | .[0].name')
		fi

		# check monthly folders
		if [ ${folder_level} -eq 1 ]; then
			if [ $level_folder_cnt -gt 0 ]; then
				month_name=${folder_name}
				month_count=${level_folder_cnt}
			else 
				color_print "BROWN" "No folder found in your root upload directory."
				break
			fi

		# check daily folders
		elif [ ${folder_level} -eq 2 ]; then
			if [ $level_folder_cnt -gt 0 ]; then			\
				day_name=${folder_name}
			else 
				if [ ${month_count} -gt 1 ]; then
					folder_path="/${video_root_folder}/${month_name}"
					delete_one_folder ${folder_id} ${folder_path}	
				else
					only_one_folder_remaining=true	
					break	
				fi
			fi

		# check hourly folders
		elif [ ${folder_level} -eq 3 ]; then
			if [ $level_folder_cnt -gt 0 ]; then			
				hour_name=${folder_name}
				folder_path="/${video_root_folder}/${month_name}/${day_name}/${hour_name}"
				delete_one_folder ${folder_id} ${folder_path}
			else
				folder_path="/${video_root_folder}/${month_name}/${day_name}"
				delete_one_folder ${folder_id} ${folder_path}
			fi
		fi 

		if [ ${level_folder_cnt} -gt 0 ]; then
			cur_path_id=${folder_id}
			folder_level=$((folder_level+1))	
		else
			break
		fi 
	done
}

check_camera_idle_status() {
	local idled=false
	if [ -f "${SD_RECORD_ROOT}/tmp.mp4.tmp" ]; then
		local size_1=$(get_file_size "${SD_RECORD_ROOT}/tmp.mp4.tmp")
		sleep 10
		local size_2=$(get_file_size "${SD_RECORD_ROOT}/tmp.mp4.tmp")
		if [ ${size_1} -eq ${size_2} ]; then
			idled=true
		fi
	else
		sleep 10
		if [ -f "${SD_RECORD_ROOT}/tmp.mp4.tmp" ]; then 
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
		build_media_file_index	# build a full files upload index when there is no uploaded file recorded
		file=$(cat ./data/files.index | awk 'FNR <= 1')
	else 
		local last_uploaded=$(jq --raw-output '.file_path' ./data/last_upload.json) 
		echo "Last uploaded file:" $last_uploaded >> ./log/next_file

		if [ "${last_upload}" = "NO_NEW_FILES" ] || [ -f "${last_uploaded}" ]; then
			echo "Search next file to upload..." >> ./log/next_file
			file=$(get_next_file ${last_uploaded}) # when last uploaded file still exists			
		else
			echo "Last uploaded file doesn't exist any more, update index..." >> ./log/next_file
			build_media_file_index ${last_uploaded}  # when last uploaded file has been deleted
			file=$(cat ./data/files.index | awk 'FNR <= 1')
		fi 
	fi 
	echo ${file}
}

# find many files will take several seconds
# param: optional, $1=filename(buid index from files after the created time of this)
# return: files list by modified time from past to current
build_media_file_index() {	
	if [ $# -eq 0 ]; then
		# when no uploaded file is recorded, it will create a full upload index
		write_log "Build a full upload index from all recorded files in sd card..."
		# files only sort by mtime in separate direcotries, cannot assure be sorted all by file mtime
		# find ${SD_RECORD_ROOT} -maxdepth 2 -type f \( -iname \*.jpg -o -iname \*.mp4 \) | xargs ls -1rt > ./data/files.index 
		# ls -1rtR ${SD_RECORD_ROOT}/*/ | awk '{ gsub("\:", ""); if ($1 ~ /sd/) { dir=$1 } else if(length($1) > 0) { printf "%s%s\n", dir, $1} }'
		if [ ${upload_video_only} != true ]; then  
			ls -1R ${SD_RECORD_ROOT}/*/ | grep -v ".h26x" | awk '{ gsub("/\:", ""); if ($1 ~ /sd/) { dir=$1 } else if(length($1) > 0) { printf "%s/%s\n", dir, $1} }' > ./data/files.index 
		else 
			ls -1R ${SD_RECORD_ROOT}/*/*.mp4 > ./data/files.index 
		fi 
		write_log "Built a new full index successfully."
	else
		# when the recorded last uploaded file cannot be found from the sd card
		write_log "Update index from files newer than file ${1}..."

		local file_parent=$(parse_file_parent ${1})  
		if [ ! -d ${SD_RECORD_ROOT}/${file_parent} ]; then 
			# the parent folder is deleted as well
			local last_uploaded_file_ts=$(get_file_created_timestamp ${1})
			local current_time_ts=$(date +%s)
			# local eclipsed_mins=$(((${current_time_ts}-${last_uploaded_file_ts})/60))		
			local eclipsed_mins=$(get_elipsed_minutes ${last_uploaded_file_ts})

			# find newer files to build index (if no files found, the files.index will be empty)
			# note that -mmin is not accurate for searching files created, its for modified match
			# and it will create a full index instead
			if [ ${upload_video_only} != true ]; then 
				find ${SD_RECORD_ROOT}/ -mindepth 1 -type d -mmin -${eclipsed_mins} | xargs ls -1R | \
				awk '{ gsub("\:", ""); if ($1 ~ /sd/) { dir=$1 } else if(length($1) > 0) { printf "%s/%s\n", dir, $1} }' | \
				grep -v ".h26x" > ./data/files.index 
			else 
				find ${SD_RECORD_ROOT}/ -mindepth 1 -type d -mmin -${eclipsed_mins} | xargs ls -1R | \
				awk '{ gsub("\:", ""); if ($1 ~ /sd/) { dir=$1 } else if($1 ~ /mp4/) { printf "%s/%s\n", dir, $1} }' | \
				grep -v ".h26x" > ./data/files.index
			fi 
		else 
			# find directories newer than the uploaded file's parent directory to build new index
			# if no directory are found, the files.index will be empty
			if [ ${upload_video_only} != true ]; then 
				find ${SD_RECORD_ROOT}/ -mindepth 1 -type d -newer ${SD_RECORD_ROOT}/${file_parent} | xargs ls -1R | \
				awk '{ gsub("\:", ""); if ($1 ~ /sd/) { dir=$1 } else if(length($1) > 0) { printf "%s/%s\n", dir, $1} }' | \
				grep -v ".h26x" > ./data/files.index
			else 
				find ${SD_RECORD_ROOT}/ -mindepth 1 -type d -newer ${SD_RECORD_ROOT}/${file_parent} | xargs ls -1R | \
				awk '{ gsub("\:", ""); if ($1 ~ /sd/) { dir=$1 } else if($1 ~ /mp4/) { printf "%s/%s\n", dir, $1} }' | \
				grep -v ".h26x" > ./data/files.index
			fi
		fi
		write_log "Updated index successfully."
	fi 

	grep -q . ./data/files.index # check if the index file is empty
	if [ $? -eq 0 ]; then 
		using_fileindex=true
	fi	
}

# note that the data command is from busybox
# param: $1=file_full_path, like ${SD_RECORD_ROOT}/2022Y11M12D15H/07M20S40.mp4
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
	# e.g: ${SD_RECORD_ROOT}/2022Y11M12D15H/07M20S40.mp4
	echo $1 | grep -oE "[0-9]{4}Y[0-9]{2}M[0-9]{2}D[0-9]{2}H"
}

# param: $1=file_full_path
# return: 07M20S40.mp4 
parse_file_name() {
	# e.g: ${SD_RECORD_ROOT}/2022Y11M12D15H/07M20S40.mp4
	echo $1 | grep -oE "[a-zA-Z]?[0-9]{2,3}M[0-9]{2}S[0-9]{2}.*"
}

# param: $1=file_full_path
# return: 2022Y11M12D15H07M20S40
parse_file_uniq_name() {
	# e.g: ${SD_RECORD_ROOT}/2022Y11M12D15H/07M20S40.mp4
	# echo $1 | sed 's/\/tmp\/sd\/record\///' | sed 's/\///' | sed 's/\..*$//'
	echo $1 | sed -E 's#.*/([0-9]{4}Y[0-9]{2}M[0-9]{2}D[0-9]{2}H)/[a-zA-Z]?[0-9]?([0-9]{2}M[0-9]{2}S[0-9]{2})\..*#\1\2#g'

}

# param: $1=folder_name
get_folder_files() {
	ls ${SD_RECORD_ROOT}/$1/ # not giving full path
	# ls ${SD_RECORD_ROOT}/$1/ | awk '{OFS="\n"; $1=$1}1'
	# find ${SD_RECORD_ROOT}/$1/ -type d -maxdepth 1 # providing full file path
}

get_record_folders() {
	ls -d ${SD_RECORD_ROOT}/*/
	#  find ${SD_RECORD_ROOT}/ -type d -maxdepth 1
}

# feature: get the path of next file to upload from files index or sd record directory
# param: $1=last_uploaded_file_full_path
# return: the new file found to upload by compare with the last uploaded file
# or return empty result
get_next_file() {
	local next_file

	# search file from index first to save time (simple way)
	# when using_fileindex is not defined, ${using_fileindex} will always be true
	if [ ${using_fileindex} = true ] && [ -f ./data/files.index ] ; then 
		echo "Search from built files index." >> ./log/next_file
		next_file=$(cat ./data/files.index | sed -n "/${last_uploaded}/{n;p}")
		if [ -z "${next_file}" ] || [ ! -f ${next_file} ]; then
			next_file=""
			using_fileindex=false
			echo "Can not find an existing file for next upload from the built files index." >> ./log/next_file
		fi 
	else 
		using_fileindex=false
	fi 

	# get next file from current or next newer folder (by hourly-named folder) 
	if [ "${using_fileindex}" = false ]; then 
		local file_name=$(parse_file_name ${last_uploaded})
		local file_parent=$(parse_file_parent ${last_uploaded})

		# check if there is a newer file in the same folder (using `ls -1` can save awk '{print $9}')
		# this will return a filename without the path included
		echo "Search in directory: '${file_parent}'" >> ./log/next_file
		if [ ${upload_video_only} != true ]; then 
			next_file=$(ls -1 ${SD_RECORD_ROOT}/${file_parent} | grep -v ".h26x" | sed -n "/${file_name}/{n;p}")  # filename only
			if [ ! -z "${next_file}" ]; then 
				next_file="${SD_RECORD_ROOT}/${file_parent}/${next_file}"
			fi 
		else
			next_file=$(ls -1 ${SD_RECORD_ROOT}/${file_parent}/*.mp4 | sed -n "/${file_name}/{n;p}") # full path
		fi
		
		# check the newer file from another newer folder
		if [ -z "${next_file}" ]; then		
			echo "No newer file found from directory last uploaded file located" >> ./log/next_file
			local next_folder=$(get_next_folder ${file_parent})
			if [ -d "${next_folder}" ]; then 
				echo "Search in another newer directory: ${next_folder}" >> ./log/next_file
				if [ ${upload_video_only} != true ]; then 
					next_file=$(find ${next_folder} -type f | grep -v ".h26x" | awk 'FNR <= 1')	# first file in the folder with full path
				else 
					next_file=$(find ${next_folder} -type f -iname \*.mp4| awk 'FNR <= 1')	# first file in the folder with full path
				fi
			else 
				echo "No more newer direcotries found" >> ./log/next_file
			fi 
		fi 
	fi 

	if [ -f "${next_file}" ]; then
		if [ ${no_available_files} = true ]; then
			no_available_files=false 
		fi 
		echo -e "Next file to upload: ${next_file}\n" >> ./log/next_file
	else 
		echo -e "No available newer file to upload for now\n" >> ./log/next_file
		next_file="NO_NEW_FILES"
	fi
	echo ${next_file}
}

# param: $1=current_folder_name, like 2022Y11M12D15H
# return: hourly-named folder name, like 2022Y11M12D16H
# use sed to get because some devices don't support grep -A option
get_next_folder() {
	# ls -d ${SD_RECORD_ROOT}/202* | sed 's/\s+/\n/g' | grep -A1 $1 | grep -v $1
	ls -d ${SD_RECORD_ROOT}/202* | sed 's/\s+/\n/g' | sed -n "/$1/{n;p}"
}

# param: $1=sd_video_file_path
upload_one_file() {
	local file_size=$(get_file_size $1)
	if [ ${file_size} -lt $((4*1024*1024)) ]; then
		upload_small_file $1
	else
		# upload_large_file $1 ${file_size}		
		# upload_large_file_by_chunks $1 ${file_size}
		upload_large_file_by_chunks_r $1 ${file_size}
		# upload_large_file_by_fragments $1 ${file_size}
	fi

	if [ -z "${error}" ] || [ "${error}" = "null" ]; then 
		update_file_upload_data $1 # failed or successful upload of one file
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
	echo `date +"%F %H:%M:%S"`: $1 >> ./log/upload.history
}