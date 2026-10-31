#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Usage: init-firewall.sh <strict|lax> <comma separated extra domains>
# The settings come from the host config of the launcher, never from the project directory.

NETWORK_MODE="$1"
IFS=',' read -r -a EXTRA_DOMAINS <<<"$2"

ipt() {
    iptables "$@"
    ip6tables "$@"
}

for cmd in iptables ip6tables; do
    $cmd -F
    $cmd -X
    $cmd -P INPUT ACCEPT
    $cmd -P OUTPUT ACCEPT
done
ipset destroy allowed-v4 2>/dev/null || true
ipset destroy allowed-v6 2>/dev/null || true

ipt -A INPUT -i lo -j ACCEPT
ipt -A OUTPUT -o lo -j ACCEPT

if [ "$NETWORK_MODE" = "lax" ]; then
    echo "Network mode: lax"
    ipt -P FORWARD DROP
    exit 0
fi

echo "Network mode: strict"
ipset create allowed-v4 hash:net family inet
ipset create allowed-v6 hash:net family inet6

# covers git over https and ssh as well
while read -r cidr; do
    ipset add allowed-v4 "$cidr" 2>/dev/null || true
done < <(curl -s https://api.github.com/meta | jq -r '(.web + .api + .git)[]' | aggregate -q)

# each entry includes its subdomains
ALLOWED_DOMAINS=(
    # anthropic
    "api.anthropic.com"
    "statsig.anthropic.com"
    "statsig.com"
    "sentry.io"
    # git hosting
    "github.com"
    "githubusercontent.com"
    # package registries
    "registry.npmjs.org"
    "crates.io"
    "deb.debian.org"
    "security.debian.org"
    # container registries for the inner podman
    "docker.io"
    "production.cloudflare.docker.com"
    "production.cloudfront.docker.com"
    "quay.io"
    "ghcr.io"
    # oauth
    "www.google.com"
    "www.googleapis.com"
)
for domain in "${EXTRA_DOMAINS[@]}"; do
    [ -n "$domain" ] && ALLOWED_DOMAINS+=("$domain")
done
if [ ${#EXTRA_DOMAINS[@]} -gt 0 ]; then
    echo "Extra domains: ${EXTRA_DOMAINS[*]}"
fi

# dnsmasq answers only allowlisted names and adds their addresses to the ipsets on the fly,
# so rotating cdn addresses keep working and dns stops being a way to reach other names
UPSTREAM=$(awk '$1 == "nameserver" {print $2; exit}' /etc/resolv.conf)
mkdir -p /run/dnsmasq
chown dnsmasq /run/dnsmasq
# dnsmasq forces mode 0660 on its log, the group makes it readable for the agent
install -o dnsmasq -g agent -m 640 /dev/null /run/dnsmasq/dnsmasq.log
{
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "no-resolv"
    echo "user=dnsmasq"
    echo "pid-file=/run/dnsmasq/dnsmasq.pid"
    echo "log-queries"
    echo "log-facility=/run/dnsmasq/dnsmasq.log"
    for domain in "${ALLOWED_DOMAINS[@]}"; do
        echo "server=/$domain/$UPSTREAM"
        echo "ipset=/$domain/allowed-v4,allowed-v6"
    done
} > /run/dnsmasq/dnsmasq.conf
dnsmasq --conf-file=/run/dnsmasq/dnsmasq.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

ipt -A OUTPUT -p udp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT
ipt -A OUTPUT -p tcp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT

ipt -P INPUT DROP
ipt -P FORWARD DROP
ipt -P OUTPUT DROP

ipt -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ipt -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -A OUTPUT -m set --match-set allowed-v4 dst -j ACCEPT
ip6tables -A OUTPUT -m set --match-set allowed-v6 dst -j ACCEPT

ipt -A OUTPUT -j REJECT

echo "Firewall ready (strict mode)."
