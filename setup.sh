#!/bin/bash
set -eu

# =============================================================================
# Extract Bundle from Azure Container Registry
# =============================================================================
#
# Created by:         RepsMate Development Team
# Last updated by:    Galan Calin Sebastian
# Last update:        29 December 2025
# Version:            1.0.0
#
# =============================================================================
# This script pulls bundled Docker images from ACR and extracts contents with
# comprehensive backup, rollback, validation, and logging capabilities.
#
# Features:
# - Interactive configuration wizard (--init-config, --configure)
# - Automatic backup before extraction
# - Atomic operations (temp → rename)
# - Version tracking and rollback
# - Comprehensive logging
# - Disk space validation
# - Secure credential management
# - Non-interactive mode for automation
# - Dry-run mode
# - Docker and Podman support (auto-detected)
# =============================================================================

SCRIPT_VERSION="1.0.2"

# --- Bundle Registry ---
# Locate bundle registry (try multiple locations for flexibility)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_REGISTRY=""

# Try common locations
for registry_path in \
    "$SCRIPT_DIR/../.bundle-registry.json" \
    "$HOME/.bundle-registry.json" \
    "/etc/saa/.bundle-registry.json"; do
    if [ -f "$registry_path" ]; then
        BUNDLE_REGISTRY="$registry_path"
        break
    fi
done

# --- Default Configuration ---
DEFAULT_REGISTRY="drepsmate.azurecr.io"
DEFAULT_USERNAME="drepsmate"
DEFAULT_EXTRACT_DIR="$HOME"
DEFAULT_BACKUP_DIR="$HOME/saa-backups"
DEFAULT_LOG_FILE="$HOME/.extract-bundle.log"
VERSION_FILE="${HOME}/.extract-bundle-versions.json"
CONFIG_FILE="${HOME}/.extract-bundle.conf"
ENV_FILE="${HOME}/.extract-bundle.env"
LOCK_FILE="${HOME}/.extract-bundle.lock"

# Runtime Configuration (will be loaded from config/env files)
ACR_REGISTRY="${ACR_REGISTRY:-$DEFAULT_REGISTRY}"
ACR_USERNAME="${ACR_USERNAME:-$DEFAULT_USERNAME}"
ACR_PASSWORD="${ACR_PASSWORD:-}"
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
AUTO_CLEANUP="${AUTO_CLEANUP:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
DRY_RUN="${DRY_RUN:-false}"
ENABLE_COLORS="${ENABLE_COLORS:-auto}"
CONTAINER_CMD="${CONTAINER_CMD:-}"

# Runtime variables
IMAGE_NAME=""
EXTRACT_DIR=""
UPGRADE_MODE="false"
DOWNGRADE_MODE="false"
ROLLBACK_MODE="false"
UPGRADE_TAG=""
DOWNGRADE_TAG=""
ROLLBACK_TAG=""
VERIFY_EXTRACTION="true"
CREATE_BACKUP="true"
LOCK_FD=""

# --- Color Management ---
setup_colors() {
    if [ "$ENABLE_COLORS" = "auto" ]; then
        if [ -t 1 ]; then
            ENABLE_COLORS="true"
        else
            ENABLE_COLORS="false"
        fi
    fi
    
    if [ "$ENABLE_COLORS" = "true" ]; then
        COLOR_RESET="\033[0m"
        COLOR_GREEN="\033[0;32m"
        COLOR_YELLOW="\033[0;33m"
        COLOR_CYAN="\033[0;36m"
        COLOR_RED="\033[0;31m"
    else
        COLOR_RESET=""
        COLOR_GREEN=""
        COLOR_YELLOW=""
        COLOR_CYAN=""
        COLOR_RED=""
    fi
}

# --- Bundle Registry Functions ---
is_bundle() {
    local repo_name="$1"

    # If no registry file, assume everything is a bundle (backward compatible)
    if [ -z "$BUNDLE_REGISTRY" ] || [ ! -f "$BUNDLE_REGISTRY" ]; then
        return 0
    fi

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        return 0  # Assume bundle if jq not available
    fi

    # Check if repo exists in bundle registry
    jq -e ".bundles.\"$repo_name\"" "$BUNDLE_REGISTRY" >/dev/null 2>&1
}

get_bundle_extraction_config() {
    local bundle_name="$1"
    local field="$2"

    if [ -z "$BUNDLE_REGISTRY" ] || [ ! -f "$BUNDLE_REGISTRY" ]; then
        echo ""
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo ""
        return
    fi

    jq -r ".bundles.\"$bundle_name\".extraction.${field} // empty" "$BUNDLE_REGISTRY" 2>/dev/null
}

get_bundle_default_extract_dir() {
    local bundle_name="$1"

    # Get extraction config from registry
    local target_name=$(get_bundle_extraction_config "$bundle_name" "target_name")
    local parent_dir=$(get_bundle_extraction_config "$bundle_name" "default_parent_dir")
    local mode=$(get_bundle_extraction_config "$bundle_name" "mode")

    # If registry provides config, use it
    if [ -n "$target_name" ] && [ -n "$parent_dir" ]; then
        # Expand environment variables in parent_dir
        parent_dir=$(eval echo "$parent_dir")

        # Return the parent directory where extraction should occur
        # The bundle content (which includes target_name/) will be placed here
        echo "$parent_dir"
    else
        # Fallback to old behavior
        echo "${DEFAULT_EXTRACT_DIR}/${bundle_name}"
    fi
}

# --- Helper Functions ---
say() { 
    printf "%s\n" "$*"
    log_info "$*"
}

die() { 
    printf "${COLOR_RED}ERROR: %s${COLOR_RESET}\n" "$*" >&2
    log_error "$*"
    cleanup_on_error
    exit 1
}

success() { 
    printf "${COLOR_GREEN}✓ %s${COLOR_RESET}\n" "$*"
    log_info "SUCCESS: $*"
}

warn() { 
    printf "${COLOR_YELLOW}⚠ %s${COLOR_RESET}\n" "$*"
    log_warn "$*"
}

info() { 
    printf "${COLOR_CYAN}ℹ %s${COLOR_RESET}\n" "$*"
    log_info "$*"
}

# --- Logging System ---
log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    printf "[%s] %-7s %s\n" "$timestamp" "$level" "$*" >> "$LOG_FILE"
}

log_info() { log "INFO" "$*"; }
log_warn() { log "WARN" "$*"; }
log_error() { log "ERROR" "$*"; }
log_debug() { log "DEBUG" "$*"; }

init_logging() {
    # Create log file if it doesn't exist
    touch "$LOG_FILE" 2>/dev/null || {
        LOG_FILE="/tmp/extract-bundle.log"
        warn "Cannot write to default log location, using: $LOG_FILE"
    }
    log_info "=========================================="
    log_info "Script started - Version $SCRIPT_VERSION"
    log_info "Command: $0 $*"
    log_info "User: $(whoami)"
    log_info "=========================================="
}

# --- File Locking ---
acquire_lock() {
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        die "Another instance is already running. Lock file: $LOCK_FILE"
    fi
    log_info "Acquired lock"
}

release_lock() {
    if [ -n "$LOCK_FD" ]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
        rm -f "$LOCK_FILE" 2>/dev/null || true
        log_info "Released lock"
    fi
}

