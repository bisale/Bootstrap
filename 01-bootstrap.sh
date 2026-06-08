#!/usr/bin/env bash
set -euo pipefail

# Vorschlagsname
DEFAULT_USER="ugg7"

# GitHub RAW Basis-Pfad.
# Sicherheitshinweis:
# Für produktive Systeme ist ein festes Release-Tag oder ein Commit-Hash sicherer als "main".
REPO_RAW="https://raw.githubusercontent.com/bisale/Bootstrap/main"

SCRIPT2="02-install-update-script.sh"
SCRIPT3="03-setup.sh"
DEST_DIR="/root/bootstrap-scripts"

if [[ $EUID -ne 0 ]]; then
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

  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

download_file() {
  local url="$1"
  local dest="$2"

  echo " - Lade ${url}"
  curl -fsSL --proto '=https' --tlsv1.2 "${url}" -o "${dest}"
}

start_qemu_guest_agent() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo " - systemctl nicht vorhanden, qemu-guest-agent wurde nur installiert."
    return 0
  fi

  if systemctl list-unit-files qemu-guest-agent.service >/dev/null 2>&1; then
    echo " - Starte qemu-guest-agent.service"
    systemctl start qemu-guest-agent.service || true
  else
    echo " - qemu-guest-agent.service wurde nicht als systemd Unit gefunden."
  fi
}

echo "[1/7] System vorbereiten"
apt-get update -y
apt-get install -y sudo curl ca-certificates coreutils

# =========================================================
# Proxmox / KVM / QEMU Detection → qemu-guest-agent
# =========================================================
echo
echo "[2/7] Proxmox/KVM/QEMU-Check (qemu-guest-agent)"

VIRT="unknown"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT="$(systemd-detect-virt 2>/dev/null || true)"
fi

if [[ "$VIRT" == "kvm" || "$VIRT" == "qemu" ]]; then
  echo "Virtualisierung erkannt: $VIRT (typisch für Proxmox/QEMU/KVM)."
  if yesno "Soll qemu-guest-agent installiert werden?" "y"; then
    apt-get install -y qemu-guest-agent
    start_qemu_guest_agent
    echo " - qemu-guest-agent installiert/gestartet."
  else
    echo " - qemu-guest-agent übersprungen."
  fi
elif [[ "$VIRT" == "lxc" || "$VIRT" == "docker" || "$VIRT" == "container" ]]; then
  echo "Container erkannt ($VIRT) → qemu-guest-agent wird nicht angeboten."
else
  echo "Keine eindeutige Virtualisierung erkannt."
  if yesno "Läuft das System auf Proxmox/KVM und soll qemu-guest-agent installiert werden?" "n"; then
    apt-get install -y qemu-guest-agent
    start_qemu_guest_agent
    echo " - qemu-guest-agent installiert/gestartet."
  fi
fi

# =========================================================
# Benutzer
# =========================================================
echo
read -rp "Soll ein neuer Benutzer angelegt werden? (y/N): " create_user
create_user="${create_user,,}"

echo
echo "Hinweis zu SSH-Schlüsseln:"
echo "Du kannst auf diesem Gastsystem einen SSH-Schlüssel erzeugen"
echo "und den Public-Key dann auf dein Host-System oder andere Server übertragen."
echo
echo "Schlüssel erzeugen:"
echo "  ssh-keygen -t ed25519"
echo
echo "Public-Key anzeigen:"
echo "  cat /home/${DEFAULT_USER}/.ssh/id_ed25519.pub"
echo
echo "Key auf einen anderen Rechner kopieren:"
echo "  ssh-copy-id user@host"
echo

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

# =========================================================
# Skripte laden & ausführen
# =========================================================
echo
echo "Sicherheitshinweis:"
echo "Die folgenden Skripte werden aus ${REPO_RAW} geladen."
echo "Für produktive Systeme ist ein festes Release-Tag oder ein Commit-Hash sicherer als 'main'."
echo

read -rp "Sollen Skript 2 und 3 von GitHub geladen werden? (y/N): " load_scripts
load_scripts="${load_scripts,,}"

if [[ "${load_scripts}" == "y" || "${load_scripts}" == "yes" ]]; then
  echo
  echo "[6/7] Lade Skripte nach ${DEST_DIR}"
  mkdir -p "${DEST_DIR}"

  for f in "${SCRIPT2}" "${SCRIPT3}"; do
    download_file "${REPO_RAW}/${f}" "${DEST_DIR}/${f}"
    chmod 0755 "${DEST_DIR}/${f}"
  done

  echo
  read -rp "Sollen Skript 2 und 3 jetzt ausgeführt werden? (y/N): " run_scripts
  run_scripts="${run_scripts,,}"

  if [[ "${run_scripts}" == "y" || "${run_scripts}" == "yes" ]]; then
    echo
    echo "[7/7] Starte Skript 2"
    bash "${DEST_DIR}/${SCRIPT2}"

    echo
    echo "Starte Skript 3"
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
