# SAA Bundle Tools

Professional DevOps tools for managing SAA (Speech Analytics Application) platform bundles using Docker images and Azure Container Registry.

## Overview

SAA Bundle Tools provides a unified solution for creating, distributing, and extracting platform bundles across development, staging, and production environments. It supports 5 different bundle types with intelligent extraction modes (atomic replace vs. merge).

## Features

- **Bundle Registry**: Single source of truth for all bundle definitions (`.bundle-registry.json`)
- **Intelligent Extraction**: Automatic unwrapping of nested directories, merge vs. replace logic
- **Version Tracking**: Track installed bundle versions across environments
- **Backup & Rollback**: Automatic backups before updates
- **Multi-Runtime Support**: Auto-detects Docker or Podman
- **Dry-Run Mode**: Test extractions without making changes
- **Comprehensive Logging**: Detailed logs for troubleshooting

## Quick Start

### Installation

#### Option 1: One-Line Install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh | bash
```

#### Option 2: Manual Install (More Secure)

```bash
# Download installer
curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh -o install.sh

# Review the script
less install.sh

# Run installation
bash install.sh
```

#### Option 3: Install from Release (Most Secure)

```bash
# Download latest release
VERSION="v1.0.2"
curl -fsSL "https://github.com/SebastianCalin/saa-bundle-tools-personal/releases/download/${VERSION}/saa-bundle-tools-${VERSION}.tar.gz" \
  -o saa-bundle-tools.tar.gz

# Extract
tar -xzf saa-bundle-tools.tar.gz
cd saa-bundle-tools-${VERSION}

# Install
bash install.sh
```

### First Steps

```bash
# List available bundles
saa-setup --list

# List available versions for a bundle
saa-setup --repository saa-platform-bundle --list-tags

# Extract platform bundle (dry-run first)
saa-setup --repository saa-platform-bundle --upgrade 1.0.3 --dry-run

# Extract platform bundle
saa-setup --repository saa-platform-bundle --upgrade 1.0.3
```

## Bundle Types

### 1. Platform Bundle (`saa-platform-bundle`)
- **Type**: `platform`
- **Mode**: `root` (atomic replace)
- **Size**: ~400MB
- **Contents**: Complete SAA platform (40+ services)
- **Use Case**: Fresh installations, disaster recovery

```bash
saa-setup --repository saa-platform-bundle --upgrade 1.0.3
```

### 2. Models Bundle (`saa-models-bundle`)
- **Type**: `models`
- **Mode**: `models` (atomic replace)
- **Size**: ~15GB
- **Contents**: ASR ML models (Romanian)
- **Use Case**: Required for ASR service

```bash
# Custom extraction directory (requires permissions)
saa-setup --repository saa-models-bundle --upgrade 1.0.3 --extract-dir ~/saa-models
```

### 3. Service Bundles

#### ASR Service
- **Repository**: `saa-asr-service-bundle`
- **Mode**: `service` (merge)
- **Dependencies**: `saa-models-bundle:1.0.0`

```bash
saa-setup --repository saa-asr-service-bundle --upgrade 1.0.3
```

#### Anonymization Service
- **Repository**: `saa-anonymization-service-bundle`
- **Mode**: `service` (merge)

```bash
saa-setup --repository saa-anonymization-service-bundle --upgrade 1.0.3
```

### 4. Infrastructure Bundle (`saa-observability-bundle`)
- **Type**: `infrastructure`
- **Mode**: `infrastructure` (merge)
- **Contents**: Prometheus, Grafana, Loki, Tempo
- **Use Case**: Monitoring stack updates

```bash
saa-setup --repository saa-observability-bundle --upgrade 1.0.3
```

## Usage Examples

### Basic Operations

```bash
# List all available bundles from registry
saa-setup --list

# List versions available in Azure Container Registry
saa-setup --repository saa-platform-bundle --list-tags

# Dry-run extraction (safe preview)
saa-setup --repository saa-platform-bundle --upgrade 1.0.3 --dry-run

# Extract to default location
saa-setup --repository saa-platform-bundle --upgrade 1.0.3

# Extract to custom location
saa-setup --repository saa-platform-bundle --upgrade 1.0.3 --extract-dir /opt/saa
```

### Advanced Operations

```bash
# Update existing installation
saa-setup --update saa-platform-bundle

# Safe update (dry-run first, then prompt)
saa-setup --safe-update saa-platform-bundle

