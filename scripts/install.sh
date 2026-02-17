#!/bin/bash
set -euo pipefail

# Install script for the Zed APT repository
# Usage: curl -fsSL https://xi72yow.github.io/zed-deb/install.sh | sudo bash

REPO_URL="${REPO_URL:-https://xi72yow.github.io/zed-deb}"

echo "Adding Zed APT repository..."

# Download and install the GPG key
curl -fsSL "${REPO_URL}/key.gpg" | gpg --dearmor -o /usr/share/keyrings/zed-deb.gpg

# Add the repository
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/zed-deb.gpg] ${REPO_URL} stable main" \
  > /etc/apt/sources.list.d/zed.list

# Update and install
apt-get update
apt-get install -y zed

echo "Zed has been installed successfully!"
echo "Run 'zed' to start the editor."
