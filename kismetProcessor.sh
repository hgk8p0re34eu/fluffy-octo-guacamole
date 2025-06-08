#!/bin/bash

#script to process a previously recorded kismetdb log file for desired info

#TODO consider adding functionality to query for captured handshakes
#https://www.kismetwireless.net/docs/api/wifi_dot11/#wpa-handshake
#curl -H 'Content-Type: application/json' -X GET \
#http://kismet:kismet@localhost:2501/phy/phy80211/by-key/<apDeviceKey>/device/<clientMAC>/pcap/handshake.pcap -o <filename.pcap>

#check for needed packages
if [ -z $(jq -V 2>/dev/null) ];then
	echo "jq not detected, please install jq" 1>&2
	exit 1
fi

if [ -z $(curl -V 2>/dev/null | head -c 4) ];then
	echo "curl not detected, please install curl" 1>&2
	exit 1
fi

if [ -z $(kismet -v 2>/dev/null | head -c 6) ];then
	echo "Kismet not detected, please install Kismet" 1>&2
	exit 1
fi

#initilization for API useage
#check for presence of config file and creds therein
configFile=~/.kismet/kismet_httpd.conf

if [ ! -f "$configFile" ];then
	echo "$configFile file not found"
	read -p 'Would you like to automatically create the file and needed credentials? (y,n): ' createFileAndCreds
	if [ "$createFileAndCreds" == "y" ];then
		echo "httpd_username=kismet" >> "$configFile"
		username=kismet
		echo 'Created user "kismet"'
		echo "httpd_password=kismet" >> "$configFile"
		password=kismet
		echo 'Created password "kismet"'

	elif [ "$createFileAndCreds" == "n" ];then
		echo "Exiting with status 0"
		exit 0	
	else
		echo "Only y or n are allowed; exiting with status 1" 1>&2
		exit 1
	fi
else
	grep -q "httpd_username=" "$configFile" > /dev/null 2>&1 
	userCheck=$(echo -n "$?")
	
	grep -q "httpd_password=" "$configFile" > /dev/null 2>&1
	passCheck=$(echo -n "$?")
	
	case "$userCheck" in
		0)
			echo "Kismet username found"
			username=$(grep "httpd_username=" "$configFile" | cut -d "=" -f 2)
			;;
		1)
			echo "Kismet username not found"
			read -p 'Would you like to automatically create the needed username? (y,n): ' createUser
			if [ "$createUser" == "y" ];then
				echo "httpd_username=kismet" >> "$configFile"
				username=kismet
				echo 'Created user "kismet"'
			elif [ "$createUser" == "n" ]
			then
				echo "Exiting with status 0"
				exit 0	
			else
				echo "Only y or n are allowed; exiting with status 1" 1>&2
				exit 1
			fi
			;;
	esac
	
	case "$passCheck" in
		0)
			echo "Kismet password found"
			password=$(grep "httpd_password=" "$configFile" | cut -d "=" -f 2)
			;;
		1) 
			echo "Kismet password not found"
			read -p 'Would you like to automatically create the needed password? (y,n): ' createPass
			if [ "$createPass" == "y" ];then
				echo "httpd_password=kismet" >> "$configFile"
				password=kismet
				echo 'Created password "kismet"'
			elif [ "$createPass" == "n" ];then
				echo "Exiting with status 0"
				exit 0	
			else
				echo "Only y or n are allowed; exiting with status 1" 1>&2
				exit 1
			fi
			;;
	esac
fi

#get kismet file to process
read -erp "Kismet file to process: " -e kismetFile
	if [ ! -f "$kismetFile" ];then
		echo "$kismetFile not found, exiting with status 1" 1>&2
		exit 1
	fi

