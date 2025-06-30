#!/bin/bash
set -euo pipefail

CONFIG_FILE="$HOME/.spotiplex.conf"
LOGFILE="spotiplex.log"
TMPDIR="/tmp"
SLSL_ZIP_URL="https://github.com/fiso64/slsk-batchdl/releases/latest/download/sldl_linux-x64.zip"
SLSK_BIN="$TMPDIR/sldl"
PYTHON_TMP=""
PLAYLISTS_TMP=""
TIMEOUT_SECONDS=300  # Increased to 5 minutes to match watchdog script
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
BAN_FILE="banned_users.txt"

# Ensure ban file exists
[[ -f "$BAN_FILE" ]] || touch "$BAN_FILE"

# Load banned users from file into array
readarray -t BANNED_USERS < <(grep -v '^#' "$BAN_FILE" | grep -v '^$')

cleanup() {
  [[ -n "$PYTHON_TMP" ]] && rm -f "$PYTHON_TMP"
  [[ -n "$PLAYLISTS_TMP" ]] && rm -f "$PLAYLISTS_TMP"
}
trap cleanup EXIT

sanitize_filename() {
  local filename="$1"
  echo "$filename" | sed 's/[<>:"/\\|?*]/_/g' | sed 's/\.\+$//' | xargs
}

print_header() {
  echo -e "\n========================[ Run started at $(date '+%F %T') ]========================\n" >> "$LOGFILE"
}

install_dependencies() {
  echo "[*] Installing dependencies..."
  if command -v apt-get &>/dev/null; then
    apt-get update
    apt-get install -y python3 python3-pip unzip wget libicu-dev
  elif command -v dnf &>/dev/null; then
    dnf install -y python3 python3-pip unzip wget libicu-dev
  elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm python python-pip unzip wget libicu-dev
  else
    echo "Package manager not detected, please install python3, pip, wget, unzip manually"
    exit 1
  fi
  python3 -m pip install --break-system-packages spotipy
}

download_sldl() {
  echo "[*] Downloading sldl..."
  mkdir -p "$TMPDIR"
  wget -q -O "$TMPDIR/sldl_linux-x64.zip" "$SLSL_ZIP_URL"
  unzip -o "$TMPDIR/sldl_linux-x64.zip" -d "$TMPDIR"
  chmod +x "$SLSK_BIN"
  rm -f "$TMPDIR/sldl.pdb" "$TMPDIR/sldl_linux-x64.zip"
}

prompt_config() {
  echo "Please enter the following configuration values:"
  read -rp "Soulseek username: " SL_USERNAME
  read -rsp "Soulseek password: " SL_PASSWORD; echo
  read -rp "Spotify Client ID: " SPOTIFY_ID
  read -rp "Spotify Client Secret: " SPOTIFY_SECRET
  read -rp "Callback URL [https://127.0.0.1:8887/callback]: " SPOTIFY_REDIRECT
  SPOTIFY_REDIRECT=${SPOTIFY_REDIRECT:-https://127.0.0.1:8887/callback}
  read -rp "Download path [/downloads/playlists]: " DL_PATH
  DL_PATH=${DL_PATH:-/downloads/playlists}
  mkdir -p $DL_PATH

  cat > "$CONFIG_FILE" <<EOF
SL_USERNAME=$(printf '%q' "$SL_USERNAME")
SL_PASSWORD=$(printf '%q' "$SL_PASSWORD")
SPOTIFY_ID=$(printf '%q' "$SPOTIFY_ID")
SPOTIFY_SECRET=$(printf '%q' "$SPOTIFY_SECRET")
SPOTIFY_REDIRECT=$(printf '%q' "$SPOTIFY_REDIRECT")
DL_PATH=$(printf '%q' "$DL_PATH")
EOF
  echo "Config saved to $CONFIG_FILE"
}

edit_config() {
  PS3="Choose option: "
  options=("Delete config" "Edit in vim" "Cancel")
  select opt in "${options[@]}"; do
    case $opt in
      "Delete config") rm -f "$CONFIG_FILE"; echo "Config deleted."; exit 0 ;;
      "Edit in vim") vim "$CONFIG_FILE"; exit 0 ;;
      "Cancel") exit 0 ;;
      *) echo "Invalid option." ;;
    esac
  done
}

check_or_create_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    read -rp "Config file exists. Reuse it? [y/n]: " reuse
    if [[ "$reuse" =~ ^[Yy]$ ]]; then
      return
    else
      edit_config
      prompt_config
    fi
  else
    prompt_config
  fi
}

