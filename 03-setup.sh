#!/usr/bin/env bash
set -euo pipefail

USER_NAME="ugg7"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

echo "[0/7] SSH-Key: erzeugen oder bereits vorhanden?"
echo " - Wenn du schon einen Public-Key hochgeladen hast: später ~/.ssh/authorized_keys prüfen."
read -rp "Soll für ${USER_NAME} ein SSH-Schlüssel erzeugt werden? (y/N): " genkey
genkey="${genkey,,}"

echo
echo "[1/7] System aktualisieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "[2/7] Basistools installieren: mc, vim, vnstat, tmux"
apt-get install -y mc vim vnstat tmux

echo "[3/7] Globale vim Einstellungen (für alle Nutzer)"
VIMRC_LOCAL="/etc/vim/vimrc.local"
touch "${VIMRC_LOCAL}"
grep -qE '^\s*syntax\s+on\s*$' "${VIMRC_LOCAL}" || echo "syntax on" >> "${VIMRC_LOCAL}"
grep -qE '^\s*set\s+mouse-=a\s*$' "${VIMRC_LOCAL}" || echo "set mouse-=a" >> "${VIMRC_LOCAL}"
echo " - OK: ${VIMRC_LOCAL}"

echo "[4/7] Globales bash alias für alle Nutzer: ll='ls -lha'"
ALIAS_FILE="/etc/profile.d/aliases.sh"
cat > "${ALIAS_FILE}" <<'EOF'
# Global aliases for all users
alias ll='ls -lha'
EOF
chmod 0644 "${ALIAS_FILE}"
echo " - OK: ${ALIAS_FILE}"

echo "[5/7] Systemweite tmux Konfiguration (/etc/tmux.conf)"
# tmux lädt standardmäßig /etc/tmux.conf (falls vorhanden) und dann ~/.tmux.conf. :contentReference[oaicite:4]{index=4}
TMUX_CONF="/etc/tmux.conf"
cat > "${TMUX_CONF}" <<'EOF'
# System-wide tmux config

set -g status on
set -g status-interval 5

set -g status-left-length 60
set -g status-left " #H | #([ -n \"$LOGNAME\" ] && echo \"$LOGNAME\" || whoami) "

setw -g window-status-format " #I:#W "
setw -g window-status-current-format " *#I:#W* "

set -g status-right-length 80
set -g status-right " %Y-%m-%d %H:%M "
EOF
chmod 0644 "${TMUX_CONF}"
echo " - OK: ${TMUX_CONF}"

echo "[6/7] SSH-Schlüssel Routine für ${USER_NAME}"
if ! id "${USER_NAME}" >/dev/null 2>&1; then
  echo "Benutzer ${USER_NAME} existiert nicht. Bitte zuerst Skript 1 ausführen."
  exit 1
fi

USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
SSH_DIR="${USER_HOME}/.ssh"
KEY_PATH="${SSH_DIR}/id_ed25519"

mkdir -p "${SSH_DIR}"
chown -R "${USER_NAME}:${USER_NAME}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [[ "${genkey}" == "y" || "${genkey}" == "yes" ]]; then
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    apt-get install -y openssh-client
  fi

  if [[ -f "${KEY_PATH}" ]]; then
    echo " - Key existiert bereits: ${KEY_PATH}"
  else
    echo " - Erzeuge ed25519 Key für ${USER_NAME} (ohne Passphrase)..."
    sudo -u "${USER_NAME}" ssh-keygen -t ed25519 -f "${KEY_PATH}" -N "" -C "${USER_NAME}@$(hostname)"
    chmod 600 "${KEY_PATH}"
    chmod 644 "${KEY_PATH}.pub"
    chown "${USER_NAME}:${USER_NAME}" "${KEY_PATH}" "${KEY_PATH}.pub"
  fi

  echo
  echo "Privater Schlüssel liegt hier:"
  echo "  ${KEY_PATH}"
  echo
  echo "Reminder: Public-Key auf Ziel/Server in ~/.ssh/authorized_keys eintragen."
else
  echo " - OK, kein Key erzeugt."
  echo "Wenn du bereits einen Key hochgeladen hast, stelle sicher:"
  echo "  - ${SSH_DIR}/authorized_keys existiert und gehört ${USER_NAME}:${USER_NAME}"
  echo "  - Rechte: ~/.ssh = 700, authorized_keys = 600"
fi

echo
echo "Teste JETZT bitte den SSH-Login (falls SSH genutzt wird)."
read -rp "ENTER drücken, sobald du getestet hast (oder STRG+C zum Abbrechen) ... " _

read -rp "Soll ich sshd_config automatisch für Key-only Login anpassen und ssh/sshd neu laden? (y/N): " harden
harden="${harden,,}"
if [[ "${harden}" == "y" || "${harden}" == "yes" ]]; then
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    echo "openssh-server ist nicht installiert. Installiere..."
    apt-get install -y openssh-server
  fi

  SSHD_CONFIG="/etc/ssh/sshd_config"
  cp -a "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

  set_sshd_option() {
    local key="$1" value="$2"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "${SSHD_CONFIG}"; then
      sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|g" "${SSHD_CONFIG}"
    else
      echo "${key} ${value}" >> "${SSHD_CONFIG}"
    fi
  }

  set_sshd_option "PubkeyAuthentication" "yes"
  set_sshd_option "PasswordAuthentication" "no"
  set_sshd_option "ChallengeResponseAuthentication" "no"

  echo " - sshd_config angepasst (Backup erstellt)."

  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh || systemctl reload sshd || systemctl restart ssh || systemctl restart sshd
  else
    service ssh reload || service ssh restart || true
  fi

  echo " - SSH/sshd neu geladen."
else
  echo "OK, keine automatische SSH-Härtung vorgenommen."
fi

# -------- Docker (sauber via Docker Repo) --------
echo
echo "[7/7] Optional: Docker (offizielles Docker Repository) installieren?"
read -rp "Soll Docker installiert werden? (y/N): " instdocker
instdocker="${instdocker,,}"

if [[ "${instdocker}" == "y" || "${instdocker}" == "yes" ]]; then
  echo " - Entferne ggf. konfliktierende/alte Docker-Pakete (falls vorhanden)..."
  apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true

  echo " - Installiere Voraussetzungen (ca-certificates, curl, keyrings dir)..."
  apt-get update -y
  apt-get install -y ca-certificates curl

  install -m 0755 -d /etc/apt/keyrings

  echo " - Docker GPG Key (ASCII) nach /etc/apt/keyrings/docker.asc"
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  echo " - Docker APT Repository einrichten"
  . /etc/os-release
  ARCH="$(dpkg --print-architecture)"
  CODENAME="${VERSION_CODENAME:-trixie}"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable
EOF

  echo " - Docker installieren: Engine + CLI + containerd + Buildx + Compose Plugin"
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo " - ${USER_NAME} optional zur docker-Gruppe hinzufügen (kein sudo für docker nötig)"
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "${USER_NAME}" || true
    echo "   Hinweis: wirksam nach neuem Login von ${USER_NAME}."
  fi

  echo " - Docker Service starten (falls systemd vorhanden)"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  else
    service docker start || true
  fi

  echo " - Test: docker version"
  docker version || true
else
  echo " - Docker Installation übersprungen."
fi

echo
echo "Fertig."
