#!/bin/bash
# wifi-fix: if Intel WiFi (en1) is down after boot, restart airportd to retrigger auto-join
WAIT=30
for i in $(seq 1 6); do
    S=$(ifconfig en1 2>/dev/null | grep -c "status: active")
    if [ "$S" -ge 1 ]; then
        logger "wifi-fix: en1 already active, nothing to do"
        exit 0
    fi
    sleep 10
done
logger "wifi-fix: en1 inactive after boot, restarting airportd"
killall airportd 2>/dev/null
sleep 20
S=$(ifconfig en1 2>/dev/null | grep -c "status: active")
if [ "$S" -ge 1 ]; then
    logger "wifi-fix: en1 recovered after airportd restart"
else
    logger "wifi-fix: en1 still down after airportd restart"
fi
