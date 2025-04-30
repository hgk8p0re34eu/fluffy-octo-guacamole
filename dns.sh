#!/bin/bash

#attempt at DNS report section automation

#TODO add zone transfer checks at end
#for i in $(cat NS_records);do dig axfr "$domain" @"$i" +short | sed "s/^; //;s/\.$//" >> testAxfrOutput;done
#awk '{print $3, $1}' FS="," OFS="," NS_ips > testNsOutput
#paste -d "," testNsOutput testAxfrOutput

#TODO add DMARC check
#dig -t TXT _dmarc."$domain" @"$server" +short

#make a working directory
mkdir -p ~/Desktop/dnsResults
cd ~/Desktop/dnsResults

#get target
read -p "Target domain: " domain

#get DNS server
read -p "Desired DNS server (defaults to 1.1.1.1 if left blank):" server
if [ -z $server ]; then
	server=1.1.1.1
fi

#send stderr to file for rest of script
exec 2>~/Desktop/dnsResults/error.log

#use dig for each record type and prune output files for later use
recordtypes='A AAAA SOA NS MX CNAME PTR TXT LOC'

echo ""
echo "Querying DNS records for $domain..."
for type in $recordtypes
do
    dig @$server -t $type $domain +short > "$type"_records
    sed -i "s/\. .*//" "$type"_records
    sed -i "s/\.$//" "$type"_records
    sort -u -o ${type}_records ${type}_records
done

#edit MX records specifically to eliminate leading numbers
sed -i "s/^[[:digit:]]\+ //" MX_records

#get IP addresses and create copy and pastable results
hostnametypes='SOA NS MX PTR CNAME'

for type in $hostnametypes; do
    file="${type}_records"
    : > ${type}_ips
    while read line; do
        echo -n "\"" >> ${type}_ips
        dig @$server -t A "$line" +short | sort -u -t. -n -k1,1 -k2,2 -k3,3 -k4,4 >> ${type}_ips
        dig @$server -t AAAA "$line" +short | sort -u -t: -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 -k6,6 -k7,7 -k8,8 >> ${type}_ips
        printf %s "$(< ${type}_ips)" > ${type}_ips
        echo "\",$type,$line" >> ${type}_ips
    done < "$file"
done

#display some results to stdout for convenience
for type in $recordtypes; do
    echo ""
    echo "$type records:"
    cat ${type}_records
done

#print copy and pastable results to stdout and a file for reporting
echo "" | tee -a dnsResults.out
echo "--------------------------------------" | tee -a dnsResults.out
echo "copy and pastable results:" | tee -a dnsResults.out
echo "" | tee -a dnsResults.out

for type in { A AAAA }; do
    if [ -s ${type}_records ]
    then
        echo -n "\"" | tee -a dnsResults.out
        printf %s "$(< ${type}_records)" | tee -a dnsResults.out
        echo "\"",$type,$domain | tee -a dnsResults.out
    fi
done

for type in $hostnametypes; do
    cat ${type}_ips | tee -a dnsResults.out
done

sed "s/^/,TXT,/" TXT_records | tee -a dnsResults.out

sed "s/^/,LOC,/" LOC_records | tee -a dnsResults.out
