#!/bin/bash

#script to automate my process of enumerating subdomains for a target domain
#requires curl jq xmlstarlet theHarvester spiderfoot recon-ng

#TODO evaluate functionality for sub-sub domains ad infinitum
#TODO make it possible to re-run one or more modules
#TODO consider adding a manual brute-force module usings seclists
#TODO consider adding some form of vhost enumeration, possibly off the main domain's A record (gobuster can do this)
#TODO consider exploiting browser-based Censys results...
#TODO consider adding a check for theharvester vs theHarvester
#TODO consider also using amass tool https://0xpatrik.com/subdomain-takeover-candidates/
#TODO consider adding a wildcard DNS check (super-bogus domain) maybe with option to continue or abort (gobuster can do this)

#could add shodan (prettyify json first might make it easier to find multiple matches that are otherwise on one line)
#curl -O -i -X GET "https://api.shodan.io/shodan/host/${ip}?history=true&key={key}
#grep -Po "hostnames.*?\]" 192* | grep -v "\[\]" | cut -d " " -f2 | sort | uniq -c | sort -ru
#grep -Po "domains.*?\]" 192* | grep -v "\[\]" | cut -d " " -f2 | sort | uniq -c | sort -ru
#grep -Po "redirects.*?\]" 192* | grep -v "\[\]" | grep -Po "http.*? " | sort | uniq -c | sort -ru
#non greedy match multiples on one line with perl
#perl -nle 'print join(", ", /(hostnames.*?\])/g)' <file>

#make a working directory
mkdir -p ~/Desktop/subdomains
cd ~/Desktop/subdomains

#get target
read -p "Target domain: " domain
read -p "Time in minutes to allow Spiderfoot to run (default 5 if left blank): " spidertime
if [ -z $spidertime ]; then
    spidertime=5
fi

#send stderr to a logfile
exec 2>~/Desktop/subdomains/error.log

#query crt.sh
echo "------------------"
echo "Querying crt.sh..."
echo "------------------"
curl -sS "https://crt.sh/?q=${domain}&output=json" > crtsh.out
cat crtsh.out | jq -r '.[] | "\(.name_value)\n\(.common_name)"' | sort -u > crtshSubdomains.lst
numsubs=$(wc -l crtshSubdomains.lst | sed "s/ crtshSubdomains.lst//")
echo "--------------------------------"
echo "Found $numsubs subdomains from crt.sh"
echo "--------------------------------"
echo ""

#censys API is no longer available free
##query censys
#echo "----------------------"
#echo "Querying Censys API..."
#echo "----------------------"
#curl -sS -g -X "GET" "https://search.censys.io/api/v2/hosts/search?per_page=100&virtual_hosts=INCLUDE&q=$domain" -H "Accept: application/json" --user "<apiKey>" -o censys.out
##and format the results
#grep -Po "\"name\":.*?," censys.out | grep -v "\"$domain\"" | grep "$domain" | sed "s/\"name\": \"//;s/\".*//" > censysSubdomains.lst

#query robtex
echo "----------------------"
echo "Querying robtex.com..."
echo "----------------------"
curl -sS "https://www.robtex.com/dns-lookup/$domain" -o robtex.out
#and format the results
grep -Pio "subdomains.*?results shown" robtex.out | grep -Po "(?<=dns-lookup\/).*?$domain" > robtexSubdomains.lst
numsubs=$(wc -l robtexSubdomains.lst | sed "s/ robtexSubdomains.lst//")
echo "------------------------------------"
echo "Found $numsubs subdomains from robtex.com"
echo "------------------------------------"
echo ""

#query dnsdumpster
echo "----------------------------"
echo "Querying DNS Dumpster API..."
echo "----------------------------"
curl -sS "https://api.hackertarget.com/hostsearch/?q=$domain" -o dnsdumpster.out
#and format the results
grep -Po "^.*?$domain" dnsdumpster.out | grep -Ev "^$domain\$" > dnsdumpsterSubdomains.lst
numsubs=$(wc -l dnsdumpsterSubdomains.lst | sed "s/ dnsdumpsterSubdomains.lst//")
echo "--------------------------------------"
echo "Found $numsubs subdomains from DNS Dumpster"
echo "--------------------------------------"
echo ""

#configure and run recon-ng
echo "----------------------------------"
echo "Setting up and running recon-ng..."
echo "----------------------------------"
recon-cli -w $domain -C "marketplace install recon/domains-hosts/bing_domain_web" -C "marketplace install recon/domains-hosts/brute_hosts" -C "marketplace install reporting/list" > /dev/null
printf "%s\n" $domain none | recon-cli -w $domain -C "db insert domains" > /dev/null
echo "Running bing_domain_web module..."
recon-cli -w $domain -m "recon/domains-hosts/bing_domain_web" -x > /dev/null
echo "Running brute_hosts module..."
recon-cli -w $domain -m "recon/domains-hosts/brute_hosts" -x > /dev/null
recon-cli -w $domain -m "reporting/list" -o FILENAME="$PWD/reconng.out" -o COLUMN=host -x > /dev/null
#and format the output
sort -u reconng.out > reconngSubdomains.lst
numsubs=$(wc -l reconngSubdomains.lst | sed "s/ reconngSubdomains.lst//")
echo "----------------------------------"
echo "Found $numsubs subdomains from recon-ng"
echo "----------------------------------"
echo ""

