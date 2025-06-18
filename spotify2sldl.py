import spotipy
from spotipy.oauth2 import SpotifyOAuth
import requests
import time
import sys
import os
import json
import tty
import termios

# === CONFIG LOADING ===
CONFIG_FILE = "sldl_config.json"

if not os.path.exists(CONFIG_FILE):
    print(f"[ERROR] Config file '{CONFIG_FILE}' not found.")
    sys.exit(1)

with open(CONFIG_FILE, "r", encoding="utf-8") as f:
    config = json.load(f)

# Assign config values
CLIENT_ID = config["spotify_client_id"]
CLIENT_SECRET = config["spotify_client_secret"]
REDIRECT_URI = config["spotify_redirect_uri"]
SCOPE = config.get("spotify_scope", "playlist-read-private")

EMAIL = config["email"]
SLDL_USER = config["sldl_user"]
SLDL_PASS = config["sldl_pass"]

DOWNLOAD_PATH = config["sldl_downloads"]
WORKING_PATH = config["working_path"]

# Paths
os.makedirs(WORKING_PATH, exist_ok=True)
OUTPUT_FILE = os.path.join(WORKING_PATH, "sldl-albums.txt")

# === CONSTANTS ===
MB_API = "https://musicbrainz.org/ws/2"
SLEEP_TIME = 1
HEADERS = {
    "User-Agent": f"SpotifyToSoulseek/1.0 ({EMAIL})"
}
SKIP_KEYWORDS = [
    "compilation", "greatest hits", "anthology", "essentials",
    "live", "remix", "remixes", "versions",
    "rarities", "b-sides", "instrumental", "compilations", "essential"
]

# === LOGGING ===
def log(section, msg):
    print(f"[{section}] {msg}")

# === USER INPUT UTILITY ===
def prompt_yes_no(message):
    print(f"{message} [y/n]: ", end="", flush=True)
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(sys.stdin.fileno())
        response = sys.stdin.read(1)
        print()  # new line after keypress
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    return response.lower() == 'y'

# === AUTH ===
def authenticate_spotify():
    log("AUTH", "Starting Spotify authentication...")
    try:
        auth_manager = SpotifyOAuth(
            client_id=CLIENT_ID,
            client_secret=CLIENT_SECRET,
            redirect_uri=REDIRECT_URI,
            scope=SCOPE,
            open_browser=False,
            cache_path=config.get("cache_path", ".cache"),
            show_dialog=True
        )
        sp = spotipy.Spotify(auth_manager=auth_manager)
        user = sp.current_user()
        log("AUTH", f"Authenticated as: {user['display_name']} ({user['id']})")
        return sp
    except Exception as e:
        log("ERROR", f"Spotify authentication failed: {e}")
        sys.exit(1)

# === SPOTIFY ARTISTS ===
def get_all_unique_artists(sp):
    artist_names = set()
    playlists = sp.current_user_playlists()
    total_playlists = 0
    log("SPOTIFY", "Fetching playlists...")

    while playlists:
        for playlist in playlists['items']:
            total_playlists += 1
            log("SPOTIFY", f"→ Playlist: {playlist['name']} ({playlist['tracks']['total']} tracks)")
            playlist_id = playlist['id']
            results = sp.playlist_tracks(playlist_id)
            track_count = 0
            while results:
                for item in results['items']:
                    track = item.get('track')
                    if track:
                        artist_objs = track.get('artists', [])
                        artist_names_in_track = [a.get('name') or "Unknown Artist" for a in artist_objs]
                        artist_names.update(artist_names_in_track)
                        track_count += 1
                results = sp.next(results) if results['next'] else None
            log("SPOTIFY", f"✓ Finished {playlist['name']} ({track_count} tracks)")
        playlists = sp.next(playlists) if playlists['next'] else None

    log("SPOTIFY", f"Total playlists processed: {total_playlists}")
    log("SPOTIFY", f"Unique artists found: {len(artist_names)}")
    return sorted(artist_names)

# === MUSICBRAINZ LOOKUP ===
def get_musicbrainz_id(artist_name):
    log("MBID", f"Looking up MBID for: {artist_name}")
    time.sleep(SLEEP_TIME)
    url = f"{MB_API}/artist/?query=artist:{requests.utils.quote(artist_name)}&fmt=json"
    try:
        r = requests.get(url, headers=HEADERS, timeout=10)
        log("MBID", f"→ HTTP {r.status_code}")
        if r.status_code == 200:
            data = r.json()
            if data['artists']:
                result = data['artists'][0]
                mbid = result['id']
                score = result.get('score', 'N/A')
                log("MBID", f"✓ Found: {result['name']} → {mbid} (score: {score})")
                return mbid
            else:
                log("MBID", "✗ No results found")
        else:
            log("MBID", f"✗ Failed response: {r.text}")
    except Exception as e:
        log("ERROR", f"MBID lookup failed for {artist_name}: {e}")
    return None

# === MUSICBRAINZ ALBUMS ===
def get_albums_for_artist(artist_name, mbid):
    log("ALBUMS", f"Fetching albums for: {artist_name}")
    albums = []
    params = {
        "artist": mbid,
        "type": "album|ep",
        "fmt": "json",
        "limit": 100
    }
    try:
        r = requests.get(f"{MB_API}/release-group", params=params, headers=HEADERS)
        log("ALBUMS", f"→ HTTP {r.status_code}")
        if not r.ok:
            log("ALBUMS", f"✗ Failed to get release-groups: {r.text}")
            return albums

        release_groups = r.json().get("release-groups", [])
        log("ALBUMS", f"✓ Found {len(release_groups)} release groups")

        for rg in release_groups:
            title = rg.get("title", "").strip()
            if not title:
                continue
            lowered = title.lower()
            if any(keyword in lowered for keyword in SKIP_KEYWORDS):
                log("SKIP", f"✗ Skipping album: {title}")
                continue
            albums.append(title)
            log("ALBUM", f"→ {title}")
            time.sleep(SLEEP_TIME)
    except Exception as e:
        log("ERROR", f"Album fetch failed for {artist_name}: {e}")
    return albums

# === MAIN ===
def main():
    log("START", "Launching Spotify-to-Soulseek export")
    sp = authenticate_spotify()
    all_artists = get_all_unique_artists(sp)

    # === INTERACTIVE FILTERING ===
    accepted_artists = []
    for artist in all_artists:
        if prompt_yes_no(f"Include artist: {artist}?"):
            accepted_artists.append(artist)
        else:
            log("FILTER", f"✗ Rejected artist: {artist}")

    log("FILTER", f"✓ Accepted {len(accepted_artists)} artists")

    with open(OUTPUT_FILE, "w", encoding="utf-8") as f:
        for idx, artist in enumerate(accepted_artists, 1):
            log("PROCESS", f"[{idx}/{len(accepted_artists)}] {artist}")
            mbid = get_musicbrainz_id(artist)
            if not mbid:
                log("SKIP", f"Skipping {artist} — no MBID found")
                continue
            albums = get_albums_for_artist(artist, mbid)
            if not albums:
                log("SKIP", f"Skipping {artist} — no albums found")
                continue
            for album in albums:
                entry = f"\"artist={artist},album={album}\"  \"format=mp3; br>180\"  \"br>=320; format=flac\""
                f.write(entry + "\n")
                f.flush()
                log("WRITE", f"✓ {entry}")

    log("DONE", f"All finished. Output saved to: {OUTPUT_FILE}")

if __name__ == "__main__":
    main()
