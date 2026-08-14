#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

UPDATE_TARGET="/usr/local/bin/update.sh"
RELEASE_TARGET="/usr/local/bin/release-upgrade.sh"
LOCAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_UPDATE_SCRIPT="${LOCAL_SCRIPT_DIR}/update.sh"
REMOTE_UPDATE_SCRIPT="https://raw.githubusercontent.com/bisale/Bootstrap/main/update.sh"
LOCAL_RELEASE_SCRIPT="${LOCAL_SCRIPT_DIR}/04-debian-release-upgrade.sh"
REMOTE_RELEASE_SCRIPT="https://raw.githubusercontent.com/bisale/Bootstrap/main/04-debian-release-upgrade.sh"

install_script_from_local_or_remote() {
  local local_path="$1"
  local remote_url="$2"
  local target="$3"
  local label="$4"

  if [[ -f "${local_path}" ]]; then
    cp "${local_path}" "${target}"
  else
    echo "Lokales ${label} nicht gefunden, lade aus GitHub..."
    if ! command -v curl >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y curl ca-certificates
    fi
    curl -fsSL --proto '=https' --tlsv1.2 "${remote_url}" -o "${target}"
  fi

  chmod 0755 "${target}"
  chown root:root "${target}"

  if bash -n "${target}"; then
    echo "Installiert: ${target}"
  else
    echo "Fehler: ${target} hat einen Syntaxfehler."
    exit 1
  fi
}

echo "Installiere update.sh nach ${UPDATE_TARGET}"
install_script_from_local_or_remote "${LOCAL_UPDATE_SCRIPT}" "${REMOTE_UPDATE_SCRIPT}" "${UPDATE_TARGET}" "update.sh"
echo "Benutzung: update.sh"

echo
echo "Installiere Release-/Major-Upgrade-Skript nach ${RELEASE_TARGET}"
install_script_from_local_or_remote "${LOCAL_RELEASE_SCRIPT}" "${REMOTE_RELEASE_SCRIPT}" "${RELEASE_TARGET}" "04-debian-release-upgrade.sh"
echo "Benutzung: release-upgrade.sh"
