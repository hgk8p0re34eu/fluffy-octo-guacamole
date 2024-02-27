#!/bin/zsh

#a simple script to automate updating of HTB Academy target IPs to a $target variable
#TODO: consider adding error handling or support for other shells like bash

echo "Usage -- changeTarget.sh <targetIP>"

newtarget=$(echo -n $1 | sed "s/\./\\\./g")

sed -i "s/export target=.*/export target="$newtarget"/" ~/.zshrc

echo "--------------tail -n 1 ~/.zshrc--------------"
tail -n 1 ~/.zshrc

echo "--------------source ~/.zshrc--------------"
source ~/.zshrc

echo "--------------echo $target--------------"
echo $target

echo "Please start a new terminal session for changes to take effect"