cleanup_on_error() {
    release_lock
}

trap cleanup_on_error EXIT

# --- Configuration Management ---
load_env_file() {
    if [ -f "$ENV_FILE" ]; then
        # Source env file securely
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
        log_info "Loaded environment from: $ENV_FILE"
        
        # Check permissions
        local perms
        perms=$(stat -c %a "$ENV_FILE" 2>/dev/null || stat -f %A "$ENV_FILE" 2>/dev/null || echo "000")
        if [ "$perms" != "600" ]; then
            warn "Environment file has insecure permissions: $perms (should be 600)"
            warn "Run: chmod 600 $ENV_FILE"
        fi
    fi
}

load_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        # Simple key=value parser
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue

            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)

            case "$key" in
                default_registry) ACR_REGISTRY="$value" ;;
                default_username) ACR_USERNAME="$value" ;;
                default_extract_dir) DEFAULT_EXTRACT_DIR="$value" ;;
                log_file) LOG_FILE="$value" ;;
                backup_dir) BACKUP_DIR="$value" ;;
                backup_retention_days) BACKUP_RETENTION_DAYS="$value" ;;
                auto_cleanup) AUTO_CLEANUP="$value" ;;
                enable_colors) ENABLE_COLORS="$value" ;;
                container_cmd) CONTAINER_CMD="$value" ;;
            esac
        done < "$CONFIG_FILE"
        log_info "Loaded configuration from: $CONFIG_FILE"
    fi
}

create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# Extract Bundle Configuration File
# Edit this file to customize default behavior

# Registry settings
default_registry=drepsmate.azurecr.io
default_username=drepsmate

# Extraction settings
# Default directory for extractions (bundles will be in subdirectories)
# Example: default_extract_dir=$HOME/saa will create $HOME/saa/bundle-name
default_extract_dir=$HOME/saa-extracted

# Logging
log_file=$HOME/.extract-bundle.log

# Backup settings
backup_dir=$HOME/saa-backups
backup_retention_days=7

# Behavior
auto_cleanup=false
enable_colors=auto

# Container runtime (auto-detected if not set)
# Options: docker, podman (leave empty for auto-detection)
container_cmd=

# Repository-specific settings (optional)
# Format: repo_<name>_dir=/path/to/extract
# repo_saa-asr-service_dir=/opt/saa/asr-service
EOF
    chmod 644 "$CONFIG_FILE"
    success "Created default configuration: $CONFIG_FILE"
}

create_default_env() {
    local password="${1:-}"
    local registry="${2:-}"
    local username="${3:-}"

    cat > "$ENV_FILE" << EOF
# Extract Bundle Environment File
# Store sensitive credentials here
# IMPORTANT: This file contains secrets - keep it secure!

# Azure Container Registry credentials
ACR_PASSWORD=$password

# Optional overrides
EOF

    if [ -n "$registry" ] && [ "$registry" != "$DEFAULT_REGISTRY" ]; then
        echo "ACR_REGISTRY=$registry" >> "$ENV_FILE"
    else
        echo "# ACR_REGISTRY=drepsmate.azurecr.io" >> "$ENV_FILE"
    fi

    if [ -n "$username" ] && [ "$username" != "$DEFAULT_USERNAME" ]; then
        echo "ACR_USERNAME=$username" >> "$ENV_FILE"
    else
        echo "# ACR_USERNAME=drepsmate" >> "$ENV_FILE"
    fi

    echo "# CONTAINER_CMD=podman" >> "$ENV_FILE"

    chmod 600 "$ENV_FILE"
    success "Created environment file: $ENV_FILE"
}

# --- Interactive Configuration Setup ---
run_interactive_setup() {
    say ""
    say "=========================================================="
    say "  Extract Bundle - Configuration Setup"
    say "=========================================================="
    say ""

    info "This wizard will help you configure the extract-bundle tool."
    say ""

    # Step 1: Registry
    local registry
    printf "Azure Container Registry [%s]: " "$DEFAULT_REGISTRY"
    read -r registry
    registry="${registry:-$DEFAULT_REGISTRY}"

    # Step 2: Username
    local username
    printf "Registry Username [%s]: " "$DEFAULT_USERNAME"
    read -r username
    username="${username:-$DEFAULT_USERNAME}"

    # Step 3: Password
    local password
    local password_confirm
    while true; do
        printf "Registry Password (input hidden): "
        read -s password
        echo ""

        if [ -z "$password" ]; then
            warn "Password cannot be empty. Please try again."
            continue
        fi

        printf "Confirm Password (input hidden): "
        read -s password_confirm
        echo ""

        if [ "$password" != "$password_confirm" ]; then
            warn "Passwords do not match. Please try again."
            continue
        fi

        break
    done

    # Step 4: Test authentication
    say ""
    info "Testing authentication..."

    local test_passed=false
    if echo "$password" | $CONTAINER_CMD login "$registry" --username "$username" --password-stdin >/dev/null 2>&1; then
        success "Authentication successful!"
        $CONTAINER_CMD logout "$registry" >/dev/null 2>&1
        test_passed=true
    else
        $CONTAINER_CMD logout "$registry" >/dev/null 2>&1
        warn "Authentication failed. Please verify your credentials."
        say ""
        printf "Save configuration anyway? [y/N]: "
        read -r save_anyway
        if [ "$save_anyway" = "y" ] || [ "$save_anyway" = "Y" ]; then
            test_passed=true
        else
            die "Configuration setup cancelled."
        fi
    fi

    # Step 5: Create configuration files
    if [ "$test_passed" = "true" ]; then
        say ""
        info "Creating configuration files..."

        # Create config file
        create_default_config

        # Create env file with credentials
        create_default_env "$password" "$registry" "$username"

        say ""
        say "=========================================================="
        say "  Configuration Complete!"
        say "=========================================================="
        say ""
        success "Registry: $registry"
        success "Username: $username"
        success "Password: *** (saved securely)"
        say ""
        info "Configuration saved to:"
        info "  - $CONFIG_FILE"
        info "  - $ENV_FILE (chmod 600)"
        say ""
        info "You can now use commands like:"
        info "  ./extract-bundle.sh --list"
        info "  ./extract-bundle.sh --update <repository>"
        say ""
    fi
}