#run spiderfoot
echo "------------------------------------"
echo "Running spiderfoot for $spidertime minutes..."
echo "------------------------------------"
timeout -s SIGINT "$spidertime"m spiderfoot -s $domain -t INTERNET_NAME,EMAILADDR -H -f -u passive  > spiderfoot.out 2>&1
#and format the results
grep -o "Found.*: .*\.$domain$" spiderfoot.out | sed "s/Found.*: //" > spiderfootSubdomains.lst
#extract found emails
grep -o "Found e-mail.*$" spiderfoot.out | sed "s/Found.*: //" > spiderfootEmails.lst
numsubs=$(wc -l spiderfootSubdomains.lst | sed "s/ spiderfootSubdomains.lst//")
numemails=$(wc -l spiderfootEmails.lst | sed "s/ spiderfootEmails.lst//")
echo "------------------------------------"
echo "Found $numsubs subdomains from Spiderfoot"
echo "Found $numemails emails from Spiderfoot"
echo "------------------------------------"
echo ""

#run theHarvester
echo "-----------------------"
echo "Running theHarvester..."
echo "-----------------------"
theHarvester -d $domain -v -e 1.1.1.1 -s -f harvester -b anubis,baidu,bing,certspotter,duckduckgo,hackertarget,otx,rapiddns,threatminer,urlscan,yahoo > /dev/null
#and format the results
xmlstarlet ed -d theHarvester/host/ip -d /theHarvester/host/hostname harvester.xml | xmlstarlet sel -t -v theHarvester/host | sort -u > harvesterSubdomains.lst
#list found emails
xmlstarlet sel -t -v theHarvester/email harvester.xml > harvesterEmails.lst; echo "" >> harvesterEmails.lst
numsubs=$(wc -l harvesterSubdomains.lst | sed "s/ harvesterSubdomains.lst//")
numemails=$(wc -l harvesterEmails.lst | sed "s/ harvesterEmails.lst//")
echo "--------------------------------------"
echo "Found $numsubs subdomains from theHarvester"
echo "Found $numemails emails from theHarvester"
echo "--------------------------------------"
echo ""

#concatenate and sort all formatted subdomain lists
cat *Subdomains.lst | tr "[:upper:]" "[:lower:]" | grep $domain | grep -v "\*" | grep -v "^$domain\$" | sort -u > allReportedSubdomains
#concatenate and sort all formatted email lists
cat *Emails.lst | tr "[:upper:]" "[:lower:]" | sort -u > ${domain}_Emails

#test that list for resolvable hosts
echo "----------------------"
echo "Resolving $(wc -l allReportedSubdomains | sed "s/ allReportedSubdomains//") hosts..."
echo "----------------------"
xargs -a allReportedSubdomains -I subd host subd 1.1.1.1 > hostResults.out
#and format the results
grep "$domain has address" hostResults.out > resolvableSubdomains
grep "$domain is an alias for" hostResults.out >> resolvableSubdomains
sed "s/\($domain\) has address.*/\1/;s/\($domain\) is an alias.*/\1/" resolvableSubdomains | grep -v "^$domain\$" | sort -u > ${domain}_Subdomains
#and create report copy/paste output
grep "has address\|is an alias for" hostResults.out | grep "$domain" | sed "s/ has address /,/;s/ is an alias for /,/;s/\.$//" > ${domain}_report.csv

#report final subdomain count
numhosts=$(wc -l ${domain}_Subdomains | sed "s/ ${domain}_Subdomains//")
echo ""
echo "-------------------------------------------------------------"
echo "Found $numhosts resolvable subdomains for $domain"
echo "cat ~/Desktop/subdomains/${domain}_Subdomains to view"
echo "Copy and paste into OSINT report subdomain section:"
echo "~/Desktop/subdomains/${domain}_report.csv"

#report final email count
numemails=$(wc -l ${domain}_Emails | sed "s/ ${domain}_Emails//")
echo ""
echo "Found $numemails email addresses for $domain"
echo "cat ~/Desktop/subdomains/${domain}_Emails to view"
echo "-------------------------------------------------------------"
echo ""

#check all sources for output and report empties
if [ $(wc -l *Subdomains.lst | grep " 0 " | wc -l) != 0 ]; then
    echo ""
    echo "The following subdomain lists are empty, consider investigating further:"
    echo ""
    wc -l *Subdomains.lst | grep " 0 "
fi
