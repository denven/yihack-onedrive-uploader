#!/bin/sh

clear_screen() {
	printf "\ec"
}

enable_auto_start() {
	local auto_start_file="/tmp/sd/yi-hack/startup.sh"

	[ -f "${auto_start_file}" ] || touch ${auto_start_file} 

	if [ -z "$(grep 'cd /tmp/sd/yi-hack/onedrive/ && ./init.sh' ${auto_start_file})" ]; then 
		echo 'cd /tmp/sd/yi-hack/onedrive/ && ./init.sh >> ./log/terminal &' >> ${auto_start_file}
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

get_percentage() {
	echo $1 $2 | awk '{printf "%.2f%%", $1/$2*100}'
}

# param: $1=the number of bytes
# return: e.g. 1.21MB
get_human_readble_size() {
	echo $1 | awk '{ split( "Byte KB MB GB TB", units ); s=1; while( $1>1024 ){ $1/=1024; s++ } printf "%.2f%s", $1, units[s] }'
}

# params: $1=free_ratio, $2=threshold_to_clean
# return 0 or 1(need to start auto-clean)
evaluate_auto_clean() {
	echo $1 $2 | awk '{if (($1 <= 100-$2) && ($2 >= 50)) {print 1} else {print 0}}'
	# echo $1 $2 | awk '{if (($1 <= 100-$2)) {print 1} else {print 0}}'
}

write_log() {
	echo `date`": $*" >> ./log/logs
	# echo `date`": $*" | tee -a logs # to be tested
}

# backup log file to *.old when it is larger than 1MB
process_log_file() {
	for log_file in ./log/*; do
		if [ $(ls -l ${log_file} | awk '{print $5}') -gt 1048576 ] && [ -z $(echo "${log_file}" | grep "old") ]; then
			mv ${log_file} ${log_file}.old 
			touch ${log_file} 
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