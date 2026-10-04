#!/bin/bash
# Einmalige Einrichtung eines Ubuntu-24.04-Servers mit NVIDIA-GPU für Mitschrift (WP8).
# Installiert Docker (offizielles Repo) und das NVIDIA Container Toolkit, richtet die Docker-Runtime
# für GPUs ein und nimmt den aufrufenden Nutzer in die Gruppe docker auf.
#
# Aufruf vom Mac aus, mit Passwortabfrage auf dem Server:
#   ssh -t <server> 'sudo bash -s' < Server/deploy/bootstrap-ubuntu.sh
# Danach einmal neu anmelden (Gruppe docker) und prüfen:
#   docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Bitte mit sudo ausführen." >&2
  exit 1
fi
TARGET_USER="${SUDO_USER:-}"
export DEBIAN_FRONTEND=noninteractive

echo "==> Grundpakete"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git >/dev/null

if command -v docker >/dev/null; then
  echo "==> Docker ist vorhanden ($(docker --version | cut -d, -f1)), Installation übersprungen"
else
echo "==> Docker (offizielles Repository)"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
systemctl enable --now docker
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "==> docker compose Plugin"
  apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || apt-get install -y -qq docker-compose-plugin >/dev/null
fi

echo "==> NVIDIA Container Toolkit"
if command -v nvidia-ctk >/dev/null; then
  echo "    bereits installiert"
else
if [[ ! -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]]; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
fi
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit >/dev/null
fi
nvidia-ctk runtime configure --runtime=docker >/dev/null
systemctl restart docker

if [[ -n "$TARGET_USER" ]]; then
  echo "==> Nutzer $TARGET_USER in Gruppe docker"
  usermod -aG docker "$TARGET_USER"
fi

echo "==> Verzeichnisse"
install -d -o "${TARGET_USER:-root}" -g "${TARGET_USER:-root}" /opt/mitschrift /opt/mitschrift/models

echo
echo "Fertig. Docker $(docker --version | cut -d, -f1), NVIDIA-Runtime konfiguriert."
echo "Bitte neu anmelden, damit die Gruppe docker gilt."
