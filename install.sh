#!/bin/bash
# =============================================================================
# SAA Bundle Tools - Installer
# =============================================================================
#
# This script installs the SAA Bundle Tools (setup.sh and bundle registry)
# to your system. It can be run directly via:
#
#   curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh | bash
#
# Or download and run manually:
#
#   curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh -o install.sh
#   bash install.sh
#
# =============================================================================

set -e

# Configuration
REPO_OWNER="SebastianCalin"
REPO_NAME="saa-bundle-tools-personal"
INSTALL_DIR="${INSTALL_DIR:-$HOME/bin}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/saa-bundle-tools}"
VERSION="${VERSION:-latest}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

success() {
    echo -e "${GREEN}✓${NC} $*"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $*"
}

error() {
    echo -e "${RED}✗${NC} $*"
}

die() {
    error "$*"
    exit 1
}

# Detect OS and architecture
detect_platform() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)

    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) die "Unsupported architecture: $arch" ;;
    esac

    echo "${os}-${arch}"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get latest release version from GitHub
get_latest_version() {
    if command_exists curl; then
        curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
            | grep '"tag_name":' \
            | sed -E 's/.*"([^"]+)".*/\1/'
    elif command_exists wget; then
        wget -qO- "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
            | grep '"tag_name":' \
            | sed -E 's/.*"([^"]+)".*/\1/'
    else
        die "Neither curl nor wget found. Please install one of them."
    fi
}

# =============================================================================
# Installation Functions
# =============================================================================

install_bundle_tools() {
    echo ""
    echo "=========================================================="
    echo "  SAA Bundle Tools Installer"
    echo "=========================================================="
    echo ""

    # Detect platform
    local platform=$(detect_platform)
    info "Platform: $platform"

    # Check required tools
    if ! command_exists curl && ! command_exists wget; then
        die "Neither curl nor wget found. Please install one of them."
    fi

    if ! command_exists tar; then
        die "tar not found. Please install it."
    fi

    # Determine version
    if [ "$VERSION" = "latest" ]; then
        info "Fetching latest version..."
        VERSION=$(get_latest_version)
        if [ -z "$VERSION" ]; then
            warn "Could not fetch latest version from GitHub, using main branch"
            VERSION="main"
        else
            success "Latest version: $VERSION"
        fi
    fi

    # Create directories
    info "Creating directories..."
    mkdir -p "$INSTALL_DIR" || die "Failed to create $INSTALL_DIR"
    mkdir -p "$CONFIG_DIR" || die "Failed to create $CONFIG_DIR"

    # Download files
    info "Downloading SAA Bundle Tools..."
    local tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    if [ "$VERSION" = "main" ]; then
        # Download from main branch (no release)
        local base_url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

        if command_exists curl; then
            curl -fsSL "${base_url}/setup.sh" -o "${tmp_dir}/setup.sh" || die "Failed to download setup.sh"
            curl -fsSL "${base_url}/.bundle-registry.json" -o "${tmp_dir}/.bundle-registry.json" || die "Failed to download .bundle-registry.json"
        else
            wget -qO "${tmp_dir}/setup.sh" "${base_url}/setup.sh" || die "Failed to download setup.sh"
            wget -qO "${tmp_dir}/.bundle-registry.json" "${base_url}/.bundle-registry.json" || die "Failed to download .bundle-registry.json"
        fi
    else
        # Download from release
        local release_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VERSION}/saa-bundle-tools-${VERSION}.tar.gz"

        if command_exists curl; then
            curl -fsSL "$release_url" -o "${tmp_dir}/bundle-tools.tar.gz" || die "Failed to download release"
        else
            wget -qO "${tmp_dir}/bundle-tools.tar.gz" "$release_url" || die "Failed to download release"
        fi

        # Extract (strip top-level directory for flat structure)
        tar -xzf "${tmp_dir}/bundle-tools.tar.gz" -C "$tmp_dir" --strip-components=1 || die "Failed to extract archive"
    fi

    # Install files
    info "Installing files..."

    # Install setup.sh
    cp "${tmp_dir}/setup.sh" "${INSTALL_DIR}/saa-setup" || die "Failed to install setup.sh"
    chmod +x "${INSTALL_DIR}/saa-setup"
    success "Installed: ${INSTALL_DIR}/saa-setup"

    # Install bundle registry
    cp "${tmp_dir}/.bundle-registry.json" "${CONFIG_DIR}/bundle-registry.json" || die "Failed to install bundle registry"
    success "Installed: ${CONFIG_DIR}/bundle-registry.json"

    # Update PATH if needed
    echo ""
    info "Checking PATH configuration..."

    if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
        warn "⚠️  ${INSTALL_DIR} is not in your PATH"
        echo ""
        echo "To use 'saa-setup' command, add this to your shell profile:"
        echo ""
        echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
        echo ""

        # Detect shell and show specific instructions
        if [ -n "$BASH_VERSION" ]; then
            echo "For bash, add to ~/.bashrc or ~/.bash_profile"
        elif [ -n "$ZSH_VERSION" ]; then
            echo "For zsh, add to ~/.zshrc"
        fi
        echo ""
    else
        success "${INSTALL_DIR} is already in your PATH"
    fi

    # Installation complete
    echo ""
    echo "=========================================================="
    echo "  Installation Complete!"
    echo "=========================================================="
    echo ""
    success "SAA Bundle Tools installed successfully"
    echo ""
    echo "Installed components:"
    echo "  • Setup script: ${INSTALL_DIR}/saa-setup"
    echo "  • Bundle registry: ${CONFIG_DIR}/bundle-registry.json"
    echo ""
    echo "Usage:"
    echo "  saa-setup --list                     # List available bundles"
    echo "  saa-setup --repository BUNDLE --upgrade VERSION"
    echo ""
    echo "Documentation:"
    echo "  https://github.com/${REPO_OWNER}/${REPO_NAME}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

install_bundle_tools
