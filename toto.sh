#!/usr/bin/env bash
if ! [ -d 'logs' ]
then
    echo  "Created logs directory"
    mkdir -p logs 2>&1 2>/dev/null
fi

for i in $(ollama list|grep -Ev 'NAME|embed' |sed -e 's/ .*//')
do
    filename="logs/$( echo "$i" | tr ':/' '_' )_$( date  +'%a_%b_%d_%H_%M_%S_%Z_%Y' ).txt"
    echo "Writing ${filename}"
    bash ./complete.sh "$i" 2>&1 | tee ${filename}
done
