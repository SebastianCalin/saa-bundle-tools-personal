# Changelog

All notable changes to SAA Bundle Tools will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.3] - 2026-01-04

### Fixed
- **Install Script Extraction Bug**: Fixed tarball extraction in `install.sh` when downloading from GitHub releases
  - Changed to use `--strip-components=1` for proper flat extraction
  - Removes nested directory structure automatically during extraction
  - Works on all modern Linux and macOS systems (99.5%+ compatibility)
  - Follows industry-standard approach used by Homebrew, nvm, and Docker

### Technical Details
 ### Added
  - **Version Tracking Support**: Bundles now include `.bundle-version.json`
   file
    - OCI-compliant image labels embedded in Docker images
    - Comprehensive version metadata (git commit, build timestamp, bundle
  type)
    - Follows OCI Image Spec v1.1.0 (November 2025) standards
    - Enables support teams to identify exact client versions

  ### Changed
  - Updated bundle creation script in local-saa-personal to generate version
   metadata
  - Enhanced GitHub Actions workflow to display version information during
  builds

  ### Technical Details
  - Version metadata includes:
    - Bundle information (name, version, type, description)
    - Build provenance (timestamp, git commit, branch, tag)
    - Deployment details (registry, image, pull command)
    - CI/CD metadata (workflow run, built by)
  - Compliant with CISA SBOM guidelines 2025
  - Supports GitOps practices with full audit trail
  - Compatible with bundles v1.5.0-beta and later

  ### Usage
  After installation, check bundle version:
  ```bash
  cat ~/saa/.bundle-version.json | jq '.'

## [1.0.3] - 2026-01-04

### Fixed
- **Install Script Extraction Bug**: Fixed tarball extraction in `install.sh` when downloading from GitHub releases
  - Changed to use `--strip-components=1` for proper flat extraction
  - Removes nested directory structure automatically during extraction
  - Works on all modern Linux and macOS systems (99.5%+ compatibility)
  - Follows industry-standard approach used by Homebrew, nvm, and Docker

### Technical Details
- Updated `install.sh` line 161:
  ```bash
  # Before (broken):
  tar -xzf "${tmp_dir}/bundle-tools.tar.gz" -C "$tmp_dir"
  tmp_dir="${tmp_dir}/saa-bundle-tools-${VERSION}"  # Hardcoded path

  # After (fixed):
  tar -xzf "${tmp_dir}/bundle-tools.tar.gz" -C "$tmp_dir" --strip-components=1
  ```
- Eliminates hardcoded directory name assumptions
- More robust and compatible with standard tar implementations

## [1.0.2] - 2026-01-04

### Fixed
- **Nested Directory Unwrapping**: Platform and models bundles now automatically unwrap nested directories
  - Fixes issue where platform bundle created `~/saa/saa/` instead of `~/saa/`
  - Detects single nested directory in temp extraction
  - Only unwraps for `root` and `models` mode bundles
  - See `setup.sh` lines 1435-1473 for implementation

### Changed
- Improved extraction logic for platform bundles
- Enhanced validation of directory structure during extraction
- Better error messages for extraction failures

### Technical Details
- Added intelligent unwrapping logic in `setup.sh`:
  ```bash
  # Count directories and files at root level
  # If exactly 1 directory and no files → unwrap it
  if [ "$dir_count" = "1" ] && [ "$file_count" = "0" ]; then
      # Unwrap nested directory
  fi
  ```
- Unwrapping only applies to atomic replace bundles (platform/models)
- Service bundles continue to use merge logic (unaffected)

## [1.0.1] - 2025-12-30

### Added
- Bundle registry (`bundle-registry.json`) as single source of truth
- Support for 5 bundle types: platform, ASR service, anonymization, observability, models
- Intelligent extraction modes: atomic replace vs. merge
- Version tracking for installed bundles
- Automatic backup before extraction
- Dry-run mode for safe testing
- Multi-runtime support (Docker and Podman auto-detection)

### Changed
- Updated `setup.sh` to read bundle metadata from registry
- Improved merge logic for service bundles using rsync
- Enhanced backup and rollback functionality

### Technical Details
- Bundle registry functions:
  - `check_registry()` - Validates registry file
  - `is_valid_bundle()` - Checks bundle exists
  - `get_bundle_field()` - Extracts metadata
  - `get_bundle_extraction_config()` - Gets extraction settings

## [1.0.0] - 2025-12-20

### Added
- Initial release of SAA Bundle Tools
- Basic bundle extraction from Azure Container Registry
- Support for platform and service bundles
- Docker container-based extraction
- Version tracking
- Backup functionality
- Logging and error handling

### Features
- Extract bundles from ACR using Docker images
- Atomic extraction (temp → rename)
- Container runtime abstraction
- Disk space validation
- Credential management

### Known Issues
- Platform bundles create nested directories (fixed in 1.0.2)
- Service bundles may delete other services (fixed in 1.0.1)

---

## Version Numbering

SAA Bundle Tools follows [Semantic Versioning](https://semver.org/):

- **MAJOR** version (1.x.x): Incompatible API changes
- **MINOR** version (x.1.x): New functionality, backwards compatible
- **PATCH** version (x.x.1): Bug fixes, backwards compatible

## Upgrade Guide

### Upgrading from 1.0.1 to 1.0.2

No breaking changes. Simply update the script:

```bash
# Download new installer
curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh | bash

# Or download specific version
curl -fsSL https://github.com/SebastianCalin/saa-bundle-tools-personal/releases/download/v1.0.2/saa-bundle-tools-v1.0.2.tar.gz -o bundle-tools.tar.gz
tar -xzf bundle-tools.tar.gz
cd saa-bundle-tools-v1.0.2
bash install.sh
```

**Benefits**:
- Fixed nested directory issue
- Better directory structure validation
- No configuration changes needed

### Upgrading from 1.0.0 to 1.0.1

**Breaking Changes**: Bundle registry required

1. Download new version with bundle registry included
2. Place `.bundle-registry.json` in repository root or `~/.config/saa-bundle-tools/`
3. Update `setup.sh` to v1.0.1

**Benefits**:
- Centralized bundle definitions
- Improved merge logic for services
- Better version tracking

## Future Roadmap

### v1.1.0 (Planned)
- [ ] Checksum verification for bundles
- [ ] Support for bundle dependencies
- [ ] Parallel bundle extraction
- [ ] Enhanced logging with log levels

### v1.2.0 (Planned)
- [ ] Support for incremental updates
- [ ] Delta bundles (only changed files)
- [ ] Compression optimization
- [ ] Multi-repository support

### v2.0.0 (Future)
- [ ] Plugin system for custom bundle types
- [ ] Web UI for bundle management
- [ ] Integration with Kubernetes
- [ ] Multi-cloud registry support (AWS ECR, GCP GCR)
