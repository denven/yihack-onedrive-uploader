#!/bin/sh

clear_screen() {
	printf "\ec"
}

enable_auto_start() {
	local auto_start_file="${YI_HACK_ROOT}/startup.sh"
	[ -f "${auto_start_file}" ] || touch ${auto_start_file} 
	
	local has_init_line=$(grep "cd ${UPLOADER_ROOT} && ./init.sh" ${auto_start_file})
	
	if [ -z "${has_init_line}" ]; then 
		echo "cd ${UPLOADER_ROOT} && ./init.sh >> ${UPLOADER_ROOT}/log/terminal 2>&1 &" >> ${auto_start_file}
		color_print "GREEN" "Enabled OneDrive Uploader auto-run when camera boots up."
	fi 
}

run_singleton() {
	for pid in $(ps -a | grep \.init\.sh | grep -v grep | awk '{print $1}'); do 
		if [ ${pid} -ne $$ ]; then 
			kill -9 $pid &> /dev/null
		fi  
	done
}

# param: $1=past_ts
get_elipsed_minutes() {
	current_ts=$(date +%s)
	echo $(((${current_ts}-$1)/60))
}

color_print() {
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	BROWN='\033[0;33m'
	PINK='\033[0;35m'

	# bold text with color
	B_RED='\033[1;31m'
	B_GREEN='\033[1;32m'
	B_BROWN='\033[1;33m'
	B_PINK='\033[1;35m'

	# bold text with color
	BG_RED='\033[41;32m'

	# SHINE='\033[33;5m'
	RESET='\033[0m'

	if [ "$#" -eq 1 ]; then
		echo -e $1 #"${RED}$1${RESET}"
	elif [ "$#" -eq 2 ]; then
		eval COLOR=\$$1
		echo -e "${COLOR}$2${RESET}"
		# echo -e $2
	fi
}

encodeurl() {
    old_lc_collate=$LC_COLLATE
    LC_COLLATE=C
    local i=1
    local length="${#1}"
    while [ $i -le $length ]
    do
        local c=$(echo "$(expr substr $1 $i 1)")
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            ' ') printf "%%20" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
        i=`expr $i + 1`
    done

    LC_COLLATE=$old_lc_collate
}

# encode url by curl
encodeurl2() {
	curl -s -o /dev/null -w "%{url_effective}" --get --data-urlencode "$1" "" | cut -b3-
}

get_file_size() {
	# file_size=$(stat -c%s "$1") # not portable
	# file_size=$(wc -c < "$1") # not portable
	# du -b $1 | awk '{print $1}' # not working on camera
	# du -a $1 | awk '{print $1}' # working on camera, but not accurate, it shows kb value
	# ls -l $1 | cut -d" " -f5 # not working on camera
	if [ -f "$1" ]; then
		ls -l $1 | awk '{print $5}' # working
	else 
		echo 0
	fi 
}

# returns a number without %
get_percent() {
	echo $1 $2 | awk '{printf "%.2f%", 100*($1/$2)}'
}

# param: $1=the number of bytes
# return: e.g. 1.21MB
get_human_readble_size() {
	echo $1 | awk '{ split( "Byte KB MB GB TB", units ); s=1; while( $1>1024 ){ $1/=1024; s++ } printf "%.2f%s", $1, units[s] }'
}

# params: $1=free_ratio, $2=threshold_to_clean
# return 0 or 1(need to start auto-clean)
evaluate_auto_clean() {
	echo $1 $2 | awk '{if ($1 > $2) {print 1} else {print 0}}'
	# echo $1 $2 | awk '{if (($1 <= 100-$2)) {print 1} else {print 0}}'
}

write_log() {
	echo `date +"%F %H:%M:%S"`": $*" >> ./log/logs
	# echo `date`": $*" | tee -a logs # to be tested
}

# backup log file to *.old when it is larger than 1MB
process_log_file() {
	for log_file in ./log/*; do
		if [ $(ls -l ${log_file} | awk '{print $5}') -gt 1048576 ] && [ -z $(echo "${log_file}" | grep "old") ]; then
			if [ -f ${log_file}.old ]; then 
				dd if=${log_file} of=${log_file}.old > /dev/null 
			else 
				cp ${log_file} ${log_file}.old 
			fi 
			echo > ${log_file} 
		fi 
	done 
}

set_cleanup_traps() {
	trap "exit" INT TERM
	trap "kill 0" EXIT
}

# not working currently
jq_update_json() {
	touch tmpfile
	key_value="'.$1 = \$a'"
	echo $key_value
	# working
	# jq --arg a "$2" '.'address = $a' config.json > tmpfile && mv -- tmpfile config.json
	# not working
	# jq --arg a "$2" ${key_value} config.json > tmpfile && mv -- tmpfile config.json && rm -f tmpfile
	# works
	# jq '.address = "abcde"' config.json > tmpfile && mv -- tmpfile config.json && rm -f 
}


# auto calculate the seconds offset between local timezone and UTC-0, not used due to the issue
# when the script is executed from boot, it always returns 0 since the new hack version v0.4.9
# has reset the timezone to UTC rather than using the user-configured timezone before scripts run.
get_timezone_seconds_delta() {
	local local_now=$(date +%Y%m%d\ %H:%M:%S)  # e.g. 20230424 23:40:20
	local utc_now=$(date -u +%Y%m%d\ %H:%M:%S) # e.g. 20230425 06:40:20
	local local_ts=$(date -d "${local_now:0:4}-${local_now:4:2}-${local_now:6:2} ${local_now:9:2}:${local_now:12:2}:${local_now:15:2}" +%s)
	local utc_ts=$(date -d "${utc_now:0:4}-${utc_now:4:2}-${utc_now:6:2} ${utc_now:9:2}:${utc_now:12:2}:${utc_now:15:2}" +%s)
	echo $((local_ts-utc_ts))
}


# make sure use TZ string instead of timezone geographic string
get_timezone_offset_seconds() {
    local TZ_string=$1
    local local_now=$(TZ=$TZ_string date +"%Y%m%d %H:%M:%S")	
	local utc_now_ts=$(date -u +%s)	
	local local_now_ts=$(date -d "${local_now:0:4}-${local_now:4:2}-${local_now:6:2} ${local_now:9:2}:${local_now:12:2}:${local_now:15:2}" +%s)
	echo $((local_now_ts-utc_now_ts))
}

# convert the folder name to the name labeled by local time instead of UTC, 
# for example: 2023Y04M23D14H -> 2023Y04M23D07H
convert_pathname_from_utc_to_local() {
	if [ "${convert_utc_path_name}" = true ]; then 
		local hourly_path=$1
		local timestamp=$(date -d "${hourly_path:0:4}-${hourly_path:5:2}-${hourly_path:8:2} ${hourly_path:11:2}:00:00" +%s)
		local timestamp=$((timestamp+timezone_offset_seconds))		
		echo $(date -d "@$timestamp" +"%YY%mM%dD%HH")
	else
		echo $1
	fi
}