run_configure() {
    say ""
    say "=========================================================="
    say "  Extract Bundle - Update Configuration"
    say "=========================================================="
    say ""

    if [ ! -f "$CONFIG_FILE" ]; then
        warn "Configuration file not found. Please run --init-config first."
        die "Missing configuration: $CONFIG_FILE"
    fi

    info "Current configuration:"
    say ""
    success "Default extraction directory: $DEFAULT_EXTRACT_DIR"
    success "Backup directory: $BACKUP_DIR"
    success "Backup retention: $BACKUP_RETENTION_DAYS days"
    say ""

    # Menu
    say "What would you like to configure?"
    say ""
    say "  1) Change default extraction directory"
    say "  2) Change backup directory"
    say "  3) Change backup retention days"
    say "  4) Reset to defaults"
    say "  5) Cancel"
    say ""

    printf "Select option [1-5]: "
    read -r option

    case "$option" in
        1)
            say ""
            info "Changing default extraction directory"
            say ""
            printf "Current: %s\n" "$DEFAULT_EXTRACT_DIR"
            printf "New default extraction directory: "
            read -r new_dir

            if [ -z "$new_dir" ]; then
                warn "No directory specified. Configuration unchanged."
                return 0
            fi

            # Update config file
            if grep -q "^default_extract_dir=" "$CONFIG_FILE"; then
                sed -i.bak "s|^default_extract_dir=.*|default_extract_dir=$new_dir|" "$CONFIG_FILE"
            else
                echo "default_extract_dir=$new_dir" >> "$CONFIG_FILE"
            fi

            say ""
            success "Default extraction directory updated to: $new_dir"
            say ""
            info "Configuration saved to: $CONFIG_FILE"
            say ""

            # Check if there are existing repositories that need migration
            if [ -f "$VERSION_FILE" ] && [ -s "$VERSION_FILE" ]; then
                local repo_count
                repo_count=$(jq 'length' "$VERSION_FILE" 2>/dev/null || echo "0")

                if [ "$repo_count" -gt 0 ]; then
                    say ""
                    warn "Note: You have $repo_count extracted repository(ies) in their previous locations."
                    say ""
                    info "Options:"
                    info "  1. Keep them in their current locations (updates will go to same places)"
                    info "  2. Future updates will use the new default for NEW repositories only"
                    say ""
                    printf "Would you like to see which repositories are affected? [y/N]: "
                    read -r show_repos

                    if [ "$show_repos" = "y" ] || [ "$show_repos" = "Y" ]; then
                        say ""
                        info "Existing repositories and their locations:"
                        jq -r 'to_entries[] | "  • \(.key): \(.value.extraction_dir)"' "$VERSION_FILE"
                        say ""
                        info "These repositories will continue using their current locations when updated."
                        say ""
                        info "To move a repository to the new default location:"
                        info "  1. Remove the old directory: rm -rf /old/path/<repo>"
                        info "  2. Run update: ./extract-bundle.sh --update <repo>"
                        info "  3. It will extract to the new default: $new_dir/<repo>"
                    fi
                fi
            fi
            ;;

        2)
            say ""
            info "Changing backup directory"
            say ""
            printf "Current: %s\n" "$BACKUP_DIR"
            printf "New backup directory: "
            read -r new_backup_dir

            if [ -z "$new_backup_dir" ]; then
                warn "No directory specified. Configuration unchanged."
                return 0
            fi

            # Update config file
            if grep -q "^backup_dir=" "$CONFIG_FILE"; then
                sed -i.bak "s|^backup_dir=.*|backup_dir=$new_backup_dir|" "$CONFIG_FILE"
            else
                echo "backup_dir=$new_backup_dir" >> "$CONFIG_FILE"
            fi

            say ""
            success "Backup directory updated to: $new_backup_dir"
            say ""
            info "Configuration saved to: $CONFIG_FILE"
            ;;

        3)
            say ""
            info "Changing backup retention days"
            say ""
            printf "Current: %s days\n" "$BACKUP_RETENTION_DAYS"
            printf "New retention (days): "
            read -r new_retention

            if [ -z "$new_retention" ]; then
                warn "No value specified. Configuration unchanged."
                return 0
            fi

            # Validate it's a number
            if ! [[ "$new_retention" =~ ^[0-9]+$ ]]; then
                die "Invalid number: $new_retention"
            fi

            # Update config file
            if grep -q "^backup_retention_days=" "$CONFIG_FILE"; then
                sed -i.bak "s|^backup_retention_days=.*|backup_retention_days=$new_retention|" "$CONFIG_FILE"
            else
                echo "backup_retention_days=$new_retention" >> "$CONFIG_FILE"
            fi

            say ""
            success "Backup retention updated to: $new_retention days"
            say ""
            info "Configuration saved to: $CONFIG_FILE"
            ;;

        4)
            say ""
            warn "This will reset configuration to defaults (credentials will be preserved)."
            printf "Are you sure? [y/N]: "
            read -r confirm

            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                say "Reset cancelled."
                return 0
            fi

            # Backup current config
            cp "$CONFIG_FILE" "$CONFIG_FILE.backup-$(date +%Y%m%d-%H%M%S)"

            # Recreate with defaults
            create_default_config

            say ""
            success "Configuration reset to defaults"
            say ""
            info "Previous config saved to: $CONFIG_FILE.backup-*"
            ;;

        5)
            say ""
            say "Configuration unchanged."
            ;;

        *)
            warn "Invalid option: $option"
            ;;
    esac

    say ""
}

# --- Container Runtime Detection ---
detect_container_runtime() {
    # CONTAINER_CMD can be set via:
    # 1. Environment variable (highest priority)
    # 2. Config file
    # 3. Auto-detection (fallback)
    
    if [ -n "$CONTAINER_CMD" ]; then
        # Already set, validate it exists
        if ! command -v "$CONTAINER_CMD" >/dev/null 2>&1; then
            die "Container runtime '$CONTAINER_CMD' not found. Install it or change CONTAINER_CMD setting."
        fi
        info "Using container runtime: $CONTAINER_CMD (configured)"
        log_info "Container runtime: $CONTAINER_CMD (from config/env)"
        return 0
    fi
    
    # Auto-detect
    if command -v docker >/dev/null 2>&1; then
        CONTAINER_CMD="docker"
        info "Using container runtime: $CONTAINER_CMD (auto-detected)"
        log_info "Container runtime: $CONTAINER_CMD (auto-detected)"
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER_CMD="podman"
        info "Using container runtime: $CONTAINER_CMD (auto-detected)"
        log_info "Container runtime: $CONTAINER_CMD (auto-detected)"
    else
        die "No container runtime found. Install Docker: sudo apt-get install docker.io OR Podman: sudo apt-get install podman"
    fi
}

# --- Credential Management ---
get_acr_password() {
    # Priority: env var > env file > interactive prompt
    if [ -n "$ACR_PASSWORD" ]; then
        log_info "Using ACR password from environment"
        return 0
    fi
    
    if [ "$NON_INTERACTIVE" = "true" ]; then
        die "ACR_PASSWORD not set and running in non-interactive mode. Set it in $ENV_FILE or environment."
    fi
    
    info "ACR credentials not found in environment file"
    printf "Enter ACR password (input hidden): "
    read -s ACR_PASSWORD
    say ""
    [ -z "$ACR_PASSWORD" ] && die "Password cannot be empty"
}

# --- Dependency Checks ---
check_dependencies() {
    local missing=()
    
    for cmd in mkdir pwd id date stat flock; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required commands: ${missing[*]}"
    fi
    
    # Detect container runtime
    detect_container_runtime
}

check_api_deps() {
    local missing=()
    
    for cmd in curl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing commands for API operations: ${missing[*]}. Install with: sudo apt-get install ${missing[*]}"
    fi
}

