#!/bin/sh
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data/ftp/uavpal/lib

function parse_json()
{
	echo $1 | \
	sed -e 's/[{}]/''/g' | \
	sed -e 's/", "/'\",\"'/g' | \
	sed -e 's/" ,"/'\",\"'/g' | \
	sed -e 's/" , "/'\",\"'/g' | \
	sed -e 's/","/'\"---SEPERATOR---\"'/g' | \
	awk -F=':' -v RS='---SEPERATOR---' "\$1~/\"$2\"/ {print}" | \
	sed -e "s/\"$2\"://" | \
	tr -d "\n\t" | \
	sed -e 's/\\"/"/g' | \
	sed -e 's/\\\\/\\/g' | \
	sed -e 's/^[ \t]*//g' | \
	sed -e 's/^"//'  -e 's/"$//'
}

function gpsDecimal()
{
	gpsVal=$1
	gpsDir="$2"
	gpsInt=$(echo "$gpsVal 100 / p" | /data/ftp/uavpal/bin/dc)
	gpsMin=$(echo "3k$gpsVal $gpsInt 100 * - p" | /data/ftp/uavpal/bin/dc)
	gpsDec=$(echo "6k$gpsMin 60 / $gpsInt + 1000000 * p" | /data/ftp/uavpal/bin/dc | cut -d '.' -f 1)
	if [[ "$gpsDir" != "E" && "$gpsDir" != "N" ]]; then gpsDec="-$gpsDec"; fi
	echo $gpsDec
}

ulogger -s -t uavpal_glympse "... reading Glympse API key from config file"
apikey="`head -1 /data/ftp/uavpal/conf/glympse_apikey |tr -d '\r\n' |tr -d '\n'`"
	if [ "$apikey" == "AAAAAAAAAAAAAAAAAAAA" ]; then
		ulogger -s -t uavpal_disco "... disabling Glympse, API key set to ignore"
		exit 0
	fi

ulogger -s -t uavpal_glympse "... reading Disco ID from avahi"
droneName=$(cat /tmp/avahi/services/ardiscovery.service |grep name |cut -d '>' -f 2 |cut -d '<' -f 0)

ulogger -s -t uavpal_glympse "... Glympse API: creating account"
glympseCreateAccount=$(/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -X POST "https://api.glympse.com/v2/account/create?api_key=${apikey}")

ulogger -s -t uavpal_glympse "... Glympse API: logging in"
glympseLogin=$(/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -X POST "https://api.glympse.com/v2/account/login?api_key=${apikey}&id=$(parse_json $glympseCreateAccount id)&password=$(parse_json $glympseCreateAccount password)")

ulogger -s -t uavpal_glympse "... Glympse API: parsing access token"
access_token=$(parse_json $(echo $glympseLogin |sed 's/\:\"access_token/\:\"tmp/g') access_token)

ulogger -s -t uavpal_glympse "... Glympse API: creating ticket"
glympseCreateTicket=$(/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST "https://api.glympse.com/v2/users/self/create_ticket?duration=14400000")

ulogger -s -t uavpal_glympse "... Glympse API: parsing ticket"
ticket=$(parse_json $glympseCreateTicket id)

ulogger -s -t uavpal_glympse "... Glympse API: creating invite"
glympseCreateInvite=$(/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST "https://api.glympse.com/v2/tickets/$ticket/create_invite?type=sms&address=1234567890&send=client")

message="You can track the location of your ${droneName} here: https://glympse.com/$(parse_json ${glympseCreateInvite%_*} id)"
title="${droneName}'s GPS location"

phone_no=`head -1 /data/ftp/uavpal/conf/phonenumber |tr -d '\r\n' |tr -d '\n'`
if [ "$phone_no" != "+XXYYYYYYYYY" ]; then
	ulogger -s -t uavpal_sms "... sending SMS with Glympse link"
	echo -e "AT+CMGF=1\rAT+CMGS=\"${phone_no}\"\r${message}\32" > /dev/ttyUSB2
fi

pb_access_token=`head -1 /data/ftp/uavpal/conf/pushbullet |tr -d '\r\n' |tr -d '\n'`
if [ "$pb_access_token" != "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" ]; then
	ulogger -s -t uavpal_glympse "... sending push notification"
	/data/ftp/uavpal/bin/curl -q -k -u ${pb_access_token}: -X POST https://api.pushbullet.com/v2/pushes --header 'Content-Type: application/json' --data-binary '{"type": "note", "title": "'"$title"'", "body": "'"$message"'"}'
fi

ulogger -s -t uavpal_glympse "... Glympse API: setting Disco thumbnail image"
/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST -d "[{\"t\": $(date +%s)000, \"pid\": 0, \"n\": \"avatar\", \"v\": \"https://uavpal.com/img/disco.png?$(date +%s)\"}]" "https://api.glympse.com/v2/tickets/$ticket/append_data"

ztVersion=$(/data/ftp/uavpal/bin/zerotier-one -v)

