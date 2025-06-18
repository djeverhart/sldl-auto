#!/bin/bash

CONFIG_FILE="./sldl_config.json"
SPOTIFY_SCRIPT="./spotify2sldl.py"
FULLRUN_SCRIPT="./fullrun.sh"
LOG_FILE="./watchdog.log"

# Function to parse working_path from config or fallback
function get_working_path() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo ""
        return 1
    fi

    # parse working_path from JSON config
    working_path=$(jq -r '.working_path // empty' "$CONFIG_FILE" 2>/dev/null)

    if [ -z "$working_path" ] || [ "$working_path" == "null" ]; then
        echo ""
        return 1
    else
        echo "$working_path"
        return 0
    fi
}

function install_requirements() {
    echo "Installing requirements..."

    # Detect package manager and install python3, python3-pip, jq
    if command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y python3 python3-pip jq wget unzip
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm python python-pip jq wget unzip
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 python3-pip jq wget unzip
    else
        echo "No supported package manager found (apt, pacman, dnf). Please install python3, pip, and jq manually."
        return 1
    fi
    wget "https://raw.githubusercontent.com/djeverhart/sldl-auto/refs/heads/main/banned_users.txt"
    wget "https://raw.githubusercontent.com/djeverhart/sldl-auto/refs/heads/main/fullrun.sh"
    chmod +x fullrun.sh
    wget "https://raw.githubusercontent.com/djeverhart/sldl-auto/refs/heads/main/sldl_config.json"
    wget "https://raw.githubusercontent.com/djeverhart/sldl-auto/refs/heads/main/spotify2sldl.py"
    chmod +x spotify2sldl.py
    wget "https://github.com/fiso64/slsk-batchdl/releases/download/v2.4.6/sldl_linux-x64.zip"
    unzip sldl_linux-x64.zip
    rm sldl.pdb
    python3 -m pip install --upgrade pip --break-system-packages
    python3 -m pip install spotipy pandas --break-system-packages

    working_path=$(get_working_path)

    if [ -z "$working_path" ]; then
        echo "Warning: working_path not found in config file."
        echo "Creating ./working_dir in current directory."
        working_path="./working_dir"
    fi

    if [ ! -d "$working_path" ]; then
        mkdir -p "$working_path"
        echo "Created working directory at $working_path"
    else
        echo "Working directory already exists at $working_path"
    fi
    echo "Installation complete."
}

function edit_config() {
    vim "$CONFIG_FILE"
}

function dump_artists() {
    if [ ! -f "$SPOTIFY_SCRIPT" ]; then
        echo "Error: $SPOTIFY_SCRIPT not found in current directory."
        return 1
    fi
    python3 "$SPOTIFY_SCRIPT"
    #echo "Dumping your spotify artists in background. Logging to $LOG_FILE"
    #tail -f "$LOG_FILE"
}

function download_artists() {
    if [ ! -f "$FULLRUN_SCRIPT" ]; then
        echo "Error: $FULLRUN_SCRIPT not found in current directory."
        return 1
    fi
    nohup bash "$FULLRUN_SCRIPT" > "$LOG_FILE" 2>&1 &
    echo "Started fullrun.sh in background. Logging to $LOG_FILE"
    tail -f "$LOG_FILE"
}

while true; do
    echo "=============================="
    echo "Select an option:"
    echo "1) Install requirements (python3, pip, spotipy, pandas, jq, create working dir from config)"
    echo "2) Edit Configuration ($CONFIG_FILE)"
    echo "3) Dump artists from Spotify (run spotify2sldl.py)"
    echo "4) Download artists with Soulseek (run fullrun.sh with logging)"
    echo "5) Exit"
    echo "=============================="
    read -rp "Enter choice [1-5]: " choice

    case $choice in
        1) install_requirements ;;
        2) edit_config ;;
        3) dump_artists ;;
        4) download_artists ;;
        5) echo "Exiting."; exit 0 ;;
        *) echo "Invalid choice, try again." ;;
    esac
done
