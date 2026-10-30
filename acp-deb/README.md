# zed-acp-pin

Pins the Claude ACP agent for Zed and updates it once a week, only to releases that are at least 7 days old. This aims to reduce the exposure to compromised releases, which tend to be caught within days. It is not a guarantee, and signatures and attestations only prove origin, not that the content is harmless.

The package contains no Anthropic code. The agent is downloaded from npm on each machine, under the terms of its publishers. Each user signs in with their own account.

## Flow

1. `zed-acp-pin-update.timer` runs every Monday at 09:00 and catches up on missed runs.
2. `zed-acp-pin-update --auto` resolves the newest stable release older than the minimum age.
3. The release is installed into a staging directory, inside a `node:22-slim` container and with `--ignore-scripts`. npm never runs on the host.
4. `npm audit signatures` and a test of the permission title run against the staging directory.
5. Only then the copy in `~/.local/share/zed-acp-pin` is swapped, the old one moves to `zed-acp-pin.previous`.
6. A desktop notification reports the update or the failure. A failed update leaves the installed version in place.

A new version becomes active after restarting Zed. New threads may start with it earlier.

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
```

`ZED_ACP_PIN_MIN_AGE_DAYS` overrides the minimum age, `ZED_ACP_PIN_DIR` the install directory.

To roll back, swap `~/.local/share/zed-acp-pin.previous` back into place and restart Zed.

## Permission title check

Versions 0.71.0 up to the fix in [#1070](https://github.com/agentclientprotocol/claude-agent-acp/pull/1070) showed the model-written description instead of the shell command in the permission card ([#1068](https://github.com/agentclientprotocol/claude-agent-acp/issues/1068)). The update rejects releases that bring this regression back, since approving a command without seeing it defeats the prompt.
