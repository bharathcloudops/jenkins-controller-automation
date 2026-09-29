#!/usr/bin/env bash

#==============================================================================
# VERSIONED JENKINS BOOTSTRAP
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# BOOTSTRAP INPUTS
#==============================================================================

action="${1:-validate}"
automation_repository="${2:-}"
automation_ref="${3:-}"
jenkins_url="${4:-http://localhost:8080}"
resource_root_url="${5:-http://jenkins-resources.localhost:8080}"
bind_address="${6:-127.0.0.1}"
operation_value="${7:-}"
restore_archive="$operation_value"
backup_bucket=${operation_value%%|*}
retire_confirmation=${operation_value#*|}
secret_bundle="${8:-}"
jenkins_host=${jenkins_url#*://}; jenkins_host=${jenkins_host%%:*}
resource_root_host=${resource_root_url#*://}; resource_root_host=${resource_root_host%%:*}

case "$action" in
  validate|dry-run|deploy|verify|status|scan|diagnose|backup|archive|restore|rollback|test-restore|retire|retirement-status) ;;
  *) printf 'Unsupported lifecycle action.\n' >&2; exit 2 ;;
esac

if [[ ! "$automation_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'GitHub owner/repository is required.\n' >&2
  exit 1
fi

if [[ ! "$automation_ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'A semantic version tag is required.\n' >&2
  exit 1
fi

if [[ ! "$jenkins_url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ || \
  ! "$resource_root_url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ || \
  "$jenkins_host" == "$resource_root_host" ]]; then
  printf 'Jenkins and resource root URLs must use distinct valid hosts.\n' >&2
  exit 1
fi

if [[ "$action" != "validate" && "$action" != "dry-run" ]]; then
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true; then
    printf '%s requires non-interactive sudo access.\n' "$action" >&2
    exit 1
  fi
fi

#==============================================================================
# VERSIONED SOURCE DOWNLOAD
#==============================================================================

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
mkdir "$temporary_directory/source"
curl --fail --location --silent --show-error \
  "https://github.com/$automation_repository/archive/refs/tags/$automation_ref.tar.gz" | \
  tar --extract --gzip --directory "$temporary_directory/source" --strip-components=1

#==============================================================================
# VERSIONED AUTOMATION EXECUTION
#==============================================================================

manage_script="$temporary_directory/source/scripts/manage.sh"
manage_environment=(
  env
  "AUTOMATION_REF=$automation_ref"
  "JENKINS_URL=$jenkins_url"
  "JENKINS_RESOURCE_ROOT_URL=$resource_root_url"
  "JENKINS_BIND_ADDRESS=$bind_address"
  "JENKINS_BACKUP_BUCKET=$backup_bucket"
  "JENKINS_RETIRE_CONFIRMATION=$retire_confirmation"
)

if [[ "$action" == "deploy" ]]; then
  sudo -n bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  sudo -n "${manage_environment[@]}" bash "$manage_script" "$action" "$secret_bundle"
elif [[ "$action" == "validate" || "$action" == "dry-run" ]]; then
  bash "$temporary_directory/source/scripts/install-docker.sh" "$action"
  "${manage_environment[@]}" bash "$manage_script" "$action"
else
  sudo -n "${manage_environment[@]}" "JENKINS_RESTORE_ARCHIVE=$restore_archive" bash "$manage_script" "$action"
fi