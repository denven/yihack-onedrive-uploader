#!/bin/sh

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
		echo $1 #"${RED}$1${RESET}"
	elif [ "$#" -eq 2 ]; then
		# eval COLOR=\$$1
		# echo "${COLOR}$2${RESET}"
		echo $2
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
	ls -l $1 | awk '{print $5}' # working

}

get_percentage() {
	echo $1 $2 | awk '{printf "%.2f%%", $1/$2*100}'
}

write_log() {
	echo `date`": $*" >> ./log/logs
	# echo `date`": $*" | tee -a logs # to be tested
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