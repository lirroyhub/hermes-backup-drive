#!/usr/bin/env bash
#
# install-rclone-catalina.sh
# Installs the last Catalina-compatible rclone (v1.70.3) into ~/bin,
# no admin / no sudo required. Safe to re-run.
#
# Why v1.70.3: newer rclone builds require a Go version that won't run on
# macOS 10.15, crashing with "dyld: Symbol not found: _SecTrustCopyCertificateChain".
# 1.70.3 is the last release the rclone project documents as Catalina-compatible.

set -euo pipefail

RCLONE_VERSION="v1.70.3"
ZIP="rclone-${RCLONE_VERSION}-osx-amd64.zip"
URL="https://downloads.rclone.org/${RCLONE_VERSION}/${ZIP}"
DIR="rclone-${RCLONE_VERSION}-osx-amd64"

echo "==> Installing rclone ${RCLONE_VERSION} (Catalina-compatible) into ~/bin"

cd "$HOME"

# 1. Download
echo "==> Downloading ${URL}"
curl -fL -O "$URL"

# 2. Extract
echo "==> Extracting"
unzip -o -a "$ZIP" >/dev/null

# 3. Install into ~/bin
mkdir -p "$HOME/bin"
cp "${DIR}/rclone" "$HOME/bin/rclone"
chmod +x "$HOME/bin/rclone"

# 4. Clean up download artifacts
rm -rf "${DIR}" "${ZIP}"

# 5. Clear macOS Gatekeeper quarantine (harmless if not present)
xattr -d com.apple.quarantine "$HOME/bin/rclone" 2>/dev/null || true

# 6. Ensure ~/bin is on PATH for this session and future ones
export PATH="$HOME/bin:$PATH"
if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$HOME/.zshrc" 2>/dev/null; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc"
    echo "==> Added ~/bin to PATH in ~/.zshrc"
fi

# 7. Verify
echo "==> Verifying..."
if "$HOME/bin/rclone" version; then
    echo ""
    echo "✅ rclone ${RCLONE_VERSION} is installed and runs on this macOS."
    echo "   Next: run 'rclone config' to connect Google Drive (remote name: gdrive)."
else
    echo ""
    echo "❌ rclone failed to run. If you see a dyld symbol error, even 1.70.3"
    echo "   is too new for this OS — tell me the exact error."
    exit 1
fi
