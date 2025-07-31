#!/bin/bash
set -euo pipefail

CONFIG_FILE="/pstore/spotiplex.conf"
LOGFILE="/pstore/spotiplex.log"
TMPDIR="/tmp"
SLSL_ZIP_URL="https://github.com/fiso64/slsk-batchdl/releases/latest/download/sldl_linux-x64.zip"
SLSK_BIN="$TMPDIR/sldl"
PYTHON_TMP=""
PLAYLISTS_TMP=""
ARTISTS_TMP=""
TIMEOUT_SECONDS=300
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
BAN_FILE="/pstore/banned_users.txt"
DISCOGRAPHY_FILE="/pstore/discography_albums.txt"

# Download modes
MODE_PLAYLISTS="playlists"
MODE_DISCOGRAPHY_ALL="discography_all"
MODE_DISCOGRAPHY_SELECTED="discography_selected"

# Ensure persistent directory exists
mkdir -p /pstore

# Ensure ban file exists
[[ -f "$BAN_FILE" ]] || touch "$BAN_FILE"

# Load banned users from file into array
readarray -t BANNED_USERS < <(grep -v '^#' "$BAN_FILE" | grep -v '^$')

cleanup() {
  [[ -n "$PYTHON_TMP" ]] && rm -f "$PYTHON_TMP"
  [[ -n "$PLAYLISTS_TMP" ]] && rm -f "$PLAYLISTS_TMP"
  [[ -n "$ARTISTS_TMP" ]] && rm -f "$ARTISTS_TMP"
}
trap cleanup EXIT

print_header() {
  echo -e "\n========================[ Run started at $(date '+%F %T') ]========================\n" >> "$LOGFILE"
}

install_gum() {
  echo "[*] Installing gum..."
  
  # Check if gum is already installed
  if command -v gum &>/dev/null; then
    echo "[*] gum is already installed"
    return 0
  fi
  
  # Detect OS and architecture
  local os=""
  local arch=""
  
  case "$(uname -s)" in
    Linux*)   os="Linux" ;;
    Darwin*)  os="Darwin" ;;
    *)        echo "Unsupported OS for gum auto-install"; return 1 ;;
  esac
  
  case "$(uname -m)" in
    x86_64)   arch="x86_64" ;;
    aarch64)  arch="arm64" ;;
    arm64)    arch="arm64" ;;
    *)        echo "Unsupported architecture for gum auto-install"; return 1 ;;
  esac
  
  local gum_version="0.16.2"
  local gum_filename="gum_${gum_version}_${os}_${arch}.tar.gz"
  local gum_url="https://github.com/charmbracelet/gum/releases/download/v${gum_version}/${gum_filename}"
  local gum_dir="/tmp/gum_install"
  local original_dir="$(pwd)"
  
  echo "[*] Downloading gum for ${os}_${arch} from: $gum_url"
  
  # Create temporary directory
  mkdir -p "$gum_dir"
  cd "$gum_dir"
  if [[ $? -ne 0 ]]; then
    echo "Failed to cd to gum_dir"
    return 1
  fi
  
  # Download and extract gum
  if command -v wget &>/dev/null; then
    wget -q "$gum_url" -O "$gum_filename"
  elif command -v curl &>/dev/null; then
    curl -sL "$gum_url" -o "$gum_filename"
  else
    echo "Error: Neither wget nor curl found"
    cd "$original_dir"
    return 1
  fi
  
  if [[ ! -f "$gum_filename" ]]; then
    echo "Error: Failed to download gum"
    cd "$original_dir"
    return 1
  fi
  
  # Extract and install
  tar -xzf "$gum_filename"
  
  # Find the gum binary - check common locations
  local gum_binary=""
  if [[ -f "gum" ]]; then
    gum_binary="gum"
  else
    # Look for gum in any subdirectory
    gum_binary=$(find . -name "gum" -type f 2>/dev/null | head -1)
  fi
  
  if [[ -z "$gum_binary" ]] || [[ ! -f "$gum_binary" ]]; then
    echo "Error: Could not find gum binary in extracted files"
    echo "Available files:"
    ls -la
    cd "$original_dir"
    return 1
  fi
  
  # Install to /usr/local/bin
  chmod +x "$gum_binary"
  
  # Ensure /usr/local/bin exists
  if [[ ! -d "/usr/local/bin" ]]; then
    if command -v sudo &>/dev/null && [[ $EUID -ne 0 ]]; then
      sudo mkdir -p /usr/local/bin
    else
      mkdir -p /usr/local/bin
    fi
  fi
  
  if command -v sudo &>/dev/null && [[ $EUID -ne 0 ]]; then
    sudo cp "$gum_binary" /usr/local/bin/gum
  else
    cp "$gum_binary" /usr/local/bin/gum
  fi
  
  # Cleanup
  cd "$original_dir"
  rm -rf "$gum_dir"
  
  # Add /usr/local/bin to PATH if it's not already there
  if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
    export PATH="/usr/local/bin:$PATH"
  fi
  
  # Verify installation
  if command -v gum &>/dev/null; then
    echo "[*] gum installed successfully"
    return 0
  else
    echo "Error: gum installation failed"
    return 1
  fi
}

install_dependencies() {
  echo "[*] Installing dependencies..."
  if command -v apt-get &>/dev/null; then
    apt-get update
    apt-get install -y python3 python3-pip unzip wget libicu-dev procps curl tar
  elif command -v dnf &>/dev/null; then
    dnf install -y python3 python3-pip unzip wget libicu-dev procps curl tar
  elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm python python-pip unzip wget libicu-dev procps curl tar
  else
    echo "Package manager not detected, please install python3, pip, wget, unzip manually"
    exit 1
  fi
  
  # Install gum manually
  if ! install_gum; then
    echo "[*] Warning: gum installation failed, basic prompts will be used"
  fi
  
  python3 -m pip install spotipy eyed3 requests
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
  
  echo ""
  echo "Additional configuration:"
  read -rp "Email for MusicBrainz API: " MB_EMAIL
  
  echo ""
  echo "Choose download mode:"
  
  # Ask for download mode using gum if available, otherwise use basic prompt
  if command -v gum &>/dev/null; then
    echo "Using interactive selection (gum)..."
    DOWNLOAD_MODE=$(gum choose \
      "playlists" \
      "discography_all" \
      "discography_selected" \
      --header "Select download mode:" \
      --height 8)
    
    # Show what was selected
    case "$DOWNLOAD_MODE" in
      "playlists") echo "Selected: Download individual playlists (current behavior)" ;;
      "discography_all") echo "Selected: Download full discographies of all artists from all playlists" ;;
      "discography_selected") echo "Selected: Download discographies from selected playlists only" ;;
    esac
  else
    echo "gum not available, using basic selection..."
    echo "1) playlists - Download individual playlists (current behavior)"
    echo "2) discography_all - Download full discographies of all artists from all playlists"
    echo "3) discography_selected - Download discographies from selected playlists only"
    while true; do
      read -rp "Enter choice [1-3]: " choice
      case $choice in
        1) DOWNLOAD_MODE="playlists"; break ;;
        2) DOWNLOAD_MODE="discography_all"; break ;;
        3) DOWNLOAD_MODE="discography_selected"; break ;;
        *) echo "Invalid choice, please enter 1, 2, or 3." ;;
      esac
    done
  fi

  echo ""
  echo "Configuration summary:"
  echo "  Soulseek user: $SL_USERNAME"
  echo "  Download path: $DL_PATH"
  echo "  MusicBrainz email: $MB_EMAIL"
  echo "  Download mode: $DOWNLOAD_MODE"
  echo ""
  
  cat > "$CONFIG_FILE" <<EOF
