# Getting Started with SAA Bundle Tools Distribution

This guide explains how to use this repository to distribute SAA Bundle Tools to clients.

## Repository Structure

```
saa-bundle-tools-personal/
├── .bundle-registry.json       # Bundle definitions (5 bundles)
├── setup.sh                    # Main extraction tool (v1.0.2)
├── install.sh                  # Installer wrapper for clients
├── VERSION                     # Current version (1.0.2)
├── README.md                   # User-facing documentation
├── CHANGELOG.md                # Version history
├── .gitignore                  # Git ignore rules
└── .github/
    └── workflows/
        └── release.yml         # Automated release creation
```

## How to Distribute to Clients

### Method 1: One-Line Install (Easiest for Clients)

Once you push to GitHub, clients can install with:

```bash
curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh | bash
```

### Method 2: GitHub Releases (Most Professional)

1. **Create a release** (see "Creating a Release" below)
2. **Share the release URL** with clients:

```bash
# Download specific version
VERSION="v1.0.2"
curl -fsSL "https://github.com/SebastianCalin/saa-bundle-tools-personal/releases/download/${VERSION}/saa-bundle-tools-${VERSION}.tar.gz" \
  -o saa-bundle-tools.tar.gz

# Extract and install
tar -xzf saa-bundle-tools.tar.gz
cd saa-bundle-tools-${VERSION}
bash install.sh
```

### Method 3: Manual Review (Most Secure)

```bash
# Download installer for review
curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh -o install.sh

# Review the script
less install.sh

# Run installation
bash install.sh
```

## Creating a Release

### Automatic Release (Recommended)

The GitHub Actions workflow automatically creates releases when you push a version tag:

```bash
# 1. Update VERSION file
echo "1.0.3" > VERSION

# 2. Update CHANGELOG.md
# Add new version section to CHANGELOG.md

# 3. Commit changes
git add VERSION CHANGELOG.md
git commit -m "Bump version to 1.0.3"

# 4. Create and push tag
git tag -a v1.0.3 -m "Release v1.0.3"
git push origin main
git push origin v1.0.3

# GitHub Actions will automatically:
# - Create the release
# - Build tarball
# - Generate checksums
# - Upload assets
```

### Manual Release

```bash
# 1. Create archive
VERSION="1.0.2"
tar -czf "saa-bundle-tools-v${VERSION}.tar.gz" \
  setup.sh \
  .bundle-registry.json \
  install.sh \
  README.md \
  CHANGELOG.md \
  VERSION

# 2. Generate checksum
sha256sum "saa-bundle-tools-v${VERSION}.tar.gz" > checksums.txt

# 3. Create release on GitHub
# Go to: https://github.com/SebastianCalin/saa-bundle-tools-personal/releases/new
# - Tag: v1.0.2
# - Title: Release v1.0.2
# - Description: Copy from CHANGELOG.md
# - Upload: saa-bundle-tools-v1.0.2.tar.gz and checksums.txt
```

## First-Time Setup (For You)

### 1. Push to GitHub

```bash
# Navigate to repository
cd /Users/sebastiangalan/Documents/Repsmate/01_Kubernetes/DevOps/saa-bundle-tools-personal

# Add all files
git add .

# Commit
git commit -m "Initial commit: SAA Bundle Tools v1.0.2

- Bundle extraction tool (setup.sh v1.0.2)
- Bundle registry with 5 bundle types
- Professional installation wrapper
- Comprehensive documentation
- Automated GitHub Actions release workflow
"

# Push to GitHub
git push origin main
```

### 2. Create First Release

```bash
# Create and push version tag
git tag -a v1.0.2 -m "Release v1.0.2

- Fixed nested directory unwrapping
- Improved merge logic for service bundles
- Enhanced error handling
"
git push origin v1.0.2
```

GitHub Actions will automatically create the release!

### 3. Verify Release

1. Go to: https://github.com/SebastianCalin/saa-bundle-tools-personal/releases
2. Verify v1.0.2 release is created
3. Download and test the tarball

## Client Installation Instructions

### Quick Reference Card for Clients

Create a simple instruction card for clients:

```markdown
# SAA Bundle Tools - Installation

## Quick Install (Recommended)
curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh | bash

## Manual Install (More Secure)
curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh -o install.sh
less install.sh  # Review first
bash install.sh

## Usage
saa-setup --list                              # List bundles
saa-setup --repository saa-platform-bundle --upgrade 1.0.3

## Documentation
https://github.com/SebastianCalin/saa-bundle-tools-personal

## Support
support@repsmate.com
```

## Updating the Tools

### For Bug Fixes (Patch Version 1.0.2 → 1.0.3)

```bash
# 1. Fix bugs in setup.sh or other files
# 2. Update VERSION file
echo "1.0.3" > VERSION

# 3. Update CHANGELOG.md
# Add new [1.0.3] section

# 4. Commit and tag
git add .
git commit -m "Fix: [description]"
git tag -a v1.0.3 -m "Release v1.0.3"
git push origin main v1.0.3
```

### For New Features (Minor Version 1.0.2 → 1.1.0)

```bash
# 1. Add new features
# 2. Update VERSION
echo "1.1.0" > VERSION

# 3. Update CHANGELOG.md
# 4. Commit and tag
git tag -a v1.1.0 -m "Release v1.1.0"
git push origin main v1.1.0
```

## Repository Settings

### Making Repository Private

If this is a private tool:

1. Go to: https://github.com/SebastianCalin/saa-bundle-tools-personal/settings
2. Scroll to "Danger Zone"
3. Click "Change repository visibility" → "Make private"

**Note**: Private repos require authentication for `curl` downloads:

```bash
# Client needs GitHub token
curl -H "Authorization: token YOUR_GITHUB_TOKEN" \
  -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh | bash
```

### Adding Collaborators

For team access:
1. Go to: Settings → Collaborators
2. Add team members

## Testing the Distribution

Before sharing with clients, test the installation:

```bash
# Test from a clean environment
docker run -it --rm ubuntu:22.04 bash

# Inside container
apt-get update && apt-get install -y curl
curl -fsSL https://raw.githubusercontent.com/SebastianCalin/saa-bundle-tools-personal/main/install.sh | bash

# Verify installation
saa-setup --version
saa-setup --list
```

## Next Steps

1. **Push to GitHub** (see section above)
2. **Create first release** (v1.0.2)
3. **Test installation** on clean machine
4. **Share with first client** and gather feedback
5. **Iterate** based on feedback

## Monitoring Usage

### GitHub Insights

Track usage via GitHub:
- **Releases**: See download counts
- **Traffic**: View clone/visitor statistics
- **Issues**: Track client problems

### Analytics (Optional)

Add analytics to install.sh to track installations:

```bash
# Add to install.sh
curl -s "https://analytics.repsmate.com/install?version=${VERSION}" >/dev/null 2>&1 || true
```

## Support & Maintenance

### Responding to Issues

When clients report issues:

1. Check GitHub Issues
2. Reproduce locally
3. Fix in new version
4. Release patch
5. Notify affected clients

### Scheduled Maintenance

- **Monthly**: Review and update dependencies
- **Quarterly**: Security audit
- **Yearly**: Major version with breaking changes if needed

---

**Questions?** Contact: sebastian.galan@repsmate.com
