#!/usr/bin/env bash
set -euo pipefail

USER_NAME="ugg7"

# >>> HIER ANPASSEN: RAW Basis-URL deines Repos (Beispiel unten)
# REPO_RAW="https://raw.githubusercontent.com/<OWNER>/<REPO>/main"
REPO_RAW="https://raw.githubusercontent.com/OWNER/REPO/main"

# Welche Skripte sollen geladen werden?
# (Passe die Dateinamen an dein Repo an.)
SCRIPTS=(
  "02-setup.sh"
  "03-install-update-script.sh"
)

DEST_DIR="/root/bootstrap-scripts"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

echo "[1/4] apt update + benötigte Tools"
apt-get update -y
apt-get install -y sudo curl ca-certificates

echo "[2/4] Benutzer ${USER_NAME} anlegen (falls nicht vorhanden)"
if id "${USER_NAME}" >/dev/null 2>&1; then
  echo " - Benutzer existiert bereits."
else
  useradd -m -s /bin/bash "${USER_NAME}"
  echo " - Benutzer ${USER_NAME} wurde angelegt."
  echo "Setze jetzt ein Passwort für ${USER_NAME}:"
  passwd "${USER_NAME}"
fi

echo "[3/4] ${USER_NAME} zur sudo-Gruppe hinzufügen"
usermod -aG sudo "${USER_NAME}"
echo " - OK (Gruppe: sudo)"

echo "[4/4] Skripte von GitHub herunterladen nach ${DEST_DIR}"
mkdir -p "${DEST_DIR}"

for f in "${SCRIPTS[@]}"; do
  url="${REPO_RAW}/${f}"
  echo " - Lade: ${url}"
  curl -fsSL "${url}" -o "${DEST_DIR}/${f}"
  chmod +x "${DEST_DIR}/${f}"
done

echo
echo "Fertig."
echo "Geladene Skripte liegen hier:"
echo "  ${DEST_DIR}"
echo
echo "Beispiel ausführen:"
echo "  bash ${DEST_DIR}/02-setup.sh"
echo "  bash ${DEST_DIR}/03-install-update-script.sh"
