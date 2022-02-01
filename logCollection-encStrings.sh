#!/bin/bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# Copyright (c) 2021 Jamf.  All rights reserved.
#
#       Redistribution and use in source and binary forms, with or without
#       modification, are permitted provided that the following conditions are met:
#               * Redistributions of source code must retain the above copyright
#                 notice, this list of conditions and the following disclaimer.
#               * Redistributions in binary form must reproduce the above copyright
#                 notice, this list of conditions and the following disclaimer in the
#                 documentation and/or other materials provided with the distribution.
#               * Neither the name of the Jamf nor the names of its contributors may be
#                 used to endorse or promote products derived from this software without
#                 specific prior written permission.
#
#       THIS SOFTWARE IS PROVIDED BY JAMF SOFTWARE, LLC "AS IS" AND ANY
#       EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#       WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#       DISCLAIMED. IN NO EVENT SHALL JAMF SOFTWARE, LLC BE LIABLE FOR ANY
#       DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
#       (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
#       LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
#       ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#       (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#       SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# This script was designed to be used in a Self Service policy to allow the facilitation
# or log collection by the end-user and upload the logs to the device record in Jamf Pro
# as an attachment.
#
# REQUIREMENTS:
#           - Jamf Pro
#           - macOS Clients running version 10.13 or later
#
#
# For more information, visit https://github.com/kc9wwh/logCollection
#
# Written by: Joshua Roskos | Jamf
#
#
# Revision History
# 2020-12-01: Added support for macOS Big Sur
# 2021-02-24: Fixed missing variables
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

## User Variables
jamfProURL="$4"
jamfProUser="$5"
jamfProPassEnc="$6"
logFiles="$7"

## System Variables
if [[ -z $jamfProURL ]]; then
    jamfProURL=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf jss_url)
    jamfProURL=${jamfProURL%%/}
fi
mySerial=$( system_profiler SPHardwareDataType | grep Serial |  awk '{print $NF}' )
currentUser=$( stat -f%Su /dev/console )
compHostName=$( scutil --get LocalHostName )
timeStamp=$( date '+%Y-%m-%d-%H-%M-%S' )
osMajor=$(/usr/bin/sw_vers -productVersion | awk -F . '{print $1}')
osMinor=$(/usr/bin/sw_vers -productVersion | awk -F . '{print $2}')
jamfProPass=$( echo "$6" | /usr/bin/openssl enc -aes256 -d -a -A -S "$8" -k "$9" )

echo "Connecting to $jamfProURL"

# created base64-encoded credentials
encodedCredentials=$( printf "${jamfProUser}:${jamfProPass}" | /usr/bin/iconv -t ISO-8859-1 | /usr/bin/base64 -i - )
# generate an auth token
authToken=$( /usr/bin/curl "$jamfProURL/api/auth/tokens" \
--silent \
--request POST \
--header "Authorization: Basic $encodedCredentials" \
--header "Content-Length: 0" \
-w "\n%{http_code}")

httpCode=$(tail -n1 <<< "${authToken}")
httpBody=$(sed '$ d' <<< "${authToken}") 

echo "Command HTTP result : ${httpCode}"
# echo "Response : ${httpBody}"

if [[ ${httpCode} == 200 ]]; then 
    echo "Token creation done"
else
    echo "[ERROR] Unable to create token. Curl code received : ${httpCode}"
    exit 1
fi

# parse authToken for token, omit expiration
token=$( awk -F \" '{ print $4 }' <<< "$authToken" | xargs )

## Log Collection
echo "Collecting logs"
fileName=$compHostName-$currentUser-$timeStamp.zip
echo "Zipping logs"
zip /private/tmp/$fileName $logFiles > /dev/null

## Upload Log File
if [[ "$osMajor" -ge 11 ]]; then
    jamfProID=$( curl -sk \
        -H "Authorization: Bearer ${token}" \
        $jamfProURL/JSSResource/computers/serialnumber/$mySerial/subset/general | \
        xpath -e "//computer/general/id/text()" -q )
elif [[ "$osMajor" -eq 10 && "$osMinor" -gt 12 ]]; then
    jamfProID=$( curl -sk -u "$jamfProUser":"$jamfProPass" \
        -H "Authorization: Bearer ${token}" \
        $jamfProURL/JSSResource/computers/serialnumber/$mySerial/subset/general | \
        xpath "//computer/general/id/text()" -q )
fi

echo "Uploading files"
curl -sk \
    -H "Authorization: Bearer ${token}" \
    $jamfProURL/JSSResource/fileuploads/computers/id/$jamfProID \
    -F name=@/private/tmp/$fileName \
    -X POST

## Cleanup
echo "Deleting temp files"
rm /private/tmp/$fileName 

# expire the auth token
echo "Expiring Token"
result=$(/usr/bin/curl "$jamfProURL/api/auth/invalidateToken" \
--silent \
--request POST \
--header "Authorization: Bearer $token" \
--header "Content-Length: 0" \
-w "\n%{http_code}")
httpCode=$(tail -n1 <<< "${result}")

if [[ ${httpCode} == 204 ]]; then 
    echo "Command HTTP result : ${httpCode}"
    echo ">> Done"
else
    echo "[ERROR] Unable to expire token. Curl code received : ${httpCode}"
fi

exit 0