kill_existing_instances() {
  echo "Killing other spotiplex.sh instances..."
  current_pid=$$
  pids=$(pgrep -f spotiplex.sh | grep -vw "$current_pid" || true)
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
  fi
  
  # Also kill any existing sldl processes
  pkill -f "$SLSK_BIN" 2>/dev/null || true
}

process_file_renaming() {
  local temp_log=$(mktemp)
  grep -E "(Searching:|Succeeded:)" "$LOGFILE" | tail -100 > "$temp_log"

  local last_search=""

  while IFS= read -r line; do
    if [[ "$line" =~ ^Searching:\ (.+)\ \([0-9]+s\)$ ]]; then
      last_search="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^Succeeded:\ +.*\\\.\.\\(.*\.(mp3|flac|m4a|wav)) ]]; then
      local downloaded_filename="${BASH_REMATCH[1]}"
      local final_path=$(find "$DL_PATH" -type f -iname "$downloaded_filename" | head -n 1)

      if [[ -n "$final_path" && -f "$final_path" ]]; then
        local dir=$(dirname "$final_path")
        local ext="${final_path##*.}"
        local new_name=$(sanitize_filename "$last_search")
        local new_path="$dir/${new_name}.${ext}"

        echo "[DEBUG] Renaming: '$final_path' -> '$new_path'" >> "$LOGFILE"

        if [[ "$final_path" != "$new_path" && ! -f "$new_path" ]]; then
          if mv "$final_path" "$new_path"; then
            echo "[$(date '+%F %T')] RENAMED: $(basename "$final_path") -> $(basename "$new_path")" >> "$LOGFILE"
          else
            echo "[$(date '+%F %T')] FAILED TO RENAME: $(basename "$final_path")" >> "$LOGFILE"
          fi
        fi
      else
        echo "[DEBUG] File not found on disk: $downloaded_filename" >> "$LOGFILE"
      fi

      last_search=""
    fi
  done < "$temp_log"

  rm -f "$temp_log"
}

# Extract the last uploader from log (adapted from watchdog script)
extract_last_uploader() {
  grep -oP 'Initialize:\s+\K[^\\]+' "$LOGFILE" | tail -n 1
}

