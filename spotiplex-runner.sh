#!/bin/bash
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/djeverhart/sldl-auto/refs/heads/main/spotiplex.sh"
SCRIPT_NAME="spotiplex.sh"

echo "[*] Spotiplex Installer & Runner (Enhanced)"
echo "==========================================="

# Function to install gum manually
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

# Function to install dependencies including gum
install_dependencies() {
    echo "[*] Installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y dos2unix wget curl procps python3 python3-pip unzip libicu-dev tar
        
    elif command -v dnf &>/dev/null; then
        dnf install -y dos2unix wget curl procps python3 python3-pip unzip libicu-dev tar
        
    elif command -v yum &>/dev/null; then
        yum install -y dos2unix wget curl procps python3 python3-pip unzip libicu-dev tar
        
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm dos2unix wget curl procps python python-pip unzip libicu-dev tar
        
    elif command -v zypper &>/dev/null; then
        zypper install -y dos2unix wget curl procps python3 python3-pip unzip libicu-dev tar
        
    elif command -v brew &>/dev/null; then
        brew install dos2unix wget curl procps python3 unzip tar
        
    else
        echo "Warning: Could not detect package manager."
        echo "Please install the following packages manually:"
        echo "  - dos2unix, wget, curl, procps, tar"
        echo "  - python3, python3-pip, unzip, libicu-dev"
        echo "Continuing without automatic installation..."
        return 1
    fi
    
    # Install gum manually
    if ! install_gum; then
        echo "[*] Warning: gum installation failed, basic prompts will be used"
    fi
    
    # Install Python packages
    echo "[*] Installing Python packages..."
    python3 -m pip install --upgrade pip spotipy eyed3 requests
    
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

# Install dependencies
if install_dependencies; then
    echo "[*] Dependencies installed successfully"
else
    echo "[*] Warning: Some dependencies may be missing"
fi

# Install and run dos2unix if available
if command -v dos2unix &>/dev/null; then
    echo "[*] Converting line endings with dos2unix..."
    dos2unix "$SCRIPT_NAME" 2>/dev/null || echo "Warning: dos2unix conversion failed, continuing anyway..."
else
    echo "[*] dos2unix not available, skipping line ending conversion"
fi

# Make executable
echo "[*] Making script executable..."
chmod +x "$SCRIPT_NAME"

# Show file info
echo "[*] Script ready:"
ls -la "$SCRIPT_NAME"

# Check if gum is available for enhanced UI
if command -v gum &>/dev/null; then
    echo "[*] gum is available - enhanced UI enabled"
    ENHANCED_UI="true"
else
    echo "[*] gum not available - using basic UI prompts"
    ENHANCED_UI="false"
fi

echo ""
echo "[*] Starting spotiplex.sh..."
echo "Note: The enhanced script supports multiple download modes:"
echo "  - Playlist mode (original behavior)"
echo "  - Full discography mode (all artists from all playlists)" 
echo "  - Selective discography mode (artists from selected playlists)"
if [[ "$ENHANCED_UI" == "true" ]]; then
    echo "  Enhanced UI with gum available for interactive selection"
else
    echo "  Basic UI - numbered selection menus will be used"
fi
echo "================================="

# Run the script
exec ./"$SCRIPT_NAME"
