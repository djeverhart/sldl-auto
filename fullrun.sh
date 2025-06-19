#!/bin/bash

CONFIG_FILE="./sldl_config.json"
DOWNLOAD_PATH=$(jq -r '.sldl_downloads' "$CONFIG_FILE")
WATCH_FILE="nohup.out"
SLEEP_INTERVAL=300
BAN_FILE="banned_users.txt"

# Ensure ban file exists
[[ -f "$BAN_FILE" ]] || touch "$BAN_FILE"

# Load banned users from file into array
readarray -t BANNED_USERS < <(grep -v '^#' "$BAN_FILE")

SLDL_USER=$(jq -r '.sldl_user' "$CONFIG_FILE")
SLDL_PASS=$(jq -r '.sldl_pass' "$CONFIG_FILE")

BASE_CMD="./sldl --user $USER --pass $PASS -p $DOWNLOAD_PATH --input-type list --input sldl-albums.txt --album --album-parallel-search --no-browse-folder --fast-search --concurrent-downloads 12 --search-timeout 3000 --max-stale-time 8000 --searches-per-time 30 --searches-renew-time 180 --failed-album-path delete --no-write-index --fails-to-ignore 1 --fails-to-downrank 1 --strict-conditions --verbose"

# Rebuilds full sldl command with banned users
build_command() {
    local joined=$(printf "%s," "${BANNED_USERS[@]}")
    joined="${joined%,}"
    CMD="$BASE_CMD --banned-users \"$joined\""
}

run_script() {
    echo "[$(date)] Killing existing sldl processes..." >> watchdog.log
    pkill -f './sldl' 2>/dev/null
    sleep 1
    : > "$WATCH_FILE"  # Clear sldl output

    echo "[$(date)] Starting new sldl instance..." >> watchdog.log
    build_command
    echo "[$(date)] Running: $CMD" >> watchdog.log
    ($CMD 2>&1 | tee "$WATCH_FILE") &
    export CURRENT_PID=$!
    echo "[$(date)] Started sldl with PID $CURRENT_PID" >> watchdog.log
}

extract_last_uploader() {
    grep -oP 'Initialize:\s+\K[^\\]+' "$WATCH_FILE" | tail -n 1
}

monitor_output() {
    local last_line=""
    while true; do
        sleep "$SLEEP_INTERVAL"
        if [[ ! -f "$WATCH_FILE" ]]; then
            echo "[$(date)] Output file missing. Restarting..." >> watchdog.log
            run_script
            continue
        fi

        new_line=$(tail -n 1 "$WATCH_FILE")
        if [[ "$new_line" == "$last_line" ]]; then
            echo "[$(date)] Output unchanged for $SLEEP_INTERVAL seconds. Restarting..." >> watchdog.log

            uploader=$(extract_last_uploader)
            if [[ -n "$uploader" ]]; then
                if [[ "$uploader" =~ \  ]]; then
                    echo "[$(date)] Skipping user with space in name: $uploader" >> watchdog.log
                elif [[ ! " ${BANNED_USERS[*]} " =~ " $uploader " ]]; then
                    echo "[$(date)] Banning user: $uploader" >> watchdog.log
                    BANNED_USERS+=("$uploader")
                    echo "$uploader" >> "$BAN_FILE"
                fi
            fi

            run_script
        else
            last_line="$new_line"
        fi
    done
}

# MAIN
run_script
monitor_output

