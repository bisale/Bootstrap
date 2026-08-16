#!/usr/bin/env bash
set -euo pipefail

AUTO_YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Dieses Skript benötigt sudo/root."
  sudo -v
  exec sudo -E bash "$0" "$@"
fi

LOG_FILE="/var/log/update.sh.log"
mkdir -p "$(dirname "${LOG_FILE}")"
# Terminal bekommt die Ausgabe inkl. Farbcodes, im Logfile werden sie rausgefiltert.
exec > >(tee >(sed -u -r 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}")) 2>&1

echo
echo "===== $(date '+%Y-%m-%d %H:%M:%S') update.sh gestartet ====="
[[ "${AUTO_YES}" == "true" ]] && echo "[update.sh] Nicht-interaktiver Modus (--yes): Prompts werden automatisch mit Standardwert beantwortet."

yesno() {
  local prompt="$1"
  local def="${2:-y}"
  local ans

  if [[ "${AUTO_YES}" == "true" ]]; then
    echo "${prompt} -> automatisch: ${def}"
    [[ "$def" == "y" ]]
    return
  fi

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

is_proxmox_host() {
  [[ -d /etc/pve ]] && command -v pveversion >/dev/null 2>&1
}

ensure_pve_no_subscription() {
  local codename
  # shellcheck disable=SC1091
  . /etc/os-release
  codename="${VERSION_CODENAME:-}"

  if [[ -z "${codename}" ]]; then
    echo "[update.sh] Konnte Debian-Codename nicht ermitteln, überspringe PVE-Repo-Check."
    return 0
  fi

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local changed=false

  for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
    if [[ -f "${f}" ]] && grep -qE '^\s*deb\s' "${f}"; then
      echo "[update.sh] Deaktiviere Enterprise-Repo: ${f}"
      cp -a "${f}" "${f}.bak.${ts}"
      sed -i -E 's/^([[:space:]]*deb[[:space:]])/#\1/' "${f}"
      changed=true
    fi
  done

  local nosub_file="/etc/apt/sources.list.d/pve-no-subscription.list"
  local nosub_line="deb http://download.proxmox.com/debian/pve ${codename} pve-no-subscription"

  if [[ ! -f "${nosub_file}" ]] || ! grep -qF "pve-no-subscription" "${nosub_file}"; then
    echo "[update.sh] Richte pve-no-subscription Repo ein: ${nosub_file}"
    echo "${nosub_line}" > "${nosub_file}"
    chmod 0644 "${nosub_file}"
    changed=true
  fi

  if [[ "${changed}" == "true" ]]; then
    echo "[update.sh] PVE-Repos auf no-subscription umgestellt (private Nutzung ohne Support-Abo)."
  else
    echo "[update.sh] PVE no-subscription Repo bereits korrekt konfiguriert."
  fi
}

current_debian_codename() {
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "${VERSION_CODENAME:-}"
}

check_new_debian_release() {
  local current next
  current="$(current_debian_codename)"
  [[ -z "${current}" ]] && return 1

  next="$(curl -fsSL --proto '=https' --tlsv1.2 https://deb.debian.org/debian/dists/stable/Release 2>/dev/null \
    | awk -F': ' '/^Codename:/{print $2; exit}')"

  [[ -z "${next}" ]] && return 1
  [[ "${next}" == "${current}" ]] && return 1

  printf '%s' "${next}"
  return 0
}

check_reboot_required() {
  if [[ -f /var/run/reboot-required ]]; then
    return 0
  fi

  local newest_kernel running_kernel
  newest_kernel="$(dpkg -l 'linux-image-*' 2>/dev/null \
    | awk '/^ii/{print $2}' \
    | sed -E 's/^linux-image-//' \
    | grep -E '^[0-9]' \
    | sort -V | tail -n1)"
  running_kernel="$(uname -r)"

  if [[ -n "${newest_kernel}" && "${newest_kernel}" != "${running_kernel}" ]]; then
    return 0
  fi

  return 1
}

echo "=============================="
echo " update.sh"
echo "=============================="
echo

IS_PVE=false
if is_proxmox_host; then
  IS_PVE=true
  echo
  echo "[update.sh] Proxmox-Host erkannt: $(pveversion 2>/dev/null | head -n1)"
  ensure_pve_no_subscription
fi

echo
echo "[update.sh] Prüfe auf verfügbares Debian Release-Upgrade"

if NEXT_RELEASE="$(check_new_debian_release)"; then
  echo "[update.sh] Neues Debian-Release verfügbar: ${NEXT_RELEASE} (aktuell: $(current_debian_codename))"

  if [[ "${IS_PVE}" == "true" ]]; then
    echo
    echo "[update.sh] ⚠ Proxmox-Host: Ein neues Major-Release (${NEXT_RELEASE}) ist verfügbar."
    echo "[update.sh] Proxmox-Major-Upgrades werden von diesem Skript bewusst NICHT automatisch durchgeführt."
    echo "[update.sh] Empfohlene Schritte:"
    echo "  1. Vollständiges Backup/Snapshot des Proxmox-Hosts UND aller VMs/LXCs erstellen."
    echo "  2. Offizielle Proxmox-Upgrade-Anleitung im Wiki lesen (pve.proxmox.com/wiki, Suche: 'Upgrade from <aktuelle> to <neue> PVE-Version')."
    echo "  3. Den von Proxmox bereitgestellten Kompatibilitäts-Checker für den Versionssprung ausführen, falls verfügbar."
    echo "  4. Bei Cluster-Betrieb: alle Nodes koordiniert und nacheinander upgraden, nicht parallel."
    echo "  5. Erst danach die Debian-Quellen wechseln und apt full-upgrade gemäß Anleitung durchführen."
  elif yesno "Soll jetzt das Release-Upgrade auf ${NEXT_RELEASE} gestartet werden (statt des normalen Updates)?" "n"; then
    if [[ -x /usr/local/bin/release-upgrade.sh ]]; then
      echo "[update.sh] Starte release-upgrade.sh ..."
      exec /usr/local/bin/release-upgrade.sh
    else
      echo "[update.sh] /usr/local/bin/release-upgrade.sh nicht gefunden. Bitte zuerst 02-install-update-script.sh ausführen."
    fi
  fi
else
  echo "[update.sh] Kein neueres Debian-Release verfügbar oder Codename nicht ermittelbar."
fi

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
echo "[update.sh] Prüfe ob Reboot erforderlich ist"

BOLD_RED="\033[1;31m"
BOLD_GREEN="\033[1;32m"
COLOR_RESET="\033[0m"

if check_reboot_required; then
  echo -e "[update.sh] ${BOLD_RED}⚠ REBOOT ERFORDERLICH (z.B. neuer Kernel installiert, aktiv: $(uname -r))${COLOR_RESET}"
else
  echo -e "[update.sh] ${BOLD_GREEN}Kein Reboot erforderlich.${COLOR_RESET}"
fi

echo
echo "[update.sh] Fertig."
echo "===== $(date '+%Y-%m-%d %H:%M:%S') update.sh beendet ====="
