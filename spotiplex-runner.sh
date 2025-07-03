#!/bin/bash
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/djeverhart/sldl-auto/refs/heads/main/spotiplex.sh"
SCRIPT_NAME="spotiplex.sh"

echo "[*] Spotiplex Installer & Runner"
echo "================================="

# Function to install dos2unix based on package manager
install_dos2unix() {
    echo "[*] Installing dos2unix..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y dos2unix wget curl procps 
    elif command -v dnf &>/dev/null; then
        dnf install -y dos2unix wget curl procps
    elif command -v yum &>/dev/null; then
        yum install -y dos2unix wget curl procps
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm dos2unix wget curl procps
    elif command -v zypper &>/dev/null; then
        zypper install -y dos2unix wget curl procps
    elif command -v brew &>/dev/null; then
        brew install dos2unix wget curl procps
    else
        echo "Warning: Could not detect package manager. Please install dos2unix manually."
        echo "Continuing without dos2unix conversion..."
        return 1
    fi
    return 0
}

# Download the script
echo "[*] Downloading spotiplex.sh from GitHub..."
if command -v wget &>/dev/null; then
    wget -q -O "$SCRIPT_NAME" "$SCRIPT_URL"
elif command -v curl &>/dev/null; then
    curl -s -o "$SCRIPT_NAME" "$SCRIPT_URL"
else
    echo "Error: Neither wget nor curl found. Please install one of them."
    exit 1
fi

echo "[*] Download completed: $SCRIPT_NAME"

# Install and run dos2unix
if install_dos2unix; then
    echo "[*] Converting line endings with dos2unix..."
    dos2unix "$SCRIPT_NAME" 2>/dev/null || echo "Warning: dos2unix conversion failed, continuing anyway..."
else
    echo "[*] Skipping dos2unix conversion"
fi

# Make executable
echo "[*] Making script executable..."
chmod +x "$SCRIPT_NAME"

# Show file info and run automatically
echo "[*] Script ready:"
ls -la "$SCRIPT_NAME"

echo ""
echo "[*] Starting spotiplex.sh automatically..."
echo "Note: The script can restart itself automatically when needed."
echo "================================="
exec ./"$SCRIPT_NAME" && tail -f spotiplex.log
