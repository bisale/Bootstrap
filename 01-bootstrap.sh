#!/usr/bin/env bash
set -euo pipefail

DEFAULT_USER="ugg7"
REPO_RAW="https://raw.githubusercontent.com/bisale/Bootstrap/main"
DEST_DIR="/root/bootstrap-scripts"

SCRIPT1="01-bootstrap.sh"
SCRIPT2="02-install-update-script.sh"
SCRIPT3="03-setup.sh"
SCRIPT4="04-debian-release-upgrade.sh"

QEMU_AGENT_NOTE=""

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

download_file() {
  local url="$1"
  local dest="$2"

  echo " - Lade ${url}"
  curl -fsSL --proto '=https' --tlsv1.2 "${url}" -o "${dest}"
}

enable_qemu_guest_agent_with_timeout() {
  local timeout_seconds=30
  local start_ts
  local now_ts

  if ! command -v systemctl >/dev/null 2>&1; then
    QEMU_AGENT_NOTE="systemctl ist nicht vorhanden. qemu-guest-agent wurde installiert, aber nicht per systemd aktiviert."
    echo " - ${QEMU_AGENT_NOTE}"
    return 0
  fi

  echo " - Versuche qemu-guest-agent per systemctl enable --now zu aktivieren."
  echo " - Timeout: ${timeout_seconds}s"

  start_ts="$(date +%s)"

  while true; do
    if systemctl enable --now qemu-guest-agent.service >/tmp/qemu-guest-agent-enable.log 2>&1; then
      echo " - qemu-guest-agent wurde aktiviert und gestartet."
      QEMU_AGENT_NOTE=""
      return 0
    fi

    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout_seconds )); then
      echo " - qemu-guest-agent konnte nach ${timeout_seconds}s nicht aktiviert werden. Schritt wird übersprungen."
      echo " - Letzte systemctl-Ausgabe:"
      sed 's/^/   /' /tmp/qemu-guest-agent-enable.log 2>/dev/null || true
      QEMU_AGENT_NOTE="qemu-guest-agent konnte nicht aktiviert werden. Bitte in Proxmox bei der VM den QEMU Guest Agent aktivieren und die VM danach vollständig herunterfahren/starten. Bei LXC ist qemu-guest-agent nicht nötig."
      return 0
    fi

    sleep 3
  done
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
    enable_qemu_guest_agent_with_timeout
  else
    echo " - qemu-guest-agent übersprungen."
  fi
elif [[ "$VIRT" == "lxc" || "$VIRT" == "docker" || "$VIRT" == "container" ]]; then
  echo "Container erkannt ($VIRT) → qemu-guest-agent wird nicht angeboten."
  QEMU_AGENT_NOTE="LXC/Container erkannt: qemu-guest-agent ist hier normalerweise nicht nötig. In Proxmox ist der QEMU Guest Agent nur für VMs relevant."
else
  echo "Keine eindeutige Virtualisierung erkannt."
  if yesno "Läuft das System auf Proxmox/KVM und soll qemu-guest-agent installiert werden?" "n"; then
    apt-get install -y qemu-guest-agent
    enable_qemu_guest_agent_with_timeout
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

if [[ "${create_user}" == "y" || "${create_user}" == "yes" || "${create_user}" == "j" || "${create_user}" == "ja" ]]; then
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
  if [[ "${make_sudo}" == "y" || "${make_sudo}" == "yes" || "${make_sudo}" == "j" || "${make_sudo}" == "ja" ]]; then
    usermod -aG sudo "${USER_NAME}"
    echo " - ${USER_NAME} hat jetzt sudo-Rechte."
  else
    echo " - ${USER_NAME} bleibt ohne sudo."
  fi
else
  echo "Kein Benutzer wird angelegt."
fi

# =========================================================
# Skripte 01-04 laden & optional ausführen
# =========================================================
echo
echo "Sicherheitshinweis:"
echo "Die folgenden Skripte werden aus ${REPO_RAW} geladen:"
echo " - ${SCRIPT1}"
echo " - ${SCRIPT2}"
echo " - ${SCRIPT3}"
echo " - ${SCRIPT4}"
echo "05-caddy.sh wird bewusst ignoriert."
echo "Für produktive Systeme ist ein festes Release-Tag oder ein Commit-Hash sicherer als 'main'."
echo

read -rp "Sollen Skript 1-4 von GitHub geladen werden? (y/N): " load_scripts
load_scripts="${load_scripts,,}"

if [[ "${load_scripts}" == "y" || "${load_scripts}" == "yes" || "${load_scripts}" == "j" || "${load_scripts}" == "ja" ]]; then
  echo
  echo "[6/7] Lade Skripte nach ${DEST_DIR}"
  mkdir -p "${DEST_DIR}"

  for f in "${SCRIPT1}" "${SCRIPT2}" "${SCRIPT3}" "${SCRIPT4}"; do
    download_file "${REPO_RAW}/${f}" "${DEST_DIR}/${f}"
    chmod 0755 "${DEST_DIR}/${f}"
  done

  echo
  echo "Syntaxprüfung:"
  for f in "${SCRIPT1}" "${SCRIPT2}" "${SCRIPT3}" "${SCRIPT4}"; do
    if bash -n "${DEST_DIR}/${f}"; then
      echo " - OK: ${f}"
    else
      echo " - FEHLER: ${f}"
      exit 1
    fi
  done

  echo
  read -rp "Sollen Skript 2 und 3 jetzt ausgeführt werden? (y/N): " run_scripts
  run_scripts="${run_scripts,,}"

  if [[ "${run_scripts}" == "y" || "${run_scripts}" == "yes" || "${run_scripts}" == "j" || "${run_scripts}" == "ja" ]]; then
    echo
    echo "[7/7] Starte Skript 2: Installation von /usr/local/bin/update.sh"
    bash "${DEST_DIR}/${SCRIPT2}"

    echo
    echo "Starte Skript 3: Basissetup"
    bash "${DEST_DIR}/${SCRIPT3}"

    echo
    echo "Bootstrap vollständig abgeschlossen."
  else
    echo
    echo "Skripte wurden nur heruntergeladen."
    echo "Manuell starten mit:"
    echo "  bash ${DEST_DIR}/${SCRIPT2}"
    echo "  bash ${DEST_DIR}/${SCRIPT3}"
    echo "  bash ${DEST_DIR}/${SCRIPT4}"
  fi
else
  echo "Skripte 1-4 wurden nicht geladen."
fi

echo
echo "Skript 1 beendet."

if [[ -n "${QEMU_AGENT_NOTE}" ]]; then
  echo
  echo "Hinweis qemu-guest-agent:"
  echo "  ${QEMU_AGENT_NOTE}"
fi

