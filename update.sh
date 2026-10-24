#!/usr/bin/env bash
# update.sh – interaktives System-/Docker-Update für Debian, Ubuntu und Proxmox
# (Hosts, VMs, LXCs). Fragt vor jeder größeren Änderung nach.
#
#   update.sh            interaktiv aktualisieren
#   update.sh --check    nur suchen und anzeigen, nichts verändern (außer apt update)
set -euo pipefail

CHECK_ONLY=false
WARNINGS=()
IS_PVE=false
UPDATE_DOCKER=false
UPDATE_CONTAINERS=false
HELD_BY_US=()

LOG_FILE="${LOG_FILE:-/var/log/update.sh.log}"
SOURCES_DIR="${SOURCES_DIR:-/etc/apt/sources.list.d}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/update.sh}"
BOOT_DIR="${BOOT_DIR:-/boot}"
CS_UPDATE_BIN="${CS_UPDATE_BIN:-/usr/bin/update}"

DOCKER_PKGS=(
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  docker-ce-rootless-extras docker.io docker-compose-v2
)

usage() {
  cat <<'EOF'
Benutzung: update.sh [--check]

  --check, -c   Nur suchen: Paket-Updates, Dist-Upgrade, Docker, Compose-Projekte,
                Reboot-Bedarf. Es wird nichts installiert oder neu gestartet.
  --help, -h    Diese Hilfe

Das Skript ist bewusst interaktiv und braucht ein Terminal (ssh -t).
Compose-Projekte mit einer Datei ".no-autoupdate" im Projektverzeichnis werden übersprungen.
EOF
}

say() { echo "[update.sh] $*"; }

warn() {
  echo "[update.sh] ⚠ $*"
  WARNINGS+=("$*")
}

