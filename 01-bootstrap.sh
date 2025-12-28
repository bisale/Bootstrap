#!/usr/bin/env bash
set -euo pipefail

USER_NAME="ugg7"

# >>> HIER DEIN GITHUB RAW BASIS-PFAD <<<
# Beispiel:
# REPO_RAW="https://raw.githubusercontent.com/meinname/debian-bootstrap/main"
REPO_RAW="https://raw.githubusercontent.com/OWNER/REPO/main"

SCRIPT2="02-install-update-script.sh"
SCRIPT3="03-setup.sh"

DEST_DIR="/root/bootstrap-scripts"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

echo "[1/5] apt vorbereiten"
apt-get update -y
apt-get install -y sudo curl ca-certificates

echo "[2/5] Benutzer ${USER_NAME}"
if id "${USER_NAME}" >/dev/null 2>&1; then
  echo " - Benutzer existiert bereits."
else
  useradd -m -s /bin/bash "${USER_NAME}"
  echo "Setze jetzt ein Passwort für ${USER_NAME}:"
  passwd "${USER_NAME}"
fi

echo "[3/5] ${USER_NAME} zur sudo-Gruppe hinzufügen"
usermod -aG sudo "${USER_NAME}"

echo
read -rp "Sollen Skript 2 und 3 jetzt von GitHub geladen werden? (y/N): " load_scripts
load_scripts="${load_scripts,,}"

if [[ "${load_scripts}" == "y" || "${load_scripts}" == "yes" ]]; then
  echo
  echo "[4/5] Lade Skripte nach ${DEST_DIR}"
  mkdir -p "${DEST_DIR}"

  for f in "${SCRIPT2}" "${SCRIPT3}"; do
    url="${REPO_RAW}/${f}"
    echo " - Lade ${url}"
    curl -fsSL "${url}" -o "${DEST_DIR}/${f}"
    chmod +x "${DEST_DIR}/${f}"
  done

  echo
  read -rp "Sollen Skript 2 und 3 jetzt ausgeführt werden? (y/N): " run_scripts
  run_scripts="${run_scripts,,}"

  if [[ "${run_scripts}" == "y" || "${run_scripts}" == "yes" ]]; then
    echo
    echo "[5/5] Starte Skript 2 (update.sh Installation)"
    bash "${DEST_DIR}/${SCRIPT2}"

    echo
    echo "[6/5] Starte Skript 3 (System-Setup)"
    bash "${DEST_DIR}/${SCRIPT3}"

    echo
    echo "Bootstrap vollständig abgeschlossen."
  else
    echo
    echo "Skripte wurden geladen, aber nicht ausgeführt."
    echo "Manuell starten mit:"
    echo "  bash ${DEST_DIR}/${SCRIPT2}"
    echo "  bash ${DEST_DIR}/${SCRIPT3}"
  fi
else
  echo
  echo "Skripte 2 und 3 wurden nicht geladen."
  echo "Du kannst sie später manuell laden."
fi

echo
echo "Skript 1 beendet."
