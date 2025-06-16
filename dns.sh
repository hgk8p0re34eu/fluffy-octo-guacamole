#!/bin/bash

#automates DNS osint report section

#check for required packages
for req in { dig xclip };do
	if ! command -v $req > /dev/null 2>&1;then
		echo "Warning: $req package not found!"
	fi
done

#define usage function
usage() {
	echo "Usage: dns.sh [OPTION] ..."
	echo "Automate generation of DNS section of OSINT reports"
	echo ""
	echo "-d DOMAIN		target domain (required)"
	echo "-h			print this help message, then exit"
	echo "-n NAMESERVER		nameserver to query (defaults to 1.1.1.1)"
	echo "-x			additionally check for zone transfer"
	echo ""
	echo "This script requires the dig and xclip packages"
	exit 0
}

#parse arguments
while getopts "d:n:hx" opt;do
	case $opt in
		d )
			domain="$OPTARG"
			;;
		n )
			nameserver="$OPTARG"
			;;
		h )
			usage
			;;
		x )
			zonecheck=true
			;;
		\? )
			echo "Invalid option; exiting with status 1" >&2
			exit 1
			;;
	esac
done

if [ "$OPTIND" -lt 3 ];then
	usage
fi

if [ -z "$domain" ];then
	echo "-d DOMAIN is required; exiting with status 1"
	exit 1
fi

if [ -z "$nameserver" ];then
	echo "No nameserver specified, defaulting to 1.1.1.1"
	nameserver="1.1.1.1"
fi

#make a working directory
workingDir=~/Desktop/${domain}_dnsResults
mkdir -p "$workingDir"
cd "$workingDir"

#send stderr to file for rest of script
: > error.log
exec 2> error.log

#use dig to query for each record type
recordtypes='A AAAA SOA NS MX CNAME PTR TXT LOC'
echo "Querying DNS records for $domain..."
for type in $recordtypes;do
	dig @"${nameserver}" -t "$type" "$domain" +short > "${type}"_records
	sort -u -o "${type}"_records "${type}"_records
done

#extract just the server name from SOA records
sed -Ei "s/^([^ ]*).*/\1/" SOA_records
#edit MX records to eliminate leading preference numbers (RFC 5321)
sed -i "s/^[[:digit:]]\+ //" MX_records
#delete trailing "." of returned FQDNs
sed -i "s/\.$//" *_records

#resolve IP addresses and create copy and pastable results
hostnametypes='SOA NS MX CNAME PTR'
for type in $hostnametypes;do
	file="${type}_records"
	: > "${type}_ips"
	while read line;do
		echo -n "\"" >> "${type}_ips"
		dig @"${nameserver}" -t A "$line" +short | sort -u -t. -n -k1,1 -k2,2 -k3,3 -k4,4 >> "${type}_ips"
		dig @"${nameserver}" -t AAAA "$line" +short | sort -u -t: -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 -k6,6 -k7,7 -k8,8 >> "${type}_ips"
		printf %s "$(< ${type}_ips)" > "${type}_ips"
		echo "\",$type,$line" >> "${type}_ips"
	done < "$file"
done

#write reportable results to output file
outputFile=dnsResults.out
: > "$outputFile"
echo "copy and pastable results:" >> "$outputFile"
echo "" >> "$outputFile"
for type in { A AAAA };do
	if [ -s ${type}_records ];then
		echo -n "\"" >> "$outputFile"
		printf %s "$(< ${type}_records)" >> "$outputFile"
		echo "\",$type,$domain" >> "$outputFile"
	fi
done

for type in $hostnametypes;do
	if [ -s ${type}_ips ];then
		cat "${type}_ips" >> "$outputFile"
	fi
done

for type in { TXT LOC };do
	if [ -s ${type}_records ];then
		sed "s/^/,${type},/" "${type}_records" >> "$outputFile"
	fi
done

#if selected, perform zone transfer checks using attackvm via SSH
if [ $zonecheck == true ];then
	#set ssh connection command and result files
	attackvmConnect="ssh -J newVultr attackVM"
	outputZoneFile=zoneTransfer.out
	reportableZoneFile=zonePaste
	: > $outputZoneFile
	: > $reportableZoneFile
	#perform zone transfer checks
	for i in $(cat NS_records);do
		eval "$attackvmConnect dig axfr @$i $domain" >> $outputZoneFile
		#check if it worked
		sed -n '$!d; /failed/q42' $outputZoneFile
		sedexit="$?"
		#if zone transfer failed
		if [ $sedexit == 42 ];then
			echo "\"${i}\",\"" >> $reportableZoneFile
			printf %s "$(< $reportableZoneFile)" > $reportableZoneFile
			dig @"${nameserver}" -t A "$i" +short | sort -u -t. -n -k1,1 -k2,2 -k3,3 -k4,4 >> $reportableZoneFile
			dig @"${nameserver}" -t AAAA "$i" +short | sort -u -t: -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 -k6,6 -k7,7 -k8,8 >> $reportableZoneFile
			printf %s "$(< $reportableZoneFile)" > $reportableZoneFile
			echo "\",\"Failed\"" >> $reportableZoneFile
		#if zone transfer succeeded
		elif [ $sedexit == 0 ];then
			echo "Zone Tranfer for $i succeeded! Results saved to $workingDir/$outputZoneFile"
			echo "\"${i}\",\"" >> $reportableZoneFile
			printf %s "$(< $reportableZoneFile)" > $reportableZoneFile
			dig @"${nameserver}" -t A "$i" +short | sort -u -t. -n -k1,1 -k2,2 -k3,3 -k4,4 >> $reportableZoneFile
			dig @"${nameserver}" -t AAAA "$i" +short | sort -u -t: -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 -k6,6 -k7,7 -k8,8 >> $reportableZoneFile
			printf %s "$(< $reportableZoneFile)" > $reportableZoneFile
			echo "\",\"Success\"" >> $reportableZoneFile
		fi
	done
	#append results to output file
	echo -e "\nzone transfer copy and pastable results:\n" >> $outputFile
	cat $reportableZoneFile >> $outputFile
fi

#DMARC check
: > demarcRecord
dig -t TXT _dmarc."$domain" @"${nameserver}" +short > demarcRecord
echo -e "\nDMARC record:\n" >> $outputFile
cat demarcRecord >> $outputFile

#let the user know we're done
echo "CSV file of reportable results written to ${workingDir}/${outputFile}" 

#be super-convenient
tail -n +3 "$outputFile" | xclip -selection clipboard
echo "Results have also been copied to clipboard"
