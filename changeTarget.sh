#!/bin/zsh

#a simple script to automate updating of HTB Academy target IPs to a $target variable
#TODO: consider input filtering or support for other shells like bash

#if no argument was supplied, print usage
if [ -z $1 ] || [ $1 = -h ] || [ $1 = --help ]
then
	echo "Usage -- changeTarget.sh <targetIP>"
	exit 0
fi

#assign supplied argument to a variable for use later
newtarget=$1

#check if "export target" exists in ~/.zshrc
grep "export target" ~/.zshrc 1>/dev/null
exitstatus=$?

#if it wasn't found, append it
if [ $exitstatus -eq 1 ]
then
	echo "export target="$newtarget"" >> ~/.zshrc
#if it was found, edit it
elif [ $exitstatus -eq 0 ]
then
	sed -i "s/export target=.*/export target="$newtarget"/" ~/.zshrc
#or if grep errored out
else
	echo "Problem...is ~/.zshrc present? Is there a "target" variable?"
	exit $exitstatus
fi

echo "--------------tail -n 1 ~/.zshrc--------------"
tail -n 1 ~/.zshrc

echo "--------------source ~/.zshrc--------------"
source ~/.zshrc

echo "--------------echo \$target--------------"
echo $target

echo "Please start a new terminal session for changes to take effect"