# Build sldl command with banned users
build_sldl_command() {
  local base_cmd="$SLSK_BIN"
  local args=(
    "--user" "$SL_USERNAME"
    "--pass" "$SL_PASSWORD" 
    "--path" "$DL_PATH"
    "--spotify-id" "$SPOTIFY_ID"
    "--spotify-secret" "$SPOTIFY_SECRET"
    "--pref-min-bitrate" "180"
    "--pref-max-bitrate" "320"
    "--strict-title"
    "--strict-artist"
    "--fast-search"
    "--concurrent-downloads" "20"
    "--search-timeout" "6000"
    "--max-stale-time" "12000"
    "--fails-to-ignore" "1"
    "--fails-to-downrank" "1"
    "--strict-conditions"
    "--verbose"
  )
  
  # Add Spotify refresh token if available
  if [[ -n "${SPOTIFY_REFRESH:-}" ]]; then
    args+=("--spotify-refresh" "$SPOTIFY_REFRESH")
  fi
  
  # Add banned users if any exist
  if [[ ${#BANNED_USERS[@]} -gt 0 ]]; then
    local joined=$(printf "%s," "${BANNED_USERS[@]}")
    joined="${joined%,}"
    args+=("--banned-users" "$joined")
  fi
  
  SLDL_CMD=("$base_cmd" "${args[@]}")
}

monitor_and_restart() {
  local logfile="$1"
  local playlist_url="$2"
  local last_size=0
  local unchanged_count=0
  local last_line=""

  while true; do
    if [[ -f "$logfile" ]]; then
      current_size=$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo "0")
      new_line=$(tail -n 1 "$logfile" 2>/dev/null || echo "")
      
      # Check if both size and content are unchanged
      if [[ "$current_size" -eq "$last_size" && "$new_line" == "$last_line" ]]; then
        ((unchanged_count++))
        if [[ $unchanged_count -ge $TIMEOUT_SECONDS ]]; then
          echo -e "\n[$(date '+%F %T')] No output for ${TIMEOUT_SECONDS} seconds, checking for user to ban..." >> "$logfile"
          
          # Extract last uploader and ban them if appropriate
          uploader=$(extract_last_uploader)
          if [[ -n "$uploader" ]]; then
            if [[ "$uploader" =~ \  ]]; then
              echo "[$(date '+%F %T')] Skipping user with space in name: $uploader" >> "$logfile"
            elif [[ ! " ${BANNED_USERS[*]} " =~ " $uploader " ]]; then
              echo "[$(date '+%F %T')] Banning user: $uploader" >> "$logfile"
              BANNED_USERS+=("$uploader")
              echo "$uploader" >> "$BAN_FILE"
              echo "[$(date '+%F %T')] Added $uploader to ban list, restarting entire script..." >> "$logfile"
              kill_existing_instances
              cd "$SCRIPT_DIR"
              exec "$SCRIPT_PATH" -s
            else
              echo "[$(date '+%F %T')] User $uploader already banned" >> "$logfile"
            fi
          else
            echo "[$(date '+%F %T')] No uploader found to ban, restarting script anyway..." >> "$logfile"
            kill_existing_instances
            cd "$SCRIPT_DIR"
            exec "$SCRIPT_PATH" -s
          fi
        fi
      else
        unchanged_count=0
        last_size="$current_size"
        last_line="$new_line"
      fi
    fi
    sleep 1  # Check every second for responsiveness
  done
}

main_loop() {
  print_header
  source "$CONFIG_FILE"

  PYTHON_TMP=$(mktemp "$TMPDIR/spotiplex_py_XXXXXX.py")
  PLAYLISTS_TMP=$(mktemp "$TMPDIR/spotiplex_playlists_XXXXXX.txt")

  cat > "$PYTHON_TMP" <<EOF
import spotipy
from spotipy.oauth2 import SpotifyOAuth
import os

auth = SpotifyOAuth(
    client_id="$SPOTIFY_ID",
    client_secret="$SPOTIFY_SECRET",
    redirect_uri="$SPOTIFY_REDIRECT",
    scope="playlist-read-private playlist-read-collaborative",
    open_browser=False,
    show_dialog=True
)

token_info = auth.get_cached_token()
if not token_info:
    print("\\n=== SPOTIFY AUTHORIZATION REQUIRED ===")
    print("Please open this URL in your browser:")
    print(auth.get_authorize_url())
    print("After authorizing, paste the FULL redirected URL.")
    redirect_response = input("Enter the URL you were redirected to: ")
    code = auth.parse_response_code(redirect_response)
    token_info = auth.get_access_token(code, as_dict=True)
else:
    print("Using cached Spotify token...")

refresh_token = token_info.get("refresh_token")
config_path = "$CONFIG_FILE"
if refresh_token:
    with open(config_path, "r") as f:
        config = f.read()
    if "SPOTIFY_REFRESH" not in config:
        with open(config_path, "a") as f:
            f.write(f'SPOTIFY_REFRESH="{refresh_token}"\\n')

sp = spotipy.Spotify(auth=token_info["access_token"])
offset = 0
urls = []
while True:
    playlists = sp.current_user_playlists(limit=50, offset=offset)["items"]
    if not playlists:
        break
    for playlist in playlists:
        urls.append(playlist["external_urls"]["spotify"])
    offset += 50

with open("$PLAYLISTS_TMP", "w") as f:
    for url in urls:
        f.write(url + "\\n")
EOF

  python3 "$PYTHON_TMP"

  while IFS= read -r playlist_url; do
    playlist_url=$(echo "$playlist_url" | xargs)
    [[ -z "$playlist_url" ]] && continue
    
    echo "[$(date '+%F %T')] Starting download for $playlist_url" >> "$LOGFILE"
    echo "[$(date '+%F %T')] Currently banned users: ${BANNED_USERS[*]}" >> "$LOGFILE"

    # Build command with current ban list
    build_sldl_command
    
    # Start the download process
    "${SLDL_CMD[@]}" "$playlist_url" >> "$LOGFILE" 2>&1 &
    local sldl_pid=$!

    # Start monitoring in background
    monitor_and_restart "$LOGFILE" "$playlist_url" &
    local monitor_pid=$!
    
    # Clean up monitor when sldl finishes
    trap "kill $monitor_pid 2>/dev/null || true" EXIT

    # Wait for sldl to complete and handle file renaming
    while kill -0 $sldl_pid 2>/dev/null; do
      process_file_renaming "$DL_PATH"
      sleep 3
    done

    # Kill the monitor for this playlist
    kill $monitor_pid 2>/dev/null || true

    sleep 2
    process_file_renaming "$DL_PATH"
    
    echo "[$(date '+%F %T')] Completed download for $playlist_url" >> "$LOGFILE"

  done < "$PLAYLISTS_TMP"

  echo "[$(date '+%F %T')] All playlists processed" >> "$LOGFILE"
}

SUPPRESS_DIALOG=0
if [[ "${1:-}" == "-s" ]]; then
  SUPPRESS_DIALOG=1
fi

kill_existing_instances
install_dependencies
download_sldl

if [[ $SUPPRESS_DIALOG -eq 1 ]]; then
  [[ -f "$CONFIG_FILE" ]] || { echo "No config file found, cannot suppress prompts."; exit 1; }
else
  check_or_create_config
fi

main_loop
