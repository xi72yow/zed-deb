# zed-acp-pin

Pins the Claude ACP agent for Zed and updates it only to releases that are at least 7 days old, including their dependency tree. This aims to reduce the exposure to compromised releases, which tend to be caught within days. It is not a guarantee, and signatures and attestations only prove origin, not that the content is harmless.

The package contains no Anthropic code. The agent is downloaded from npm on each machine, under the terms of its publishers. Each user signs in with their own account.

## Flow

1. `zed-acp-pin-update.timer` runs daily at 09:00 and catches up on missed runs.
2. `zed-acp-pin-update --auto` resolves the newest stable release older than the minimum age.
3. The release is installed into a staging directory, inside a digest-pinned `node:22-slim` container and with `--ignore-scripts`. `npm install --before` applies the same cutoff to every transitive dependency.
4. `npm audit signatures` and a test of the permission title run against the staging directory.
5. Only then the copy in `~/.local/share/zed-acp-pin` is swapped, the old one moves to `zed-acp-pin.previous`.
6. `npm audit` checks the installed tree for high or critical advisories.
7. A desktop notification reports the update, the advisories or the failure. A failed update leaves the installed version in place.

A new version becomes active after restarting Zed. New threads may start with it earlier.

## Scope

The delay is the actual protection. The container only isolates the installation. At runtime `zed-acp-pin` starts the agent with the host node and the full rights of the user, so malicious code in a settled release would still run. `zed-acp-sandbox` (below) runs the same pinned agent in a container instead.

Security fixes are delayed by the minimum age as well. The daily audit surfaces known advisories earlier, installing the fix stays a manual decision:

```bash
zed-acp-pin-update 0.96.1                          # fixed release, dependencies as of its release
ZED_ACP_PIN_MIN_AGE_DAYS=0 zed-acp-pin-update latest  # newest release and newest dependencies
```

The image digest is the `node` stage of `acp-deb/sandbox/Containerfile`, is updated by Dependabot and is written into the script at package build time.

## Setup

```bash
sudo apt install zed-acp-pin
zed-acp-pin-update latest
systemctl --user daemon-reload
systemctl --user start zed-acp-pin-update.timer
```

The node runtime has to be version 22 or newer. Debian 13 ships an older one, so `nodejs-24` from a separate repository is needed there.

In `~/.config/zed/settings.json`:

```json
"agent_servers": {
  "zed-acp-pin": {
    "type": "custom",
    "command": "zed-acp-pin",
    "default_config_options": { "model": "opus[1m]" }
  }
}
```

The registry entry `claude-acp` resolves the newest release through npx on every start, without a minimum age, and should be removed for the pin to be effective.

## Usage

```bash
zed-acp-pin-update            # shows the installed version
zed-acp-pin-update latest     # newest stable release past the minimum age
zed-acp-pin-update 0.95.0     # exactly this version, bypasses the minimum age
zed-acp-pin-update --auto     # what the timer runs
zed-acp-pin-update audit      # advisories in the installed tree
```

`ZED_ACP_PIN_MIN_AGE_DAYS` overrides the minimum age, `ZED_ACP_PIN_DIR` the install directory.

To roll back, swap `~/.local/share/zed-acp-pin.previous` back into place and restart Zed.

## zed-acp-sandbox

Runs the pinned agent in a rootless podman container, as two agent servers next to `zed-acp-pin`:

| Agent server | Runtime | Permission prompts | Use |
|---|---|---|---|
| `zed-acp-pin` | host node | yes | administration and planning across projects |
| `zed-acp-sandbox work` | container | yes | work inside one project |
| `zed-acp-sandbox yolo` | container | no (`bypassPermissions`) | implementing a finished plan |

### Setup

```bash
sudo apt install zed-acp-sandbox
zed-acp-sandbox build     # builds the local image, otherwise the first start in Zed does it
zed-acp-sandbox login     # creates a long-lived token with the pinned claude, checks it and stores it in the keyring
```

```json
"agent_servers": {
  "zed-admin": { "type": "custom", "command": "zed-acp-pin" },
  "zed-work": { "type": "custom", "command": "zed-acp-sandbox", "args": ["work"] },
  "zed-yolo": { "type": "custom", "command": "zed-acp-sandbox", "args": ["yolo"] }
}
```

### What the sandbox does

- **Project:** Zed starts the agent in the first folder of the window, which is mounted under its host path. Further folders of the same window are not mounted, so the sandbox expects one folder per window.
- **Network:** In `strict` mode a dnsmasq inside the container resolves only allowlisted domains and adds their addresses to the firewall on the fly. This keeps CDNs with rotating addresses working and refuses DNS for every other name. Only dnsmasq may send DNS to the outside.
- **Podman inside:** Projects build and test through their own `Containerfile`. Inner containers share the network of the sandbox, so the firewall applies to them as well.
- **Git:** `.git` is writable, so yolo can commit. `.git/hooks` and `.git/config`, including those of submodules, are mounted read-only, since they would run on the host with the next git call there. A git wrapper rejects `push`, `prune`, `reflog expire` and `gc --prune=now`. This is a hurdle against mistakes, not a boundary.
- **Claude config:** Each profile has its own config dir in `~/.local/share/zed-acp-sandbox/<profile>/`. `CLAUDE.md`, skills, agents, commands and output styles of `~/.claude` are mounted read-only, `settings.json` is copied without hooks and status line. A writable `~/.claude` would let a session place hooks that `zed-acp-pin` then runs on the host.
- **Login:** The sandbox uses a token from `claude setup-token` via `CLAUDE_CODE_OAUTH_TOKEN`, read from the keyring over D-Bus (Secret Service). Sharing `~/.claude/.credentials.json` would let a refresh in the sandbox rotate the token under host sessions, because Claude locks the refresh per config dir.

### Host config

Network settings are read from `~/.config/zed-acp-sandbox/settings.json`, never from the project, so a session cannot open its own firewall:

```json
{
  "domains": ["registry.opencode.de"],
  "projects": {
    "/home/user/project": { "network": "lax", "domains": ["example.org"], "kvm": true }
  }
}
```

`kvm` passes `/dev/kvm` into the sandbox, for projects that start VMs.

### Debugging

```bash
zed-acp-sandbox shell work                       # bash in the sandbox of the current directory
zed-acp-sandbox shell work cat /run/dnsmasq/dnsmasq.log   # dns queries, refused ones have no forwarded line
```

Zed shows the stderr of the launcher under `dev: open acp logs`.

### Limits

- Changes in the working tree can still reach the host later, for example through build scripts, `.claude/settings.json` hooks of the project or Zed tasks. They should be reviewed before building on the host or opening the project with `zed-acp-pin`.
- `/proc` of the sandbox is unmasked, which nested podman needs to mount its own `/proc`. Writes there stay denied by the host kernel.
- The local image is rebuilt automatically when its sources change, from the layer cache. Debian security updates in between need `zed-acp-sandbox build`, which builds without cache.

## Permission title check

Versions 0.71.0 up to the fix in [#1070](https://github.com/agentclientprotocol/claude-agent-acp/pull/1070) showed the model-written description instead of the shell command in the permission card ([#1068](https://github.com/agentclientprotocol/claude-agent-acp/issues/1068)). The update rejects releases that bring this regression back, since approving a command without seeing it defeats the prompt.