# Non-interactive mode (for automation)
saa-setup --repository saa-platform-bundle --upgrade 1.0.3 --non-interactive

# Skip backup creation
saa-setup --repository saa-platform-bundle --upgrade 1.0.3 --no-backup

# Custom container runtime
CONTAINER_CMD=podman saa-setup --list
```

### Working with Version Tracking

```bash
# View installed bundle versions
cat ~/.saa-bundle-versions

# Example output:
# saa-platform-bundle:1.0.3:/home/user/saa
# saa-models-bundle:1.0.3:/home/user/saa-models
# saa-asr-service-bundle:1.0.3:/home/user/saa/saa-asr-service
```

## How It Works

### Extraction Modes

#### Atomic Replace (Platform & Models)
- Deletes old directory
- Moves new content atomically
- Used for complete replacements
- **Bundles**: `platform`, `models`

#### Merge (Services & Infrastructure)
- Merges new files into existing directory using `rsync`
- Preserves other content
- Used for service updates
- **Bundles**: `service`, `infrastructure`

### Nested Directory Unwrapping (v1.0.2+)

The tool automatically detects and unwraps nested directories in platform/models bundles:

```
Before:  ~/saa/saa/*           (nested - BAD)
After:   ~/saa/*               (flat - GOOD)
```

This ensures proper directory structure regardless of how bundles were created.

### Bundle Registry

All bundle definitions are stored in `.bundle-registry.json`:

```json
{
  "bundles": {
    "saa-platform-bundle": {
      "description": "Complete SAA Platform",
      "type": "platform",
      "extraction": {
        "mode": "root",
        "target_name": "saa",
        "default_parent_dir": "$HOME"
      }
    }
  }
}
```

## Configuration

### Environment Variables

```bash
# Custom installation directory
export INSTALL_DIR="$HOME/bin"

# Custom config directory
export CONFIG_DIR="$HOME/.config/saa-bundle-tools"

# Container runtime (auto-detected if not set)
export CONTAINER_CMD="docker"  # or "podman"

# Bundle registry location
export BUNDLE_REGISTRY="$HOME/.config/saa-bundle-tools/bundle-registry.json"
```

### Backup Configuration

```bash
# Backup retention (days)
export BACKUP_RETENTION_DAYS=7

# Backup location
export BACKUP_DIR="$HOME/saa-backups"
```

## Troubleshooting

### Common Issues

#### "Permission denied" when extracting to /opt

**Solution**: Use custom extraction directory or pre-create with proper permissions:

```bash
sudo mkdir -p /opt/saa-models
sudo chown $USER:$USER /opt/saa-models
saa-setup --repository saa-models-bundle --upgrade 1.0.3 --extract-dir /opt/saa-models
```

#### Nested directory structure after extraction

**Solution**: Upgrade to v1.0.2+ which includes automatic unwrapping:

```bash
# This is fixed in v1.0.2+
saa-setup --repository saa-platform-bundle --upgrade 1.0.3
```

#### Service bundle deleted other services

**Solution**: Upgrade to v1.0.2+ which uses merge logic for service bundles:

```bash
# Service bundles now merge instead of replacing
saa-setup --repository saa-asr-service-bundle --upgrade 1.0.3
```

### Logs

Check extraction logs for detailed information:

```bash
# Logs are stored in /tmp/setup-*.log
ls -lt /tmp/setup-*.log | head -5

# View latest log
tail -f $(ls -t /tmp/setup-*.log | head -1)
```

## Requirements

- **OS**: Linux, macOS
- **Tools**: `bash`, `docker` or `podman`, `tar`, `curl` or `wget`
- **Optional**: `rsync` (for merge operations), `jq` (for registry parsing)

## Version History

### v1.0.2 (2026-01-04)
- Fixed nested directory unwrapping for platform/models bundles
- Improved merge logic for service bundles
- Added intelligent directory structure detection
- Enhanced error handling and validation

### v1.0.1 (2025-12-30)
- Added bundle registry support
- Improved version tracking
- Enhanced backup and rollback functionality

### v1.0.0 (2025-12-20)
- Initial release
- Support for 5 bundle types
- Docker and Podman support
- Azure Container Registry integration

## License

Proprietary - RepsMate Development Team

## Support

For issues, questions, or feature requests:
- GitHub Issues: https://github.com/SebastianCalin/saa-bundle-tools-personal/issues
- Email: support@repsmate.com

## Contributing

This is a private repository. For contribution guidelines, please contact the development team.