#ask about rate-limiting packet replay
rateLimit=10000
read -p "Should packet replay be rate-limited (Default 10k pps)? (y/n/c[ustom])" rateLimiting
	case $rateLimiting in
		y)
			echo "Continuing with default rate limit of 10k pps"
			;;
		n)
			echo "Coninuing with no rate limit, beware of dropped packets"
			unset rateLimit
			;;
		c|custom)
	        	read -p "Enter desired uptake rate in packets per second: " rateLimit
			if [[ ! "$rateLimit" =~ ^[1-9][0-9]*$ ]];then
				echo "Only positive integers are allowed; exiting with status 1" 1>&2
				exit 1
			fi
			;;
		*)
			echo "Only y, n, c, or custom are allowed; exiting with status 1" 1>&2
	        	exit 1
			;;
	esac

#start kismet using specified file, [rate-limited], without logging, in the background
if [ -z "$rateLimit" ];then
	echo "Starting Kismet and replaying file $kismetFile at unlimited pps"
	( kismet --no-logging -c "${kismetFile}" > /dev/null 2>&1 & )
else
	echo "Starting Kismet and replaying file $kismetFile at $rateLimit pps"
	( kismet --no-logging -c "${kismetFile}":pps="${rateLimit}" > /dev/null 2>&1 & )
fi

#wait until it's finished replaying
startTime=$(date +%s)
#get the number of packets in the capture file
filePackets=$(kismetdb_statistics --in $kismetFile 2>&1 | awk '/Packets: /{print $2; exit}')
#get number of packets processed by the server 
packetsReplayed=$(curl -s -H 'Content-Type: application/json' -X POST  \
"http://${username}:${password}@localhost:2501/datasource/all_sources.prettyjson" \
-d '{"fields": ["kismet.datasource.num_packets"]}' \
 | jq '.[0]["kismet.datasource.num_packets"]')
#compare the packet counts to detect completion
while [ "$filePackets" != "$packetsReplayed" ];do
	echo -ne "\rPackets replayed: $packetsReplayed / $filePackets"
	sleep 1
	packetsReplayed=$(curl -s -H 'Content-Type: application/json' -X POST  \
	"http://${username}:${password}@localhost:2501/datasource/all_sources.prettyjson" \
	-d '{"fields": ["kismet.datasource.num_packets"]}' \
	 | jq '.[0]["kismet.datasource.num_packets"]')
	
	currentTime=$(date +%s)
	elapsedTime=$(($currentTime - startTime))
	if [ "$elapsedTime" -ge 30 ]; then
		echo "Warning: 30 seconds have passed and replay is not complete" 1>&2
		read -p "Continue? (y/n): " keepGoing
		case $keepGoing in
			y) 
				startTime=$(date +%s)
				;;
			n)
				echo "Replay incomplete; exiting with status 1" 1>&2
				exit 1
				;;
			*)
				echo "Only y or n are allowed; exiting with status 1" 1>&2
				exit 1
				;;
		esac
	fi
done
echo -ne "\rPackets replayed: $packetsReplayed / $filePackets"
echo ""

#query kismet API for interesting data
#consider also "kismet.device.base.key"
dataFile=$(mktemp -p /tmp kismetProcessor_XXXXXX)
curl -s -o "${dataFile}" -H 'Content-Type: application/json' -X POST  \
http://${username}:${password}@localhost:2501/devices/views/phydot11_accesspoints/devices.prettyjson \
-d '{"fields": ["kismet.device.base.macaddr", "dot11.device/dot11.device.last_beaconed_ssid_record/dot11.advertisedssid.ssid", "kismet.device.base.crypt", "dot11.device/dot11.device.last_beaconed_ssid_record/dot11.advertisedssid.channel", "kismet.device.base.frequency", "dot11.device/dot11.device.num_associated_clients", "dot11.device/dot11.device.associated_client_map", "kismet.device.base.signal/kismet.common.signal.min_signal", "kismet.device.base.signal/kismet.common.signal.max_signal"]}'
echo "Device JSON data saved to $dataFile"

#create output csv file
outFile="${kismetFile}_processed_$(date +%m%d%y%H%M%S).csv"
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
