#!/bin/bash

source lib.sh

readonly help='
Generates pages for all channel vids and adds channel to db.
* channel id as given by yt (/channel/${channel_id} and not /c/${channel_name})
* `--db ${db_name}` DynamoDB name which stores channels
* optinal `--max-concurrent integer` flag which limits how many videos are
    processed at once

$ ./add_channel.sh ${channel_id} \
    --db yt_channels \
    [--max-concurrent 4]
'
if [ "${1}" = "help" ]; then echo "${help}" && exit 0; fi

check_dependency "aws"

# youtube.com/channel/${channel_id}
readonly channel_id=$1
if [ -z "${channel_id}" ]; then
    echo "Channel id must be provided. See ./add_channel help"
    exit 1
fi

max_concurrent=4
for key in "$@"; do
    case ${key} in
        --db)
        db_name=$2
        ;;
        --max-concurrent)
        max_concurrent=$2
        ;;
    esac
    # go to next flag
    shift
done

if [ -z "${db_name}" ]; then
    echo "--db must be provided. See ./add_channel help"
    exit 1
fi

# Imports the .env file environment variables if present.
if test -f ".env"; then
    echo "(source .env)"
    source .env
fi

# get it from ddb, if exists exit 1
already_exists=$(aws dynamodb get-item --table-name "${db_name}" \
    --key "{\"channel_id\": {\"S\": \"${channel_id}\"}}" \
    | grep "${channel_id}" -c)

if [ $already_exists -eq 1 ]; then
    echo "Channel ${channel_id} already exists."
    exit 1
fi

# scrape all vids to date
echo "[`date`] Scraping channel videos..."
./gen_channel_vids_pages.sh "${channel_id}" --max-concurrent "${max_concurrent}"
abort_on_err $? "Videos for channel ${channel_id} cannot be created."

echo "[`date`] Inserting channel to db..."
aws dynamodb put-item \
    --table-name "${db_name}" \
    --item "{
        \"channel_id\": {\"S\": \"${channel_id}\"},
        \"updated_at\": {\"N\": \"$(date +%s)\"}
      }"
abort_on_err $? "Cannot store channel in db."

echo "[`date`] Done!"
