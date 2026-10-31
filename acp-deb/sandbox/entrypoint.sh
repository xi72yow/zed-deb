#!/bin/bash
set -euo pipefail

# Usage: entrypoint.sh <strict|lax> <comma separated extra domains> <command...>
# stdout belongs to the ACP protocol, everything before the command goes to stderr

NETWORK="$1"
DOMAINS="$2"
shift 2

sudo /usr/local/bin/init-firewall.sh "$NETWORK" "$DOMAINS" >&2
sudo /usr/local/bin/cleanup-firewall.sh >&2

# the bounding set keeps what the inner podman needs, NET_ADMIN and NET_RAW stay dropped
# so the firewall cannot be changed; no-new-privs would disable the setuid newuidmap
exec setpriv \
    --inh-caps=-all \
    --ambient-caps=-all \
    --bounding-set=-all,+chown,+dac_override,+fowner,+fsetid,+kill,+setgid,+setuid,+setpcap,+sys_chroot,+setfcap \
    -- "$@"
