#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Bitte als root ausführen."
  exit 1
fi

UPDATE_TARGET="/usr/local/bin/update.sh"
RELEASE_TARGET="/usr/local/bin/release-upgrade.sh"
LOCAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_RELEASE_SCRIPT="${LOCAL_SCRIPT_DIR}/04-debian-release-upgrade.sh"
REMOTE_RELEASE_SCRIPT="https://raw.githubusercontent.com/bisale/Bootstrap/main/04-debian-release-upgrade.sh"

cat > "${UPDATE_TARGET}" <<'UPDATE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Dieses Skript benötigt sudo/root."
  sudo -v
  exec sudo -E bash "$0" "$@"
fi

yesno() {
  local prompt="$1"
  local def="${2:-y}"
  local ans

  if [[ "$def" == "y" ]]; then
    read -rp "${prompt} (J/n): " ans
    ans="${ans,,}"
    [[ -z "$ans" ]] && ans="j"
  else
    read -rp "${prompt} (j/N): " ans
    ans="${ans,,}"
    [[ -z "$ans" ]] && ans="n"
  fi

  [[ "$ans" == "j" || "$ans" == "ja" || "$ans" == "y" || "$ans" == "yes" ]]
}

docker_installed() {
  command -v docker >/dev/null 2>&1
}

docker_compose_available() {
  docker compose version >/dev/null 2>&1
}

find_compose_dirs() {
  find /opt /srv /root /home \
    \( -name compose.yml -o -name compose.yaml -o -name docker-compose.yml -o -name docker-compose.yaml \) \
    -type f 2>/dev/null \
    -printf '%h\n' \
    | sort -u
}

