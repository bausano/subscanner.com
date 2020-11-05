#!/bin/bash

# Downloads video subtitles from YouTube with youtube-dl and formats them into
# html. Uses template.html file to replace placeholders and stores the result in
# another html file.
#
# # Usage
#
# ```
# $ ./gen_html_for_vid.sh ${video_id}
# ```

function check_dependency {
    ## Checks that dependency is installed, otherwise exits.

    local dep=$1

    if ! command -v $dep &> /dev/null
    then
        echo "${dep} is missing"
        echo "\$ sudo apt-get install ${dep}"
        exit 1
    fi
}

check_dependency "youtube-dl"
check_dependency "jq"
check_dependency "gzip"
check_dependency "minify"
check_dependency "ffmpeg"

readonly HTML_TEMPLATE_PATH="template.html"
# "11:22:33.938 --> 44:55:66" matches position "nn" in nth group for 6 groups
readonly D="[[:digit:]]"
readonly MATCH_TIMESPAN="^($D{2}):($D{2}):($D{2}),$D{3}\s-->\s($D{2}):($D{2}):($D{2})"
# don't display timestamp all the time (clutters page)
readonly DISPLAY_TIMESTAMP_EVERY_N_S=20

# first arg is famous "?v=" query param
readonly video_id=$1
if [ -z "${video_id}" ]; then
    echo "Video id must be provided. Example: ./gen_html_for_vid MBnnXbOM5S4"
    exit 1
fi

readonly video_url="https://www.youtube.com/watch?v=${video_id}"
readonly info_file_name="${video_id}.info.json"
readonly vtt_file_name="${video_id}.en.vtt"
readonly srt_file_name="${video_id}.en.srt"

# will be stored as a file
html_mut=$(cat $HTML_TEMPLATE_PATH)
# html to replace template's transcript placeholder with paht
transcript_mut=""

function download_video_subtitles {
    ## Given video id downloads subtitles to disk and returns path to the file.
    echo "[$(date)] Downloading subs for ${video_id}..."

    function youtube_dl {
        ## Runs youtube-dl to get subtitles. Can be parametrized to get auto
        ## or manmade subs.

        # Can be either "--write-sub" or "--write-auto-sub".
        local sub_flag=$1

        local success_msg="Writing video subtitles"

        # --id stores file with video id in name
        # --write-info-json creates a new json file with video metadata which
        #                   we use to get title, tags, thumbbnail, ...
        result_download_subs=$(youtube-dl --retries 50 --id --write-info-json --skip-download --sub-lang en "${sub_flag}" "${video_url}")
        if [[ "${result_download_subs}" == *"${success_msg}"* ]]; then
            return 0
        fi

        return 1
    }

    # attempt download manmade subs or fallback to autogen
    youtube_dl --write-sub || youtube_dl --write-auto-sub

    if [[ $? != 0 || -z "${vtt_file_name}" ]]; then
        echo "Subtitles for ${video_id} cannot be downloaded."
        exit $?
    fi

    # convert vtt to srt, better format to parse
    ffmpeg -y -i "${vtt_file_name}" "${srt_file_name}" > /dev/null 2>&1
}

