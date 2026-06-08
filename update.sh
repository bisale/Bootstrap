#!/usr/bin/env bash
set -euo pipefail

# Immer mit sudo/root laufen
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Dieses Skript benötigt sudo/root."
  sudo -v
  exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

CONFIRM_MODE=""

ask_yes_no() {
  local prompt="$1"

  if [[ "$CONFIRM_MODE" == "all" ]]; then
    return 0
  fi

  while true; do
    read -r -p "$prompt [j/N]: " answer
    case "$answer" in
      [jJ]|[jJ][aA]|[yY]|[yY][eE][sS])
        return 0
        ;;
      [nN]|[nN][eE][iI][nN]|"")
        return 1
        ;;
      *)
        echo "Bitte mit j oder n antworten."
        ;;
    esac
  done
}

get_debian_version_id() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${VERSION_ID:-unknown}"
  else
    echo "unknown"
  fi
}

get_debian_codename() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "${VERSION_CODENAME:-unknown}"
  else
    echo "unknown"
  fi
}

get_target_codename_for_major_upgrade() {
  local current_codename="$1"

  case "$current_codename" in
    bullseye)
      echo "bookworm"
      ;;
    bookworm)
      echo "trixie"
      ;;
    trixie)
      echo "forky"
      ;;
    *)
      echo ""
      ;;
  esac
}