yesno() {
  local prompt="$1" def="${2:-y}" ans hint
  if [[ "${def}" == "y" ]]; then hint="J/n"; else hint="j/N"; fi
  read -rp "${prompt} (${hint}): " ans || ans=""
  case "${ans:-${def}}" in
    [jJyY] | [jJ][aA] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

os_field() {
  ( # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${!1:-}"
  )
}

# ---------------------------------------------------------------- Proxmox ----

is_proxmox_host() {
  [[ -d /etc/pve ]] && command -v pveversion >/dev/null 2>&1
}

# Setzt Enabled: false in einer deb822-Datei, falls dort ein Enterprise-Repo aktiv ist.
disable_deb822_enterprise() {
  local f="$1" ts="$2" tmp
  grep -qE '^Components:.*enterprise' "${f}" || return 1
  grep -qE '^Enabled:[[:space:]]*([Ff]alse|[Nn]o)[[:space:]]*$' "${f}" && return 1

  say "Deaktiviere Enterprise-Repo: ${f}"
  cp -a "${f}" "${BACKUP_DIR}/$(basename "${f}").${ts}"
  tmp="$(mktemp)"
  if grep -qE '^Enabled:' "${f}"; then
    awk '/^Enabled:/ { print "Enabled: false"; next } { print }' "${f}" >"${tmp}"
  else
    awk '{ print } /^Components:.*enterprise/ { print "Enabled: false" }' "${f}" >"${tmp}"
  fi
  cat "${tmp}" >"${f}"
  rm -f "${tmp}"
  return 0
}

ensure_pve_no_subscription() {
  local codename ts changed=false f
  codename="$(os_field VERSION_CODENAME)"

  if [[ -z "${codename}" ]]; then
    say "Konnte Debian-Codename nicht ermitteln, überspringe PVE-Repo-Check."
    return 0
  fi

  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"

  # PVE 8 (bookworm): klassische .list-Dateien
  for f in "${SOURCES_DIR}/pve-enterprise.list" "${SOURCES_DIR}/ceph.list"; do
    if [[ -f "${f}" ]] && grep -qE '^[[:space:]]*deb[[:space:]]' "${f}"; then
      say "Deaktiviere Enterprise-Repo: ${f}"
      cp -a "${f}" "${BACKUP_DIR}/$(basename "${f}").${ts}"
      sed -i -E 's/^([[:space:]]*deb[[:space:]])/#\1/' "${f}"
      changed=true
    fi
  done

  # PVE 9 (trixie): deb822 .sources
  for f in "${SOURCES_DIR}/pve-enterprise.sources" "${SOURCES_DIR}/ceph.sources"; do
    if [[ -f "${f}" ]] && disable_deb822_enterprise "${f}" "${ts}"; then
      changed=true
    fi
  done

  # no-subscription: nur anlegen, wenn es nirgends (.list oder .sources) aktiv ist
  if grep -qsE '^[[:space:]]*(deb[[:space:]].*pve-no-subscription|Components:.*pve-no-subscription)' \
    "${SOURCES_DIR}"/*.list "${SOURCES_DIR}"/*.sources /etc/apt/sources.list 2>/dev/null; then
    say "PVE no-subscription Repo bereits konfiguriert."
  elif [[ "${codename}" == "bookworm" ]]; then
    say "Richte pve-no-subscription Repo ein: ${SOURCES_DIR}/pve-no-subscription.list"
    echo "deb http://download.proxmox.com/debian/pve ${codename} pve-no-subscription" \
      >"${SOURCES_DIR}/pve-no-subscription.list"
    chmod 0644 "${SOURCES_DIR}/pve-no-subscription.list"
    changed=true
  else
    say "Richte pve-no-subscription Repo ein: ${SOURCES_DIR}/pve-no-subscription.sources"
    cat >"${SOURCES_DIR}/pve-no-subscription.sources" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${codename}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    chmod 0644 "${SOURCES_DIR}/pve-no-subscription.sources"
    changed=true
  fi

  if [[ "${changed}" == "true" ]]; then
    say "PVE-Repos auf no-subscription umgestellt (private Nutzung ohne Support-Abo). Backups: ${BACKUP_DIR}"
  else
    say "PVE-Repos sind bereits korrekt konfiguriert."
  fi
}

# ------------------------------------------------------- Debian-Release ----

# Gibt den Codename des neuen Debian-Stable aus (Rückgabe 0), wenn er vom aktuellen abweicht.
check_new_debian_release() {
  local current next
  [[ "$(os_field ID)" == "debian" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  current="$(os_field VERSION_CODENAME)"
  [[ -n "${current}" ]] || return 1

  next="$(curl -fsSL --proto '=https' --tlsv1.2 https://deb.debian.org/debian/dists/stable/Release 2>/dev/null \
    | awk -F': ' '/^Codename:/{print $2; exit}')" || true

  [[ -n "${next}" && "${next}" != "${current}" ]] || return 1
  printf '%s' "${next}"
}

release_upgrade_step() {
  local next
  if ! next="$(check_new_debian_release)"; then
    say "Kein neueres Debian-Release gefunden (oder Prüfung nicht möglich: kein Debian, kein curl, kein Netz)."
    return 0
  fi

  say "Neues Debian-Release verfügbar: ${next} (aktuell: $(os_field VERSION_CODENAME))"

  if [[ "${IS_PVE}" == "true" ]]; then
    echo
    say "⚠ Proxmox-Host: Ein neues Major-Release (${next}) ist verfügbar."
    say "Proxmox-Major-Upgrades werden von diesem Skript bewusst NICHT durchgeführt."
    echo "  1. Backup/Snapshot des Hosts UND aller VMs/LXCs erstellen."
    echo "  2. Offizielle Upgrade-Anleitung im Proxmox-Wiki lesen (Upgrade from <alt> to <neu>)."
    echo "  3. Den Checker für den Versionssprung ausführen (z.B. pve8to9), falls vorhanden."
    echo "  4. Im Cluster alle Nodes nacheinander upgraden, nicht parallel."
    echo "  5. Erst danach die Debian-Quellen wechseln und full-upgrade gemäß Anleitung ausführen."
    return 0
  fi

  [[ "${CHECK_ONLY}" == "true" ]] && return 0

  if yesno "Soll jetzt das Release-Upgrade auf ${next} gestartet werden (statt des normalen Updates)?" "n"; then
    if [[ -x /usr/local/bin/release-upgrade.sh ]]; then
      say "Starte release-upgrade.sh ..."
      exec /usr/local/bin/release-upgrade.sh
    else
      say "/usr/local/bin/release-upgrade.sh nicht gefunden. Bitte zuerst 02-install-update-script.sh ausführen."
    fi
  fi
}

# ------------------------------------------------------------------ APT ----

# Zeigt, was `apt-get -s <modus>` installieren (Inst) oder entfernen (Remv) würde.
apt_changes() {
  apt-get -s "$1" 2>/dev/null | grep -E '^(Inst|Remv) ' || true
}

hold_docker_packages() {
  local pkg already
  already="$(apt-mark showhold 2>/dev/null || true)"
  for pkg in "${DOCKER_PKGS[@]}"; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || continue
    # vom Benutzer selbst gesetzte Holds nicht anfassen und später nicht lösen
    if grep -qxF "${pkg}" <<<"${already}"; then continue; fi
    if apt-mark hold "${pkg}" >/dev/null; then HELD_BY_US+=("${pkg}"); fi
  done
}

release_docker_holds() {
  if [[ ${#HELD_BY_US[@]} -gt 0 ]]; then
    apt-mark unhold "${HELD_BY_US[@]}" >/dev/null || true
    HELD_BY_US=()
  fi
}

show_apt_state() {
  local up count
  up="$(apt list --upgradable 2>/dev/null | tail -n +2 || true)"
  if [[ -z "${up}" ]]; then
    say "Keine Paket-Updates verfügbar."
    return 1
  fi
  count="$(grep -c . <<<"${up}")"
  say "${count} Paket-Update(s) verfügbar:"
  sed 's/^/  /' <<<"${up}"
  return 0
}

# Dist-Upgrade (full-upgrade) nur nach Rückfrage, wenn nach dem normalen Upgrade noch etwas offen ist.
dist_upgrade_step() {
  local pending def=y
  pending="$(apt_changes full-upgrade)"
  [[ -n "${pending}" ]] || return 0

  echo
  say "Ein Dist-Upgrade (apt full-upgrade) ist möglich. Zusätzlich würde apt Folgendes tun:"
  sed 's/^/  /' <<<"${pending}"
  if [[ "${IS_PVE}" == "true" ]]; then
    say "Hinweis: Proxmox empfiehlt full-upgrade, damit neue Kernel und PVE-Pakete installiert werden."
  fi
  if grep -q '^Remv' <<<"${pending}"; then
    say "⚠ Dabei werden Pakete ENTFERNT (Remv). Bitte genau prüfen."
    def=n
  fi

  if yesno "Dist-Upgrade jetzt durchführen?" "${def}"; then
    apt-get full-upgrade -y
  else
    say "Dist-Upgrade übersprungen."
  fi
}

apt_step() {
  say "apt update"
  apt-get update

  echo
  say "Suche Paket-Updates"
  if ! show_apt_state; then
    return 0
  fi

  if [[ "${CHECK_ONLY}" == "true" ]]; then
    local pending
    pending="$(apt_changes full-upgrade)"
    if [[ -n "${pending}" ]]; then
      say "Ein Dist-Upgrade (full-upgrade) würde ausführen:"
      sed 's/^/  /' <<<"${pending}"
    fi
    return 0
  fi

  echo
  say "Systempakete aktualisieren (apt upgrade)"
  if [[ "${UPDATE_DOCKER}" != "true" ]] && command -v docker >/dev/null 2>&1; then
    say "Docker-Pakete werden von Upgrade und Dist-Upgrade ausgenommen."
    hold_docker_packages
  fi
  apt-get upgrade -y

  dist_upgrade_step
  release_docker_holds

  echo
  local removable
  removable="$(apt_removals_after_cleanup)"
  if [[ -n "${removable}" ]]; then
    say "Nicht mehr benötigte Pakete (autoremove --purge):"
    sed 's/^/  /' <<<"${removable}"
    if yesno "Diese Pakete entfernen?" "y"; then
      apt-get autoremove -y --purge
    fi
  else
    say "Keine nicht mehr benötigten Pakete."
  fi
  apt-get autoclean -y
}

apt_removals_after_cleanup() {
  apt-get -s autoremove --purge 2>/dev/null | grep -E '^Remv ' || true
}

# --------------------------------------------------------------- Docker ----

docker_installed() { command -v docker >/dev/null 2>&1; }

docker_compose_available() { docker compose version >/dev/null 2>&1; }

# Compose-Projekte mit laufenden Containern direkt von Docker erfragen – egal, wo sie liegen.
list_compose_projects() {
  docker ps --filter 'label=com.docker.compose.project' --format \
    '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' \
    | sort -u
}

# Container ohne Compose-Projekt (docker run): nur anzeigen, nicht anfassen.
list_unmanaged_containers() {
  docker ps --format '{{.Names}}|{{.Image}}|{{.Label "com.docker.compose.project"}}' \
    | awk -F'|' '$3=="" {printf "  - %s (%s)\n", $1, $2}'
}

show_docker_state() {
  local projects unmanaged
  projects="$(list_compose_projects)"
  if [[ -z "${projects}" ]]; then
    say "Keine laufenden Compose-Projekte gefunden."
  else
    say "Laufende Compose-Projekte (Name | Verzeichnis | Datei):"
    sed 's/^/  - /' <<<"${projects}"
  fi

  unmanaged="$(list_unmanaged_containers)"
  if [[ -n "${unmanaged}" ]]; then
    say "Container ohne Compose-Projekt (werden NICHT automatisch aktualisiert):"
    echo "${unmanaged}"
  fi
}

update_compose_containers() {
  local failed=() name wdir files f ok
  while IFS='|' read -r name wdir files; do
    [[ -n "${name}" ]] || continue
    if [[ -e "${wdir}/.no-autoupdate" ]]; then
      say "Überspringe ${name} (.no-autoupdate in ${wdir})"
      continue
    fi
    local -a args=(--project-name "${name}" --project-directory "${wdir}")
    local -a cfiles=()
    IFS=',' read -ra cfiles <<<"${files}"
    ok=true
    for f in "${cfiles[@]}"; do
      if [[ ! -f "${f}" ]]; then
        say "${name}: Compose-Datei fehlt: ${f}"
        ok=false
      fi
      args+=(-f "${f}")
    done

    say "Aktualisiere Compose-Projekt ${name} (${wdir})"
    if [[ "${ok}" == true ]] && docker compose "${args[@]}" pull \
      && docker compose "${args[@]}" up -d --remove-orphans; then
      say "${name}: OK"
    else
      failed+=("${name}")
    fi
  done < <(list_compose_projects)

  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Compose-Update fehlgeschlagen: ${failed[*]}"
    return 1
  fi
  return 0
}

docker_containers_step() {
  if ! docker_installed; then
    say "Docker ist nicht installiert. Container-Update wird übersprungen."
    return 0
  fi
  if ! docker_compose_available; then
    say "docker compose ist nicht verfügbar. Container-Update wird übersprungen."
    return 0
  fi

  show_docker_state
  [[ "${CHECK_ONLY}" == "true" ]] && return 0
  [[ "${UPDATE_CONTAINERS}" == "true" ]] || { say "Docker-Container werden nicht aktualisiert."; return 0; }

  echo
  update_compose_containers || true

  echo
  say "Entferne ungenutzte (dangling) Docker Images"
  docker image prune -f
}

# ------------------------------------------------- community-scripts-LXC ----

# LXCs aus den community-scripts haben /usr/bin/update, das die App-spezifische
# Update-Routine (ct/<app>.sh) von GitHub holt. PHS_SILENT=1 überspringt deren Menü.
update_community_script_app() {
  [[ -x "${CS_UPDATE_BIN}" ]] && grep -q 'community-scripts' "${CS_UPDATE_BIN}" 2>/dev/null || return 0

  say "community-scripts-LXC erkannt (${CS_UPDATE_BIN})."
  [[ "${CHECK_ONLY}" == "true" ]] && { say "App-Update würde über ${CS_UPDATE_BIN} laufen."; return 0; }

  if yesno "App per ${CS_UPDATE_BIN} aktualisieren? (vorher Snapshot/Backup empfohlen)" "y"; then
    if ! PHS_SILENT=1 "${CS_UPDATE_BIN}"; then
      warn "App-Update über ${CS_UPDATE_BIN} meldete einen Fehler (Ausgabe siehe oben)."
    fi
  fi
}

# --------------------------------------------------------------- Reboot ----

reboot_reason() {
  local newest running
  if [[ -f /var/run/reboot-required ]]; then
    echo "/var/run/reboot-required vorhanden"
    return 0
  fi

  # Container teilen sich den Kernel mit dem Host
  if systemd-detect-virt -cq 2>/dev/null; then
    return 1
  fi

  newest="$(ls -1 "${BOOT_DIR}"/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n1 || true)"
  running="$(uname -r)"
  if [[ -n "${newest}" && "${newest}" != "${running}" ]]; then
    echo "neuester installierter Kernel: ${newest}, aktiv: ${running}"
    return 0
  fi
  return 1
}

reboot_step() {
  local reason BOLD_RED="\033[1;31m" BOLD_GREEN="\033[1;32m" COLOR_RESET="\033[0m"
  if reason="$(reboot_reason)"; then
    echo -e "[update.sh] ${BOLD_RED}⚠ REBOOT ERFORDERLICH (${reason})${COLOR_RESET}"
    WARNINGS+=("Reboot erforderlich")
  else
    echo -e "[update.sh] ${BOLD_GREEN}Kein Reboot erforderlich.${COLOR_RESET}"
  fi

  # Dienste mit veralteten Bibliotheken (v.a. nützlich in LXCs/VMs), nur auflisten
  if command -v needrestart >/dev/null 2>&1; then
    needrestart -r l 2>&1 || true
  fi
}

# ----------------------------------------------------------------- main ----

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --check | -c) CHECK_ONLY=true ;;
      --help | -h) usage; exit 0 ;;
      *) echo "Unbekannte Option: ${arg}"; usage; exit 2 ;;
    esac
  done

  if [[ "${CHECK_ONLY}" != "true" && ! -t 0 ]]; then
    echo "update.sh ist interaktiv und braucht ein Terminal (bei ssh: ssh -t). Zum reinen Suchen: --check"
    exit 1
  fi

  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if [[ ! -f "$0" ]]; then
      echo "Bitte als root starten (das Skript wird nicht aus einer Datei gelesen, sudo-Neustart nicht möglich)."
      exit 1
    fi
    echo "Dieses Skript benötigt sudo/root."
    sudo -v
    exec sudo -E bash "$0" "$@"
  fi

  mkdir -p /run/lock
  exec 9>/run/lock/update.sh.lock
  if ! flock -n 9; then
    echo "update.sh läuft bereits (Lock /run/lock/update.sh.lock)."
    exit 1
  fi

  trap release_docker_holds EXIT

  mkdir -p "$(dirname "${LOG_FILE}")"
  # Terminal bekommt die Ausgabe inkl. Farbcodes, im Logfile werden sie rausgefiltert.
  exec > >(tee >(sed -u -r 's/\x1b\[[0-9;]*m//g' >>"${LOG_FILE}")) 2>&1

  echo
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') update.sh gestartet$([[ "${CHECK_ONLY}" == "true" ]] && echo ' (--check)') ====="
  echo "=============================="
  echo " update.sh"
  echo "=============================="

  if is_proxmox_host; then
    IS_PVE=true
    echo
    say "Proxmox-Host erkannt: $(pveversion 2>/dev/null | head -n1)"
    if [[ "${CHECK_ONLY}" == "true" ]]; then
      say "(--check: Repo-Konfiguration wird nicht angepasst)"
    else
      ensure_pve_no_subscription
    fi
  fi

  echo
  say "Prüfe auf verfügbares Debian Release-Upgrade"
  release_upgrade_step

  echo
  if docker_installed; then
    if [[ "${CHECK_ONLY}" != "true" ]]; then
      if yesno "Soll Docker mit aktualisiert werden?" "y"; then UPDATE_DOCKER=true; fi
      if yesno "Sollen Docker-Container aktualisiert werden?" "y"; then UPDATE_CONTAINERS=true; fi
    fi
  else
    say "Docker wurde nicht gefunden. Docker- und Container-Aktualisierung werden übersprungen."
  fi

  echo
  apt_step

  echo
  update_community_script_app

  echo
  say "Docker-Container"
  docker_containers_step

  echo
  say "Prüfe ob Reboot erforderlich ist"
  reboot_step

  echo
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    say "Zusammenfassung – bitte beachten:"
    printf '  - %s\n' "${WARNINGS[@]}"
  fi
  say "Fertig."
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') update.sh beendet ====="
}

# Nur ausführen, wenn direkt gestartet (nicht beim `source` in Tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
