#!/usr/bin/env bash
set -euo pipefail

# Vorschlagsname
DEFAULT_USER="ugg7"

# GitHub RAW Basis-Pfad
REPO_RAW="https://raw.githubusercontent.com/bisale/Bootstrap/main"

SCRIPT2="02-install-update-script.sh"
SCRIPT3="03-setup.sh"
DEST_DIR="/root/bootstrap-scripts"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

yesno() {
  # usage: yesno "Frage" "default" (default y|n)
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

echo "[1/7] System vorbereiten"
apt-get update -y
apt-get install -y sudo curl ca-certificates

# =========================================================
# Proxmox/KVM/QEMU Check -> qemu-guest-agent (optional)
# =========================================================
echo
echo "[2/7] Proxmox/KVM/QEMU-Check (qemu-guest-agent)"

VIRT="unknown"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT="$(systemd-detect-virt 2>/dev/null || true)"
fi

# In Proxmox-VMs ist es meistens kvm oder qemu.
# In Containern (LXC/Docker) macht qemu-guest-agent keinen Sinn -> überspringen.
if [[ "$VIRT" == "kvm" || "$VIRT" == "qemu" ]]; then
  echo "Virtualisierung erkannt: $VIRT (typisch für Proxmox/QEMU/KVM-VMs)."
  if yesno "Soll qemu-guest-agent installiert werden?" "y"; then
    apt-get update -y
    apt-get install -y qemu-guest-agent

    # Falls systemd vorhanden, Agent aktivieren/starten
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now qemu-guest-agent 2>/dev/null || true
    fi

    echo " - qemu-guest-agent installiert."
  else
    echo " - qemu-guest-agent übersprungen."
  fi
elif [[ "$VIRT" == "lxc" || "$VIRT" == "docker" || "$VIRT" == "container" ]]; then
  echo "Container erkannt ($VIRT) -> qemu-guest-agent wird nicht angeboten."
else
  echo "Keine eindeutige VM-Erkennung (VIRT='$VIRT')."
  if yesno "Läuft das System auf Proxmox/QEMU/KVM und soll qemu-guest-agent installiert werden?" "n"; then
    apt-get update -y
    apt-get install -y qemu-guest-agent
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now qemu-guest-agent 2>/dev/null || true
    fi
    echo " - qemu-guest-agent installiert."
  else
    echo " - qemu-guest-agent übersprungen."
  fi
fi
# =========================================================

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
  echo "[6/7] Lade Skripte nach ${DEST_DIR}"
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
