#!/usr/bin/env bash

#==============================================================================
# ISOLATED PERMANENT RETIREMENT REGRESSION TESTS
#==============================================================================

set -euo pipefail
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

for scenario in invalid-confirmation upload-failure success; do
  scenario_root="$temporary_directory/$scenario"
  install_root="$scenario_root/install"
  backup_directory="$scenario_root/backups"
  action=retire
  health_failure_file="$scenario_root/health"
  maintenance_file="$scenario_root/maintenance"
  retire_confirmation=RETIRE-JENKINS
  : "$action" "$health_failure_file" "$maintenance_file" "$retire_confirmation"
  mkdir -p "$install_root/current" "$backup_directory"
  calls="$scenario_root/calls"
  : > "$calls"

  require_root() { printf 'root\n' >> "$calls"; }
  verify_controller() { printf 'verify\n' >> "$calls"; }
  assert_controller_idle() { printf 'idle\n' >> "$calls"; }
  install_oci_cli() { printf 'oci\n' >> "$calls"; printf '/mock/oci\n'; }
  backup_controller() {
    archive_path="$backup_directory/jenkins-home-20260928T000000Z.tar.gz"
    touch "$archive_path"
    printf 'backup\n' >> "$calls"
    printf 'jenkins_backup_archive=%s\njenkins_backup=ready\n' "$archive_path"
  }
  upload_backup_archive() {
    printf 'upload\n' >> "$calls"
    [[ "$scenario" != upload-failure ]]
  }
  quiet_controller() { printf 'quiet\n' >> "$calls"; }
  resume_controller() { printf 'resume\n' >> "$calls"; }
  systemctl() { printf 'systemctl %s\n' "$*" >> "$calls"; }
  docker() {
    printf 'docker %s\n' "$*" >> "$calls"
    if [[ "$*" == *'config --images'* ]]; then
      printf 'jenkins-controller:test\njenkins-platform-agent:test\n'
    fi
  }
  rm() { printf 'rm %s\n' "$*" >> "$calls"; }

  eval "$(sed -n '/^retire_controller() {/,/^}/p' "$repository_root/scripts/manage.sh")"
  if [[ "$scenario" == invalid-confirmation ]]; then
    retire_confirmation=invalid
    : "$retire_confirmation"
  fi
  exit_code=0
  retire_controller >/dev/null 2>&1 || exit_code=$?

  case "$scenario" in
    invalid-confirmation)
      [[ "$exit_code" != 0 ]]
      grep -Fxq root "$calls"
      if grep -qE '^(verify|idle|backup|upload|quiet|systemctl|docker .* down)' "$calls"; then exit 1; fi
      ;;
    upload-failure)
      [[ "$exit_code" != 0 ]]
      grep -Fxq upload "$calls"
      if grep -qE '^(quiet|systemctl|docker .* down)' "$calls"; then exit 1; fi
      ;;
    success)
      [[ "$exit_code" == 0 ]]
      upload_line=$(grep -n '^upload$' "$calls" | cut -d: -f1)
      teardown_line=$(grep -n '^systemctl disable --now jenkins-controller-backup.timer' "$calls" | cut -d: -f1)
      (( upload_line < teardown_line ))
      grep -Fq 'docker image rm --force jenkins-controller:test' "$calls"
      grep -Fq 'docker image rm --force jenkins-platform-agent:test' "$calls"
      ;;
  esac
  printf 'jenkins_retirement_%s=ready\n' "$scenario"
done
