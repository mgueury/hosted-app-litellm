#!/usr/bin/env bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd $SCRIPT_DIR/..

. starter.sh env -silent

get_ui_url

echo 
echo "Build done"

# Do not show the Done URLs if after_build.sh exists 
if [ "$UI_URL" != "" ]; then
    echo "URLs" > $FILE_DONE
    append_done "- User Interface: $UI_URL/"     
    if [ "$UI_HTTP" != "" ]; then
        append_done "- HTTP : $UI_HTTP/"
    fi
    append_done "- LiteLLM API: $UI_URL/v1/chat/completions"
    append_done "- Models: $UI_URL/v1/models"

elif [ ! -f $FILE_DONE ]; then
    echo "-" > $FILE_DONE  
fi
cat $FILE_DONE
