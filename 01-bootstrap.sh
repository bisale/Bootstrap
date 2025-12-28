#!/usr/bin/env bash
set -euo pipefail

# Vorschlagsname
DEFAULT_USER="ugg7"

# >>> HIER DEIN GITHUB RAW BASIS-PFAD <<<
# Beispiel:
# REPO_RAW="https://raw.githubusercontent.com/meinname/debian-bootstrap/main"
REPO_RAW="https://raw.githubusercontent.com/bisale/Bootstrap/main"

SCRIPT2="02-install-update-script.sh"
SCRIPT3="03-setup.sh"
DEST_DIR="/root/bootstrap-scripts"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

echo "[1/6] System vorbereiten"
apt-get update -y
apt-get install -y sudo curl ca-certificates

echo
read -rp "Soll ein neuer Benutzer angelegt werden? (y/N): " create_user
create_user="${create_user,,}"

USER_NAME=""

if [[ "${create_user}" == "y" || "${create_user}" == "yes" ]]; then
  read -rp "Benutzername [${DEFAULT_USER}]: " USER_NAME
  USER_NAME="${USER_NAME:-$DEFAULT_USER}"

  if id "${USER_NAME}" >/dev/null 2>&1; then
    echo " - Benutzer ${USER_NAME} existiert bereits."
  else
    useradd -m -s /bin/bash "${USER_NAME}"
    echo "Setze jetzt ein Passwort für ${USER_NAME}:"
    passwd "${USER_NAME}"
    echo " - Benutzer ${USER_NAME} wurde angelegt."
  fi

  read -rp "Soll ${USER_NAME} zur sudo-Gruppe hinzugefügt werden? (y/N): " make_sudo
  make_sudo="${make_sudo,,}"

  if [[ "${make_sudo}" == "y" || "${make_sudo}" == "yes" ]]; then
    usermod -aG sudo "${USER_NAME}"
    echo " - ${USER_NAME} hat jetzt sudo-Rechte."
  else
    echo " - ${USER_NAME} bleibt ohne sudo."
  fi
else
  echo "Kein Benutzer wird angelegt."
fi

echo
read -rp "Sollen Skript 2 und 3 von GitHub geladen werden? (y/N): " load_scripts
load_scripts="${load_scripts,,}"

if [[ "${load_scripts}" == "y" || "${load_scripts}" == "yes" ]]; then
  echo
  echo "[2/6] Lade Skripte nach ${DEST_DIR}"
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
    echo "[3/6] Starte Skript 2"
    bash "${DEST_DIR}/${SCRIPT2}"

    echo
    echo "[4/6] Starte Skript 3"
    bash "${DEST_DIR}/${SCRIPT3}"

    echo
    echo "Bootstrap vollständig abgeschlossen."
  else
    echo
    echo "Skripte wurden nur heruntergeladen."
    echo "Manuell starten mit:"
    echo "  bash ${DEST_DIR}/${SCRIPT2}"
    echo "  bash ${DEST_DIR}/${SCRIPT3}"
  fi
else
  echo "Skripte 2 und 3 wurden nicht geladen."
fi

echo
echo "Skript 1 beendet."