# --- Disk Space Management ---
check_disk_space() {
    local target_dir="$1"
    local required_bytes="$2"  # Required space in bytes

    # Find nearest existing parent directory for df check
    local check_dir="$target_dir"
    while [ ! -d "$check_dir" ] && [ "$check_dir" != "/" ]; do
        check_dir=$(dirname "$check_dir")
    done

    # If we couldn't find any existing directory, use /
    if [ ! -d "$check_dir" ]; then
        check_dir="/"
    fi

    log_info "Checking disk space on: $check_dir"

    # Get available space on target partition
    local available_bytes
    available_bytes=$(df -B1 "$check_dir" | tail -1 | awk '{print $4}')

    local required_gb
    required_gb=$(awk "BEGIN {printf \"%.2f\", $required_bytes/1024/1024/1024}")

    local available_gb
    available_gb=$(awk "BEGIN {printf \"%.2f\", $available_bytes/1024/1024/1024}")

    log_info "Disk space check: Required=${required_gb}GB, Available=${available_gb}GB"

    # Check if we have enough space (with 1.5x safety margin)
    local required_with_margin
    required_with_margin=$(awk "BEGIN {print int($required_bytes * 1.5)}")

    if [ "$available_bytes" -lt "$required_with_margin" ]; then
        die "Insufficient disk space. Required: ${required_gb}GB (+ margin), Available: ${available_gb}GB"
    fi

    # Warn if less than 10% free after extraction
    local remaining
    remaining=$(awk "BEGIN {print $available_bytes - $required_with_margin}")
    local total_bytes
    total_bytes=$(df -B1 "$check_dir" | tail -1 | awk '{print $2}')
    local percent_free
    percent_free=$(awk "BEGIN {printf \"%.1f\", ($remaining / $total_bytes) * 100}")

    if awk "BEGIN {exit !($percent_free < 10)}"; then
        warn "Low disk space warning: Only ${percent_free}% will remain free after extraction"
    fi

    success "Disk space check passed: ${available_gb}GB available"
}

# --- Docker Registry API ---
get_api_token() {
    local scope="${1:-registry:catalog:*}"
    
    echo "Getting authentication token..." >&2
    
    local token_response
    token_response=$(curl -s -u "${ACR_USERNAME}:${ACR_PASSWORD}" \
        "https://${ACR_REGISTRY}/oauth2/token?service=${ACR_REGISTRY}&scope=${scope}")
    
    local token
    token=$(echo "$token_response" | jq -r '.access_token // empty')
    
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        die "Failed to get API token. Check credentials."
    fi
    
    echo "$token"
}

# --- Version File Management ---
init_version_file() {
    if [ ! -f "$VERSION_FILE" ]; then
        echo '{}' > "$VERSION_FILE"
        log_info "Created version tracking file: $VERSION_FILE"
    fi
}

get_current_version() {
    local repo="$1"
    init_version_file
    jq -r --arg repo "$repo" '.[$repo].current // empty' "$VERSION_FILE"
}

get_previous_version() {
    local repo="$1"
    init_version_file
    jq -r --arg repo "$repo" '.[$repo].history[0].version // empty' "$VERSION_FILE"
}

get_extraction_dir() {
    local repo="$1"
    init_version_file
    jq -r --arg repo "$repo" '.[$repo].extraction_dir // empty' "$VERSION_FILE"
}

get_backup_path() {
    local repo="$1"
    init_version_file
    jq -r --arg repo "$repo" '.[$repo].backup_path // empty' "$VERSION_FILE"
}