function replace_template_placeholders {
    ## Gets info from metadata file and replaces placeholders in "html_mut".
    echo "[$(date)] Replacing template placeholders..."

    # get info from youtube-dl created json
    local info_json=$( jq -c '.' "${info_file_name}" )

    # replace "video_$PROP_prop" keys with values from info json
    local properties=(
        id title thumbnail webpage_url
        uploader channel_url
    )
    for prop in "${properties[@]}"
    do
        prop_value=$( jq -r -c ".$prop" <<< $info_json )
        html_mut=${html_mut//"video_${prop}_prop"/"${prop_value}"}
    done

    # build keywords by removing quotes and square brackets from json array
    local tags=$( jq -r -c ".tags" <<< $info_json | sed 's/\"//g' )
    local categories=$( jq -r -c ".categories" <<< $info_json | sed 's/\"//g' )
    html_mut=${html_mut/video_keywords_prop/"${categories:1:-1},${tags:1:-1}"}
}

function parse_subtitles_file {
    ## Loads and parses subs, puts results into html. This function mutates
    ## parameter "html_mut".
    echo "[$(date)] Parsing subs file..."

    # keeps track of when last <time> tag was displayed
    # display <time> only once in a while to avoid cluttering
    local last_timestamp_displayed_at_sec=0

    function time_to_int {
        ## Converts double digit number such as hours, minutes, seconds.

        local number=$1

        if [[ ${number} = 0* ]]; then
            return ${number:1}
        else
            return ${number}
        fi
    }

    function subtitles_html_template {
        ## Given seconds into the video and timestamp, generate timeline and
        ## subtitle html.

        local appear_at_sec=$1
        local hh_mm_ss=$2
        local text=$3
        local display_timestamp=$4

        transcript_mut+="<div class=\"subtitle\">"

        if $display_timestamp; then
           transcript_mut+="
                <span class=\"timestamp\" unselectable=\"on\">
                    <a href=\"${video_url}&t=${appear_at_sec}\" target=\"${video_id}\">
                        <time>${hh_mm_ss}</time>
                    </a>
                </span>
            "
        fi

        transcript_mut+="<span>${text}</span>"
        transcript_mut+="</div>"
    }

    next_index=2
    last_line=""
    while read -r timespan; do
        # reads until timespan and stores groups in `$BASH_REMATCH`
        if [[ ! ${timespan} =~ $MATCH_TIMESPAN ]]; then
            continue
        fi

        text_mut=""
        while read -r nline; do
            # trim spaces
            nline="${nline#"${nline%%[![:space:]]*}"}"
            nline="${nline%"${nline##*[![:space:]]}"}"

            if [ -z "${nline}" ]; then
                continue
            fi

            # if next index is reached, write html and start next timespan
            if [ "${next_index}" = "${nline}" ]; then
                next_index=$(( next_index + 1 ))
                break
            fi

            # protection against duplicates
            # (https://github.com/bausano/yt-search/issues/7)
            if [ "${last_line}" = "${nline}" ]; then
                continue
            fi

            last_line="${nline}"
            text_mut+=" ${nline}"
        done

        # when subs start?
        s_hh="${BASH_REMATCH[1]}"
        s_mm="${BASH_REMATCH[2]}"
        s_ss="${BASH_REMATCH[3]}"
        s_hh_mm_ss="${s_hh}:${s_mm}:${s_ss}"
        time_to_int ${s_hh}; s_hours=$?
        time_to_int ${s_mm}; s_minutes=$?
        time_to_int ${s_ss}; s_seconds=$?
        curr_subs_appeared_at_sec="$(($s_hours * 3600 + $s_minutes * 60 + $s_seconds))"

        # only show timestamp here and there to avoid clutter
        display_timestamp=false
        secs_without_timestamp=$(( $curr_subs_appeared_at_sec - $last_timestamp_displayed_at_sec ))
        if [[ $secs_without_timestamp -ge $DISPLAY_TIMESTAMP_EVERY_N_S ]]; then
            display_timestamp=true
            last_timestamp_displayed_at_sec=$curr_subs_appeared_at_sec
        fi

        # appends html to html_mut
        subtitles_html_template ${curr_subs_appeared_at_sec} ${s_hh_mm_ss} "${text_mut}" ${display_timestamp}

        # when subs end?
        time_to_int ${BASH_REMATCH[4]}; e_hours=$?
        time_to_int ${BASH_REMATCH[5]}; e_minutes=$?
        time_to_int ${BASH_REMATCH[6]}; e_seconds=$?
    done <<< $(tail -n +2 "${srt_file_name}") # the first line is always index "1"

    # and finally attach transcript to the html
    html_mut=${html_mut/video_transcript_prop/${transcript_mut}}
}

download_video_subtitles # (and meta info) to disk
replace_template_placeholders # with values from meta info json file
parse_subtitles_file # and store results in "html_mut"

# Minifies the html, gzips it and stores it in a file.
echo "[$(date)] Minifying html and storing it gzipped..."
echo "${html_mut}" | minify --type=html | gzip -c > "pages/${video_id}.html"

# delete temp downloads
rm -rf "${info_file_name}" "${vtt_file_name}" "${srt_file_name}"

echo "[$(date)] Done!"
