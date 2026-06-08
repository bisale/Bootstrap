#!/usr/bin/env bash
set -euo pipefail

# Immer mit sudo/root laufen (fragt ggf. nach Passwort)
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Dieses Skript ben  tigt sudo/root."
  sudo -v
  exec sudo -E bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

echo "[update.sh] apt update"
apt update

echo "[update.sh] apt upgrade"
apt upgrade

echo "[update.sh] autoremove --purge"
apt autoremove --purge

echo "[update.sh] autoclean"
apt autoclean

echo "[update.sh] Fertig."
