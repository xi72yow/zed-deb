# Sandbox

Diese Session läuft in einem rootless Podman-Container (`zed-acp-sandbox`), gestartet aus Zed.

## Werkzeuge

Das Image enthält keine Toolchains, nur git, git-lfs, curl, jq, ripgrep, fd (`fdfind`), ssh und
Podman. Builds und Tests laufen über das `Containerfile` des Projekts mit `podman build` und
`podman run`. Fehlt im Projekt ein Containerfile, abbrechen und melden.

## Netzwerk

Im Modus strict sind nur Anthropic, GitHub, npm, crates.io, Debian und die Container-Registries
(Docker Hub, Quay, GHCR) erreichbar. Andere Namen löst DNS gar nicht erst auf (`REFUSED`).
Innere Container teilen sich das Netz der Sandbox und damit die Firewall. Zusätzliche Domains
werden auf dem Host freigeschaltet, nicht im Projekt. Alle DNS-Anfragen stehen in
`/run/dnsmasq/dnsmasq.log`, abgewiesene haben keine `forwarded`-Zeile.

## Git

- Commits nur nach Conventional Commits, Englisch, kurz.
- `push`, `prune`, `reflog expire` und `gc --prune=now` sind gesperrt.
- `.git/hooks` und `.git/config` sind read-only, keine Hooks und keine Config-Änderungen.

## Dateisystem

- Das Projekt liegt unter seinem echten Host-Pfad.
- Außerhalb des Projekts ist nichts vom Host beschreibbar.
- `/tmp` ist noexec.
