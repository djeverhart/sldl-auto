#!/bin/bash
set -euo pipefail

CONFIG_FILE="/pstore/spotiplex.conf"
LOGFILE="/pstore/spotiplex.log"
TMPDIR="/tmp"
SLSL_ZIP_URL="https://github.com/fiso64/slsk-batchdl/releases/latest/download/sldl_linux-x64.zip"
SLSK_BIN="$TMPDIR/sldl"
PYTHON_TMP=""
PLAYLISTS_TMP=""
TIMEOUT_SECONDS=300  # Increased to 5 minutes to match watchdog script
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
BAN_FILE="/pstore/banned_users.txt"

# Ensure persistent directory exists
mkdir -p /pstore

# Ensure ban file exists
[[ -f "$BAN_FILE" ]] || touch "$BAN_FILE"

# Load banned users from file into array
readarray -t BANNED_USERS < <(grep -v '^#' "$BAN_FILE" | grep -v '^$')

cleanup() {
  [[ -n "$PYTHON_TMP" ]] && rm -f "$PYTHON_TMP"
  [[ -n "$PLAYLISTS_TMP" ]] && rm -f "$PLAYLISTS_TMP"
}
trap cleanup EXIT

print_header() {
  echo -e "\n========================[ Run started at $(date '+%F %T') ]========================\n" >> "$LOGFILE"
}

install_dependencies() {
  echo "[*] Installing dependencies..."
  if command -v apt-get &>/dev/null; then
    apt-get update
    apt-get install -y python3 python3-pip unzip wget libicu-dev procps
  elif command -v dnf &>/dev/null; then
    dnf install -y python3 python3-pip unzip wget libicu-dev procps
  elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm python python-pip unzip wget libicu-dev procps
  else
    echo "Package manager not detected, please install python3, pip, wget, unzip manually"
    exit 1
  fi
  python3 -m pip install spotipy eyed3
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
      "Delete config")
        rm -f "$CONFIG_FILE"
        echo "Config deleted."
        break  # exit select loop and return to caller
        ;;
      "Edit in vim")
        vim "$CONFIG_FILE"
        break
        ;;
      "Cancel")
        break
        ;;
      *)
        echo "Invalid option."
        ;;
    esac
  done
}

