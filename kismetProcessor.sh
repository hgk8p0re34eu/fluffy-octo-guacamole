#!/bin/bash

#script to process a previously recorded kismetdb file for desired info

#TODO consider adding support for a list of input files
#TODO see if I can refine the stop the server section at the end
#TODO consider refining usage with printf
#TODO consider adding functionality to query for captured handshakes
#https://www.kismetwireless.net/docs/api/wifi_dot11/#wpa-handshake
#curl -H 'Content-Type: application/json' -X GET \
#http://kismet:kismet@localhost:2501/phy/phy80211/by-key/<apDeviceKey>/device/<clientMAC>/pcap/handshake.pcap -o <filename.pcap>
#bonkers one-liner to do that for all clients in one AP:
#i=1;apdevicekey="4202770D00000000_16935BA82A86";for clientmac in "18:B1:69:2A:08:AC" "C2:E8:76:34:9B:C0" "3C:06:30:35:D1:46" "76:98:AB:3E:43:FF" "86:36:F5:78:A8:12";do curl -H 'Content-Type: application/json' -X GET \
#http://kismet:kismet@localhost:2501/phy/phy80211/by-key/"${apdevicekey}"/device/"${clientmac}"/pcap/handshake.pcap -o handshake"${i}".pcap;((i++));done

#establish required packages
requiredPackages=(
	awk
	curl
	grep
	jq
	kismet
	kismetdb_statistics
	pgrep
)
#set default rateLimit
rateLimit=10000
#default Kismet config file
configFile=~/.kismet/kismet_httpd.conf
#centralize array of error flags
errorFlags=(
	optionConflict
	configFileError
	credError
	kismetFileNotFound
	invalidRate
)

#define usage function
usage() {
	echo "Usage: kismetProcessor.sh [OPTION] ..."
	echo "A script to process a previously recorded kismetdb file for desired info"
	echo ""
	echo "-c FILE		Kismet config file from which to read API credentials (default ~/.kismet/kismet_httpd.conf, cannot be used with -n)"
	echo "-f FILE		kismetdb file to process (required)"
	echo "-h		print this help message, then exit"
	echo "-n FILE		create and use a Kismet config file with credentials kismet:kismet (cannot be used with -c)"
	echo "-r RATE		custom rate-limit packet replay to Kismet server (default 10k pps)"
	echo ""
	echo "This script requires the commands (part of X apt package in Kali): awk (mawk|gawk), curl, grep, jq, kismet (kismet-core), kismetdb_statistics (kismet-logtools), and pgrep (procps)"
	exit 0
}

#parse arguments
while getopts "c:f:hn:r:" opt;do
	case "$opt" in
		c )
			opt_c=1
			configFile=$OPTARG
			;;
		f )
			kismetFile="$OPTARG"
			if [[ ! -r $kismetFile ]];then
				echo "$kismetFile not found or not readable, exiting with status 1" 1>&2
				kismetFileNotFound=1
			fi
			;;
		h )
			showHelp=1
			;;
		n)
			opt_n=1
			configFile=$OPTARG
			;;
		r )
			rateLimit="$OPTARG"
			#ensure input is valid
			if [[ ! $rateLimit =~ ^[1-9][0-9]*$ ]];then
				echo "Only positive integers are allowed; exiting with status 1" 1>&2
				invalidRate=1
			fi
			;;
		\? )
			echo "Invalid option; exiting with status 1" >&2
			exit 1
			;;
		esac
done

#print usage if requested or if no options provided
if (( OPTIND == 1 || showHelp == 1 ));then
	usage
	exit 0
fi

#check for needed packages beyond bash and coreutils
for req in "${requiredPackages[@]}";do
	if ! command -v "$req" > /dev/null 2>&1;then
		echo "$req package is required, but is not available, exiting with status 1" 1>&2
		exit 1
	fi
done

#if option c was chosen
if (( opt_c ));then
	if (( opt_n ));then
		echo "-n cannot be supplied with -c, exiting with status 1" 1>&2
		optionConflict=1
	fi
	if [[ ! -r $configFile ]];then
		echo "$configFile file not found or not readable, exiting with status 1" 1>&2
		configFileError=1
	fi
fi

#get creds from config file
username=$(grep "^httpd_username=.*$" "$configFile" | cut -d "=" -f 2)
password=$(grep "^httpd_password=.*$" "$configFile" | cut -d "=" -f 2)
if [[ -z $username || -z $password ]];then
	echo "Kismet username or password not found in $configFile, exiting with status 1" 1>&2
	credError=1
fi