backup_apt_sources() {
  local backup_dir="/root/apt-sources-backup-$(date +%Y%m%d-%H%M%S)"

  echo "[update.sh] Erstelle Backup der APT-Sources unter: $backup_dir"
  mkdir -p "$backup_dir"

  if [[ -f /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "$backup_dir/sources.list"
  fi

  if [[ -d /etc/apt/sources.list.d ]]; then
    cp -a /etc/apt/sources.list.d "$backup_dir/sources.list.d"
  fi
}

replace_codename_in_apt_sources() {
  local old_codename="$1"
  local new_codename="$2"

  echo "[update.sh] Passe APT-Sources an: $old_codename → $new_codename"

  # Klassische .list-Dateien
  if [[ -f /etc/apt/sources.list ]]; then
    sed -i "s/\b${old_codename}\b/${new_codename}/g" /etc/apt/sources.list
  fi

  if [[ -d /etc/apt/sources.list.d ]]; then
    find /etc/apt/sources.list.d \
      -type f \
      \( -name "*.list" -o -name "*.sources" \) \
      -print0 |
      while IFS= read -r -d '' file; do
        sed -i "s/\b${old_codename}\b/${new_codename}/g" "$file"
      done
  fi
}

run_point_release_upgrade() {
  echo
  echo "[update.sh] Führe Point-Release-/Paketupgrade aus..."
  apt update
  apt full-upgrade
  apt autoremove --purge
  apt autoclean
}

run_major_release_upgrade() {
  local old_codename="$1"
  local new_codename="$2"

  echo
  echo "[update.sh] Major-Release-Upgrade erkannt/vorbereitet:"
  echo "  Von: $old_codename"
  echo "  Nach: $new_codename"

  echo
  echo "WICHTIG:"
  echo "- Vor einem Major-Upgrade sollte ein VM-/LXC-Backup oder Snapshot vorhanden sein."
  echo "- Drittanbieter-Repositories können Probleme verursachen."
  echo "- Prüfe nach dem Upgrade besonders Docker, Proxmox-Gast-Agent, Netzwerk und Dienste."

  if ! ask_yes_no "Major-Release-Upgrade wirklich vorbereiten und durchführen?"; then
    echo "[update.sh] Major-Release-Upgrade übersprungen."
    return 0
  fi

  backup_apt_sources
  replace_codename_in_apt_sources "$old_codename" "$new_codename"

  echo "[update.sh] apt update nach sources-Änderung"
  apt update

  echo "[update.sh] Minimales Upgrade ohne neue Pakete"
  apt upgrade --without-new-pkgs

  echo "[update.sh] Vollständiges Release-Upgrade"
  apt full-upgrade

  echo "[update.sh] Aufräumen nach Major-Upgrade"
  apt autoremove --purge
  apt autoclean

  echo
  echo "[update.sh] Major-Release-Upgrade abgeschlossen."
  echo "[update.sh] Ein Neustart wird dringend empfohlen."
}

check_system_upgrade_loop() {
  while true; do
    local current_version
    local current_codename
    local target_codename

    current_version="$(get_debian_version_id)"
    current_codename="$(get_debian_codename)"
    target_codename="$(get_target_codename_for_major_upgrade "$current_codename")"

    echo
    echo "[update.sh] Systemstand:"
    echo "  Debian-Version:  $current_version"
    echo "  Codename:        $current_codename"

    echo
    echo "[update.sh] Prüfe verfügbare Paketupdates..."
    apt update

    local upgradable_count
    upgradable_count="$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"

    if [[ "$upgradable_count" -gt 0 ]]; then
      echo "[update.sh] Es sind $upgradable_count Paketupdates verfügbar."
      if ask_yes_no "Verfügbare Paket-/Point-Release-Updates jetzt installieren?"; then
        run_point_release_upgrade
        continue
      else
        echo "[update.sh] Paket-/Point-Release-Updates übersprungen."
      fi
    else
      echo "[update.sh] Keine normalen Paketupdates gefunden."
    fi

    echo
    echo "[update.sh] Major-Release-Option:"
    if [[ -n "$target_codename" ]]; then
      echo "  Aktuell: $current_codename"
      echo "  Möglich: $target_codename"

      if ask_yes_no "Sources auf $target_codename umstellen und Major-Release-Upgrade durchführen?"; then
        run_major_release_upgrade "$current_codename" "$target_codename"
        continue
      else
        echo "[update.sh] Major-Release-Upgrade nicht durchgeführt."
      fi
    else
      echo "  Für Codename '$current_codename' ist kein automatischer nächster Codename im Script hinterlegt."
    fi

    echo
    echo "[update.sh] Keine weiteren Upgrade-Aktionen ausgewählt."
    break
  done
}

echo "[update.sh] Update-Modus auswählen:"
echo "1) Jeden Schritt einzeln bestätigen"
echo "2) Alle Updates pauschal durchführen"

while true; do
  read -r -p "Auswahl [1/2]: " mode
  case "$mode" in
    1)
      CONFIRM_MODE="single"
      echo "[update.sh] Modus: einzelne Bestätigung"
      break
      ;;
    2)
      CONFIRM_MODE="all"
      echo "[update.sh] Modus: pauschale Durchführung"
      break
      ;;
    *)
      echo "Bitte 1 oder 2 eingeben."
      ;;
  esac
done

echo
echo "[update.sh] Starte Systemupdate..."

if ask_yes_no "APT-Paketlisten aktualisieren?"; then
  echo "[update.sh] apt update"
  apt update
else
  echo "[update.sh] Überspringe apt update."
fi

if ask_yes_no "APT-Systempakete aktualisieren?"; then
  echo "[update.sh] apt upgrade"
  apt upgrade
else
  echo "[update.sh] Überspringe apt upgrade."
fi

echo
echo "[update.sh] Prüfe Docker-Installation..."

DOCKER_AVAILABLE=false
COMPOSE_AVAILABLE=false

if command -v docker >/dev/null 2>&1; then
  DOCKER_AVAILABLE=true
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_AVAILABLE=true
fi

echo "[update.sh] Docker-Pakete prüfen..."

DOCKER_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

INSTALLED_DOCKER_PACKAGES=()

for pkg in "${DOCKER_PACKAGES[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    INSTALLED_DOCKER_PACKAGES+=("$pkg")
  fi
done

