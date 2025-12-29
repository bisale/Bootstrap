#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "=== Debian Release Upgrade ==="
echo "Dieses Skript passt APT-Quellen an und führt ein Release-Upgrade durch."
echo "Hinweis: Drittanbieter-Repos können Probleme machen. Prüfe /etc/apt/sources.list.d/"
echo

# Detect current codename
. /etc/os-release
CURRENT_CODENAME="${VERSION_CODENAME:-}"
CURRENT_VERSION="${VERSION_ID:-unknown}"
if [[ -z "${CURRENT_CODENAME}" ]]; then
  echo "Konnte VERSION_CODENAME nicht ermitteln. Abbruch."
  exit 1
fi

echo "Aktuell erkannt: Debian ${CURRENT_VERSION} (${CURRENT_CODENAME})"
echo

# Suggest target (common path 12->13)
SUGGEST_TARGET="trixie"
read -rp "Ziel-Codename? [${SUGGEST_TARGET}]: " TARGET_CODENAME
TARGET_CODENAME="${TARGET_CODENAME:-$SUGGEST_TARGET}"

if [[ "${TARGET_CODENAME}" == "${CURRENT_CODENAME}" ]]; then
  echo "Ziel ist identisch mit aktuellem Codename (${CURRENT_CODENAME}). Abbruch."
  exit 1
fi

echo
read -rp "Drittanbieter-Repos automatisch deaktivieren (empfohlen)? (Y/n): " disable3p
disable3p="${disable3p,,}"
if [[ -z "${disable3p}" || "${disable3p}" == "y" || "${disable3p}" == "yes" ]]; then
  DISABLE_3P=true
else
  DISABLE_3P=false
fi

echo
read -rp "Fortfahren mit Upgrade ${CURRENT_CODENAME} -> ${TARGET_CODENAME}? (y/N): " go
go="${go,,}"
if [[ "${go}" != "y" && "${go}" != "yes" ]]; then
  echo "Abgebrochen."
  exit 0
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/apt-backup-${timestamp}"
mkdir -p "${BACKUP_DIR}"

echo
echo "[1/7] Backups der APT-Quellen nach ${BACKUP_DIR}"
cp -a /etc/apt/sources.list "${BACKUP_DIR}/sources.list" 2>/dev/null || true
cp -a /etc/apt/sources.list.d "${BACKUP_DIR}/sources.list.d" 2>/dev/null || true
cp -a /etc/apt/preferences* "${BACKUP_DIR}/" 2>/dev/null || true
echo " - Backup OK."

echo
echo "[2/7] System auf aktuellen Stand bringen (vor dem Release-Upgrade)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get full-upgrade -y
apt-get autoremove -y --purge
apt-get autoclean -y

echo
echo "[3/7] Optional: Drittanbieter-Repos deaktivieren"
if [[ "${DISABLE_3P}" == "true" ]]; then
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.list; do
    # Heuristik: alles außer deb.debian.org / security.debian.org / ftp.debian.org / snapshot.debian.org deaktivieren
    if ! grep -Eq 'deb\.debian\.org|security\.debian\.org|ftp\.debian\.org|snapshot\.debian\.org' "$f"; then
      echo " - Deaktiviere: $f"
      sed -i 's/^[[:space:]]*deb /# deb /' "$f" || true
      sed -i 's/^[[:space:]]*deb-src /# deb-src /' "$f" || true
    fi
  done
  shopt -u nullglob
else
  echo " - Übersprungen."
fi

echo
echo "[4/7] Debian-Quellen: ${CURRENT_CODENAME} -> ${TARGET_CODENAME}"
# Tauscht Codename in sources.list und allen *.list Dateien
replace_codename_in_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  sed -i \
    -e "s/\b${CURRENT_CODENAME}\b/${TARGET_CODENAME}/g" \
    "$file"
}

replace_codename_in_file /etc/apt/sources.list
shopt -s nullglob
for f in /etc/apt/sources.list.d/*.list; do
  replace_codename_in_file "$f"
done
shopt -u nullglob

echo " - Quellen angepasst."

echo
echo "[5/7] apt update (neue Quellen)"
apt-get update -y

echo
echo "[6/7] Release-Upgrade (erst upgrade, dann full-upgrade)"
echo " - Schritt A: apt-get upgrade"
apt-get upgrade -y
echo " - Schritt B: apt-get full-upgrade"
apt-get full-upgrade -y

echo
echo "[7/7] Cleanup"
apt-get autoremove -y --purge
apt-get autoclean -y

echo
echo "=== Fertig ==="
echo "Backup liegt hier: ${BACKUP_DIR}"
echo "Empfohlen: Reboot."
read -rp "Jetzt rebooten? (y/N): " rb
rb="${rb,,}"
if [[ "${rb}" == "y" || "${rb}" == "yes" ]]; then
  reboot
else
  echo "Bitte später manuell rebooten: reboot"
fi
