#!/usr/bin/env bash
set -euo pipefail

USER_NAME="ugg7"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

echo "[1/6] System aktualisieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "[2/6] Pakete installieren: mc, vim, vnstat, screen"
apt-get install -y mc vim vnstat screen

echo "[3/6] Globale vim Einstellungen (für alle Nutzer)"
# Debian: /etc/vim/vimrc.local wird automatisch eingebunden, falls vorhanden.
VIMRC_LOCAL="/etc/vim/vimrc.local"
touch "${VIMRC_LOCAL}"

# Sicherstellen, dass die Zeilen genau einmal existieren
grep -qE '^\s*syntax\s+on\s*$' "${VIMRC_LOCAL}" || echo "syntax on" >> "${VIMRC_LOCAL}"
grep -qE '^\s*set\s+mouse-=a\s*$' "${VIMRC_LOCAL}" || echo "set mouse-=a" >> "${VIMRC_LOCAL}"

echo " - OK: ${VIMRC_LOCAL}"

echo "[4/6] Globales bash alias für alle Nutzer: ll='ls -lha'"
ALIAS_FILE="/etc/profile.d/aliases.sh"
cat > "${ALIAS_FILE}" <<'EOF'
# Global aliases for all users
alias ll='ls -lha'
EOF
chmod 0644 "${ALIAS_FILE}"
echo " - OK: ${ALIAS_FILE}"

echo "[5/6] Globales screen config setzen"
SCREENRC="/etc/screenrc"
CAPTION_LINE='screen -X caption always "%{rw} * | %H * $LOGNAME | %{bw}%c %D | %{-}%-Lw%{rw}%50>%{rW}%n%f* %t %{-}%+Lw%<"'

# In /etc/screenrc eintragen, falls noch nicht vorhanden
touch "${SCREENRC}"
if ! grep -Fq "${CAPTION_LINE}" "${SCREENRC}"; then
  echo "" >> "${SCREENRC}"
  echo "# Custom caption" >> "${SCREENRC}"
  echo "${CAPTION_LINE}" >> "${SCREENRC}"
fi
echo " - OK: ${SCREENRC}"

echo "[6/6] SSH Schlüssel für ${USER_NAME} erzeugen (falls nicht vorhanden)"
# openssh-client ist i.d.R. da; ssh-keygen kommt damit.
# Optional: Server installieren, falls sshd gewünscht ist.
if ! command -v ssh-keygen >/dev/null 2>&1; then
  apt-get install -y openssh-client
fi

if ! id "${USER_NAME}" >/dev/null 2>&1; then
  echo "Benutzer ${USER_NAME} existiert nicht. Bitte erst Skript 1 ausführen."
  exit 1
fi

USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
SSH_DIR="${USER_HOME}/.ssh"
KEY_PATH="${SSH_DIR}/id_ed25519"

mkdir -p "${SSH_DIR}"
chown -R "${USER_NAME}:${USER_NAME}" "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [[ -f "${KEY_PATH}" ]]; then
  echo " - Key existiert bereits: ${KEY_PATH}"
else
  echo " - Erzeuge ed25519 Key für ${USER_NAME}..."
  # Ohne Passphrase, damit später keine Passwortabfrage mehr nötig ist.
  sudo -u "${USER_NAME}" ssh-keygen -t ed25519 -f "${KEY_PATH}" -N "" -C "${USER_NAME}@$(hostname)"
  chmod 600 "${KEY_PATH}"
  chmod 644 "${KEY_PATH}.pub"
  chown "${USER_NAME}:${USER_NAME}" "${KEY_PATH}" "${KEY_PATH}.pub"
fi

echo
echo "Privater Schlüssel liegt hier:"
echo "  ${KEY_PATH}"
echo
echo "Nächster Schritt (Server-Seite): sshd so konfigurieren, dass Passwortlogin endet."
echo "Typisch in /etc/ssh/sshd_config:"
echo "  PubkeyAuthentication yes"
echo "  PasswordAuthentication no"
echo "  ChallengeResponseAuthentication no"
echo "  UsePAM no   (je nach Setup; in Debian oft besser: UsePAM yes lassen)"
echo
echo "Teste JETZT bitte den Login mit dem Schlüssel (z.B. von deinem Client aus)."
read -rp "Bestätige mit ENTER, sobald du getestet hast (oder abbrechen mit STRG+C) ... " _

read -rp "Soll ich sshd_config automatisch anpassen und SSH/sshd neu laden? (y/N): " ans
ans="${ans,,}"  # lowercase
if [[ "${ans}" == "y" || "${ans}" == "yes" ]]; then
  # sicherstellen, dass sshd vorhanden ist
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    echo "openssh-server ist nicht installiert. Installiere..."
    apt-get install -y openssh-server
  fi

  SSHD_CONFIG="/etc/ssh/sshd_config"
  cp -a "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

  # Setzen/Ersetzen (robust: vorhandene Zeilen ersetzen, sonst anhängen)
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
  echo "OK, keine automatische Anpassung vorgenommen."
fi

echo
echo "Fertig."
