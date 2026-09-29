#!/usr/bin/env bash

#==============================================================================
# PINNED DOCKER ENGINE INSTALLATION
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# INSTALLATION INPUTS
#==============================================================================

action="${1:-validate}"
containerd_version="${CONTAINERD_VERSION:-2.3.6-1~ubuntu.24.04~noble}"
docker_buildx_version="${DOCKER_BUILDX_VERSION:-0.37.1-1~ubuntu.24.04~noble}"
docker_compose_version="${DOCKER_COMPOSE_VERSION:-5.5.1-1~ubuntu.24.04~noble}"
docker_engine_version="${DOCKER_ENGINE_VERSION:-5:29.8.1-1~ubuntu.24.04~noble}"

#==============================================================================
# ACTION VALIDATION
#==============================================================================

if [[ "$action" != "validate" && "$action" != "dry-run" && "$action" != "deploy" ]]; then
  printf 'Usage: %s validate|dry-run|deploy\n' "$0" >&2
  exit 2
fi

#==============================================================================
# OPERATING SYSTEM VALIDATION
#==============================================================================

if [[ ! -r /etc/os-release ]]; then
  printf 'Ubuntu operating system metadata is required.\n' >&2
  exit 1
fi

operating_system_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
operating_system_codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')

if [[ "$operating_system_id" != "ubuntu" || "$operating_system_codename" != "noble" ]]; then
  printf 'Ubuntu 24.04 noble is required, found %s %s.\n' \
    "${operating_system_id:-unknown}" "${operating_system_codename:-unknown}" >&2
  exit 1
fi

#==============================================================================
# VALIDATION RESULT
#==============================================================================

if [[ "$action" == "validate" ]]; then
  printf 'docker_install_validation=ready\n'
  exit 0
fi

#==============================================================================
# DRY RUN RESULT
#==============================================================================

if [[ "$action" == "dry-run" ]]; then
  printf 'Would install Docker Engine %s, containerd %s, Buildx %s, and Compose %s.\n' \
    "$docker_engine_version" "$containerd_version" "$docker_buildx_version" "$docker_compose_version"
  printf 'docker_install_dry_run=ready\n'
  exit 0
fi

#==============================================================================
# PRIVILEGE VALIDATION
#==============================================================================

if (( EUID != 0 )); then
  printf 'Docker deployment must run as root.\n' >&2
  exit 1
fi

if [[ "$(dpkg-query --show --showformat='${Version}' docker-ce 2>/dev/null || true)" == "$docker_engine_version" &&
  "$(dpkg-query --show --showformat='${Version}' docker-ce-cli 2>/dev/null || true)" == "$docker_engine_version" &&
  "$(dpkg-query --show --showformat='${Version}' containerd.io 2>/dev/null || true)" == "$containerd_version" &&
  "$(dpkg-query --show --showformat='${Version}' docker-buildx-plugin 2>/dev/null || true)" == "$docker_buildx_version" &&
  "$(dpkg-query --show --showformat='${Version}' docker-compose-plugin 2>/dev/null || true)" == "$docker_compose_version" &&
  systemctl is-active --quiet docker ]]; then
  docker version >/dev/null
  docker compose version >/dev/null
  printf 'docker_install=unchanged\n'
  printf 'docker_install=ready\n'
  exit 0
fi

#==============================================================================
# DOCKER PACKAGE REPOSITORY
#==============================================================================

install -d -m 0755 /etc/apt/keyrings
curl --fail --location --silent --show-error \
  https://download.docker.com/linux/ubuntu/gpg \
  --output /etc/apt/keyrings/docker.asc
chmod 0644 /etc/apt/keyrings/docker.asc
architecture=$(dpkg --print-architecture)
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$architecture" "$operating_system_codename" > /etc/apt/sources.list.d/docker.list

#==============================================================================
# PINNED DOCKER PACKAGES
#==============================================================================

apt-get update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install --yes --quiet \
  "docker-ce=$docker_engine_version" \
  "docker-ce-cli=$docker_engine_version" \
  "containerd.io=$containerd_version" \
  "docker-buildx-plugin=$docker_buildx_version" \
  "docker-compose-plugin=$docker_compose_version" >/dev/null

#==============================================================================
# DOCKER RUNTIME VALIDATION
#==============================================================================

systemctl enable --now docker
docker version >/dev/null
docker compose version >/dev/null
printf 'docker_install=ready\n'