#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

TARGET="/usr/local/bin/update.sh"

cat > "${TARGET}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Immer mit sudo/root laufen (fragt ggf. nach Passwort)
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Dieses Skript benötigt sudo/root."
  sudo -v
  exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

echo "[update.sh] apt update"
apt-get update -y

echo "[update.sh] apt upgrade"
apt-get upgrade -y

echo "[update.sh] autoremove --purge"
apt-get autoremove -y --purge

echo "[update.sh] autoclean"
apt-get autoclean -y

echo "[update.sh] Fertig."
EOF

chmod 0755 "${TARGET}"
chown root:root "${TARGET}"

echo "Installiert: ${TARGET}"
echo "Benutzung: update.sh"