ulogger -s -t uavpal_glympse "... Glympse API: reading out Disco's GPS coordinates every 5 seconds to update Glympse via API"
while true
do
	gps_nmea_out=$(grep GNRMC -m 1 /tmp/gps_nmea_out | cut -c4-)
	lat=$(echo $gps_nmea_out | cut -d ',' -f 4)
	latdir=$(echo $gps_nmea_out | cut -d ',' -f 5)
	long=$(echo $gps_nmea_out | cut -d ',' -f 6)
	longdir=$(echo $gps_nmea_out | cut -d ',' -f 7)
	speed=$(printf "%.0f\n" $(/data/ftp/uavpal/bin/dc -e "$(echo $gps_nmea_out | cut -d ',' -f 8) 51.4444 * p"))
	heading="$(printf "%.0f\n" $(echo $gps_nmea_out | cut -d ',' -f 9))"
	altitude_abs=$(grep GNGNS -m 1 /tmp/gps_nmea_out | cut -c4- | cut -d ',' -f 10)

	if [ -f /data/ftp/internal_000/Disco/academy/*.pud.temp ]; then
		altitude_rel=$(/data/ftp/uavpal/bin/dc -e "$altitude_abs $(cat /tmp/alt_before_takeoff) - p")
	else
		echo $altitude_abs > /tmp/alt_before_takeoff
		altitude_rel="0"
  fi

	if [ `cat /tmp/sc2ping | wc -l` -eq '1' ]; then
		latency=$(/data/ftp/uavpal/bin/dc -e "$(cat /tmp/sc2ping) 2 / p")ms
	else
		latency="n/a"
	fi
	bat_msb="00" && while [[ $bat_msb == "00" -o $bat_msb == "01" ]]; do bat_msb=$(i2cdump -r 0x20-0x23 -y 1 0x08 |tail -1 | cut -d " " -f 4); done
	bat_lsb="00" && while [[ $bat_lsb == "00" -o $bat_lsb == "01" ]]; do bat_lsb=$(i2cdump -r 0x20-0x23 -y 1 0x08 |tail -1 | cut -d " " -f 5); done
	bat_volts=$(/data/ftp/uavpal/bin/dc -e "2k $(printf "%d\n" 0x${bat_msb}${bat_lsb}) 1000 / p")
	bat_percent=$(ulogcat -d -v csv |grep "Battery percentage" |tail -n 1 | cut -d " " -f 4)

	ip_sc2=`netstat -nu |grep 9988 | head -1 | awk '{ print $5 }' | cut -d ':' -f 1`
	ztConn=""
	if [ `echo $ip_sc2 | awk -F. '{print $1"."$2"."$3}'` == "192.168.42" ]; then
		signal="Wi-Fi"
	else
		# detect if zerotier connection is direct vs. relayed
		if [ $(/data/ftp/uavpal/bin/zerotier-one -q listpeers |grep LEAF |grep $ztVersion |grep -v ' - ' | wc -l) != '0' ] && [ "$ip_sc2" != "" ]; then
			ztConn=" [D]"
		fi
		if [ $(/data/ftp/uavpal/bin/zerotier-one -q listpeers |grep LEAF |grep $ztVersion |grep -v ' - ' | wc -l) == '0' ] && [ "$ip_sc2" != "" ]; then
			ztConn=" [R]"
		fi

		# reading out the modem's connection type
		while true; do
			/data/ftp/uavpal/bin/chat -V -t 1 '' 'AT\^SYSINFOEX' 'OK' '' > /dev/ttyUSB2 < /dev/ttyUSB2 2>/tmp/mode
			if grep "SYSINFOEX:" /tmp/mode >/dev/null; then
				break # break out of loop
			fi
		done
		modeString=`grep "SYSINFOEX:" /tmp/mode |tail -n 1`
		modeNumeric=`echo $modeString | cut -d "," -f 8`
		if [ $modeNumeric -ge 101 ]; then
			mode="4G"
		elif [ $modeNumeric -ge 23 ] && [ $modeNumeric -le 65 ]; then
			mode="3G"
		elif [ $modeNumeric -ge 1 ] && [ $modeNumeric -le 3 ]; then
			mode="2G"
		else
			mode="n/a"
		fi

		# reading out the modem's signal strength
		while true; do
			/data/ftp/uavpal/bin/chat -V -t 1 '' 'AT+CSQ' 'OK' '' > /dev/ttyUSB2 < /dev/ttyUSB2 2>/tmp/signal
			if grep "CSQ:" /tmp/signal >/dev/null; then
				break # break out of loop
			fi
		done
		signalString=`grep "CSQ:" /tmp/signal |tail -n 1`
		signalRSSI=`echo $signalString | awk '{print $2}' | cut -d ',' -f 1`
		if [ "$signalRSSI" == "99" ]; then signalRSSI=0; fi
		signalPercentage=$(printf "%.0f\n" $(/data/ftp/uavpal/bin/dc -e "$(echo $signalRSSI) 3.33 * p"))%
		signal="$mode/$signalPercentage"
	fi

	droneLabel="${droneName} (Sig:${signal} Alt:${altitude_rel}m Bat:${bat_percent}%/${bat_volts}V Ltn:${latency}${ztConn})"

### DEBUG ####
ulogger -s -t uavpal_glympse "$droneLabel"
echo

	/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST -d "[[$(date +%s)000,$(gpsDecimal $lat $latdir),$(gpsDecimal $long $longdir),$speed,$heading]]" "https://api.glympse.com/v2/tickets/$ticket/append_location" &
	/data/ftp/uavpal/bin/curl -q -k -H "Content-Type: application/json" -H "Authorization: Bearer ${access_token}" -X POST -d "[{\"t\": $(date +%s)000, \"pid\": 0, \"n\": \"name\", \"v\": \"${droneLabel}\"}]" "https://api.glympse.com/v2/tickets/$ticket/append_data" &

	if test -n "$ip_sc2"; then
		ping -c 1 $ip_sc2 |grep 'bytes from' | cut -d '=' -f 4 | tr -d ' ms' > /tmp/sc2ping &
	else
		rm /tmp/sc2ping 2>/dev/null
	fi
	sleep 5
	# make sure all curl processes have ended
	while ps |grep curl |grep -v grep >/dev/null; do usleep 100000; done
done

