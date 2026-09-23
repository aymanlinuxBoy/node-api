# Release Process

This project uses **semantic versioning** for Docker image tags. Releases are managed via git tags.

## Semantic Versioning Format

Tags must follow: `vX.Y.Z` (e.g., `v1.0.0`, `v1.2.3`)

- **MAJOR** (X): Breaking changes
- **MINOR** (Y): New features, backward compatible
- **PATCH** (Z): Bug fixes, backward compatible

## Creating a Release

### 1. Update Version (Optional)
If using package.json versioning, update it:
```bash
npm version minor  # or major, patch
```

### 2. Create and Push a Git Tag
```bash
git tag v1.0.0
git push origin v1.0.0
```

### 3. CI Automatically:
- ✅ Runs all security checks (`lint-and-security` job)
- ✅ Builds Docker image
- ✅ Scans image with Trivy
- ✅ Runs smoke test with Postgres
- ✅ Pushes to Docker Hub with tags:
  - `username/node-api-poc:1.0.0` (semantic version)
  - `username/node-api-poc:latest` (convenience tag)

## Examples

### First Release
```bash
git tag v1.0.0
git push origin v1.0.0
# → Builds and pushes: image:1.0.0, image:latest
```

### Bug Fix Release
```bash
git tag v1.0.1
git push origin v1.0.1
# → Builds and pushes: image:1.0.1, image:latest
```

### Development Builds (No Tag)
Pushing to `main` without a tag:
```bash
git push origin main
# → Builds and pushes: image:abc123def456 (short SHA)
# → No 'latest' tag, prevents accidental overwrite
```

## Docker Hub Tags

| Git Action | Docker Tags |
|-----------|------------|
| `git push origin v1.0.0` | `1.0.0`, `latest` |
| `git push origin v1.0.1` | `1.0.1`, `latest` |
| `git push origin main` (no tag) | `abc123def456` (short SHA) |

## Quick Start - First Release

```bash
# Make sure everything is committed
git status

# Create and push version tag
git tag v1.0.0
git push origin v1.0.0

# Monitor CI in GitHub Actions
# Once complete, check Docker Hub for new images
```

## Viewing Tags

```bash
# List local tags
git tag

# List remote tags
git ls-remote --tags origin

# Show details of a tag
git show v1.0.0
```

## Deleting a Tag (if needed)

```bash
# Delete local tag
git tag -d v1.0.0

# Delete remote tag
git push origin --delete v1.0.0
```
