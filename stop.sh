#!/bin/sh

# maintanence script for stop the uploader

for pid in $(ps -a | grep \.init\.sh | grep -v grep | awk '{print $1}'); do 
	kill -9 $pid &> /dev/null
done