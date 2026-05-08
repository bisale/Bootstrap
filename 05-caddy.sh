#!/usr/bin/env bash
set -euo pipefail

CADDY_ENV_FILE="/etc/caddy/hetzner.env"
CADDY_BIN="/usr/bin/caddy"
CADDY_BACKUP="/usr/bin/caddy.stock"
PLUGIN="github.com/caddy-dns/hetzner/v2"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen, z. B.: sudo $0"
  exit 1
fi

echo "==> Installiere Grundpakete..."
apt update
apt install -y \
  debian-keyring \
  debian-archive-keyring \
  apt-transport-https \
  curl \
  gpg \
  git \
  golang

echo "==> Richte offizielles Caddy APT-Repository ein..."
if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
fi

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list

chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod o+r /etc/apt/sources.list.d/caddy-stable.list

echo "==> Installiere Caddy..."
apt update
apt install -y caddy

echo "==> Installiere xcaddy..."
export GOPATH="${GOPATH:-/root/go}"
export PATH="$PATH:$GOPATH/bin"

go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

if ! command -v xcaddy >/dev/null 2>&1; then
  echo "xcaddy wurde nicht gefunden. Erwarteter Pfad: $GOPATH/bin/xcaddy"
  exit 1
fi

echo "==> Baue Caddy mit Hetzner DNS Plugin..."
BUILD_DIR="$(mktemp -d)"
cd "$BUILD_DIR"

xcaddy build --with "$PLUGIN"

if [[ ! -x ./caddy ]]; then
  echo "Build fehlgeschlagen: ./caddy wurde nicht erstellt."
  exit 1
fi

echo "==> Stoppe Caddy..."
systemctl stop caddy || true

echo "==> Sichere aktuelle Caddy-Binary..."
if [[ -x "$CADDY_BIN" && ! -f "$CADDY_BACKUP" ]]; then
  cp "$CADDY_BIN" "$CADDY_BACKUP"
fi

echo "==> Installiere Custom-Caddy-Binary..."
cp ./caddy "$CADDY_BIN"
chown root:root "$CADDY_BIN"
chmod 755 "$CADDY_BIN"

echo "==> Prüfe Hetzner-Modul..."
if ! "$CADDY_BIN" list-modules | grep -q '^dns.providers.hetzner$'; then
  echo "Fehler: Hetzner DNS Plugin wurde nicht gefunden."
  "$CADDY_BIN" list-modules | grep hetzner || true
  exit 1
fi

echo
echo "==> Hetzner DNS API Token"
read -rsp "Bitte Hetzner DNS API Token eingeben: " HETZNER_TOKEN
echo

if [[ -z "$HETZNER_TOKEN" ]]; then
  echo "Fehler: API Token darf nicht leer sein."
  exit 1
fi

echo "==> Schreibe Environment-Datei nach $CADDY_ENV_FILE..."
cat > "$CADDY_ENV_FILE" <<EOF
HETZNER_AUTH_API_TOKEN=$HETZNER_TOKEN
EOF

chown root:caddy "$CADDY_ENV_FILE"
chmod 640 "$CADDY_ENV_FILE"

echo "==> Richte systemd Override ein..."
mkdir -p /etc/systemd/system/caddy.service.d

cat > /etc/systemd/system/caddy.service.d/override.conf <<EOF
[Service]
EnvironmentFile=$CADDY_ENV_FILE
EOF

echo "==> Lade systemd neu..."
systemctl daemon-reload

echo "==> Prüfe Caddy-Version und Plugin..."
"$CADDY_BIN" version
"$CADDY_BIN" list-modules | grep hetzner

echo "==> Starte Caddy..."
systemctl enable caddy
systemctl restart caddy

echo
echo "Fertig."
echo
echo "Beispiel für /etc/caddy/Caddyfile:"
cat <<'EOF'

example.com {
    reverse_proxy 127.0.0.1:3000

    tls {
        dns hetzner {env.HETZNER_AUTH_API_TOKEN}
        propagation_delay 30s
    }
}

EOF

echo "Konfiguration testen mit:"
echo "  sudo caddy validate --config /etc/caddy/Caddyfile"
echo
echo "Logs ansehen mit:"
echo "  sudo journalctl -u caddy -f"
