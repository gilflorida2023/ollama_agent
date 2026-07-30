#!/usr/bin/env bash
set -e
clear

# Kill any leftover java/javac processes from previous runs
cleanup_children() {
    echo "Cleaning up child processes..."
    pkill -f "java hashprime" 2>/dev/null || true
    pkill -f "javac hashprime" 2>/dev/null || true
    pkill -f "timeout.*curl.*localhost:11434" 2>/dev/null || true
    ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r model; do
        [ -n "$model" ] && ollama stop "$model" 2>/dev/null || true
    done
}

trap cleanup_children EXIT INT TERM

rm -rf logs/ sandbox/
mkdir -p logs

for i in $(ollama list | grep -Ev 'NAME|embed|ocr' | sed -e 's/ .*//'); do
    filename="logs/$(echo "$i" | tr ':/' '_')_$(date +'%a_%b_%d_%H_%M_%S_%Z_%Y').txt"
    echo "Writing ${filename}"

    cleanup_children
    sleep 1

    #bash ./ralph.sh "$i" 30 2>&1 | tee "${filename}" | tee -a "logs/toto.log"
    bash ./complete.sh "$i" 30 2>&1 | tee "${filename}" | tee -a "logs/toto.log"
done