if [[ ${#INSTALLED_DOCKER_PACKAGES[@]} -gt 0 ]]; then
  echo "[update.sh] Gefundene Docker-Pakete:"
  printf ' - %s\n' "${INSTALLED_DOCKER_PACKAGES[@]}"

  if ask_yes_no "Docker-Pakete aktualisieren?"; then
    echo "[update.sh] Aktualisiere Docker-Pakete..."
    apt install --only-upgrade "${INSTALLED_DOCKER_PACKAGES[@]}"
  else
    echo "[update.sh] Überspringe Docker-Paketupdate."
  fi
else
  echo "[update.sh] Keine Docker-CE-Pakete gefunden. Überspringe Docker-Paketupdate."
fi

# Nach Paketupdate erneut prüfen
if command -v docker >/dev/null 2>&1; then
  DOCKER_AVAILABLE=true
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_AVAILABLE=true
fi

if [[ "$DOCKER_AVAILABLE" == true && "$COMPOSE_AVAILABLE" == true ]]; then
  echo
  echo "[update.sh] Docker und Docker Compose gefunden."
  docker --version
  docker compose version

  echo
  echo "[update.sh] Suche Docker-Compose-Projekte..."

  SEARCH_DIRS=(
    /opt
    /srv
    /home
    /root
  )

  COMPOSE_FILES=()

  for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      while IFS= read -r -d '' file; do
        COMPOSE_FILES+=("$file")
      done < <(
        find "$dir" \
          -maxdepth 4 \
          -type f \
          \( -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yml" -o -name "compose.yaml" \) \
          -print0 2>/dev/null
      )
    fi
  done

  if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
    echo "[update.sh] Keine Compose-Dateien gefunden. Überspringe Container-Updates."
  else
    echo "[update.sh] Gefundene Compose-Projekte:"
    printf ' - %s\n' "${COMPOSE_FILES[@]}"

    for compose_file in "${COMPOSE_FILES[@]}"; do
      compose_dir="$(dirname "$compose_file")"

      echo
      echo "[update.sh] Compose-Projekt gefunden: $compose_dir"

      if ask_yes_no "Dieses Compose-Projekt aktualisieren?"; then
        cd "$compose_dir"

        echo "[update.sh] docker compose pull"
        docker compose -f "$compose_file" pull

        echo "[update.sh] docker compose up -d --remove-orphans"
        docker compose -f "$compose_file" up -d --remove-orphans
      else
        echo "[update.sh] Überspringe Compose-Projekt: $compose_dir"
      fi
    done

    echo
    if ask_yes_no "Alte ungenutzte Docker Images aufräumen?"; then
      echo "[update.sh] Docker Images aufräumen..."
      docker image prune -f
    else
      echo "[update.sh] Überspringe Docker Image Prune."
    fi
  fi
else
  echo "[update.sh] Docker oder Docker Compose nicht verfügbar. Überspringe Container-Updates."
fi

echo
if ask_yes_no "Nicht mehr benötigte Pakete entfernen?"; then
  echo "[update.sh] autoremove --purge"
  apt autoremove --purge
else
  echo "[update.sh] Überspringe autoremove."
fi

if ask_yes_no "APT-Cache bereinigen?"; then
  echo "[update.sh] autoclean"
  apt autoclean
else
  echo "[update.sh] Überspringe autoclean."
fi

echo
echo "[update.sh] Starte abschließende Systemupgrade-Prüfung..."
check_system_upgrade_loop

echo
echo "[update.sh] Fertig."
if ask_yes_no "APT-Paketlisten aktualisieren?"; then
  echo "[update.sh] apt update"
  apt update
else
  echo "[update.sh] Überspringe apt update."
fi

if ask_yes_no "APT-Systempakete aktualisieren?"; then
  echo "[update.sh] apt upgrade"
  apt upgrade
else
  echo "[update.sh] Überspringe apt upgrade."
fi

echo
echo "[update.sh] Prüfe Docker-Installation..."

DOCKER_AVAILABLE=false
COMPOSE_AVAILABLE=false

if command -v docker >/dev/null 2>&1; then
  DOCKER_AVAILABLE=true
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_AVAILABLE=true
fi

echo "[update.sh] Docker-Pakete prüfen..."

DOCKER_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

INSTALLED_DOCKER_PACKAGES=()

for pkg in "${DOCKER_PACKAGES[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    INSTALLED_DOCKER_PACKAGES+=("$pkg")
  fi
done

if [[ ${#INSTALLED_DOCKER_PACKAGES[@]} -gt 0 ]]; then
  echo "[update.sh] Gefundene Docker-Pakete:"
  printf ' - %s\n' "${INSTALLED_DOCKER_PACKAGES[@]}"

  if ask_yes_no "Docker-Pakete aktualisieren?"; then
    echo "[update.sh] Aktualisiere Docker-Pakete..."
    apt install --only-upgrade "${INSTALLED_DOCKER_PACKAGES[@]}"
  else
    echo "[update.sh] Überspringe Docker-Paketupdate."
  fi
else
  echo "[update.sh] Keine Docker-CE-Pakete gefunden. Überspringe Docker-Paketupdate."
fi

# Nach Paketupdate erneut prüfen
if command -v docker >/dev/null 2>&1; then
  DOCKER_AVAILABLE=true
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE_AVAILABLE=true
fi

if [[ "$DOCKER_AVAILABLE" == true && "$COMPOSE_AVAILABLE" == true ]]; then
  echo
  echo "[update.sh] Docker und Docker Compose gefunden."
  docker --version
  docker compose version

  echo
  echo "[update.sh] Suche Docker-Compose-Projekte..."

  SEARCH_DIRS=(
    /opt
    /srv
    /home
    /root
  )

  COMPOSE_FILES=()

  for dir in "${SEARCH_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      while IFS= read -r -d '' file; do
        COMPOSE_FILES+=("$file")
      done < <(
        find "$dir" \
          -maxdepth 4 \
          -type f \
          \( -name "docker-compose.yml" -o -name "docker-compose.yaml" -o -name "compose.yml" -o -name "compose.yaml" \) \
          -print0 2>/dev/null
      )
    fi
  done

  if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
    echo "[update.sh] Keine Compose-Dateien gefunden. Überspringe Container-Updates."
  else
    echo "[update.sh] Gefundene Compose-Projekte:"
    printf ' - %s\n' "${COMPOSE_FILES[@]}"

    for compose_file in "${COMPOSE_FILES[@]}"; do
      compose_dir="$(dirname "$compose_file")"

      echo
      echo "[update.sh] Compose-Projekt gefunden: $compose_dir"

      if ask_yes_no "Dieses Compose-Projekt aktualisieren?"; then
        cd "$compose_dir"

        echo "[update.sh] docker compose pull"
        docker compose -f "$compose_file" pull

        echo "[update.sh] docker compose up -d --remove-orphans"
        docker compose -f "$compose_file" up -d --remove-orphans
      else
        echo "[update.sh] Überspringe Compose-Projekt: $compose_dir"
      fi
    done

    echo
    if ask_yes_no "Alte ungenutzte Docker Images aufräumen?"; then
      echo "[update.sh] Docker Images aufräumen..."
      docker image prune -f
    else
      echo "[update.sh] Überspringe Docker Image Prune."
    fi
  fi
else
  echo "[update.sh] Docker oder Docker Compose nicht verfügbar. Überspringe Container-Updates."
fi

echo
if ask_yes_no "Nicht mehr benötigte Pakete entfernen?"; then
  echo "[update.sh] autoremove --purge"
  apt autoremove --purge
else
  echo "[update.sh] Überspringe autoremove."
fi

if ask_yes_no "APT-Cache bereinigen?"; then
  echo "[update.sh] autoclean"
  apt autoclean
else
  echo "[update.sh] Überspringe autoclean."
fi

echo
echo "[update.sh] Fertig."