#if option n was chosen
if (( opt_n ));then
	if (( opt_c ));then
		echo "-c cannot be supplied with -n, exiting with status 1" 1>&2
		optionConflict=1
	fi
	if [[ -e $configFile ]];then
		echo "$configFile already exists, exiting with status 1" 1>&2
		configFileError=1
	else
		username=kismet
		password=kismet
		echo "httpd_username=$username" >> "$configFile"
		echo "Created user $username"
		echo "httpd_password=$password" >> "$configFile"
		echo "Created password $password"
	fi
fi

#exit if errors were found
for flag in "${errorFlags[@]}";do
	if (( $flag ));then
		exit 1
	fi
done
if [[ -z $kismetFile ]];then
	echo "-f option is required but was not provided, exiting with status 1" 1>&2
	exit 1
fi

#start kismet using specified file, rate-limited, without logging, in the background
startTime=$(date +%s)
echo "Starting Kismet and replaying file $kismetFile at $rateLimit pps"
( kismet --no-logging --no-ncurses --no-line-wrap -c "${kismetFile}":pps="${rateLimit}" > /dev/null 2>&1 & )

#wait until it's finished replaying
#get the number of packets in the capture file
filePackets=$(kismetdb_statistics --in $kismetFile 2>&1 | grep -m 1 "Packets:" | cut -d " " -f 4)
#get number of packets processed by the server 
packetsReplayed=$(curl -s -H 'Content-Type: application/json' -X POST \
"http://${username}:${password}@localhost:2501/datasource/all_sources.prettyjson" \
-d '{"fields": ["kismet.datasource.num_packets"]}' \
 | jq '.[0]["kismet.datasource.num_packets"]')
#compare the packet counts to detect completion
while [ "$filePackets" != "$packetsReplayed" ];do
	echo -ne "\rPackets replayed: $packetsReplayed / $filePackets"
	sleep 0.25s
	packetsReplayed=$(curl -s -H 'Content-Type: application/json' -X POST \
	"http://${username}:${password}@localhost:2501/datasource/all_sources.prettyjson" \
	-d '{"fields": ["kismet.datasource.num_packets"]}' \
	 | jq '.[0]["kismet.datasource.num_packets"]')
	currentTime=$(date +%s)
	elapsedTime=$(($currentTime - startTime))
done
echo -ne "\rPackets replayed: $packetsReplayed / $filePackets in ${elapsedTime}s"
echo ""

#query kismet API for interesting data
#consider also "kismet.device.base.key"
dataFile=$(mktemp -p /tmp kismetProcessor_XXXXXX)
curl -s -o "${dataFile}" -H 'Content-Type: application/json' -X POST  \
http://${username}:${password}@localhost:2501/devices/views/phydot11_accesspoints/devices.prettyjson \
-d '{"fields": ["kismet.device.base.macaddr", "dot11.device/dot11.device.last_beaconed_ssid_record/dot11.advertisedssid.ssid", "kismet.device.base.crypt", "dot11.device/dot11.device.last_beaconed_ssid_record/dot11.advertisedssid.channel", "kismet.device.base.frequency", "dot11.device/dot11.device.num_associated_clients", "dot11.device/dot11.device.associated_client_map", "kismet.device.base.signal/kismet.common.signal.min_signal", "kismet.device.base.signal/kismet.common.signal.max_signal"]}'
echo "Device JSON data saved to $dataFile"

#create output csv file in the current working directory
outFile="${kismetFile##*/}_processed_$(date +%m%d%y%H%M%S).csv"
echo '"Advertised SSID","MAC","Crypt","Channel","Min","Max"' > "$outFile"
#extract and format relevant data from downloaded JSON
jq '.[] | .["dot11.advertisedssid.ssid"],.["kismet.device.base.macaddr"],.["kismet.device.base.crypt"],.["dot11.advertisedssid.channel"],.["kismet.common.signal.min_signal"],.["kismet.common.signal.max_signal"]' "$dataFile" | \
awk '
{
    lines[NR % 6] = $0
    if (NR % 6 == 0) {
        for (i = 1; i <= 6; i++) {
            printf "%s%s", lines[i], (i < 6 ? "," : $0"\n")
        }
    }
}
' | sort -t',' -k1 >> "$outFile"
echo "Device data processed into $outFile"

#stop the kismet server

pid1=$(pgrep -nl "kismet$" | awk 'NR == 1 {print $1}')
pid2=$(pgrep -nl "kismet_cap_kism" | awk 'NR == 1 {print $1}')
kill "$pid1"
kill "$pid2"

timeout 5 pidwait "$pid1"
sleep 1

case $? in
	0)
		echo "Kismet server stopped; exiting"
		exit 0
		;;
	1)
		echo "Warning: Problem stopping kismet server; exiting with status 1" 1>&2
		exit 1
		;;
	*)
		echo "Warning: Problem stopping kismet server; exiting with status $?" 1>&2
		exit "$?"
		;;	
esac