check_or_create_config() {
  while true; do
    if [[ -f "$CONFIG_FILE" ]]; then
      read -rp "Config file exists. Use it? [y/n]: " reuse
      if [[ "$reuse" =~ ^[Yy]$ ]]; then
        return
      else
        edit_config
        # After editing/deleting, re-check if config file exists:
        if [[ ! -f "$CONFIG_FILE" ]]; then
          echo "Config file missing, prompting for new config..."
          prompt_config
        fi
      fi
    else
      prompt_config
    fi
  done
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

# Extract the last uploader from log (adapted from watchdog script)
extract_last_uploader() {
  grep -oP 'Initialize:\s+\K[^\\]+' "$LOGFILE" | tail -n 1
}

# Sanitize filename by removing/replacing problematic characters
sanitize_filename() {
  local name="$1"
  python3 -c "
name = '''$name'''
# Replace problematic characters
name = name.replace('/', '-').replace('\\\\', '-')
for ch in ['?', '*', ':', '\"', '<', '>', '|']:
    name = name.replace(ch, '')
name = name.strip(' .')
print(name)
"
}

# Extract playlist name from sldl output
extract_playlist_name_from_log() {
  local playlist_line=$(grep -E "(Downloading playlist:|Processing playlist:|Album:|Playlist:)" "$LOGFILE" | tail -n 1)
  if [[ -n "$playlist_line" ]]; then
    local name=$(echo "$playlist_line" | sed -E 's/.*(Downloading playlist:|Processing playlist:|Album:|Playlist:)\s*//g' | sed 's/[[:space:]]*$//')
    echo "$name"
  else
    echo ""
  fi
}

# Get playlist info from Spotify API
get_playlist_info() {
  local playlist_url="$1"
  local playlist_id="${playlist_url##*/}"
  playlist_id="${playlist_id%%\?*}"  # Remove query params if any

  local py_tmp=$(mktemp "$TMPDIR/spotiplex_info_XXXXXX.py")

  cat > "$py_tmp" <<EOF
import spotipy
from spotipy.oauth2 import SpotifyClientCredentials
import sys

try:
    auth = SpotifyClientCredentials(
        client_id="$SPOTIFY_ID",
        client_secret="$SPOTIFY_SECRET"
    )
    sp = spotipy.Spotify(auth_manager=auth)
    playlist = sp.playlist("$playlist_id", fields="name")
    print(playlist['name'])
except Exception as e:
    print("", file=sys.stderr)
EOF

  local playlist_name=$(python3 "$py_tmp" 2>/dev/null)
  rm -f "$py_tmp"

  if [[ -n "$playlist_name" ]]; then
    sanitize_filename "$playlist_name"
  else
    echo ""
  fi
}

generate_m3u_playlist() {
  local playlist_dir="$1"
  local playlist_name="$2"

  mkdir -p "$DL_PATH/Playlists"
  local sanitized_name
  sanitized_name=$(sanitize_filename "$playlist_name")
  local m3u_file="$DL_PATH/Playlists/${sanitized_name}.m3u"

  echo "[$(date '+%F %T')] Generating M3U file: $m3u_file" >> "$LOGFILE"

  # Replace this with your actual host music root
  local host_music_root="$DL_PATH"
  local container_music_root="/music"

  find "$playlist_dir" -maxdepth 1 -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" \) | sort | while read -r filepath; do
    # Convert host path to container path
    container_path="${filepath/#$host_music_root/$container_music_root}"
    echo "$container_path"
  done > "$m3u_file"
}

# Process completed playlist folder - simplified version using index data
process_completed_playlist() {
  local playlist_dir="$1"
  local index_file="$playlist_dir/_index.sldl"

  echo "[$(date '+%F %T')] Processing playlist: $playlist_dir"

  [[ ! -f "$index_file" ]] && { echo "No index file at $index_file, skipping"; return; }

  # Create a temporary Python script
  local temp_script=$(mktemp "$TMPDIR/spotiplex_process_XXXXXX.py")

  cat > "$temp_script" <<'PYTHONSCRIPT'
import sys
import os
import csv
import shutil

# Enable debugging in debug mode
DEBUG = os.environ.get('DEBUG_MODE', '0') == '1'

def debug(msg):
    if DEBUG:
        print(f"[PYTAG] {msg}", file=sys.stderr, flush=True)

debug("Script started")

# Import eyed3 for tagging
try:
    import eyed3
    eyed3.log.setLevel("ERROR")
    debug("eyed3 imported successfully")
    tagging_available = True
except ImportError as e:
    print(f"[WARNING] eyed3 not available, skipping tagging: {e}", file=sys.stderr)
    tagging_available = False

# Get arguments
index_path = sys.argv[1]
playlist_dir = sys.argv[2]

def sanitize(s):
    return ''.join(c for c in s if c not in '/\\?*:"<>|').strip(' .')

# Read index
debug(f"Reading index from {index_path}")
with open(index_path, newline='', encoding='utf-8') as f:
    reader = csv.reader(f)
    rows = list(reader)

header = rows[0]
data_rows = rows[1:]

updated_rows = [header]
files_processed = 0
files_renamed = 0
files_tagged = 0

debug(f"Processing {len(data_rows)} files")

for row in data_rows:
    if len(row) < 8:
        updated_rows.append(row)
        continue
    
    filepath, artist, album, title, length, tracktype, state, failurereason = row

    if not filepath.strip():
        print(f"[-] Skipping empty filepath: artist='{artist}', title='{title}'")
        updated_rows.append(row)
        continue

    files_processed += 1
    original_path = os.path.join(playlist_dir, filepath.strip('./\\'))

    if not os.path.isfile(original_path):
        debug(f"File not found: {original_path}")
        updated_rows.append(row)
        continue

    # Sanitize new filename
    new_name = f"{sanitize(artist)} - {sanitize(title)}"
    ext = os.path.splitext(filepath)[1]
    new_filename = new_name + ext
    new_path = os.path.join(playlist_dir, new_filename)

    # Rename file if needed
    if os.path.abspath(original_path) != os.path.abspath(new_path):
        print(f"[-] Renaming '{os.path.basename(original_path)}' → '{new_filename}'")
        try:
            shutil.move(original_path, new_path)
            files_renamed += 1
        except Exception as e:
            debug(f"Rename failed: {e}")
            updated_rows.append(row)
            continue

    # Tag file using data from index
    if tagging_available:
        debug(f"Tagging file: {new_filename}")
        debug(f"  From index - Artist: {artist}, Album: {album}, Title: {title}")
        
        try:
            audiofile = eyed3.load(new_path)
            
            if audiofile is None:
                debug(f"eyed3 couldn't load: {new_path}")
            else:
                if audiofile.tag is None:
                    debug(f"Initializing new tag")
                    audiofile.initTag()
                
                # Clear ALL existing tags first to ensure clean metadata
                if audiofile.tag:
                    # Set our clean metadata from index
                    audiofile.tag.artist = artist
                    audiofile.tag.title = title
                    audiofile.tag.album = album
                    
                    # Clear fields that might have junk data
                    audiofile.tag.album_artist = None
                    audiofile.tag.genre = None
                    audiofile.tag.disc_num = None
                    
                    # Remove all comments (correct way for eyed3)
                    for comment in list(audiofile.tag.comments):
                        audiofile.tag.comments.remove(comment.description)
                    
                    # Clear all user text frames (often contain junk)
                    for frame in list(audiofile.tag.user_text_frames):
                        audiofile.tag.user_text_frames.remove(frame.description)
                    
                    # Save the clean tags
                    audiofile.tag.save(version=eyed3.id3.ID3_V2_3)
                    debug(f"  ✓ Tags saved: {artist} - {title} [Album: {album}]")
                    files_tagged += 1
                    
        except Exception as e:
            debug(f"Tagging failed: {type(e).__name__}: {str(e)}")
            import traceback
            if DEBUG:
                traceback.print_exc(file=sys.stderr)
    else:
        debug("Skipping tagging - eyed3 not available")

    # Write row to updated index (with same data, just new filename)
    updated_rows.append([new_filename, artist, album, title, length, tracktype, state, failurereason])

debug(f"Summary - Processed: {files_processed}, Renamed: {files_renamed}, Tagged: {files_tagged}")

# Rewrite index file with updated filenames
with open(index_path, 'w', newline='', encoding='utf-8') as f_out:
    writer = csv.writer(f_out)
    writer.writerows(updated_rows)

debug("Index file updated")
debug("Script completed")
PYTHONSCRIPT

  # Execute the Python script
  echo "[$(date '+%F %T')] Running rename and tagging script..."
  python3 "$temp_script" "$index_file" "$playlist_dir" 2>&1

  # Clean up
  rm -f "$temp_script"

  echo "[$(date '+%F %T')] Completed rename, tagging and index rewrite."

    # Generate M3U playlist for Navidrome
  echo "[$(date '+%F %T')] Generating M3U for: $playlist_dir"
  generate_m3u_playlist "$playlist_dir" "$(basename "$playlist_dir")"
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
    "--max-stale-time" "10000"
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
    cache_path="/pstore/spotiplex-token",
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

with open("$PLAYLISTS_TMP", "w", encoding="utf-8") as f:
    for url in urls:
        f.write(url + "\\n")
EOF

  python3 "$PYTHON_TMP"

  # Process all playlists in background
  (
    while IFS= read -r playlist_url; do
      playlist_url=$(echo "$playlist_url" | xargs)
      [[ -z "$playlist_url" ]] && continue
      
      echo "[$(date '+%F %T')] Starting download for $playlist_url" >> "$LOGFILE"
      echo "[$(date '+%F %T')] Currently banned users: ${BANNED_USERS[*]}" >> "$LOGFILE"

      # Get playlist name from Spotify API first
      local playlist_name=$(get_playlist_info "$playlist_url")
      if [[ -z "$playlist_name" ]]; then
        echo "[$(date '+%F %T')] Warning: Could not get playlist name from Spotify API" >> "$LOGFILE"
      else
        echo "[$(date '+%F %T')] Playlist name: $playlist_name" >> "$LOGFILE"
      fi

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

      # Wait for sldl to complete
      while kill -0 $sldl_pid 2>/dev/null; do
        sleep 3
      done

      # Kill the monitor for this playlist
      kill $monitor_pid 2>/dev/null || true

      echo "[$(date '+%F %T')] Completed download for $playlist_url" >> "$LOGFILE"
      
      # Process the completed playlist folder for file renaming and tagging
      local playlist_folder=""
      
      # Try multiple methods to find the playlist folder
      # Method 1: Use the playlist name we got from Spotify API
      if [[ -n "$playlist_name" ]]; then
        playlist_folder="$DL_PATH/$playlist_name"
        if [[ ! -d "$playlist_folder" ]]; then
          # Try without sanitization in case sldl uses the raw name
          local playlist_id="${playlist_url##*/}"
          playlist_id="${playlist_id%%\?*}"
          local raw_name=$(python3 -c "
import spotipy
from spotipy.oauth2 import SpotifyClientCredentials
try:
    auth = SpotifyClientCredentials(client_id='$SPOTIFY_ID', client_secret='$SPOTIFY_SECRET')
    sp = spotipy.Spotify(auth_manager=auth)
    print(sp.playlist('$playlist_id', fields='name')['name'])
except: pass
" 2>/dev/null)
          if [[ -n "$raw_name" ]]; then
            playlist_folder="$DL_PATH/$raw_name"
          fi
        fi
      fi
      
      # Method 2: Look for the most recently modified directory in DL_PATH
      if [[ ! -d "$playlist_folder" ]]; then
        playlist_folder=$(find "$DL_PATH" -maxdepth 1 -type d -not -path "$DL_PATH" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
      fi
      
      # Method 3: Try to extract from sldl log output
      if [[ ! -d "$playlist_folder" ]]; then
        local extracted_name=$(extract_playlist_name_from_log)
        if [[ -n "$extracted_name" ]]; then
          playlist_folder="$DL_PATH/$extracted_name"
        fi
      fi
      
      if [[ -n "$playlist_folder" && -d "$playlist_folder" ]]; then
        echo "[$(date '+%F %T')] Processing playlist folder: $playlist_folder" >> "$LOGFILE"
        process_completed_playlist "$playlist_folder"
      else
        echo "[$(date '+%F %T')] Could not determine playlist folder for renaming" >> "$LOGFILE"
        echo "[$(date '+%F %T')] Checked paths: $DL_PATH/$playlist_name" >> "$LOGFILE"
        echo "[$(date '+%F %T')] Available folders in $DL_PATH:" >> "$LOGFILE"
        ls -la "$DL_PATH" >> "$LOGFILE" 2>&1
      fi

    done < "$PLAYLISTS_TMP"

    echo "[$(date '+%F %T')] All playlists processed" >> "$LOGFILE"
  ) &

  # Start tailing the log file in the foreground
  echo "[$(date '+%F %T')] Starting log tail..." >> "$LOGFILE"
  tail -f "$LOGFILE"
}

# Debug mode for testing single playlist
debug_single_playlist() {
  local playlist_url="$1"
  
  # Set debug flag for extra output
  export DEBUG_MODE=1
  
  echo "=== DEBUG MODE ==="
  echo "Testing playlist: $playlist_url"
  echo ""
  
  # Load config
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: No config file found. Run script normally first to create config."
    exit 1
  fi
  
  source "$CONFIG_FILE"
  
  # Initialize variables
  local sldl_folder=""
  local sldl_playlist_name=""
  
  # Get playlist info from Spotify
  echo "[DEBUG] Getting playlist info from Spotify API..."
  local playlist_name=$(get_playlist_info "$playlist_url")
  
  if [[ -n "$playlist_name" ]]; then
    echo "[DEBUG] ✓ Playlist name: '$playlist_name'"
    echo "[DEBUG] Expected folder: $DL_PATH/$playlist_name"
  else
    echo "[DEBUG] ✗ Failed to get playlist name from Spotify API"
  fi
  
  # Build and show sldl command
  echo ""
  echo "[DEBUG] Building sldl command..."
  build_sldl_command
  
  # Run the actual download
  echo ""
  echo "[DEBUG] Starting download..."
  echo "[DEBUG] Monitoring sldl output for folder creation..."
  echo "========================="
  
  # Create a temp file to capture sldl output
  local temp_output=$(mktemp)
  
  "${SLDL_CMD[@]}" "$playlist_url" 2>&1 | tee "$temp_output" | tee -a "$LOGFILE"
  
  echo "========================="
  echo "[DEBUG] Download completed"
  echo ""
  
  # Try to extract the actual folder name from sldl output
  echo "[DEBUG] Analyzing sldl output for folder information..."
  local sldl_folder=""
  
  # Look for common patterns in sldl output that indicate folder creation
  # Patterns to look for: "Downloading to", "Output directory", "Saving to", etc.
  if grep -q "Downloading.*to '" "$temp_output"; then
    sldl_folder=$(grep -oP "Downloading.*to '\K[^']+" "$temp_output" | head -1 | xargs dirname)
    echo "[DEBUG] Extracted folder from 'Downloading to' pattern: $sldl_folder"
  fi
  
  # Also check for album/playlist name in output
  local sldl_playlist_name=""
  if grep -q "Album:" "$temp_output"; then
    sldl_playlist_name=$(grep -oP "Album:\s*\K.*" "$temp_output" | head -1)
    echo "[DEBUG] sldl reported album/playlist name: $sldl_playlist_name"
  fi
  
  rm -f "$temp_output"
  
  # Now test folder detection
  echo "[DEBUG] Testing folder detection..."
  
  local found_folder=""
  
  # Method 1: Expected path using playlist name from API
  if [[ -n "$playlist_name" && -d "$DL_PATH/$playlist_name" ]]; then
    found_folder="$DL_PATH/$playlist_name"
    echo "[DEBUG] ✓ Method 1 SUCCESS: Found via expected path: $found_folder"
  else
    echo "[DEBUG] ✗ Method 1 FAILED: Expected path not found: $DL_PATH/$playlist_name"
    # Also check without parentheses in case sldl strips them
    local sanitized_name="${playlist_name//[()]/}"
    if [[ "$sanitized_name" != "$playlist_name" && -d "$DL_PATH/$sanitized_name" ]]; then
      found_folder="$DL_PATH/$sanitized_name"
      echo "[DEBUG] ✓ Method 1b SUCCESS: Found with sanitized name: $found_folder"
    fi
  fi
  
  # Method 2: Try to find from sldl output in log
  if [[ -z "$found_folder" ]]; then
    echo "[DEBUG] Trying method 2: Extract from log..."
    local extracted_name=$(extract_playlist_name_from_log)
    if [[ -n "$extracted_name" ]]; then
      local test_path="$DL_PATH/$extracted_name"
      if [[ -d "$test_path" ]]; then
        found_folder="$test_path"
        echo "[DEBUG] ✓ Method 2 SUCCESS: Found via log extraction: $found_folder"
      else
        echo "[DEBUG] ✗ Method 2 FAILED: Extracted '$extracted_name' but path doesn't exist"
      fi
    else
      echo "[DEBUG] ✗ Method 2 FAILED: Could not extract name from log"
    fi
  fi
  
  # Method 3: Most recent folder
  if [[ -z "$found_folder" ]]; then
    echo "[DEBUG] Trying method 3: Most recent folder..."
    found_folder=$(find "$DL_PATH" -maxdepth 1 -type d -not -path "$DL_PATH" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    if [[ -n "$found_folder" ]]; then
      echo "[DEBUG] ✓ Method 3 SUCCESS: Found via most recent: $found_folder"
    else
      echo "[DEBUG] ✗ Method 3 FAILED: No folders found"
    fi
  fi
  
  # Method 4: Look for any folder with an _index.sldl file
  if [[ -z "$found_folder" ]]; then
    echo "[DEBUG] Trying method 4: Any folder with _index.sldl..."
    while IFS= read -r -d '' index_file; do
      local parent_dir=$(dirname "$index_file")
      # Check if this index was modified recently (within last 5 minutes)
      if [[ $(find "$index_file" -mmin -5 -print 2>/dev/null) ]]; then
        found_folder="$parent_dir"
        echo "[DEBUG] ✓ Method 4 SUCCESS: Found via recent index file: $found_folder"
        break
      fi
    done < <(find "$DL_PATH" -maxdepth 2 -name "_index.sldl" -print0 2>/dev/null)
    
    if [[ -z "$found_folder" ]]; then
      echo "[DEBUG] ✗ Method 4 FAILED: No recent _index.sldl files found"
    fi
  fi
  
  # Show all folders in download path for debugging
  echo ""
  echo "[DEBUG] All folders in $DL_PATH:"
  ls -la "$DL_PATH" | grep '^d'
  
  echo ""
  echo "[DEBUG] Looking for folders modified in last 10 minutes:"
  find "$DL_PATH" -maxdepth 1 -type d -mmin -10 -not -path "$DL_PATH" -exec ls -ld {} \; 2>/dev/null || echo "[DEBUG] No recently modified folders"
  
  # If we found a folder, test renaming and tagging
  if [[ -n "$found_folder" && -d "$found_folder" ]]; then
    echo ""
    echo "[DEBUG] Found folder: $found_folder"
    
    recent_files=$(find "$found_folder" -maxdepth 1 -type f -mmin -10 -print | wc -l 2>/dev/null || echo 0)
    if [[ $recent_files -eq 0 ]]; then
      echo "[DEBUG] WARNING: This folder has no recently modified files!"
      echo "[DEBUG] This might be the wrong folder."
    fi
    
    echo ""
    echo "[DEBUG] Contents before rename:"
    ls -la "$found_folder" | grep -E "\.(mp3|flac|m4a|ogg)$" | head -20 || echo "[DEBUG] No music files found"
    
    if [[ -f "$found_folder/_index.sldl" ]]; then
      echo ""
      echo "[DEBUG] Index file sample:"
      head -10 "$found_folder/_index.sldl"
      
      echo ""
      echo "[DEBUG] Index file stats:"
      echo "  Total lines: $(wc -l < "$found_folder/_index.sldl")"
      echo "  Modified: $(stat -c "%y" "$found_folder/_index.sldl" 2>/dev/null || stat -f "%Sm" "$found_folder/_index.sldl" 2>/dev/null || echo "unknown")"
    else
      echo ""
      echo "[DEBUG] WARNING: No _index.sldl file found!"
    fi
    
    echo ""
    echo "[DEBUG] Running rename and tagging process..."
    echo "========================="
    
    # Run the rename and tagging with extra debug output
    process_completed_playlist "$found_folder"
    
    echo "========================="
    echo ""
    echo "[DEBUG] Contents after rename:"
    ls -la "$found_folder" | head -10
    
    # Check if tags were applied
    echo ""
    echo "[DEBUG] Checking tags on first few files:"
    for file in "$found_folder"/*.mp3; do
      if [[ -f "$file" ]]; then
        echo ""
        echo "File: $(basename "$file")"
        python3 -c "
import eyed3
eyed3.log.setLevel('ERROR')
try:
    af = eyed3.load('$file')
    if af and af.tag:
        print(f'  Artist: {af.tag.artist}')
        print(f'  Title: {af.tag.title}')
        print(f'  Album: {af.tag.album}')
        print(f'  Track#: {af.tag.track_num[0] if af.tag.track_num else \"None\"}')
    else:
        print('  No tags found')
except Exception as e:
    print(f'  Error: {e}')
"
        # Only check first 3 files
        if [[ $(find "$found_folder" -name "*.mp3" -print | head -3 | wc -l) -eq 3 ]]; then
          break
        fi
      fi
    done
    
    echo ""
    echo "[DEBUG] Mismatch Analysis:"
    echo "[DEBUG] Files in folder but not in index:"
    
    # Get list of files in folder
    local folder_files=()
    while IFS= read -r -d '' file; do
      folder_files+=("$(basename "$file")")
    done < <(find "$found_folder" -maxdepth 1 -type f -name "*.mp3" -print0)
    
    # Get list of files from index
    local index_files=()
    if [[ -f "$found_folder/_index.sldl" ]]; then
      while IFS=, read -r filepath rest; do
        if [[ "$filepath" != "filepath" ]]; then
          filepath="${filepath#./}"
          filepath="${filepath%\"}"
          filepath="${filepath#\"}"
          index_files+=("$filepath")
        fi
      done < "$found_folder/_index.sldl"
    fi
    
    # Show files in folder but not in index
    for file in "${folder_files[@]}"; do
      if [[ ! " ${index_files[*]} " =~ " ${file} " ]]; then
        echo "  - $file"
      fi
    done
    
    echo ""
    echo "[DEBUG] Files in index but not in folder:"
    for file in "${index_files[@]}"; do
      if [[ ! " ${folder_files[*]} " =~ " ${file} " ]]; then
        echo "  - $file"
      fi
    done
  else
    echo ""
    echo "[DEBUG] ERROR: Could not find downloaded folder!"
    echo "[DEBUG] Checked paths:"
    echo "  - $DL_PATH/$playlist_name"
    echo "  - Most recent folder in $DL_PATH"
  fi
  
  echo ""
  echo "[DEBUG] === SUMMARY ==="
  echo "[DEBUG] Spotify playlist name: ${playlist_name:-'(failed to get)'}"
  echo "[DEBUG] Expected folder path: $DL_PATH/${playlist_name:-'???'}"
  echo "[DEBUG] Actual folder found: ${found_folder:-'(none)'}"
  
  if [[ -n "$sldl_playlist_name" ]] && [[ "$sldl_playlist_name" != "$playlist_name" ]]; then
    echo "[DEBUG] Note: sldl used different name: $sldl_playlist_name"
  fi
  
  echo ""
  echo "=== DEBUG MODE COMPLETE ==="
}

# Parse command line arguments
SUPPRESS_DIALOG=0
DEBUG_MODE=0
DEBUG_URL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -s)
      SUPPRESS_DIALOG=1
      shift
      ;;
    -d)
      DEBUG_MODE=1
      DEBUG_URL="${2:-}"
      if [[ -z "$DEBUG_URL" ]]; then
        echo "Error: -d requires a playlist URL"
        echo "Usage: $0 -d <spotify_playlist_url>"
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [-s] [-d <spotify_playlist_url>]"
      exit 1
      ;;
  esac
done

# Run appropriate mode
if [[ $DEBUG_MODE -eq 1 ]]; then
  # Debug mode - single playlist test
  install_dependencies
  download_sldl
  debug_single_playlist "$DEBUG_URL"
else
  # Normal mode
  kill_existing_instances
  install_dependencies
  download_sldl

  if [[ $SUPPRESS_DIALOG -eq 1 ]]; then
    [[ -f "$CONFIG_FILE" ]] || { echo "No config file found, cannot suppress prompts."; exit 1; }
  else
    check_or_create_config
  fi

  main_loop
fi

