#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

yesno() {
  local prompt="$1"
  local def="${2:-n}"
  local ans

  if [[ "$def" == "y" ]]; then
    read -rp "${prompt} (Y/n): " ans
    ans="${ans,,}"
    [[ -z "$ans" ]] && ans="y"
  else
    read -rp "${prompt} (y/N): " ans
    ans="${ans,,}"
    [[ -z "$ans" ]] && ans="n"
  fi

  [[ "$ans" == "y" || "$ans" == "yes" || "$ans" == "j" || "$ans" == "ja" ]]
}

detect_next_debian_codename() {
  local current="$1"
  case "$current" in
    bullseye) echo "bookworm" ;;
    bookworm) echo "trixie" ;;
    trixie) echo "forky" ;;
    *) echo "" ;;
  esac
}

backup_apt_sources() {
  local backup_dir="$1"

  mkdir -p "$backup_dir"
  cp -a /etc/apt/sources.list "${backup_dir}/sources.list" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d "${backup_dir}/sources.list.d" 2>/dev/null || true
  cp -a /etc/apt/preferences "${backup_dir}/preferences" 2>/dev/null || true
  cp -a /etc/apt/preferences.d "${backup_dir}/preferences.d" 2>/dev/null || true
}

disable_existing_debian_sources() {
  local timestamp="$1"

  if [[ -f /etc/apt/sources.list ]]; then
    mv /etc/apt/sources.list "/etc/apt/sources.list.disabled-by-release-upgrade-${timestamp}"
    touch /etc/apt/sources.list
  fi

  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    if grep -Eqi 'deb\.debian\.org|security\.debian\.org|ftp\.[a-z0-9.-]*debian\.org|snapshot\.debian\.org' "$f"; then
      mv "$f" "${f}.disabled-by-release-upgrade-${timestamp}"
    fi
  done
  shopt -u nullglob
}

disable_third_party_sources() {
  local timestamp="$1"

  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    if ! grep -Eqi 'deb\.debian\.org|security\.debian\.org|ftp\.[a-z0-9.-]*debian\.org|snapshot\.debian\.org' "$f"; then
      mv "$f" "${f}.disabled-by-release-upgrade-${timestamp}"
      echo " - Deaktiviert: $f"
    fi
  done
  shopt -u nullglob
}

write_clean_debian_sources() {
  local target="$1"
  local file="/etc/apt/sources.list.d/debian-${target}.sources"

  cat > "$file" <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: ${target} ${target}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: ${target}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

  chmod 0644 "$file"
  echo " - Neue Debian-Quelle geschrieben: $file"
}

preflight_checks() {
  echo
  echo "[Preflight] Prüfe Systemzustand"

  echo " - dpkg --audit"
  dpkg --audit || true

  echo
  echo " - apt-mark showhold"
  apt-mark showhold || true

  echo
  echo " - Freier Speicher auf /"
  df -h /

  echo
  echo " - Aktuelle APT-Quellen"
  find /etc/apt -maxdepth 2 \( -name '*.list' -o -name '*.sources' \) -type f -print
}

echo "=== Debian Release-/Major-Upgrade ==="
echo "Dieses Skript ist für Debian-VMs/LXCs gedacht."
echo "Es ersetzt die Debian-Quellen nicht per blindem sed, sondern:"
echo "  1. sichert alle Quellen,"
echo "  2. deaktiviert bestehende Debian-Quellen,"
echo "  3. schreibt eine neue saubere Deb822-Quelle für das Zielrelease."
echo

. /etc/os-release

CURRENT_CODENAME="${VERSION_CODENAME:-}"
CURRENT_VERSION="${VERSION_ID:-unknown}"

if [[ -z "${CURRENT_CODENAME}" ]]; then
  echo "Konnte VERSION_CODENAME nicht ermitteln. Abbruch."
  exit 1
fi

echo "Aktuell erkannt: Debian ${CURRENT_VERSION} (${CURRENT_CODENAME})"
echo

if ! yesno "Soll ein Debian Release-/Major-Upgrade durchgeführt werden?" "n"; then
  echo "Abgebrochen. Für normale Updates nutze: update.sh"
  exit 0
fi

SUGGEST_TARGET="$(detect_next_debian_codename "${CURRENT_CODENAME}")"
if [[ -z "$SUGGEST_TARGET" ]]; then
  SUGGEST_TARGET="trixie"
fi

read -rp "Ziel-Codename? [${SUGGEST_TARGET}]: " TARGET_CODENAME
TARGET_CODENAME="${TARGET_CODENAME:-$SUGGEST_TARGET}"

if [[ "${TARGET_CODENAME}" == "${CURRENT_CODENAME}" ]]; then
  echo "Ziel ist identisch mit aktuellem Codename (${CURRENT_CODENAME}). Abbruch."
  exit 1
fi

echo
echo "Geplant: ${CURRENT_CODENAME} -> ${TARGET_CODENAME}"
echo "Wichtig: Vorher Snapshot/Backup der VM/LXC erstellen."
echo

if ! yesno "Snapshot/Backup ist vorhanden und Upgrade soll starten?" "n"; then
  echo "Abgebrochen."
  exit 0
fi

if yesno "Drittanbieter-Repos während des Upgrades deaktivieren? (empfohlen)" "y"; then
  DISABLE_3P=true
else
  DISABLE_3P=false
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/apt-backup-${timestamp}"

echo
echo "[1/8] Backups der APT-Konfiguration nach ${BACKUP_DIR}"
backup_apt_sources "$BACKUP_DIR"
echo " - Backup OK."

preflight_checks

echo
echo "[2/8] Aktuelles System vollständig aktualisieren"
echo "Hinweis: apt fragt normal nach Bestätigung; kein automatisches -y."
apt-get update
apt-get upgrade
apt-get full-upgrade
apt-get autoremove --purge
apt-get autoclean

echo
echo "[3/8] Bestehende Debian-Quellen sicher deaktivieren"
disable_existing_debian_sources "$timestamp"

echo
echo "[4/8] Neue saubere Debian-Quellen für ${TARGET_CODENAME} schreiben"
write_clean_debian_sources "$TARGET_CODENAME"

echo
echo "[5/8] Optional Drittanbieter-Repos deaktivieren"
if [[ "${DISABLE_3P}" == "true" ]]; then
  disable_third_party_sources "$timestamp"
else
  echo " - Übersprungen."
fi

echo
echo "[6/8] apt update mit neuen Quellen"
apt-get update

echo
echo "[7/8] Release-/Major-Upgrade"
echo "Hinweis: apt fragt normal nach Bestätigung; kein automatisches -y."

echo " - Schritt A: apt-get upgrade"
apt-get upgrade

echo " - Schritt B: apt-get full-upgrade"
apt-get full-upgrade

echo
echo "[8/8] Cleanup"
apt-get autoremove --purge
apt-get autoclean

echo
echo "=== Fertig ==="
echo "Backup liegt hier: ${BACKUP_DIR}"
echo "Alte/deaktivierte Quellen liegen mit Endung:"
echo "  .disabled-by-release-upgrade-${timestamp}"
echo
echo "Empfohlen: Reboot."

read -rp "Jetzt rebooten? (y/N): " rb
rb="${rb,,}"
if [[ "${rb}" == "y" || "${rb}" == "yes" || "${rb}" == "j" || "${rb}" == "ja" ]]; then
  reboot
else
  echo "Bitte später manuell rebooten: reboot"
fi