update_compose_containers() {
  if ! docker_installed; then
    echo "[update.sh] Docker ist nicht installiert. Container-Update wird übersprungen."
    return 0
  fi

  if ! docker_compose_available; then
    echo "[update.sh] docker compose ist nicht verfügbar. Container-Update wird übersprungen."
    return 0
  fi

  echo "[update.sh] Suche Docker-Compose-Projekte unter /opt, /srv, /root und /home"
  mapfile -t compose_dirs < <(find_compose_dirs)

  if [[ ${#compose_dirs[@]} -eq 0 ]]; then
    echo "[update.sh] Keine Compose-Projekte gefunden."
    return 0
  fi

  echo "[update.sh] Gefundene Compose-Projekte:"
  for dir in "${compose_dirs[@]}"; do
    echo " - ${dir}"
  done

  echo
  for dir in "${compose_dirs[@]}"; do
    echo "[update.sh] Aktualisiere Container in: ${dir}"
    (
      cd "${dir}"
      docker compose pull
      docker compose up -d --remove-orphans
    )
  done

  echo
  echo "[update.sh] Entferne ungenutzte Docker Images"
  docker image prune -f
}

echo "=============================="
echo " update.sh"
echo "=============================="
echo

UPDATE_DOCKER="false"
UPDATE_CONTAINERS="false"

if docker_installed; then
  if yesno "Soll Docker mit aktualisiert werden?" "y"; then
    UPDATE_DOCKER="true"
  fi

  if yesno "Sollen Docker-Container aktualisiert werden?" "y"; then
    UPDATE_CONTAINERS="true"
  fi
else
  echo "[update.sh] Docker wurde nicht gefunden."
  echo "[update.sh] Docker- und Container-Aktualisierung werden übersprungen."
fi

echo
echo "[update.sh] apt update"
apt-get update -y

echo
echo "[update.sh] Systempakete aktualisieren"
if [[ "${UPDATE_DOCKER}" == "true" ]]; then
  echo "[update.sh] Docker-Pakete werden mit aktualisiert."
  apt-get upgrade -y
else
  echo "[update.sh] Docker-Pakete werden vom Upgrade ausgenommen."

  docker_packages=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
  )

  packages_to_hold=()

  for pkg in "${docker_packages[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      packages_to_hold+=("$pkg")
    fi
  done

  if [[ ${#packages_to_hold[@]} -gt 0 ]]; then
    apt-mark hold "${packages_to_hold[@]}" >/dev/null
    apt-get upgrade -y
    apt-mark unhold "${packages_to_hold[@]}" >/dev/null
  else
    apt-get upgrade -y
  fi
fi

echo
echo "[update.sh] autoremove --purge"
apt-get autoremove -y --purge

echo
echo "[update.sh] autoclean"
apt-get autoclean -y

if [[ "${UPDATE_CONTAINERS}" == "true" ]]; then
  echo
  echo "[update.sh] Docker-Container aktualisieren"
  update_compose_containers
else
  echo
  echo "[update.sh] Docker-Container werden nicht aktualisiert."
fi

echo
echo "[update.sh] Fertig."
UPDATE_SCRIPT

chmod 0755 "${UPDATE_TARGET}"
chown root:root "${UPDATE_TARGET}"

echo "Installiert: ${UPDATE_TARGET}"
echo "Benutzung: update.sh"

echo
echo "Installiere Release-/Major-Upgrade-Skript nach ${RELEASE_TARGET}"

if [[ -f "${LOCAL_RELEASE_SCRIPT}" ]]; then
  cp "${LOCAL_RELEASE_SCRIPT}" "${RELEASE_TARGET}"
else
  echo "Lokales 04-debian-release-upgrade.sh nicht gefunden, lade aus GitHub..."
  if ! command -v curl >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl ca-certificates
  fi
  curl -fsSL --proto '=https' --tlsv1.2 "${REMOTE_RELEASE_SCRIPT}" -o "${RELEASE_TARGET}"
fi

chmod 0755 "${RELEASE_TARGET}"
chown root:root "${RELEASE_TARGET}"

if bash -n "${RELEASE_TARGET}"; then
  echo "Installiert: ${RELEASE_TARGET}"
  echo "Benutzung: release-upgrade.sh"
else
  echo "Fehler: ${RELEASE_TARGET} hat einen Syntaxfehler."
  exit 1
fi

  fi

  echo "[update.sh] Suche Docker-Compose-Projekte unter /opt, /srv, /root und /home"
  mapfile -t compose_dirs < <(find_compose_dirs)

  if [[ ${#compose_dirs[@]} -eq 0 ]]; then
    echo "[update.sh] Keine Compose-Projekte gefunden."
    return 0
  fi

  echo "[update.sh] Gefundene Compose-Projekte:"
  for dir in "${compose_dirs[@]}"; do
    echo " - ${dir}"
  done

  echo
  for dir in "${compose_dirs[@]}"; do
    echo "[update.sh] Aktualisiere Container in: ${dir}"
    (
      cd "${dir}"
      docker compose pull
      docker compose up -d --remove-orphans
    )
  done

  echo
  echo "[update.sh] Entferne ungenutzte Docker Images"
  docker image prune -f
}

echo "=============================="
echo " update.sh"
echo "=============================="
echo

UPDATE_DOCKER="false"
UPDATE_CONTAINERS="false"

if docker_installed; then
  if yesno "Soll Docker mit aktualisiert werden?" "y"; then
    UPDATE_DOCKER="true"
  fi

  if yesno "Sollen Docker-Container aktualisiert werden?" "y"; then
    UPDATE_CONTAINERS="true"
  fi
else
  echo "[update.sh] Docker wurde nicht gefunden."
  echo "[update.sh] Docker- und Container-Aktualisierung werden übersprungen."
fi

echo
echo "[update.sh] apt update"
apt-get update -y

echo
echo "[update.sh] Systempakete aktualisieren"
if [[ "${UPDATE_DOCKER}" == "true" ]]; then
  echo "[update.sh] Docker-Pakete werden mit aktualisiert."
  apt-get upgrade -y
else
  echo "[update.sh] Docker-Pakete werden vom Upgrade ausgenommen."

  docker_packages=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
  )

  packages_to_hold=()

  for pkg in "${docker_packages[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      packages_to_hold+=("$pkg")
    fi
  done

  if [[ ${#packages_to_hold[@]} -gt 0 ]]; then
    apt-mark hold "${packages_to_hold[@]}" >/dev/null
    apt-get upgrade -y
    apt-mark unhold "${packages_to_hold[@]}" >/dev/null
  else
    apt-get upgrade -y
  fi
fi

echo
echo "[update.sh] autoremove --purge"
apt-get autoremove -y --purge

echo
echo "[update.sh] autoclean"
apt-get autoclean -y

if [[ "${UPDATE_CONTAINERS}" == "true" ]]; then
  echo
  echo "[update.sh] Docker-Container aktualisieren"
  update_compose_containers
else
  echo
  echo "[update.sh] Docker-Container werden nicht aktualisiert."
fi

echo
echo "[update.sh] Fertig."
UPDATE_SCRIPT

chmod 0755 "${TARGET}"
chown root:root "${TARGET}"

echo "Installiert: ${TARGET}"
echo "Benutzung: update.sh"

    return 0
  fi

  echo "[update.sh] Suche Docker-Compose-Projekte unter /opt, /srv, /root und /home"

  mapfile -t compose_dirs < <(find_compose_dirs)

  if [[ ${#compose_dirs[@]} -eq 0 ]]; then
    echo "[update.sh] Keine Compose-Projekte gefunden."
    return 0
  fi

  echo "[update.sh] Gefundene Compose-Projekte:"
  for dir in "${compose_dirs[@]}"; do
    echo " - ${dir}"
  done

  echo
  for dir in "${compose_dirs[@]}"; do
    echo "[update.sh] Aktualisiere Container in: ${dir}"
    (
      cd "${dir}"
      docker compose pull
      docker compose up -d --remove-orphans
    )
  done

  echo
  echo "[update.sh] Entferne ungenutzte Docker Images"
  docker image prune -f
}

echo "=============================="
echo " update.sh"
echo "=============================="
echo

UPDATE_DOCKER="false"
UPDATE_CONTAINERS="false"

if docker_installed; then
  if yesno "Soll Docker mit aktualisiert werden?" "y"; then
    UPDATE_DOCKER="true"
  fi

  if yesno "Sollen Docker-Container aktualisiert werden?" "y"; then
    UPDATE_CONTAINERS="true"
  fi
else
  echo "[update.sh] Docker wurde nicht gefunden."
  echo "[update.sh] Docker- und Container-Aktualisierung werden übersprungen."
fi

echo
echo "[update.sh] apt update"
apt-get update

echo
echo "[update.sh] Systempakete aktualisieren"
if [[ "${UPDATE_DOCKER}" == "true" ]]; then
  echo "[update.sh] Docker-Pakete werden mit aktualisiert."
  apt-get upgrade
else
  echo "[update.sh] Docker-Pakete werden vom Upgrade ausgenommen."

  docker_packages=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
  )

  packages_to_hold=()

  for pkg in "${docker_packages[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      packages_to_hold+=("$pkg")
    fi
  done

  if [[ ${#packages_to_hold[@]} -gt 0 ]]; then
    apt-mark hold "${packages_to_hold[@]}" >/dev/null
    apt-get upgrade
    apt-mark unhold "${packages_to_hold[@]}" >/dev/null
  else
    apt-get upgrade
  fi
fi

echo
echo "[update.sh] autoremove --purge"
apt-get autoremove --purge

echo
echo "[update.sh] autoclean"
apt-get autoclean

if [[ "${UPDATE_CONTAINERS}" == "true" ]]; then
  echo
  echo "[update.sh] Docker-Container aktualisieren"
  update_compose_containers
else
  echo
  echo "[update.sh] Docker-Container werden nicht aktualisiert."
fi

echo
echo "[update.sh] Fertig."
UPDATE_SCRIPT

chmod 0755 "${TARGET}"
chown root:root "${TARGET}"

echo "Installiert: ${TARGET}"
echo "Benutzung: update.sh"