save_version() {
    local repo="$1"
    local tag="$2"
    local extract_dir="$3"
    local backup_path="${4:-}"
    local status="${5:-success}"
    
    init_version_file
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local user
    user=$(whoami)
    
    # Get current version before updating
    local old_version
    old_version=$(get_current_version "$repo")
    
    # Use atomic write
    local tmp_file="${VERSION_FILE}.tmp.$$"
    
    if [ -n "$old_version" ] && [ "$old_version" != "$tag" ]; then
        # Add old version to history
        jq --arg repo "$repo" \
           --arg tag "$tag" \
           --arg old "$old_version" \
           --arg time "$timestamp" \
           --arg dir "$extract_dir" \
           --arg backup "$backup_path" \
           --arg status "$status" \
           --arg user "$user" \
           '.[$repo] = {
               current: $tag,
               extracted_at: $time,
               extraction_dir: $dir,
               extracted_by: $user,
               extraction_status: $status,
               backup_path: $backup,
               history: (
                   [{version: $old, extracted_at: (.[$repo].extracted_at // $time), status: "replaced"}] + 
                   (.[$repo].history // [])
               ) | .[0:10]
           }' "$VERSION_FILE" > "$tmp_file"
    else
        # First time or same version
        jq --arg repo "$repo" \
           --arg tag "$tag" \
           --arg time "$timestamp" \
           --arg dir "$extract_dir" \
           --arg backup "$backup_path" \
           --arg status "$status" \
           --arg user "$user" \
           '.[$repo] = {
               current: $tag,
               extracted_at: $time,
               extraction_dir: $dir,
               extracted_by: $user,
               extraction_status: $status,
               backup_path: $backup,
               history: (.[$repo].history // [])
           }' "$VERSION_FILE" > "$tmp_file"
    fi
    
    mv "$tmp_file" "$VERSION_FILE"
    success "Version tracking updated: $repo → $tag"
}

show_versions() {
    init_version_file
    
    say ""
    say "=========================================================="
    say "  Version History"
    say "=========================================================="
    say ""
    
    if [ ! -s "$VERSION_FILE" ] || [ "$(cat "$VERSION_FILE")" = "{}" ]; then
        warn "No version history found"
        say ""
        info "Extract bundles using this script to track versions"
        exit 0
    fi
    
    jq -r 'to_entries[] | 
        "Repository: \(.key)\n" +
        "  Current: \(.value.current)\n" +
        "  Status: \(.value.extraction_status // "unknown")\n" +
        "  Extracted: \(.value.extracted_at)\n" +
        "  By: \(.value.extracted_by // "unknown")\n" +
        "  Directory: \(.value.extraction_dir)\n" +
        (if .value.backup_path and (.value.backup_path != "") then 
            "  Backup: \(.value.backup_path)\n"
        else "" end) +
        (if (.value.history | length) > 0 then 
            "  History:\n" + 
            (.value.history | map("    - \(.version) (\(.extracted_at // "unknown"))") | join("\n")) + "\n"
        else "" end) +
        ""' "$VERSION_FILE"
    
    say "=========================================================="
    say ""
    info "Version file: $VERSION_FILE"
    info "Log file: $LOG_FILE"
    say ""
}

# --- Backup Management ---
create_backup_if_exists() {
    local source_dir="$1"
    local repo_name="$2"
    local current_tag="$3"
    
    if [ ! -d "$source_dir" ]; then
        log_info "No existing directory to backup: $source_dir"
        return 0
    fi
    
    if [ "$CREATE_BACKUP" != "true" ]; then
        log_info "Backup disabled, skipping"
        return 0
    fi
    
    # Create backup directory if needed
    mkdir -p "$BACKUP_DIR" || die "Failed to create backup directory: $BACKUP_DIR"
    
    local backup_name="${repo_name}-${current_tag}-$(date +%Y%m%d-%H%M%S)"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would backup: $source_dir → $backup_path"
        return 0
    fi

    info "Creating backup: $backup_path" >&2
    log_info "Backing up $source_dir to $backup_path"

    # Use cp -al for instant hardlink-based backup (if supported)
    if cp --help 2>&1 | grep -q -- '-l'; then
        cp -al "$source_dir" "$backup_path" || {
            # Fallback to regular copy
            cp -a "$source_dir" "$backup_path" || die "Backup failed"
        }
    else
        cp -a "$source_dir" "$backup_path" || die "Backup failed"
    fi

    success "Backup created: $backup_path" >&2
    echo "$backup_path"
}

cleanup_old_backups() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi
    
    log_info "Cleaning up backups older than $BACKUP_RETENTION_DAYS days"
    
    # Find and remove old backups
    find "$BACKUP_DIR" -maxdepth 1 -type d -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf {} \; 2>/dev/null || true
    
    log_info "Backup cleanup complete"
}

rollback_from_backup() {
    local repo="$1"
    local target_tag="${2:-}"
    
    local current_version
    current_version=$(get_current_version "$repo")
    
    if [ -z "$current_version" ]; then
        die "No version history for repository: $repo"
    fi
    
    local extract_dir
    extract_dir=$(get_extraction_dir "$repo")
    
    if [ -z "$extract_dir" ]; then
        die "No extraction directory found for repository: $repo"
    fi
    
    # If no target tag specified, use the backup from version file
    if [ -z "$target_tag" ]; then
        local backup_path
        backup_path=$(get_backup_path "$repo")
        
        if [ -z "$backup_path" ] || [ ! -d "$backup_path" ]; then
            die "No backup found for repository: $repo. Cannot rollback."
        fi
        
        local backup_version
        backup_version=$(get_previous_version "$repo")
        
        info "Rolling back to previous backup: $backup_version"
        info "Backup path: $backup_path"
    else
        # Find backup for specific tag
        local backup_path
        backup_path=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "${repo}-${target_tag}-*" | head -1)
        
        if [ -z "$backup_path" ] || [ ! -d "$backup_path" ]; then
            die "No backup found for ${repo}:${target_tag}"
        fi
        
        info "Rolling back to: $target_tag"
        info "Backup path: $backup_path"
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would rollback: $backup_path → $extract_dir"
        return 0
    fi
    
    # Create backup of current state before rollback
    local rollback_backup
    rollback_backup=$(create_backup_if_exists "$extract_dir" "$repo" "${current_version}-rollback")
    
    # Perform rollback
    info "Performing rollback..."
    rm -rf "$extract_dir" || die "Failed to remove current directory"
    cp -a "$backup_path" "$extract_dir" || die "Failed to restore backup"
    
    success "Rollback complete!"
    
    # Update version tracking
    local rolled_version
    local backup_basename=$(basename "$backup_path")
    # Remove repo name and hyphen from beginning: ${repo}-
    local version_and_timestamp="${backup_basename#${repo}-}"
    # Remove timestamp from end: -YYYYMMDD-HHMMSS
    rolled_version="${version_and_timestamp%-*-*}"
    save_version "$repo" "$rolled_version" "$extract_dir" "$rollback_backup" "rollback"
}

# --- List Operations ---
list_repositories() {
    say ""
    say "=========================================================="
    say "  Available Bundles"
    say "=========================================================="
    say ""

    # If bundle registry exists, list only bundles from registry
    if [ -n "$BUNDLE_REGISTRY" ] && [ -f "$BUNDLE_REGISTRY" ]; then
        if ! command -v jq >/dev/null 2>&1; then
            die "jq is required for bundle operations but not installed. Install with: brew install jq or apt-get install jq"
        fi

        # Get all bundles from registry
        local bundles
        bundles=$(jq -r '.bundles | keys[]' "$BUNDLE_REGISTRY" 2>/dev/null | sort)

        if [ -z "$bundles" ]; then
            warn "No bundles found in registry"
            exit 0
        fi

        # Display each bundle with description
        echo "$bundles" | while read -r bundle; do
            local desc=$(get_bundle_extraction_config "$bundle" "description")
            if [ -n "$desc" ]; then
                printf "  • %s - %s\n" "$bundle" "$desc"
            else
                printf "  • %s\n" "$bundle"
            fi
        done

        say ""
        info "Bundle registry: $BUNDLE_REGISTRY"
        say ""
    else
        # Fallback: Query ACR for all repositories (backward compatible)
        check_api_deps
        get_acr_password

        local token
        token=$(get_api_token "registry:catalog:*")

        local repos
        repos=$(curl -s -H "Authorization: Bearer $token" \
            "https://${ACR_REGISTRY}/v2/_catalog" | jq -r '.repositories[] // empty')

        if [ -z "$repos" ]; then
            warn "No repositories found"
            exit 0
        fi

        echo "$repos" | while read -r repo; do
            printf "  • %s\n" "$repo"
        done

        say ""
        warn "Bundle registry not found - showing all ACR repositories"
        say ""
    fi
}

list_tags() {
    local repo="$1"
    
    check_api_deps
    get_acr_password
    
    say ""
    say "=========================================================="
    say "  Tags for: $repo"
    say "=========================================================="
    say ""
    
    local token
    token=$(get_api_token "repository:${repo}:pull")

    local tags
    tags=$(curl -s -H "Authorization: Bearer $token" \
        "https://${ACR_REGISTRY}/v2/${repo}/tags/list" | jq -r '.tags[]? // empty' 2>/dev/null | sort -r)

    if [ -z "$tags" ]; then
        warn "No tags found for repository: $repo"
        exit 0
    fi
    
    echo "$tags" | while read -r tag; do
        printf "  • %s:%s\n" "$repo" "$tag"
    done
    
    say ""
}

# --- Browse and Select ---
browse_tags_for_repo() {
    local repo="$1"
    
    check_api_deps
    get_acr_password
    
    say ""
    say "=========================================================="
    say "  Select Tag: $repo"
    say "=========================================================="
    say ""
    
    local current_version
    current_version=$(get_current_version "$repo")
    if [ -n "$current_version" ]; then
        info "Current version: $current_version"
    fi
    
    local token
    token=$(get_api_token "repository:${repo}:pull")
    
    info "Fetching tags..."
    local tags
    tags=$(curl -s -H "Authorization: Bearer $token" \
        "https://${ACR_REGISTRY}/v2/${repo}/tags/list" | jq -r '.tags[]? // empty' 2>/dev/null | sort -r)

    if [ -z "$tags" ]; then
        die "No tags found for repository: $repo"
    fi
    
    local tag_array=()
    while IFS= read -r tag; do
        tag_array+=("$tag")
    done <<< "$tags"
    
    local tag_count=${#tag_array[@]}
    
    # Auto-select modes
    if [ "$UPGRADE_MODE" = "true" ]; then
        local selected_tag
        if [ -n "$UPGRADE_TAG" ]; then
            # Validate tag exists
            if ! echo "$tags" | grep -q "^${UPGRADE_TAG}$"; then
                die "Tag '$UPGRADE_TAG' not found in repository '$repo'"
            fi
            selected_tag="$UPGRADE_TAG"
            info "Using specified tag: $selected_tag"
        else
            selected_tag="${tag_array[0]}"
            info "Using latest tag: $selected_tag"
        fi
        IMAGE_NAME="${ACR_REGISTRY}/${repo}:${selected_tag}"
        success "Selected: $IMAGE_NAME"
        return 0
    fi
    
    if [ "$DOWNGRADE_MODE" = "true" ]; then
        local selected_tag
        if [ -n "$DOWNGRADE_TAG" ]; then
            if ! echo "$tags" | grep -q "^${DOWNGRADE_TAG}$"; then
                die "Tag '$DOWNGRADE_TAG' not found in repository '$repo'"
            fi
            selected_tag="$DOWNGRADE_TAG"
        else
            selected_tag=$(get_previous_version "$repo")
            if [ -z "$selected_tag" ]; then
                die "No previous version found. Specify tag with --downgrade <tag>"
            fi
            if ! echo "$tags" | grep -q "^${selected_tag}$"; then
                die "Previous version '$selected_tag' no longer exists in registry"
            fi
        fi
        IMAGE_NAME="${ACR_REGISTRY}/${repo}:${selected_tag}"
        info "Downgrading to: $selected_tag"
        success "Selected: $IMAGE_NAME"
        return 0
    fi
    
    # Interactive mode
    if [ "$NON_INTERACTIVE" = "true" ]; then
        die "Cannot interactively select tag in non-interactive mode"
    fi
    
    say ""
    say "Available tags ($tag_count):"
    say "=========================================================="
    
    local i=1
    for tag in "${tag_array[@]}"; do
        local marker=""
        if [ -n "$current_version" ] && [ "$tag" = "$current_version" ]; then
            marker=" ${COLOR_CYAN}(current)${COLOR_RESET}"
        fi
        printf "%3d. %s:%s%s\n" "$i" "$repo" "$tag" "$marker"
        ((i++))
    done
    
    say "=========================================================="
    say ""
    
    local selected_tag=""
    while true; do
        printf "Enter tag number (1-$tag_count) or q to quit: "
        read -r selected_index
        
        if [ "$selected_index" = "q" ] || [ "$selected_index" = "Q" ]; then
            say "Cancelled."
            exit 0
        fi
        
        if [[ "$selected_index" =~ ^[0-9]+$ ]] && \
           [ "$selected_index" -ge 1 ] && \
           [ "$selected_index" -le "$tag_count" ]; then
            selected_tag="${tag_array[$((selected_index - 1))]}"
            success "Selected: $repo:$selected_tag"
            break
        else
            warn "Invalid selection. Please enter a number between 1 and $tag_count"
        fi
    done
    
    IMAGE_NAME="${ACR_REGISTRY}/${repo}:${selected_tag}"
}

# --- Extraction ---
perform_extraction() {
    local image_name="$1"
    local extract_dir="$2"
    
    # Extract metadata
    local repo
    repo=$(echo "$image_name" | sed "s|${ACR_REGISTRY}/||" | cut -d: -f1)
    local tag
    tag=$(echo "$image_name" | cut -d: -f2)
    
    log_info "Starting extraction: $image_name → $extract_dir"
    
    # Step 1: Login
    say ""
    say "=========================================================="
    say "Step 1/6: Container Login"
    say "=========================================================="
    say ""
    
    if [ "$DRY_RUN" != "true" ]; then
        if echo "$ACR_PASSWORD" | $CONTAINER_CMD login "$ACR_REGISTRY" --username "$ACR_USERNAME" --password-stdin >/dev/null 2>&1; then
            success "Logged in to $ACR_REGISTRY"
        else
            die "Failed to login to registry"
        fi
    else
        info "[DRY-RUN] Would login to $ACR_REGISTRY using $CONTAINER_CMD"
    fi
    
    # Step 2: Pull Image
    say ""
    say "=========================================================="
    say "Step 2/6: Pull Image"
    say "=========================================================="
    say ""
    
    info "Pulling: $image_name"
    
    if [ "$DRY_RUN" != "true" ]; then
        if $CONTAINER_CMD pull "$image_name"; then
            success "Image pulled successfully"
        else
            die "Failed to pull image: $image_name"
        fi
        
        # Get image size
        local img_size_bytes
        img_size_bytes=$($CONTAINER_CMD image inspect "$image_name" --format='{{.Size}}' 2>/dev/null || echo "0")
        
        if [ "$img_size_bytes" != "0" ]; then
            local img_size_gb
            img_size_gb=$(awk "BEGIN {printf \"%.2f\", $img_size_bytes/1024/1024/1024}")
            info "Image size: ${img_size_gb} GB"
        fi
    else
        info "[DRY-RUN] Would pull: $image_name using $CONTAINER_CMD"
        img_size_bytes=2147483648  # Assume 2GB for dry-run
    fi
    
    # Step 3: Disk Space Check
    say ""
    say "=========================================================="
    say "Step 3/6: Disk Space Check"
    say "=========================================================="
    say ""
    
    check_disk_space "$(dirname "$extract_dir")" "$img_size_bytes"
    
    # Step 4: Backup
    say ""
    say "=========================================================="
    say "Step 4/6: Backup Current Version"
    say "=========================================================="
    say ""
    
    local backup_path=""
    local current_version
    current_version=$(get_current_version "$repo")
    
    if [ -n "$current_version" ]; then
        backup_path=$(create_backup_if_exists "$extract_dir" "$repo" "$current_version")
    else
        info "No current version to backup"
    fi
    
    # Step 5: Extract (Atomic)
    say ""
    say "=========================================================="
    say "Step 5/6: Extract Bundle"
    say "=========================================================="
    say ""
    
    local temp_extract_dir="${extract_dir}.tmp.$$"

    if [ "$DRY_RUN" = "true" ]; then
        info "[DRY-RUN] Would extract to: $temp_extract_dir using $CONTAINER_CMD"
        info "[DRY-RUN] Would rename: $temp_extract_dir → $extract_dir"

        # Step 6: Cleanup (dry-run)
        say ""
        say "=========================================================="
        say "Step 6/6: Cleanup"
        say "=========================================================="
        say ""

        if [ "$AUTO_CLEANUP" = "true" ]; then
            info "[DRY-RUN] Would remove image from cache: $image_name"
        else
            info "[DRY-RUN] Would prompt to remove image from cache: $image_name"
        fi

        info "[DRY-RUN] Would update version tracking: $repo → $tag"
        info "[DRY-RUN] Would cleanup old backups (retention: $BACKUP_RETENTION_DAYS days)"

        return 0
    fi
    
    # Create temp directory
    mkdir -p "$temp_extract_dir" || die "Failed to create temp directory"
    
    info "Extracting to temporary location: $temp_extract_dir"
    log_info "Temporary extraction directory: $temp_extract_dir"
    
    if $CONTAINER_CMD run --rm \
        -e TARGET_UID="$(id -u)" \
        -e TARGET_GID="$(id -g)" \
        -v "$temp_extract_dir:/out" \
        "$image_name"; then
        success "Bundle extracted to temporary location"
    else
        rm -rf "$temp_extract_dir"
        die "Failed to extract bundle"
    fi
    
    # Validate extraction
    if [ "$VERIFY_EXTRACTION" = "true" ]; then
        info "Validating extraction..."
        if [ ! -d "$temp_extract_dir" ] || [ -z "$(ls -A "$temp_extract_dir")" ]; then
            rm -rf "$temp_extract_dir"
            die "Extraction validation failed: directory is empty"
        fi
        success "Extraction validated"
    fi

    # Unwrap single nested directory for root/models bundles
    # This fixes the issue where bundles contain a single wrapped directory
    # (e.g., payload/saa/* instead of payload/*)
    if is_bundle "$repo"; then
        local bundle_mode_check=$(get_bundle_extraction_config "$repo" "mode")

        # Only unwrap for platform (root) and models bundles
        if [ "$bundle_mode_check" = "root" ] || [ "$bundle_mode_check" = "models" ]; then
            # Count directories and files at root level of temp extraction
            local dir_count=$(find "$temp_extract_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
            local file_count=$(find "$temp_extract_dir" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

            # If exactly 1 directory and no files at root → unwrap it
            if [ "$dir_count" = "1" ] && [ "$file_count" = "0" ]; then
                local nested_dir=$(find "$temp_extract_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
                local nested_name=$(basename "$nested_dir")

                info "Unwrapping nested directory: $nested_name/"

                # Create temporary location for unwrapping
                local unwrap_temp="${temp_extract_dir}.unwrap.$$"
                mkdir -p "$unwrap_temp" || die "Failed to create unwrap temp directory"

                # Move contents of nested dir to unwrap temp
                mv "$nested_dir"/* "$unwrap_temp/" 2>/dev/null || true
                # Also move hidden files if any
                mv "$nested_dir"/.[!.]* "$unwrap_temp/" 2>/dev/null || true

                # Remove now-empty nested dir and old temp
                rmdir "$nested_dir" 2>/dev/null || true
                rm -rf "$temp_extract_dir"

                # Move unwrap temp to final temp location
                mv "$unwrap_temp" "$temp_extract_dir" || die "Failed to complete unwrap"

                success "Directory unwrapped successfully"
            fi
        fi
    fi

    # Move extracted content to final location
    # Check if this is a bundle and get its mode
    local bundle_mode=""
    if is_bundle "$repo"; then
        bundle_mode=$(get_bundle_extraction_config "$repo" "mode")
    fi

    # For service/infrastructure bundles: merge into existing directory
    # For platform/models bundles: atomic replace
    if [ "$bundle_mode" = "service" ] || [ "$bundle_mode" = "infrastructure" ]; then
        info "Merging bundle contents into existing directory..."

        # Create parent directory if it doesn't exist
        mkdir -p "$extract_dir" || die "Failed to create extraction directory"

        # Move/merge contents from temp to final location
        # rsync --remove-source-files ensures atomic-like behavior while merging
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --remove-source-files "$temp_extract_dir/" "$extract_dir/" || die "Failed to merge bundle contents"
            # Cleanup empty temp directory
            rm -rf "$temp_extract_dir"
        else
            # Fallback to cp + rm
            cp -r "$temp_extract_dir/"* "$extract_dir/" || die "Failed to merge bundle contents"
            rm -rf "$temp_extract_dir"
        fi
    else
        # Atomic replace for platform/models bundles
        info "Performing atomic move..."
        if [ -d "$extract_dir" ]; then
            rm -rf "$extract_dir" || die "Failed to remove old directory"
        fi

        mv "$temp_extract_dir" "$extract_dir" || {
            # Try to recover
            warn "Move failed, attempting recovery..."
            if [ -d "$temp_extract_dir" ]; then
                mv "$temp_extract_dir" "$extract_dir" || die "Recovery failed"
            fi
        }
    fi
    
    success "Extraction complete: $extract_dir"
    
    # Step 6: Cleanup
    say ""
    say "=========================================================="
    say "Step 6/6: Cleanup"
    say "=========================================================="
    say ""
    
    if [ "$AUTO_CLEANUP" = "true" ]; then
        if $CONTAINER_CMD rmi "$image_name" >/dev/null 2>&1; then
            success "Removed image from cache"
        fi
    elif [ "$NON_INTERACTIVE" = "false" ]; then
        printf "Remove image from cache? [y/N]: "
        read -r cleanup_choice
        if [ "$cleanup_choice" = "y" ] || [ "$cleanup_choice" = "Y" ]; then
            if $CONTAINER_CMD rmi "$image_name" >/dev/null 2>&1; then
                success "Removed image from cache"
            fi
        fi
    fi
    
    # Update version tracking
    save_version "$repo" "$tag" "$extract_dir" "$backup_path" "success"
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Final summary
    say ""
    say "=========================================================="
    say "  EXTRACTION COMPLETE"
    say "=========================================================="
    say ""
    success "Repository: $repo"
    success "Version: $tag"
    success "Location: $extract_dir"
    if [ -n "$backup_path" ]; then
        success "Backup: $backup_path"
    fi
    say ""
    
    log_info "Extraction completed successfully"
}

# --- Simplified Commands ---
cmd_update() {
    local repo="$1"

    info "Running update for repository: $repo"

    # Set flags for update operation
    UPGRADE_MODE="true"
    CREATE_BACKUP="true"
    AUTO_CLEANUP="true"
    NON_INTERACTIVE="true"

    # Get extraction directory from history or use bundle-aware default
    # This preserves "update in place" behavior for existing extractions
    EXTRACT_DIR=$(get_extraction_dir "$repo")
    if [ -z "$EXTRACT_DIR" ] || [ ! -d "$EXTRACT_DIR" ]; then
        # Use bundle-aware default extraction directory
        EXTRACT_DIR=$(get_bundle_default_extract_dir "$repo")

        info "Using default extraction directory for $repo: $EXTRACT_DIR"
    fi

    # Browse and select latest
    browse_tags_for_repo "$repo"

    # Perform extraction
    perform_extraction "$IMAGE_NAME" "$EXTRACT_DIR"
}

cmd_safe_update() {
    local repo="$1"
    
    info "Running safe update for repository: $repo"
    
    # First: dry-run
    say ""
    info "=== DRY-RUN MODE ==="
    say ""
    
    DRY_RUN="true"
    UPGRADE_MODE="true"
    NON_INTERACTIVE="true"
    
    EXTRACT_DIR=$(get_extraction_dir "$repo")
    if [ -z "$EXTRACT_DIR" ]; then
        EXTRACT_DIR=$(get_bundle_default_extract_dir "$repo")
    fi

    browse_tags_for_repo "$repo"
    perform_extraction "$IMAGE_NAME" "$EXTRACT_DIR"
    
    # Ask for confirmation
    say ""
    if [ "$NON_INTERACTIVE" = "false" ]; then
        printf "Proceed with actual update? [y/N]: "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            say "Update cancelled"
            exit 0
        fi
    fi
    
    # Actual update
    DRY_RUN="false"
    CREATE_BACKUP="true"
    AUTO_CLEANUP="true"
    
    perform_extraction "$IMAGE_NAME" "$EXTRACT_DIR"
}

# --- Help System ---
show_help_brief() {
    cat << EOF
Extract Bundle - Container Registry Tool v${SCRIPT_VERSION}

USAGE:
  extract-bundle.sh [OPTIONS] [COMMAND]

COMMON COMMANDS:
  --update <repo>              Update repository to latest version
  --safe-update <repo>         Update with dry-run confirmation
  --rollback <repo>            Rollback to previous backup
  --show-versions              Show version history

REPOSITORY SELECTION:
  --repository <repo>          Select repository
  --upgrade [tag]              Upgrade to latest or specific tag
  --downgrade [tag]            Downgrade to previous or specific tag

INFORMATION:
  --list                       List all repositories
  --list-tags <repo>           List tags for repository
  --help                       Show this help
  --help-full                  Show detailed help
  --version                    Show script version

OPTIONS:
  --non-interactive            Run without prompts
  --dry-run                    Show what would happen
  --no-backup                  Skip backup creation
  --no-cleanup                 Keep container images

CONFIGURATION:
  --init-config                Initial setup wizard (first time)
  --configure                  Update configuration interactively

  Config file: ~/.extract-bundle.conf
  Env file: ~/.extract-bundle.env
  Log file: ~/.extract-bundle.log

CONTAINER RUNTIME:
  Auto-detected (Docker or Podman). Override with:
    CONTAINER_CMD=podman ./extract-bundle.sh ...
  Or set in ~/.extract-bundle.env:
    CONTAINER_CMD=podman

EXAMPLES:
  # Quick update to latest version
  extract-bundle.sh --update saa-asr-service

  # Safe update with confirmation
  extract-bundle.sh --safe-update saa-asr-service

  # Rollback to previous version
  extract-bundle.sh --rollback saa-asr-service

  # Use Podman instead of Docker
  CONTAINER_CMD=podman extract-bundle.sh --update saa-asr-service

For detailed help: extract-bundle.sh --help-full
EOF
}

show_help_full() {
    cat << EOF
Extract Bundle - Container Registry Tool v${SCRIPT_VERSION}
=================================================================

CONTAINER RUNTIME SUPPORT:
  This script supports both Docker and Podman. The runtime is
  automatically detected in this order:
    1. CONTAINER_CMD environment variable (highest priority)
    2. container_cmd setting in config file
    3. Auto-detection: docker → podman (fallback)

  To use Podman:
    - Install: sudo apt-get install podman
    - Script auto-detects it if Docker is not installed
    - Or force it: CONTAINER_CMD=podman ./extract-bundle.sh ...
    - Or set permanently in ~/.extract-bundle.env

  Both Docker and Podman are fully supported with identical syntax.

DESCRIPTION:
  Tool for extracting container bundles from Azure
  Container Registry with comprehensive backup, rollback, and version
  tracking.

FEATURES:
  ✓ Automatic backup before extraction
  ✓ Atomic operations (extract to temp, then rename)
  ✓ Version tracking and history
  ✓ Instant rollback from backups
  ✓ Comprehensive logging
  ✓ Disk space validation
  ✓ Secure credential management
  ✓ Non-interactive mode for automation
  ✓ Dry-run mode
  ✓ Docker and Podman support

For complete documentation, see:
  ~/.extract-bundle.log (operation logs)
  --show-versions (version history)
  --help (this message)

Version: ${SCRIPT_VERSION}
EOF
}

# --- Main Argument Parser ---
parse_arguments() {
    if [ $# -eq 0 ]; then
        show_help_brief
        exit 0
    fi
    
    local repo_arg=""
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --version)
                echo "extract-bundle.sh version $SCRIPT_VERSION"
                exit 0
                ;;
            --help)
                show_help_brief
                exit 0
                ;;
            --help-full)
                show_help_full
                exit 0
                ;;
            --init-config)
                run_interactive_setup
                exit 0
                ;;
            --configure)
                run_configure
                exit 0
                ;;
            --show-versions)
                show_versions
                exit 0
                ;;
            --list)
                list_repositories
                exit 0
                ;;
            --list-tags)
                [ -z "${2:-}" ] && die "Usage: $0 --list-tags <repository-name>"
                list_tags "$2"
                exit 0
                ;;
            --update)
                [ -z "${2:-}" ] && die "Usage: $0 --update <repository-name>"
                cmd_update "$2"
                exit 0
                ;;
            --safe-update)
                [ -z "${2:-}" ] && die "Usage: $0 --safe-update <repository-name>"
                NON_INTERACTIVE="false"  # Override for confirmation
                cmd_safe_update "$2"
                exit 0
                ;;
            --rollback)
                [ -z "${2:-}" ] && die "Usage: $0 --rollback <repository-name> [tag]"
                rollback_from_backup "$2" "${3:-}"
                exit 0
                ;;
            --repository)
                [ -z "${2:-}" ] && die "Usage: $0 --repository <repository-name>"
                repo_arg="$2"
                shift 2
                ;;
            --upgrade)
                UPGRADE_MODE="true"
                if [ -n "${2:-}" ] && [[ ! "${2:-}" =~ ^-- ]]; then
                    UPGRADE_TAG="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --downgrade)
                DOWNGRADE_MODE="true"
                if [ -n "${2:-}" ] && [[ ! "${2:-}" =~ ^-- ]]; then
                    DOWNGRADE_TAG="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --non-interactive)
                NON_INTERACTIVE="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --no-backup)
                CREATE_BACKUP="false"
                shift
                ;;
            --no-cleanup)
                AUTO_CLEANUP="false"
                shift
                ;;
            --no-colors)
                ENABLE_COLORS="false"
                shift
                ;;
            --extract-dir)
                [ -z "${2:-}" ] && die "Usage: $0 --extract-dir <path>"
                EXTRACT_DIR="$2"
                shift 2
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
    
    # If repository specified, browse tags
    if [ -n "$repo_arg" ]; then
        browse_tags_for_repo "$repo_arg"
        
        # If IMAGE_NAME is set, proceed to extraction
        if [ -n "$IMAGE_NAME" ]; then
            # Determine extraction directory
            if [ -z "$EXTRACT_DIR" ]; then
                EXTRACT_DIR=$(get_extraction_dir "$repo_arg")
                if [ -z "$EXTRACT_DIR" ]; then
                    # Use bundle-aware default directory
                    local bundle_default=$(get_bundle_default_extract_dir "$repo_arg")

                    if [ "$NON_INTERACTIVE" = "true" ]; then
                        EXTRACT_DIR="$bundle_default"
                    else
                        printf "Extraction directory (default: %s): " "$bundle_default"
                        read -r user_dir
                        EXTRACT_DIR="${user_dir:-$bundle_default}"
                    fi
                fi
            fi
            
            perform_extraction "$IMAGE_NAME" "$EXTRACT_DIR"
        fi
    fi
}

# --- Main ---
main() {
    # Initialize
    setup_colors
    load_env_file
    load_config_file
    init_logging "$@"
    check_dependencies
    
    # Acquire lock (unless dry-run or read-only operations)
    if [ "$DRY_RUN" != "true" ] && [[ ! " $* " =~ " --list" ]] && [[ ! " $* " =~ " --show-versions" ]] && [[ ! " $* " =~ " --help" ]] && [[ ! " $* " =~ " --version" ]]; then
        acquire_lock
    fi
    
    # Parse and execute
    parse_arguments "$@"
    
    # Cleanup
    release_lock
    log_info "Script completed successfully"
}

# Run main
main "$@"
