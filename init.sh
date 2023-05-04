#!/bin/sh

# include other shell scripts
. "$PWD/scripts/api.sh"
. "$PWD/scripts/utils.sh"
. "$PWD/scripts/oauth2.sh"
. "$PWD/scripts/upload.sh"

init_globals() {
	camera_idled=false 
	default_video_root_folder="yihack_videos"
	query=''; resp=''; error=''; video_root_folder=''
	upload_video_only=true # upload mp4 files only
	auto_clean_threshold=100  # disable the auto-clean feature
	convert_utc_path_name=false # for v0.4.9
	timezone_offset_seconds=0 # it will be calated when convert_utc_path_name is true

	app_token_timer=$(date +%s) # global timer used for token check
	DRIVE_BASE_URI="https://graph.microsoft.com/v1.0/me/drive"

	SD_RECORD_ROOT="/tmp/sd/record"
	YI_HACK_ROOT="/tmp/sd/yi-hack"
	UPLOADER_ROOT="${YI_HACK_ROOT}/onedrive"

	# append curl and jq path to system env variable to avoid failures
	# and use separate curl and jq programs other than from yi-hack's path (to remove the boot sequence dependency)
	export PATH=$PATH:/tmp/sd/yi-hack/onedrive/bin

	mkdir -p data log # prepare folders to store upload info and logs

	write_log "OneDive Uploader started..."
	color_print "GREEN" "Checking your OneDrive-uploader configuration..."
	if [ ! -f ./config.json ]; then
		echo '{ "grant_type": "authorization_code", "client_id": "", "client_secret": "", "tenant_id": "" }' \
		| jq -M '. + {"video_root_folder": "yihack_videos", "convert_utc_path_name": "false", "TZ_string": "", "auto_clean_threshold": "100", "enable_idle_transfer": "false"}' \
		> config.json
		color_print "BROWN" "A template config.json file is generated for you, please fill in it and try again."
		exit 0
	else
		local upload_file_type=$(jq --raw-output '.upload_video_only' config.json)
		if [ ! -z "${upload_file_type}" ] && [ "${upload_file_type}" != "null" ]; then
			upload_video_only=${upload_file_type}
		fi

		local threshold=$(jq --raw-output '.auto_clean_threshold' config.json)
		if [ ! -z "${threshold}" ] && [ "${threshold}" != "null" ]; then
			auto_clean_threshold=${threshold}
		fi 
		if [ ${auto_clean_threshold} -ge 50 ] && [ ${auto_clean_threshold} -lt 100 ]; then
			color_print "BROWN" "You've enabled auto-clean feature when you use more than ${auto_clean_threshold}% of storage capacity."
		fi 

		convert_utc_path_name=$(jq --raw-output '.convert_utc_path_name' config.json)
		if [ "${convert_utc_path_name}" = true ]; then
			if [ ! -z ${TZ} ]; then
				color_print "BROWN" "Your camera currently uses $TZ as the timezone string."
			else 
				color_print "BROWN" "Your camera currently uses GMT0 as the timezone string."			
			fi
			timezone_offset_seconds=$(get_timezone_offset_seconds)
			if [ ${timezone_offset_seconds} -ge 1800 ] || [ ${timezone_offset_seconds} -le -1800 ]; then
				color_print "BROWN" "You've enabled the folder name conversion, and your timezone offset $((timezone_offset_seconds/3600)) hours."
				color_print "BROWN" "The video file direcotries names will be converted and named by your local time when uploading."
			fi 
		fi
	fi
}

test_onedrive_status() {		
	get_drive_status

	local used=$(echo ${resp} | jq -r '.quota.used')
	local remaining=$(echo ${resp} | jq -r '.quota.remaining')
	local total=$(echo ${resp} | jq -r '.quota.total')

	local used_ratio=$(get_percent ${used} ${total})
	local free_ratio=$(get_percent ${remaining} ${total})

	echo $resp | jq '.quota' > ./data/drive_status.json
	local used_gb=$(echo ${used} | awk '{printf "%.2f", $1/(1024*1024*1024)}')
	local remain_gb=$(echo ${remaining} | awk '{printf "%.2f", $1/(1024*1024*1024)}')

	color_print "B_GREEN" "You have used ${used_gb}GB(${used_ratio}%) of your storage space, with ${remain_gb}GB(${free_ratio}%) space remaining."
	color_print "GREEN" "Check './data/drive_status.json' to see your drive quota details."

	if [ ! -z "${error}" ] && [ "${error}" != "null" ]; then
		color_print "RED" "You don't have the access to the drive, please check your config.json file."
		exit 1
	else		
		color_print "GREEN" "Your OneDrive access is available."
	fi
}

create_video_root_folder() {
	video_root_folder=$(jq --raw-output '.video_root_folder' config.json)
	video_root_folder_id=$(jq --raw-output '.video_root_folder_id' config.json)
	# echo $video_root_folder $video_root_folder_id

	local need_create=true
	if [ ! -z "${video_root_folder_id}" ] && [ "${video_root_folder_id}" != "null" ]; then
		get_drive_items ${video_root_folder_id}
		if [ -z "${error}" ] || [ "${error}" = "null" ]; then
			need_create=false
		fi
	fi

	if [ -z "${video_root_folder}" ] || [ "${video_root_folder}" = "null" ]; then
		video_root_folder=${default_video_root_folder}
	else
		video_root_folder=$(echo ${video_root_folder} | sed 's/ /_/g')
	fi

	if [ ${need_create} = true ]; then
		create_folder $video_root_folder  # create the root folder to store video files
		if [ -z "${error}" ] || [ "${error}" = "null" ]; then					
			touch tmpfile
			video_root_folder_id=$(echo ${resp} | jq --raw-output '.id')
			jq --arg folder "${video_root_folder}" '.video_root_folder = $folder' config.json > tmpfile && mv -- tmpfile config.json 
			jq --arg folder_id "${video_root_folder_id}" '.video_root_folder_id = $folder_id' config.json > tmpfile && mv -- tmpfile config.json
			rm -f tmpfile	

			color_print "GREEN" "Created folder ${video_root_folder} to store your video files successfully."
			color_print "B_GREEN" "Configuration is done."
			break
		fi
	else
		color_print "GREEN" "You've specified the folder '${video_root_folder}' to store your files."		
		color_print "B_GREEN" "Configuration check is done: OK!"
	fi 
}


init() {
	clear_screen
	run_singleton
	
	init_globals
	manage_oauth2_tokens
	set_cleanup_traps

	test_onedrive_status
	create_video_root_folder

	manage_video_uploads
	exit 0
}	

init