SL_USERNAME=$(printf '%q' "$SL_USERNAME")
SL_PASSWORD=$(printf '%q' "$SL_PASSWORD")
SPOTIFY_ID=$(printf '%q' "$SPOTIFY_ID")
SPOTIFY_SECRET=$(printf '%q' "$SPOTIFY_SECRET")
SPOTIFY_REDIRECT=$(printf '%q' "$SPOTIFY_REDIRECT")
DL_PATH=$(printf '%q' "$DL_PATH")
MB_EMAIL=$(printf '%q' "$MB_EMAIL")
DOWNLOAD_MODE=$(printf '%q' "$DOWNLOAD_MODE")
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
        break
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
  
  pkill -f "$SLSK_BIN" 2>/dev/null || true
}

extract_last_uploader() {
  grep -oP 'Initialize:\s+\K[^\\]+' "$LOGFILE" | tail -n 1
}

sanitize_filename() {
  local name="$1"
  python3 -c "
name = '''$name'''
name = name.replace('/', '-').replace('\\\\', '-')
for ch in ['?', '*', ':', '\"', '<', '>', '|']:
    name = name.replace(ch, '')
name = name.strip(' .')
print(name)
"
}

get_playlist_info() {
  local playlist_url="$1"
  local playlist_id="${playlist_url##*/}"
  playlist_id="${playlist_id%%\?*}"

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

# Get all unique artists from playlists
get_unique_artists() {
  local selected_playlists="$1"
  ARTISTS_TMP=$(mktemp "$TMPDIR/spotiplex_artists_XXXXXX.py")

  cat > "$ARTISTS_TMP" <<EOF
import spotipy
from spotipy.oauth2 import SpotifyOAuth
import sys

auth = SpotifyOAuth(
    client_id="$SPOTIFY_ID",
    client_secret="$SPOTIFY_SECRET",
    redirect_uri="$SPOTIFY_REDIRECT",
    scope="playlist-read-private playlist-read-collaborative",
    open_browser=False,
    cache_path="/pstore/spotiplex-token",
    show_dialog=False
)

token_info = auth.get_cached_token()
if not token_info:
    print("Error: No cached token found", file=sys.stderr)
    sys.exit(1)

sp = spotipy.Spotify(auth=token_info["access_token"])
artist_names = set()

# Read selected playlist URLs if provided
selected_urls = set()
if "$selected_playlists":
    with open("$selected_playlists", "r") as f:
        selected_urls = {line.strip() for line in f if line.strip()}

offset = 0
while True:
    playlists = sp.current_user_playlists(limit=50, offset=offset)["items"]
    if not playlists:
        break
    
    for playlist in playlists:
        playlist_url = playlist["external_urls"]["spotify"]
        
        # If we have selected playlists, only process those
        if selected_urls and playlist_url not in selected_urls:
            continue
            
        print(f"Processing playlist: {playlist['name']}", file=sys.stderr)
        
        # Get all tracks from this playlist
        results = sp.playlist_tracks(playlist["id"])
        while results:
            for item in results["items"]:
                track = item.get("track")
                if track and track.get("artists"):
                    for artist in track["artists"]:
                        artist_names.add(artist["name"])
            results = sp.next(results) if results["next"] else None
    
    offset += 50

# Output unique artists
for artist in sorted(artist_names):
    print(artist)
EOF

  python3 "$ARTISTS_TMP"
  rm -f "$ARTISTS_TMP"
}

generate_m3u_playlist() {
  local playlist_dir="$1"
  local playlist_name="$2"

  mkdir -p "$DL_PATH/Playlists"
  local sanitized_name
  sanitized_name=$(sanitize_filename "$playlist_name")
  local m3u_file="$DL_PATH/Playlists/${sanitized_name}.m3u"

  echo "[$(date '+%F %T')] Generating M3U file: $m3u_file" >> "$LOGFILE"

  local host_music_root="$DL_PATH"
  local container_music_root="/music"

  find "$playlist_dir" -maxdepth 2 -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" \) | sort | while read -r filepath; do
    container_path="${filepath/#$host_music_root/$container_music_root}"
    echo "$container_path"
  done > "$m3u_file"
}

# Generate playlist M3U files that reference centralized artist folders
generate_playlist_m3u_from_tracks() {
  local playlist_name="$1"
  local tracks_info="$2"  # File containing track info (artist, title)
  
  mkdir -p "$DL_PATH/Playlists"
  local sanitized_name
  sanitized_name=$(sanitize_filename "$playlist_name")
  local m3u_file="$DL_PATH/Playlists/${sanitized_name}.m3u"

  echo "[$(date '+%F %T')] Generating M3U file from tracks: $m3u_file" >> "$LOGFILE"

  local host_music_root="$DL_PATH"
  local container_music_root="/music"

  # Read track info and find corresponding files in artist folders
  while IFS='|' read -r artist title; do
    # Look for the track in the artist's folder
    local artist_folder="$DL_PATH/Artists/$(sanitize_filename "$artist")"
    if [[ -d "$artist_folder" ]]; then
      # Find files that match this track
      find "$artist_folder" -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" \) | while read -r filepath; do
        local filename=$(basename "$filepath")
        # Check if this file matches the track (basic matching)
        if [[ "$filename" == *"$title"* ]] || [[ "$filename" == *"$(sanitize_filename "$title")"* ]]; then
          container_path="${filepath/#$host_music_root/$container_music_root}"
          echo "$container_path"
          break  # Only add the first match
        fi
      done
    fi
  done < "$tracks_info" > "$m3u_file"
}

process_completed_playlist() {
  local playlist_dir="$1"
  local index_file="$playlist_dir/_index.sldl"

  echo "[$(date '+%F %T')] Processing playlist: $playlist_dir"

  [[ ! -f "$index_file" ]] && { echo "No index file at $index_file, skipping"; return; }

  # Same processing script as before, but adapted for new structure
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

try:
    import eyed3
    eyed3.log.setLevel("ERROR")
    debug("eyed3 imported successfully")
    tagging_available = True
except ImportError as e:
    print(f"[WARNING] eyed3 not available, skipping tagging: {e}", file=sys.stderr)
    tagging_available = False

index_path = sys.argv[1]
playlist_dir = sys.argv[2]

def sanitize(s):
    return ''.join(c for c in s if c not in '/\\?*:"<>|').strip(' .')

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

    new_name = f"{sanitize(artist)} - {sanitize(title)}"
    ext = os.path.splitext(filepath)[1]
    new_filename = new_name + ext
    new_path = os.path.join(playlist_dir, new_filename)

    if os.path.abspath(original_path) != os.path.abspath(new_path):
        print(f"[-] Renaming '{os.path.basename(original_path)}' → '{new_filename}'")
        try:
            shutil.move(original_path, new_path)
            files_renamed += 1
        except Exception as e:
            debug(f"Rename failed: {e}")
            updated_rows.append(row)
            continue

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
                
                if audiofile.tag:
                    audiofile.tag.artist = artist
                    audiofile.tag.title = title
                    audiofile.tag.album = album
                    
                    audiofile.tag.album_artist = None
                    audiofile.tag.genre = None
                    audiofile.tag.disc_num = None
                    
                    for comment in list(audiofile.tag.comments):
                        audiofile.tag.comments.remove(comment.description)
                    
                    for frame in list(audiofile.tag.user_text_frames):
                        audiofile.tag.user_text_frames.remove(frame.description)
                    
                    audiofile.tag.save(version=eyed3.id3.ID3_V2_3)
                    debug(f"  ✓ Tags saved: {artist} - {title} [Album: {album}]")
                    files_tagged += 1
                    
        except Exception as e:
            debug(f"Tagging failed: {type(e).__name__}: {str(e)}")
    else:
        debug("Skipping tagging - eyed3 not available")

    updated_rows.append([new_filename, artist, album, title, length, tracktype, state, failurereason])

debug(f"Summary - Processed: {files_processed}, Renamed: {files_renamed}, Tagged: {files_tagged}")

with open(index_path, 'w', newline='', encoding='utf-8') as f_out:
    writer = csv.writer(f_out)
    writer.writerows(updated_rows)

debug("Index file updated")
debug("Script completed")
PYTHONSCRIPT

  python3 "$temp_script" "$index_file" "$playlist_dir" 2>&1
  rm -f "$temp_script"

  echo "[$(date '+%F %T')] Completed rename, tagging and index rewrite."
}

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
  
  if [[ -n "${SPOTIFY_REFRESH:-}" ]]; then
    args+=("--spotify-refresh" "$SPOTIFY_REFRESH")
  fi
  
  if [[ ${#BANNED_USERS[@]} -gt 0 ]]; then
    local joined=$(printf "%s," "${BANNED_USERS[@]}")
    joined="${joined%,}"
    args+=("--banned-users" "$joined")
  fi
  
  SLDL_CMD=("$base_cmd" "${args[@]}")
}

monitor_and_restart() {
  local logfile="$1"
  local download_target="$2"
  local last_size=0
  local unchanged_count=0
  local last_line=""

  while true; do
    if [[ -f "$logfile" ]]; then
      current_size=$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo "0")
      new_line=$(tail -n 1 "$logfile" 2>/dev/null || echo "")
      
      if [[ "$current_size" -eq "$last_size" && "$new_line" == "$last_line" ]]; then
        ((unchanged_count++))
        if [[ $unchanged_count -ge $TIMEOUT_SECONDS ]]; then
          echo -e "\n[$(date '+%F %T')] No output for ${TIMEOUT_SECONDS} seconds, checking for user to ban..." >> "$logfile"
          
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
    sleep 1
  done
}

# Main loop for playlist mode (existing behavior)
playlist_mode() {
  echo "[$(date '+%F %T')] Running in playlist mode" >> "$LOGFILE"
  
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

  # Process playlists (existing logic)
  while IFS= read -r playlist_url; do
    playlist_url=$(echo "$playlist_url" | xargs)
    [[ -z "$playlist_url" ]] && continue
    
    echo "[$(date '+%F %T')] Starting download for $playlist_url" >> "$LOGFILE"
    
    local playlist_name=$(get_playlist_info "$playlist_url")
    if [[ -n "$playlist_name" ]]; then
      echo "[$(date '+%F %T')] Playlist name: $playlist_name" >> "$LOGFILE"
    fi

    build_sldl_command
    
    "${SLDL_CMD[@]}" "$playlist_url" >> "$LOGFILE" 2>&1 &
    local sldl_pid=$!

    monitor_and_restart "$LOGFILE" "$playlist_url" &
    local monitor_pid=$!
    
    trap "kill $monitor_pid 2>/dev/null || true" EXIT

    while kill -0 $sldl_pid 2>/dev/null; do
      sleep 3
    done

    kill $monitor_pid 2>/dev/null || true

    echo "[$(date '+%F %T')] Completed download for $playlist_url" >> "$LOGFILE"
    
    # Process completed playlist
    local playlist_folder=""
    if [[ -n "$playlist_name" ]]; then
      playlist_folder="$DL_PATH/$playlist_name"
    fi
    
    if [[ ! -d "$playlist_folder" ]]; then
      playlist_folder=$(find "$DL_PATH" -maxdepth 1 -type d -not -path "$DL_PATH" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    fi
    
    if [[ -n "$playlist_folder" && -d "$playlist_folder" ]]; then
      echo "[$(date '+%F %T')] Processing playlist folder: $playlist_folder" >> "$LOGFILE"
      process_completed_playlist "$playlist_folder"
      generate_m3u_playlist "$playlist_folder" "$(basename "$playlist_folder")"
    fi

  done < "$PLAYLISTS_TMP"
}

# Main loop for discography mode - FIXED VERSION
discography_mode() {
  local mode="$1"
  echo "[$(date '+%F %T')] Running in discography mode: $mode" >> "$LOGFILE"
  
  # Create Artists directory structure
  mkdir -p "$DL_PATH/Artists"
  
  # Get unique artists
  local artists_file=$(mktemp "$TMPDIR/spotiplex_artists_XXXXXX.txt")
  local selected_playlists=""
  
  if [[ "$mode" == "$MODE_DISCOGRAPHY_SELECTED" ]]; then
    # Let user select playlists
    echo "Select playlists for discography download:"
    PLAYLISTS_TMP=$(mktemp "$TMPDIR/spotiplex_playlists_XXXXXX.txt")
    
    # Get all playlists first
    echo "Fetching your playlists..."
    python3 << EOF > "$PLAYLISTS_TMP" 2>> "$LOGFILE"
import spotipy
from spotipy.oauth2 import SpotifyOAuth
import sys

auth = SpotifyOAuth(
    client_id="$SPOTIFY_ID",
    client_secret="$SPOTIFY_SECRET",
    redirect_uri="$SPOTIFY_REDIRECT",
    scope="playlist-read-private playlist-read-collaborative",
    open_browser=False,
    cache_path="/pstore/spotiplex-token",
    show_dialog=False
)

token_info = auth.get_cached_token()
if token_info:
    sp = spotipy.Spotify(auth=token_info["access_token"])
    offset = 0
    while True:
        playlists = sp.current_user_playlists(limit=50, offset=offset)["items"]
        if not playlists:
            break
        for playlist in playlists:
            print(f"{playlist['external_urls']['spotify']}|{playlist['name']}")
        offset += 50
else:
    print("Error: No Spotify token found", file=sys.stderr)
EOF
    
    # Check if we got any playlists
    if [[ ! -s "$PLAYLISTS_TMP" ]]; then
      echo "Error: No playlists found or Spotify authentication failed"
      echo "Please check your Spotify credentials and try again"
      return 1
    fi
    
    local playlist_count=$(wc -l < "$PLAYLISTS_TMP")
    echo "Found $playlist_count playlists"
    
    # Let user select with gum or basic prompt
    selected_playlists=$(mktemp "$TMPDIR/spotiplex_selected_XXXXXX.txt")
    
    if command -v gum &>/dev/null; then
      # Use gum for multi-select - robust approach using pipe separator
      echo "Use SPACE to select playlists, ENTER to confirm:"
      
      # Create a temporary file with numbered playlists for robust selection
      local playlist_mapping_tmp=$(mktemp "$TMPDIR/spotiplex_mapping_XXXXXX.txt")
      local playlist_names_tmp=$(mktemp "$TMPDIR/spotiplex_names_XXXXXX.txt")
      
      # Create numbered mapping and names file using pipe separator
      local counter=1
      while IFS='|' read -r url name; do
        echo "$counter|$url" >> "$playlist_mapping_tmp"
        echo "$counter) $name" >> "$playlist_names_tmp"
        ((counter++))
      done < "$PLAYLISTS_TMP"
      
      # Let user select using numbered format
      local selected_numbers_tmp=$(mktemp "$TMPDIR/spotiplex_selected_numbers_XXXXXX.txt")
      gum choose --no-limit < "$playlist_names_tmp" | sed 's/) .*//' > "$selected_numbers_tmp"
      
      # Convert numbers back to URLs using the mapping
      while IFS= read -r selected_number; do
        grep "^$selected_number|" "$playlist_mapping_tmp" | cut -d'|' -f2
      done < "$selected_numbers_tmp" > "$selected_playlists"
      
      # Cleanup temp files
      rm -f "$playlist_mapping_tmp" "$playlist_names_tmp" "$selected_numbers_tmp"
      
    else
      # Fallback to basic selection
      echo "Available playlists:"
      local counter=1
      declare -A playlist_array
      while IFS='|' read -r url name; do
        echo "$counter) $name"
        playlist_array["$counter"]="$url"
        ((counter++))
      done < "$PLAYLISTS_TMP"
      
      echo "Enter playlist numbers separated by spaces (e.g., 1 3 5):"
      read -rp "Playlist numbers: " selection
      
      for num in $selection; do
        if [[ -n "${playlist_array[$num]:-}" ]]; then
          echo "${playlist_array[$num]}" >> "$selected_playlists"
        fi
      done
    fi
    
    # Check if user selected any playlists
    if [[ ! -s "$selected_playlists" ]]; then
      echo "No playlists selected. Exiting."
      return 1
    fi
    
    local selected_count=$(wc -l < "$selected_playlists")
    echo "Selected $selected_count playlists for discography download"
  fi
  
  echo "[$(date '+%F %T')] Extracting unique artists..." >> "$LOGFILE"
  get_unique_artists "$selected_playlists" > "$artists_file" 2>> "$LOGFILE"
  
  local artist_count=$(wc -l < "$artists_file")
  echo "[$(date '+%F %T')] Found $artist_count unique artists" >> "$LOGFILE"
  
  if [[ $artist_count -eq 0 ]]; then
    echo "No artists found. This could be because:"
    echo "- No playlists were selected"
    echo "- Selected playlists are empty"
    echo "- Spotify API access failed"
    return 1
  fi
  
  # Show first few artists for confirmation
  echo "First few artists found:"
  head -10 "$artists_file"
  
  # Generate discography list with individual tracks
  echo "[$(date '+%F %T')] Generating discography with individual tracks..." >> "$LOGFILE"
  echo "Starting discography generation in background..."
  echo "Progress will be logged to $LOGFILE"
  echo "You can safely detach from this session - the process will continue running."
  echo ""
  
  # Auto-use existing file if it exists and has content, otherwise generate
  if [[ -f "$DISCOGRAPHY_FILE" && -s "$DISCOGRAPHY_FILE" ]]; then
    local track_count=$(wc -l < "$DISCOGRAPHY_FILE")
    echo "[$(date '+%F %T')] Using existing discography file with $track_count tracks" >> "$LOGFILE"
    echo "Using existing discography file with $track_count tracks"
  else
    echo "[$(date '+%F %T')] Starting discography generation in background..." >> "$LOGFILE"
    
    # Create a wrapper script that runs the discography generation completely in background
    local bg_script=$(mktemp "$TMPDIR/spotiplex_bg_discography_XXXXXX.sh")
    
    cat > "$bg_script" <<'BACKGROUND_SCRIPT'
#!/bin/bash
set -euo pipefail

# All arguments passed to this script
ARTISTS_FILE="$1"
DISCOGRAPHY_FILE="$2"
LOGFILE="$3"
MB_EMAIL="$4"

echo "[$(date '+%F %T')] Background discography generation started (PID: $$)" >> "$LOGFILE"

# Export variables for Python script
export ARTISTS_FILE
export DISCOGRAPHY_FILE
export MB_EMAIL
export PYTHONUNBUFFERED=1

# Redirect all output to log file and close stdin
exec 1>> "$LOGFILE" 2>> "$LOGFILE" 0</dev/null

# Set up signal handling for clean exit - but don't kill background discography process
cleanup_bg() {
  if [[ "$1" != "TERM" ]]; then
    echo "[$(date '+%F %T')] Background discography generation continuing after main process detach (PID: $$)" >> "$LOGFILE"
  else
    echo "[$(date '+%F %T')] Background discography generation terminated (PID: $$)" >> "$LOGFILE"
    exit 1
  fi
}
trap 'cleanup_bg INT' INT
trap 'cleanup_bg TERM' TERM

generate_discography_bg() {
  local artists_file="$1"
  
  echo "[$(date '+%F %T')] Generating discography with individual tracks from artists..." 
  
  PYTHONUNBUFFERED=1 python3 -u << 'PYTHON_SCRIPT'
import requests
import time
import sys
import os
import re
import signal

# For background processes, ignore SIGINT (Ctrl+C) but still handle SIGTERM for clean shutdown
def signal_handler(sig, frame):
    if sig == signal.SIGTERM:
        print(f"[{time.strftime('%F %T')}] Received SIGTERM, exiting gracefully...", flush=True)
        sys.exit(1)
    elif sig == signal.SIGINT:
        print(f"[{time.strftime('%F %T')}] Received SIGINT - ignoring (background process)", flush=True)
        # Don't exit on SIGINT when running in background

# Only handle SIGTERM for clean shutdown, ignore SIGINT
signal.signal(signal.SIGINT, signal.SIG_IGN)  # Ignore SIGINT completely
signal.signal(signal.SIGTERM, signal_handler)

MB_API = "https://musicbrainz.org/ws/2"
SLEEP_TIME = 1.5  # More conservative rate limiting
HEADERS = {
    "User-Agent": f"Spotiplex/1.0 ({os.environ.get('MB_EMAIL', 'unknown')})"
}
SKIP_KEYWORDS = [
    "compilation", "greatest hits", "anthology", "essentials",
    "live", "remix", "remixes", "versions", "rarities", "b-sides", 
    "instrumental", "compilations", "essential", "karaoke"
]

def sanitize_for_sldl(text):
    """Sanitize text for sldl input format - escape quotes and problematic characters"""
    if not text:
        return ""
    
    # Remove or replace problematic characters that could break sldl parsing
    # Replace quotes with smart quotes or remove them
    text = text.replace('"', "'")  # Replace double quotes with single quotes
    text = text.replace("'", "'")  # Replace curly single quotes with straight quotes
    text = text.replace(""", "'")  # Replace curly double quotes
    text = text.replace(""", "'")  # Replace curly double quotes
    
    # Remove other problematic characters that could break parsing
    text = re.sub(r'[<>|\\\\]', '', text)  # Remove pipe, backslash, angle brackets
    
    # Replace multiple spaces with single space and strip
    text = re.sub(r'\s+', ' ', text).strip()
    
    return text

def get_musicbrainz_id(artist_name, max_retries=2):
    for attempt in range(max_retries + 1):
        if attempt > 0:
            print(f"[{time.strftime('%F %T')}] Retry {attempt} for MBID lookup: {artist_name}", flush=True)
            time.sleep(SLEEP_TIME * attempt)  # Progressive backoff
            
        print(f"[{time.strftime('%F %T')}] Looking up MBID for: {artist_name}", flush=True)
        time.sleep(SLEEP_TIME)
        url = f"{MB_API}/artist/?query=artist:{requests.utils.quote(artist_name)}&fmt=json"
        try:
            r = requests.get(url, headers=HEADERS, timeout=15)
            if r.status_code == 200:
                data = r.json()
                if data['artists']:
                    result = data['artists'][0]
                    mbid = result['id']
                    print(f"[{time.strftime('%F %T')}] Found MBID: {mbid}", flush=True)
                    return mbid
            else:
                print(f"[{time.strftime('%F %T')}] Failed to get MBID: {r.status_code}", flush=True)
        except requests.exceptions.Timeout:
            print(f"[{time.strftime('%F %T')}] Timeout looking up MBID for: {artist_name} (attempt {attempt + 1})", flush=True)
            if attempt < max_retries:
                time.sleep(SLEEP_TIME * 3)  # Back off more on timeout
                continue
        except requests.exceptions.RequestException as e:
            print(f"[{time.strftime('%F %T')}] Request error looking up MBID for {artist_name}: {e} (attempt {attempt + 1})", flush=True)
            if attempt < max_retries:
                time.sleep(SLEEP_TIME * 2)  # Back off on request errors
                continue
        except Exception as e:
            print(f"[{time.strftime('%F %T')}] MBID lookup failed: {e}", flush=True)
            break
            
    print(f"[{time.strftime('%F %T')}] Failed to get MBID for {artist_name} after {max_retries + 1} attempts", flush=True)
    return None

def get_albums_for_artist(artist_name, mbid):
    print(f"[{time.strftime('%F %T')}] Fetching releases for: {artist_name}", flush=True)
    albums = []
    
    params = {
        "artist": mbid,
        "fmt": "json",
        "limit": 100
    }
    
    try:
        r = requests.get(f"{MB_API}/release-group", params=params, headers=HEADERS, timeout=15)
        if r.ok:
            release_groups = r.json().get("release-groups", [])
            print(f"[{time.strftime('%F %T')}] Raw API returned {len(release_groups)} release groups", flush=True)
            
            for rg in release_groups:
                title = rg.get("title", "").strip()
                if not title:
                    continue
                
                primary_type = rg.get("primary-type", "N/A")
                secondary_types = rg.get("secondary-types", [])
                
                # FIXED: Now include Albums, EPs, AND Singles as potential mainline releases
                if primary_type.lower() not in ["album", "ep", "single"]:
                    continue
                
                # Skip releases with certain secondary types that indicate non-mainline
                if secondary_types:
                    secondary_lower = [st.lower() for st in secondary_types]
                    excluded_secondary = [
                        "compilation", "live", "soundtrack", 
                        "remix", "dj-mix", "demo"
                    ]
                    
                    if any(exc in secondary_lower for exc in excluded_secondary):
                        print(f"[{time.strftime('%F %T')}]   Skipped '{title}' - Secondary type: {secondary_types}", flush=True)
                        continue
                
                # Skip obvious compilation/live keywords in title
                # Note: We DO want to keep deluxe editions as they're mainline releases
                lowered = title.lower()
                skip_keywords = [
                    "greatest hits", "best of", "anthology", "collection",
                    "compilation", "live at", "live in", "live from",
                    "unreleased", "rarities", "b-sides", "demo",
                    "remaster", "remastered"
                ]
                
                should_skip = False
                for keyword in skip_keywords:
                    if keyword in lowered:
                        print(f"[{time.strftime('%F %T')}]   Skipped '{title}' - Keyword: {keyword}", flush=True)
                        should_skip = True
                        break
                
                if should_skip:
                    continue
                
                # Accept this as a mainline release
                albums.append({
                    'title': title,
                    'id': rg.get('id'),
                    'primary_type': primary_type,
                    'secondary_types': secondary_types
                })
                print(f"[{time.strftime('%F %T')}]   INCLUDED '{title}' - Primary: {primary_type}", flush=True)
            
            time.sleep(SLEEP_TIME)
            
        print(f"[{time.strftime('%F %T')}] Found {len(albums)} mainline releases (albums/EPs/singles) for {artist_name}", flush=True)
        
    except requests.exceptions.Timeout:
        print(f"[{time.strftime('%F %T')}] Timeout fetching releases for {artist_name}, skipping", flush=True)
        time.sleep(SLEEP_TIME * 3)  # Back off more on timeout
    except requests.exceptions.RequestException as e:
        print(f"[{time.strftime('%F %T')}] Request error fetching releases for {artist_name}: {e}", flush=True)
        time.sleep(SLEEP_TIME * 2)  # Back off on request errors
    except Exception as e:
        print(f"[{time.strftime('%F %T')}] Release fetch failed for {artist_name}: {e}", flush=True)
    
    return albums

def get_tracks_for_album(artist_name, album_title, release_group_id):
    print(f"[{time.strftime('%F %T')}] Fetching tracks for: {artist_name} - {album_title}", flush=True)
    tracks = []
    
    # Get releases for this release group
    params = {
        "release-group": release_group_id,
        "fmt": "json",
        "limit": 25
    }
    
    try:
        r = requests.get(f"{MB_API}/release", params=params, headers=HEADERS, timeout=15)
        time.sleep(SLEEP_TIME)
        
        if r.ok:
            releases = r.json().get("releases", [])
            if not releases:
                return tracks
            
            # Use the first release to get track listing
            release_id = releases[0]['id']
            
            # Get track listing
            track_params = {
                "inc": "recordings",
                "fmt": "json"
            }
            
            track_r = requests.get(f"{MB_API}/release/{release_id}", params=track_params, headers=HEADERS, timeout=15)
            time.sleep(SLEEP_TIME)
            
            if track_r.ok:
                release_data = track_r.json()
                media_list = release_data.get("media", [])
                
                for media in media_list:
                    track_list = media.get("tracks", [])
                    for track in track_list:
                        track_title = track.get("title", "").strip()
                        if track_title:
                            tracks.append(track_title)
                            
        print(f"[{time.strftime('%F %T')}] Found {len(tracks)} tracks for {album_title}", flush=True)
        
    except requests.exceptions.Timeout:
        print(f"[{time.strftime('%F %T')}] Timeout fetching tracks for {album_title}, skipping", flush=True)
        time.sleep(SLEEP_TIME * 3)  # Back off more on timeout
    except requests.exceptions.RequestException as e:
        print(f"[{time.strftime('%F %T')}] Request error fetching tracks for {album_title}: {e}", flush=True)
        time.sleep(SLEEP_TIME * 2)  # Back off on request errors
    except Exception as e:
        print(f"[{time.strftime('%F %T')}] Track fetch failed for {album_title}: {e}", flush=True)
    
    return tracks

# Read artists from file
with open(os.environ['ARTISTS_FILE'], "r") as f:
    artists = [line.strip() for line in f if line.strip()]

output_lines = []
total_tracks = 0

print(f"[{time.strftime('%F %T')}] Processing {len(artists)} artists for discography generation", flush=True)

for artist_idx, artist in enumerate(artists, 1):
    print(f"[{time.strftime('%F %T')}] Processing artist {artist_idx}/{len(artists)}: {artist}", flush=True)
    mbid = get_musicbrainz_id(artist)
    if not mbid:
        print(f"[{time.strftime('%F %T')}] Skipping {artist} - no MBID found", flush=True)
        continue
    
    albums = get_albums_for_artist(artist, mbid)
    print(f"[{time.strftime('%F %T')}] Processing {len(albums)} releases for {artist}", flush=True)
    
    for i, album in enumerate(albums, 1):
        album_title = album['title']
        album_id = album['id']
        album_type = album['primary_type']
        
        print(f"[{time.strftime('%F %T')}]   Release {i}/{len(albums)}: {album_title} ({album_type})", flush=True)
        
        # Get individual tracks for this album/single
        tracks = get_tracks_for_album(artist, album_title, album_id)
        
        if not tracks:
            print(f"[{time.strftime('%F %T')}]   No tracks found for {album_title}, skipping", flush=True)
            continue
        
        for track_title in tracks:
            # Sanitize all fields for sldl input format
            clean_artist = sanitize_for_sldl(artist)
            clean_album = sanitize_for_sldl(album_title)
            clean_title = sanitize_for_sldl(track_title)
            
            # Format for sldl with individual track search - using sanitized values
            line = f'artist="{clean_artist}",album="{clean_album}",title="{clean_title}"'
            output_lines.append(line)
            total_tracks += 1
            
            if total_tracks % 50 == 0:
                print(f"[{time.strftime('%F %T')}] Generated {total_tracks} tracks so far...", flush=True)

print(f"[{time.strftime('%F %T')}] Total tracks generated: {total_tracks}", flush=True)

# Output all tracks to the discography file
with open(os.environ['DISCOGRAPHY_FILE'], 'w') as f:
    for line in output_lines:
        f.write(line + '\n')

print(f"[{time.strftime('%F %T')}] Discography file written to: {os.environ['DISCOGRAPHY_FILE']}", flush=True)
PYTHON_SCRIPT
}

# Call the function with the artists file
generate_discography_bg "$ARTISTS_FILE"

echo "[$(date '+%F %T')] Background discography generation completed (PID: $$)" >> "$LOGFILE"
BACKGROUND_SCRIPT
    
    chmod +x "$bg_script"
    
    # Run the background script as a detached process with better signal isolation
    setsid nohup "$bg_script" "$artists_file" "$DISCOGRAPHY_FILE" "$LOGFILE" "$MB_EMAIL" >/dev/null 2>&1 &
    local bg_pid=$!
    
    echo "[$(date '+%F %T')] Started background discography generation (PID: $bg_pid)" >> "$LOGFILE"
    echo "Background discography generation started (PID: $bg_pid)"
    
    # Wait for the process to start and create some output
    sleep 5
    
    # Check if the background process is still running
    if kill -0 $bg_pid 2>/dev/null; then
      echo "Discography generation is running in background."
      echo "Monitor progress with: tail -f $LOGFILE"
      echo ""
      echo "Waiting for discography generation to complete..."
      echo "(This may take 10-30 minutes depending on number of artists)"
      echo "You can press Ctrl+C to detach - the process will continue running."
      
      # Set up trap to allow clean detachment
      detached=0
      trap 'echo ""; echo "Detaching from background process..."; detached=1' INT
      
      # Wait for completion but allow user to detach
      while kill -0 $bg_pid 2>/dev/null && [[ $detached -eq 0 ]]; do
        sleep 10
        
        # Show periodic progress if file is being written
        if [[ -f "$DISCOGRAPHY_FILE" ]]; then
          local current_tracks=$(wc -l < "$DISCOGRAPHY_FILE" 2>/dev/null || echo 0)
          if [[ $current_tracks -gt 0 ]]; then
            echo "[$(date '+%H:%M:%S')] Progress: $current_tracks tracks generated so far..."
          fi
        fi
      done
      
      # Reset trap
      trap - INT
      
      if [[ $detached -eq 1 ]]; then
        echo "Successfully detached. Background process continues running."
        echo "Monitor progress with: tail -f $LOGFILE"
        echo "Process will continue and downloads will start automatically when complete."
        
        # Wait for discography file to be completed in background
        echo "Waiting for discography generation to complete in background..."
        while kill -0 $bg_pid 2>/dev/null; do
          sleep 30
        done
      fi
    else
      echo "[$(date '+%F %T')] Background process failed to start" >> "$LOGFILE"
      echo "ERROR: Background discography generation failed to start"
      return 1
    fi
    
    # Clean up background script
    rm -f "$bg_script"
  fi
  
  # Check if we have tracks
  if [[ ! -f "$DISCOGRAPHY_FILE" || ! -s "$DISCOGRAPHY_FILE" ]]; then
    echo "ERROR: No discography file generated or file is empty"
    echo "Check the log file for errors: $LOGFILE"
    return 1
  fi
  
  local track_count=$(wc -l < "$DISCOGRAPHY_FILE")
  echo "[$(date '+%F %T')] Generated $track_count individual tracks for download" >> "$LOGFILE"
  
  if [[ $track_count -eq 0 ]]; then
    echo "No tracks found in discography. This could be because:"
    echo "- MusicBrainz couldn't find the artists"
    echo "- All albums were filtered out (compilations, live, etc.)"
    echo "- API rate limits or network issues"
    return 1
  fi
  
  echo "Generated $track_count individual tracks for download"
  echo "First few tracks:"
  head -5 "$DISCOGRAPHY_FILE"
  
  # Download using sldl with the generated track list
  build_sldl_command
  
  # Modify path to use Artists directory and add list input parameters
  local modified_cmd=("${SLDL_CMD[@]}")
  
  # Replace the path to use Artists directory
  for i in "${!modified_cmd[@]}"; do
    if [[ "${modified_cmd[$i]}" == "--path" ]]; then
      modified_cmd[$((i+1))]="$DL_PATH/Artists"
      break
    fi
  done
  
  # Add list input parameters for individual track downloads
  modified_cmd+=(
    "--input-type" "list"
    "--input" "$DISCOGRAPHY_FILE"
  )
  
  echo "[$(date '+%F %T')] Starting individual track downloads..." >> "$LOGFILE"
  echo "Command: ${modified_cmd[*]}" >> "$LOGFILE"
  echo ""
  echo "Starting download of $track_count individual tracks..."
  echo "This will take a while. Progress will be logged to $LOGFILE"
  echo "You can safely detach from this session."
  
  "${modified_cmd[@]}" >> "$LOGFILE" 2>&1 &
  local sldl_pid=$!
  
  monitor_and_restart "$LOGFILE" "discography" &
  local monitor_pid=$!
  
  trap "kill $monitor_pid 2>/dev/null || true" EXIT
  
  while kill -0 $sldl_pid 2>/dev/null; do
    sleep 3
  done
  
  kill $monitor_pid 2>/dev/null || true
  
  echo "[$(date '+%F %T')] Individual track downloads completed" >> "$LOGFILE"
  echo "Download phase completed. Starting organization..."
  
  # Organize downloaded tracks into album folders and process
  echo "[$(date '+%F %T')] Starting track organization into album folders..." >> "$LOGFILE"
  organize_tracks_into_albums "$DL_PATH/Artists"
  
  # Generate master M3U playlists for each artist
  echo "[$(date '+%F %T')] Generating artist-level M3U playlists..." >> "$LOGFILE"
  find "$DL_PATH/Artists" -maxdepth 1 -type d | while read -r artist_folder; do
    if [[ "$artist_folder" != "$DL_PATH/Artists" ]]; then
      local artist_name=$(basename "$artist_folder")
      local artist_m3u="$DL_PATH/Playlists/${artist_name}_Complete_Discography.m3u"
      
      mkdir -p "$DL_PATH/Playlists"
      
      echo "[$(date '+%F %T')] Generating discography M3U for: $artist_name" >> "$LOGFILE"
      
      # Find all music files in artist folder and subfolders
      find "$artist_folder" -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" \) | sort | while read -r music_file; do
        # Convert to container path
        local container_path="${music_file/#$DL_PATH/\/music}"
        echo "$container_path"
      done > "$artist_m3u"
    fi
  done
  
  echo "[$(date '+%F %T')] Discography mode completed successfully" >> "$LOGFILE"
  echo ""
  echo "Discography download and organization completed!"
  echo "Results:"
  echo "- Individual tracks downloaded: $track_count"
  echo "- Organized into album folders under: $DL_PATH/Artists/"
  echo "- Album M3U playlists generated for each album"
  echo "- Artist discography M3U playlists generated in: $DL_PATH/Playlists/"
  echo "- All tracks tagged with proper metadata"
  echo ""
  echo "Check the log for details: $LOGFILE"
  
  # Cleanup
  rm -f "$artists_file" "$selected_playlists" 2>/dev/null
}

# Organize individual tracks into album folders
organize_tracks_into_albums() {
  local base_path="$1"
  echo "[$(date '+%F %T')] Organizing tracks into album folders..." >> "$LOGFILE"
  
  local organize_script=$(mktemp "$TMPDIR/spotiplex_organize_XXXXXX.py")
  
  cat > "$organize_script" <<'ORGANIZE_SCRIPT'
import os
import sys
import shutil
import csv
from pathlib import Path
import eyed3

def sanitize_filename(name):
    """Sanitize filename by removing problematic characters"""
    for char in ['/', '\\', '?', '*', ':', '"', '<', '>', '|']:
        name = name.replace(char, '')
    return name.strip(' .')

def organize_artist_folder(artist_path):
    """Organize an artist folder by moving tracks into album subfolders"""
    print(f"Processing artist folder: {artist_path}")
    
    # Read the index file if it exists
    index_file = os.path.join(artist_path, "_index.sldl")
    if not os.path.exists(index_file):
        print(f"No index file found in {artist_path}")
        return
    
    tracks_by_album = {}
    
    # Read index to get track->album mapping
    with open(index_file, 'r', newline='', encoding='utf-8') as f:
        reader = csv.reader(f)
        header = next(reader, None)
        
        for row in reader:
            if len(row) >= 4:
                filepath, artist, album, title = row[0], row[1], row[2], row[3]
                
                if not album or not filepath:
                    continue
                
                sanitized_album = sanitize_filename(album)
                
                if sanitized_album not in tracks_by_album:
                    tracks_by_album[sanitized_album] = []
                
                tracks_by_album[sanitized_album].append({
                    'filepath': filepath.strip('./\\'),
                    'artist': artist,
                    'album': album,
                    'title': title,
                    'full_row': row
                })
    
    print(f"Found {len(tracks_by_album)} albums with tracks")
    
    # Create album folders and move tracks
    new_index_data = [header] if header else []
    
    for album_name, tracks in tracks_by_album.items():
        album_folder = os.path.join(artist_path, album_name)
        os.makedirs(album_folder, exist_ok=True)
        
        print(f"  Processing album: {album_name} ({len(tracks)} tracks)")
        
        album_index_data = [header] if header else []
        
        for track_info in tracks:
            old_path = os.path.join(artist_path, track_info['filepath'])
            
            if os.path.exists(old_path):
                # Create new filename: Artist - Title.ext
                file_ext = os.path.splitext(track_info['filepath'])[1]
                new_filename = f"{sanitize_filename(track_info['artist'])} - {sanitize_filename(track_info['title'])}{file_ext}"
                new_path = os.path.join(album_folder, new_filename)
                
                try:
                    shutil.move(old_path, new_path)
                    print(f"    Moved: {track_info['filepath']} -> {album_name}/{new_filename}")
                    
                    # Update the row data for the new path
                    updated_row = track_info['full_row'].copy()
                    updated_row[0] = new_filename  # Update filepath
                    album_index_data.append(updated_row)
                    
                    # Tag the file
                    tag_file(new_path, track_info['artist'], track_info['album'], track_info['title'])
                    
                except Exception as e:
                    print(f"    Error moving {old_path}: {e}")
                    album_index_data.append(track_info['full_row'])
            else:
                print(f"    File not found: {old_path}")
                album_index_data.append(track_info['full_row'])
        
        # Create album-specific index file
        album_index_file = os.path.join(album_folder, "_index.sldl")
        with open(album_index_file, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerows(album_index_data)
        
        # Generate M3U playlist for this album
        generate_album_m3u(album_folder, album_name)
    
    # Update main index file (remove entries that were moved)
    with open(index_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerows(new_index_data)

def tag_file(filepath, artist, album, title):
    """Tag audio file with metadata"""
    try:
        eyed3.log.setLevel("ERROR")
        audiofile = eyed3.load(filepath)
        
        if audiofile and audiofile.tag:
            audiofile.tag.artist = artist
            audiofile.tag.title = title
            audiofile.tag.album = album
            
            # Clear junk metadata
            audiofile.tag.album_artist = None
            audiofile.tag.genre = None
            
            # Remove comments and user text frames
            for comment in list(audiofile.tag.comments):
                audiofile.tag.comments.remove(comment.description)
            
            for frame in list(audiofile.tag.user_text_frames):
                audiofile.tag.user_text_frames.remove(frame.description)
            
            audiofile.tag.save(version=eyed3.id3.ID3_V2_3)
            
    except Exception as e:
        print(f"    Tagging failed for {filepath}: {e}")

def generate_album_m3u(album_folder, album_name):
    """Generate M3U playlist for album"""
    m3u_file = os.path.join(album_folder, f"{sanitize_filename(album_name)}.m3u")
    
    music_files = []
    for ext in ['.mp3', '.flac', '.m4a', '.ogg']:
        music_files.extend(Path(album_folder).glob(f"*{ext}"))
    
    music_files.sort()
    
    with open(m3u_file, 'w', encoding='utf-8') as f:
        for music_file in music_files:
            # Use relative path within the album folder
            f.write(f"{music_file.name}\n")

# Main execution
base_path = sys.argv[1]

for artist_folder in os.listdir(base_path):
    artist_path = os.path.join(base_path, artist_folder)
    if os.path.isdir(artist_path):
        organize_artist_folder(artist_path)

print("Organization complete!")
ORGANIZE_SCRIPT

  python3 "$organize_script" "$base_path"
  rm -f "$organize_script"
  
  echo "[$(date '+%F %T')] Track organization completed" >> "$LOGFILE"
}

main_loop() {
  print_header
  source "$CONFIG_FILE"

  # Determine mode
  local download_mode="${DOWNLOAD_MODE:-$MODE_PLAYLISTS}"
  
  case "$download_mode" in
    "$MODE_PLAYLISTS")
      playlist_mode
      ;;
    "$MODE_DISCOGRAPHY_ALL"|"$MODE_DISCOGRAPHY_SELECTED")
      discography_mode "$download_mode"
      ;;
    *)
      echo "[$(date '+%F %T')] Unknown download mode: $download_mode, defaulting to playlists" >> "$LOGFILE"
      playlist_mode
      ;;
  esac

  echo "[$(date '+%F %T')] All processing completed" >> "$LOGFILE"
  tail -f "$LOGFILE"
}

# Debug mode for testing single playlist
debug_single_playlist() {
  local playlist_url="$1"
  export DEBUG_MODE=1
  
  echo "=== DEBUG MODE ==="
  echo "Testing playlist: $playlist_url"
  
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: No config file found. Run script normally first to create config."
    exit 1
  fi
  
  source "$CONFIG_FILE"
  
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
  
  # Method 2: Most recent folder
  if [[ -z "$found_folder" ]]; then
    echo "[DEBUG] Trying method 2: Most recent folder..."
    found_folder=$(find "$DL_PATH" -maxdepth 1 -type d -not -path "$DL_PATH" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    if [[ -n "$found_folder" ]]; then
      echo "[DEBUG] ✓ Method 2 SUCCESS: Found via most recent: $found_folder"
    else
      echo "[DEBUG] ✗ Method 2 FAILED: No folders found"
    fi
  fi
  
  # Method 3: Look for any folder with an _index.sldl file
  if [[ -z "$found_folder" ]]; then
    echo "[DEBUG] Trying method 3: Any folder with _index.sldl..."
    while IFS= read -r -d '' index_file; do
      local parent_dir=$(dirname "$index_file")
      # Check if this index was modified recently (within last 5 minutes)
      if [[ $(find "$index_file" -mmin -5 -print 2>/dev/null) ]]; then
        found_folder="$parent_dir"
        echo "[DEBUG] ✓ Method 3 SUCCESS: Found via recent index file: $found_folder"
        break
      fi
    done < <(find "$DL_PATH" -maxdepth 2 -name "_index.sldl" -print0 2>/dev/null)
    
    if [[ -z "$found_folder" ]]; then
      echo "[DEBUG] ✗ Method 3 FAILED: No recent _index.sldl files found"
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
    echo "[DEBUG] === SUMMARY ==="
    echo "[DEBUG] Spotify playlist name: ${playlist_name:-'(failed to get)'}"
    echo "[DEBUG] Expected folder path: $DL_PATH/${playlist_name:-'???'}"
    echo "[DEBUG] Actual folder found: ${found_folder:-'(none)'}"
    
    if [[ -n "$sldl_playlist_name" ]] && [[ "$sldl_playlist_name" != "$playlist_name" ]]; then
      echo "[DEBUG] Note: sldl used different name: $sldl_playlist_name"
    fi
  else
    echo ""
    echo "[DEBUG] ERROR: Could not find downloaded folder!"
    echo "[DEBUG] Checked paths:"
    echo "  - $DL_PATH/$playlist_name"
    echo "  - Most recent folder in $DL_PATH"
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
  install_dependencies
  download_sldl
  debug_single_playlist "$DEBUG_URL"
else
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
