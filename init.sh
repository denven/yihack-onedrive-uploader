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
	auto_clean_threshold=90  # remaining space threshold
	DRIVE_BASE_URI="https://graph.microsoft.com/v1.0/me/drive"
	SD_RECORD_ROOT="/tmp/sd/record"

	mkdir -p data log # prepare folders to store upload info and logs

	color_print "GREEN" "Checking your OneDrive-uploader configuration..."
	if [ ! -f ./config.json ]; then
		echo '{ "grant_type": "", "client_id": "", "client_secret": "", "tenant_id": "" }' \
		| jq -M '. + {"video_root_folder": "yihack_videos", "auto_clean_threshold": "90", "enable_idle_transfer": "false"}' \
		> config.json
		color_print "BROWN" "A template config.json file is generated for you, please fill in it and try again."
		exit 0
	else
		auto_clean_threshold=$(jq --raw-output '.auto_clean_threshold' config.json)	
		if [ "${auto_clean_threshold}" = "null" ]; then
			auto_clean_threshold=90
		fi	
	fi
}

test_onedrive_status() {		
	get_my_drive_info # test drive access
	if [ ! -z "${error}" ] && [ "${error}" != "null" ]; then
		color_print "RED" "You don't have the access to the drive, please check your config.json file."
		exit 1
	else
		check_drive_free_space "1st-time"
		color_print "GREEN" "Your OneDrive access is available."
	fi
}

create_video_root_folder() {
	video_root_folder=$(jq --raw-output '.video_root_folder' config.json)
	video_root_folder_id=$(jq --raw-output '.video_root_folder_id' config.json)
	# echo $video_root_folder $video_root_folder_id

	local need_create=true
	if [ ! -z "${video_root_folder_id}" ] && [ "${video_root_folder_id}" != "null" ]; then
		get_drive_item ${video_root_folder_id}
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
			color_print "GREEN" "Configuration is done."
			break
		fi
	else
		color_print "GREEN" "You've already specified the folder '${video_root_folder}' to store your video files."		
		color_print "B_GREEN" "Configuration check is done: OK"
	fi 
}


init() {
	clear_screen
	init_globals

	manage_oauth2_tokens
	set_cleanup_traps

	test_onedrive_status
	create_video_root_folder

	manage_video_uploads

	# while [ 1 ]; do
	# 	sleep 60
	# done 	
	exit 0
}	

init