# zed-deb

Unofficial Debian/APT repository for [Zed](https://zed.dev), hosted on GitHub Pages.

Automatically checks for new Zed releases every 6 hours, builds a `.deb` package, and publishes it.

## Installation

### Quick install

```bash
# Replace xi72yow with your GitHub username
curl -fsSL https://xi72yow.github.io/zed-deb/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/zed-deb.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/zed-deb.gpg] https://xi72yow.github.io/zed-deb stable main" \
  | sudo tee /etc/apt/sources.list.d/zed.list
sudo apt update
sudo apt install zed
```

### Update

```bash
sudo apt update && sudo apt upgrade zed
```

### Uninstall

```bash
sudo apt remove zed
sudo rm /etc/apt/sources.list.d/zed.list /usr/share/keyrings/zed-deb.gpg
```

## Setup (for repository maintainers)

### 1. Create a GPG key

```bash
gpg --full-generate-key
# Choose: RSA, 4096 bits, no expiry, name: "zed-deb", email: your email
```

### 2. Export the private key

```bash
gpg --armor --export-secret-keys "zed-deb" | base64 -w0
```

### 3. Add GitHub Secret

Go to your repo Settings > Secrets and variables > Actions > New repository secret:
- Name: `GPG_PRIVATE_KEY`
- Value: the **raw** (not base64) armored private key output of:
  ```bash
  gpg --armor --export-secret-keys "zed-deb"
  ```

### 4. Enable GitHub Pages

Go to Settings > Pages:
- Source: **GitHub Actions**

### 5. Trigger first build

Go to Actions > "Update Zed Package" > Run workflow.

## How it works

1. GitHub Action runs on schedule (every 6h) or manually
2. Checks the latest Zed release via GitHub API
3. Compares with the currently packaged version
4. If new: downloads tarball, builds `.deb`, updates APT repo metadata
5. Signs the repository with GPG
6. Deploys `repo/` directory to GitHub Pages

## License

The packaging scripts in this repository are MIT licensed.
Zed itself is licensed under GPL-3.0-or-later by Zed Industries, Inc.
