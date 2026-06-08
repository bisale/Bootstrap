#!/usr/bin/env bash

set -euo pipefail

CADDY_ENV_FILE="/etc/caddy/hetzner.env"
CADDY_BIN="/usr/bin/caddy"
CADDY_BACKUP="/usr/bin/caddy.stock"

# Version-Pinning für reproduzierbarere Builds.
# Hetzner DNS Plugin v2.0.1 verlangt Caddy v2.11.2.
XCADDY_VERSION="v0.4.4"
CADDY_VERSION="v2.11.2"
HETZNER_PLUGIN_VERSION="v2.0.1"
PLUGIN="github.com/caddy-dns/hetzner/v2@${HETZNER_PLUGIN_VERSION}"

# Aktuelle stabile Go-Version von go.dev/dl.
# Wichtig: Das Hetzner Plugin v2.0.1 nutzt go 1.25.0 in go.mod,
# Debian/Ubuntu-Paket "golang" kann dafür zu alt sein.
GO_VERSION="1.26.4"
GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://go.dev/dl/${GO_TARBALL}"

CADDY_GPG_URL="https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
CADDY_REPO_URL="https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"
CADDY_KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
CADDY_EXPECTED_FPR="65760C51EDEA2017CEA2CA15155B6D79CA56EA34"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen, z. B.: sudo $0"
  exit 1
fi

BUILD_DIR=""

cleanup() {
  if [[ -n "${BUILD_DIR}" && -d "${BUILD_DIR}" ]]; then
    rm -rf "${BUILD_DIR}"
  fi
}

trap cleanup EXIT

normalize_fpr() {
  tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

verify_gpg_fingerprint() {
  local key_file="$1"
  local expected="$2"
  local actual=""

  actual="$(gpg --show-keys --with-colons --fingerprint "$key_file" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print $10; exit}' \
    | normalize_fpr)"

  expected="$(printf '%s' "$expected" | normalize_fpr)"

  if [[ -z "$actual" ]]; then
    echo "Fehler: Fingerprint konnte nicht aus ${key_file} gelesen werden."
    return 1
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "Fehler: GPG-Key-Fingerprint stimmt nicht."
    echo "Erwartet: $expected"
    echo "Gefunden : $actual"
    return 1
  fi

  echo " - Fingerprint OK: $actual"
}

install_go_from_official_tarball() {
  echo "==> Installiere Go ${GO_VERSION} aus offiziellem Tarball..."

  local tmp_go
  tmp_go="$(mktemp)"

  curl -fsSL --proto '=https' --tlsv1.2 "${GO_URL}" -o "$tmp_go"

  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$tmp_go"
  rm -f "$tmp_go"

  export PATH="/usr/local/go/bin:${PATH}"

  if ! command -v go >/dev/null 2>&1; then
    echo "Fehler: Go wurde nicht gefunden."
    exit 1
  fi

  echo " - $(go version)"
}

echo "==> Installiere Grundpakete..."
apt-get update
apt-get install -y \
  debian-keyring \
  debian-archive-keyring \
  apt-transport-https \
  ca-certificates \
  curl \
  gpg \
  git \
  tar

install_go_from_official_tarball

echo "==> Richte offizielles Caddy APT-Repository ein..."
TMP_CADDY_KEY="$(mktemp)"

curl -1sLf --proto '=https' --tlsv1.2 "${CADDY_GPG_URL}" -o "${TMP_CADDY_KEY}"

echo "==> Prüfe Caddy/Cloudsmith GPG-Key-Fingerprint..."
verify_gpg_fingerprint "${TMP_CADDY_KEY}" "${CADDY_EXPECTED_FPR}"

gpg --dearmor -o "${CADDY_KEYRING}.tmp" "${TMP_CADDY_KEY}"
mv "${CADDY_KEYRING}.tmp" "${CADDY_KEYRING}"
rm -f "${TMP_CADDY_KEY}"

curl -1sLf --proto '=https' --tlsv1.2 "${CADDY_REPO_URL}" > /etc/apt/sources.list.d/caddy-stable.list

chmod 0644 "${CADDY_KEYRING}"
chmod 0644 /etc/apt/sources.list.d/caddy-stable.list

echo "==> Installiere Caddy aus offiziellem Repository..."
apt-get update
apt-get install -y caddy

echo "==> Installiere xcaddy (${XCADDY_VERSION})..."
export GOPATH="${GOPATH:-/root/go}"
export PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"

go install "github.com/caddyserver/xcaddy/cmd/xcaddy@${XCADDY_VERSION}"

if ! command -v xcaddy >/dev/null 2>&1; then
  echo "xcaddy wurde nicht gefunden. Erwarteter Pfad: ${GOPATH}/bin/xcaddy"
  exit 1
fi

echo "==> Baue Caddy ${CADDY_VERSION} mit Hetzner DNS Plugin ${HETZNER_PLUGIN_VERSION}..."
BUILD_DIR="$(mktemp -d)"
cd "$BUILD_DIR"

xcaddy build "${CADDY_VERSION}" --with "${PLUGIN}"

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
chmod 0755 "$CADDY_BIN"

echo "==> Prüfe Hetzner-Modul..."
if ! "$CADDY_BIN" list-modules | grep -q '^dns.providers.hetzner$'; then
  echo "Fehler: Hetzner DNS Plugin wurde nicht gefunden."
  "$CADDY_BIN" list-modules | grep hetzner || true
  exit 1
fi

echo
echo "==> Hetzner DNS API Token"
echo "Sicherheitshinweis:"
echo "Lege den Token bei Hetzner mit möglichst wenig Rechten und nur für die benötigte DNS-Zone an."
echo "Der Token wird lokal in ${CADDY_ENV_FILE} gespeichert und ist für root sowie die Gruppe caddy lesbar."

read -rsp "Bitte Hetzner DNS API Token eingeben: " HETZNER_TOKEN
echo

if [[ -z "$HETZNER_TOKEN" ]]; then
  echo "Fehler: API Token darf nicht leer sein."
  exit 1
fi

if [[ -f "$CADDY_ENV_FILE" ]]; then
  cp -a "$CADDY_ENV_FILE" "${CADDY_ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
fi

echo "==> Schreibe Environment-Datei nach ${CADDY_ENV_FILE}..."
install -d -m 0750 -o root -g caddy /etc/caddy

umask 027
cat > "$CADDY_ENV_FILE" <<EOF
HETZNER_AUTH_API_TOKEN=${HETZNER_TOKEN}
EOF

chown root:caddy "$CADDY_ENV_FILE"
chmod 0640 "$CADDY_ENV_FILE"
unset HETZNER_TOKEN

echo "==> Richte systemd Override ein..."
mkdir -p /etc/systemd/system/caddy.service.d

cat > /etc/systemd/system/caddy.service.d/override.conf <<EOF
[Service]
EnvironmentFile=${CADDY_ENV_FILE}
EOF

chmod 0644 /etc/systemd/system/caddy.service.d/override.conf

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
