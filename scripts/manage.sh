#!/usr/bin/env bash

#==============================================================================
# JENKINS CONTROLLER LIFECYCLE
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -Eeuo pipefail
trap 'printf "jenkins_failure=line_%s\n" "$LINENO"' ERR

#==============================================================================
# LIFECYCLE INPUTS
#==============================================================================

action="${1:-validate}"
secret_bundle="${2:-}"
source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
install_root="${JENKINS_INSTALL_ROOT:-/opt/jenkins-controller}"
release_ref="${AUTOMATION_REF:-local}"
release_key=${release_ref//[^a-zA-Z0-9._-]/-}
release_path="$install_root/releases/$release_key"
backup_directory="${JENKINS_BACKUP_DIRECTORY:-/var/backups/jenkins-controller}"
backup_retention_days="${JENKINS_BACKUP_RETENTION_DAYS:-7}"
backup_bucket="${JENKINS_BACKUP_BUCKET:-}"
health_failure_file="${JENKINS_HEALTH_FAILURE_FILE:-/run/jenkins-controller-health-failures}"
maintenance_file="${JENKINS_MAINTENANCE_FILE:-/run/jenkins-controller-maintenance}"
retire_confirmation="${JENKINS_RETIRE_CONFIRMATION:-}"

#==============================================================================
# MANAGED JOB TOPOLOGY
#==============================================================================

managed_jobs_ready() {
  jq -e '
    def child($folder; $name; $class):
      any(.jobs[];
        .name == $folder and
        ._class == "com.cloudbees.hudson.plugins.folder.Folder" and
        any(.jobs[]?; .name == $name and ._class == $class)
      );
    child("bharath-oci-host-config"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("github-pipeline-templates"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("jenkins-controller-automation"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("jenkins-pipeline-templates"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("monitoring-stack-automation"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("shared-host-automation"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("terraform-oci-modules"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("tf-bharath-oci-infra"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("clinirova"; "validate"; "org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject") and
    child("clinirova"; "publish-runtime"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("clinirova"; "publish-migration"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("clinirova"; "deploy"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("bharath-oci-host-config"; "configure-jenkins"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("bharath-oci-host-config"; "configure-monitoring"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("bharath-oci-host-config"; "operate-host-network"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("bharath-oci-host-config"; "operate-ingress-connector"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("tf-bharath-oci-infra"; "operate-infrastructure"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("ignitox-wordpress"; "publish-image"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("ignitox-wordpress"; "deploy-wordpress"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("jenkins-controller-automation"; "scheduled-validation"; "org.jenkinsci.plugins.workflow.job.WorkflowJob") and
    child("monitoring-stack-automation"; "scheduled-validation"; "org.jenkinsci.plugins.workflow.job.WorkflowJob")
  ' >/dev/null
}

reconcile_legacy_jobs() {
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local controller_jobs
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local cookie_jar
  local crumb
  local crumb_field
  local crumb_response
  local legacy_job
  local response_code
  local legacy_jobs=(
    configure-production-jenkins
    configure-production-monitoring
    operate-production-oci-infrastructure
    operate-production-host-network
    operate-production-ingress-connector
    bharath-oci-host-config/job/operate-wordpress
    validate-github-pipeline-templates
    validate-jenkins-pipeline-templates
    validate-shared-host-automation
    validate-terraform-oci-modules
  )

  wait_for_endpoint "$controller_origin/api/json" "$admin_password_file"
  controller_jobs=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/api/json?tree=jobs[name,_class,jobs[name,_class]]")
  if ! managed_jobs_ready <<< "$controller_jobs"; then
    printf 'New Jenkins job topology is incomplete; legacy jobs will not be removed.\n' >&2
    return 1
  fi

  cookie_jar=$(mktemp)
  chmod 0600 "$cookie_jar"
  crumb_response=$(curl --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    --cookie "$cookie_jar" \
    --cookie-jar "$cookie_jar" \
    "$controller_origin/crumbIssuer/api/json")
  crumb_field=$(jq -r '.crumbRequestField' <<< "$crumb_response")
  crumb=$(jq -r '.crumb' <<< "$crumb_response")
  if [[ -z "$crumb_field" || "$crumb_field" == "null" || -z "$crumb" || "$crumb" == "null" ]]; then
    rm -f "$cookie_jar"
    printf 'Jenkins did not return a valid CSRF crumb for job reconciliation.\n' >&2
    return 1
  fi

  for legacy_job in "${legacy_jobs[@]}"; do
    response_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
      --cookie "$cookie_jar" \
      "$controller_origin/job/$legacy_job/api/json")
    case "$response_code" in
      200)
        curl --fail --silent --show-error --output /dev/null --request POST \
          --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
          --cookie "$cookie_jar" \
          --header "$crumb_field:$crumb" \
          "$controller_origin/job/$legacy_job/doDelete"
        ;;
      404)
        ;;
      *)
        rm -f "$cookie_jar"
        printf 'Unexpected HTTP %s while checking legacy Jenkins job %s.\n' \
          "$response_code" "$legacy_job" >&2
        return 1
        ;;
    esac
  done

  rm -f "$cookie_jar"
  printf 'jenkins_legacy_jobs=clear\n'
}

#==============================================================================
# CONTROLLER VALIDATION
#==============================================================================

validate_controller() {
  local validation_output

  if ! validation_output=$(bash "$source_root/scripts/validate.sh" 2>&1); then
    printf '%s\n' "$validation_output" >&2
    return 1
  fi
  printf 'jenkins_validation=ready\n'
}

#==============================================================================
# ROOT PRIVILEGE VALIDATION
#==============================================================================

require_root() {
  if (( EUID != 0 )); then
    printf '%s must run as root.\n' "$action" >&2
    exit 1
  fi
}

#==============================================================================
# RELEASE ENVIRONMENT
#==============================================================================

write_environment() {
  cat > "$release_path/.env" <<EOF
GITHUB_REGISTRY_TOKEN_FILE=./secrets/github-registry-token
GITHUB_TOKEN_FILE=./secrets/github-token
JENKINS_ADMIN_ID=${JENKINS_ADMIN_ID:-admin}
JENKINS_ADMIN_PASSWORD_FILE=./secrets/jenkins-admin-password
JENKINS_BIND_ADDRESS=${JENKINS_BIND_ADDRESS:-127.0.0.1}
JENKINS_CONTROLLER_VERSION=2.568.3-lts-jdk21
JENKINS_RESOURCE_ROOT_URL=${JENKINS_RESOURCE_ROOT_URL:-http://jenkins-resources.localhost:8080}
JENKINS_URL=${JENKINS_URL:-http://localhost:8080}
EOF
  chmod 0600 "$release_path/.env"
}

#==============================================================================
# CONTROLLER DEPLOYMENT
#==============================================================================

deploy_controller() {
  local deployment_fingerprint
  local fingerprint_file="$install_root/deployment.sha256"

  require_root
  if ! jq -e '
    type == "object" and
    (.admin_password | type == "string" and length >= 16 and (contains("\n") | not)) and
    (.github_token | type == "string" and length >= 20 and (contains("\n") | not)) and
    (.registry_token | type == "string" and length >= 20 and (contains("\n") | not))
  ' <<< "$secret_bundle" >/dev/null; then
    printf 'Secret bundle must contain administrator, GitHub SCM, and registry credentials.\n' >&2
    exit 1
  fi

  validate_controller
  docker compose version >/dev/null
  deployment_fingerprint=$(printf '%s\0' "$release_ref" "${JENKINS_ADMIN_ID:-admin}" "${JENKINS_BIND_ADDRESS:-127.0.0.1}" "${JENKINS_RESOURCE_ROOT_URL:-http://jenkins-resources.localhost:8080}" "${JENKINS_URL:-http://localhost:8080}" "$secret_bundle" | sha256sum | awk '{print $1}')
  if [[ -f "$fingerprint_file" && "$(<"$fingerprint_file")" == "$deployment_fingerprint" && -L "$install_root/current" ]] && verify_controller; then
    printf 'jenkins_deploy=unchanged\n'
    printf 'jenkins_deploy=ready\n'
    return 0
  fi
  install -d -m 0755 "$install_root/releases"
  rm -rf "$release_path"
  install -d -m 0755 "$release_path"
  cp -a "$source_root/." "$release_path/"
  install -d -m 0700 "$release_path/secrets"
  jq -r '.admin_password' <<< "$secret_bundle" > "$release_path/secrets/jenkins-admin-password"
  jq -r '.registry_token' <<< "$secret_bundle" > "$release_path/secrets/github-registry-token"
  jq -r '.github_token' <<< "$secret_bundle" > "$release_path/secrets/github-token"
  chown 1000:1000 "$release_path/secrets/jenkins-admin-password" \
    "$release_path/secrets/github-registry-token" "$release_path/secrets/github-token"
  chmod 0400 "$release_path/secrets/jenkins-admin-password" \
    "$release_path/secrets/github-registry-token" "$release_path/secrets/github-token"
  write_environment

  if [[ -L "$install_root/current" ]]; then
    ln -sfn "$(readlink -f "$install_root/current")" "$install_root/previous"
  fi

  ln -sfn "$release_path" "$install_root/current"
  install -m 0644 "$release_path/systemd/jenkins-controller.service" /etc/systemd/system/jenkins-controller.service
  install -m 0644 "$release_path/systemd/jenkins-controller-backup.service" /etc/systemd/system/jenkins-controller-backup.service
  install -m 0644 "$release_path/systemd/jenkins-controller-backup.timer" /etc/systemd/system/jenkins-controller-backup.timer
  install -m 0644 "$release_path/systemd/jenkins-controller-health.service" /etc/systemd/system/jenkins-controller-health.service
  install -m 0644 "$release_path/systemd/jenkins-controller-health.timer" /etc/systemd/system/jenkins-controller-health.timer
  systemctl daemon-reload
  systemctl enable jenkins-controller.service
  touch "$maintenance_file"
  rm -f "$health_failure_file"
  trap 'rm -f "$maintenance_file"' EXIT
  systemctl stop jenkins-controller-health.timer >/dev/null 2>&1 || true
  if ! systemctl reload-or-restart jenkins-controller.service; then
    journalctl --unit jenkins-controller.service --no-pager --lines 200 >&2
    return 1
  fi
  systemctl enable --now jenkins-controller-backup.timer
  systemctl enable --now jenkins-controller-health.timer
  printf 'jenkins_deploy=ready\n'
  activate_managed_jobs
  reconcile_legacy_jobs
  verify_controller
  printf '%s\n' "$deployment_fingerprint" > "$fingerprint_file.partial"
  chmod 0600 "$fingerprint_file.partial"
  mv "$fingerprint_file.partial" "$fingerprint_file"
  rm -f "$maintenance_file"
  trap - EXIT
  printf 'jenkins_deploy=ready\n'
}

#==============================================================================
# CONTROLLER HEALTH VERIFICATION
#==============================================================================

wait_for_endpoint() {
  local endpoint="$1"
  local password_file="${2:-}"
  local attempt

  for (( attempt = 1; attempt <= 120; attempt++ )); do
    if [[ -n "$password_file" ]] && curl --fail --silent --show-error \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$password_file")" "$endpoint" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -z "$password_file" ]] && curl --fail --silent --show-error "$endpoint" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  printf 'Jenkins did not become ready at %s.\n' "$endpoint" >&2
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps >&2 || true
  return 1
}

activate_managed_jobs() {
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local controller_jobs
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"

  wait_for_endpoint "$controller_origin/login"
  controller_jobs=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/api/json?tree=jobs[name,_class,jobs[name,_class]]")
  if managed_jobs_ready <<< "$controller_jobs"; then
    printf 'jenkins_job_activation=ready\n'
    return 0
  fi

  printf 'jenkins_job_activation=restart_required\n'
  if ! systemctl restart jenkins-controller.service; then
    journalctl --unit jenkins-controller.service --no-pager --lines 200 >&2
    return 1
  fi
  wait_for_endpoint "$controller_origin/login"
  controller_jobs=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/api/json?tree=jobs[name,_class,jobs[name,_class]]")
  if ! managed_jobs_ready <<< "$controller_jobs"; then
    printf 'New Jenkins job topology did not activate after the bounded restart.\n' >&2
    return 1
  fi
  printf 'jenkins_job_activation=ready\n'
}

wait_for_metrics() {
  local endpoint="$1"
  local password_file="$2"
  local attempt
  local metrics_content_type="unavailable"
  local metrics_details
  local metrics_size="0"

  printf 'jenkins_metrics_wait=started\n'
  for (( attempt = 1; attempt <= 120; attempt++ )); do
    if metrics_details=$(curl --fail --silent --show-error --output /dev/null \
      --write-out $'%{content_type}\n%{size_download}' \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$password_file")" "$endpoint" 2>/dev/null); then
      metrics_content_type=${metrics_details%%$'\n'*}
      metrics_size=${metrics_details##*$'\n'}
      if [[ "$metrics_content_type" =~ ^(text/plain|application/openmetrics-text)(\;|$) && \
        "$metrics_size" =~ ^[0-9]+$ && "$metrics_size" != "0" ]]; then
        return 0
      fi
    fi
    if (( attempt % 6 == 0 )); then
      printf 'jenkins_metrics_wait=attempt_%s\n' "$attempt"
    fi
    sleep 5
  done

  printf 'Jenkins Prometheus metrics did not become ready: content_type=%q size=%s.\n' \
    "$metrics_content_type" "$metrics_size" >&2
  return 1
}

show_controller_diagnostics() {
  local container_id

  container_id=$(docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps --all --quiet jenkins)
  if [[ -n "$container_id" ]]; then
    docker inspect --format 'jenkins_container={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' \
      "$container_id" >&2 || true
  fi
  docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    logs --no-color --tail 20 jenkins platform-agent-bootstrap platform-agent >&2 || true
}

verify_controller() {
  local agent_nodes
  local anonymous_status
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local controller_container_id
  local controller_jobs
  local expected_controller_image
  local expected_controller_version
  local jenkins_headers
  local persisted_admin_accounts
  local resource_root_authority
  local resource_root_port
  local resource_root_scheme
  local resource_root_status
  local running_controller_version

  if [[ "$(docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps --services --filter status=running | sort)" != $'jenkins\nplatform-agent' ]]; then
    printf 'Jenkins controller and platform agent services are not running.\n' >&2
    show_controller_diagnostics
    return 1
  fi

  wait_for_endpoint "$controller_origin/login"
  expected_controller_image=$(sed -n 's/^JENKINS_CONTROLLER_VERSION=//p' "$install_root/current/.env")
  expected_controller_version=${expected_controller_image%-lts-jdk21}
  running_controller_version=$(curl --fail --silent --show-error \
    --dump-header - --output /dev/null "$controller_origin/login" | \
    tr -d '\r' | sed -n 's/^X-Jenkins:[[:space:]]*//Ip' | tail -n 1)
  if [[ "$running_controller_version" != "$expected_controller_version" ]]; then
    printf 'Running Jenkins version %s does not match active release %s.\n' \
      "${running_controller_version:-unknown}" "$expected_controller_version" >&2
    return 1
  fi
  jenkins_headers=$(curl --fail --silent --show-error --dump-header - --output /dev/null "$controller_origin/login" | tr -d '\r')
  if ! grep -Eqi '^Content-Security-Policy:' <<< "$jenkins_headers"; then
    printf 'Jenkins UI Content Security Policy is not enforced.\n' >&2
    return 1
  fi
  resource_root_authority=${JENKINS_RESOURCE_ROOT_URL#*://}
  resource_root_authority=${resource_root_authority%/}
  resource_root_scheme=${JENKINS_RESOURCE_ROOT_URL%%://*}
  if [[ "$resource_root_authority" == *:* ]]; then
    resource_root_port=${resource_root_authority##*:}
  elif [[ "$resource_root_scheme" == "https" ]]; then
    resource_root_port=443
  else
    resource_root_port=80
  fi
  resource_root_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --header "Host: $resource_root_authority" \
    --header "X-Forwarded-Host: $resource_root_authority" \
    --header "X-Forwarded-Port: $resource_root_port" \
    --header "X-Forwarded-Proto: $resource_root_scheme" \
    "$controller_origin/instance-identity/")
  if [[ "$resource_root_status" != "404" ]]; then
    printf 'Jenkins resource root returned HTTP %s instead of 404 for a non-resource request.\n' "$resource_root_status" >&2
    return 1
  fi
  wait_for_metrics "$controller_origin/prometheus/" "$admin_password_file"
  agent_nodes=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/computer/api/json?tree=computer[displayName,numExecutors,offline]")
  if ! jq -e '
    any(.computer[]; .displayName == "Built-In Node" and .numExecutors == 0) and
    any(.computer[]; .displayName == "platform-agent" and .numExecutors == 1 and .offline == false)
  ' <<< "$agent_nodes" >/dev/null; then
    printf 'Jenkins controller isolation or platform agent readiness is invalid.\n' >&2
    return 1
  fi
  controller_container_id=$(docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    ps --quiet jenkins)
  if docker inspect --format '{{range .Mounts}}{{println .Source .Destination}}{{end}}' \
    "$controller_container_id" | grep -Fq '/var/run/docker.sock'; then
    printf 'Jenkins controller must not have Docker socket access.\n' >&2
    return 1
  fi
  anonymous_status=$(curl --silent --output /dev/null --write-out '%{http_code}' "$controller_origin/manage")
  if [[ "$anonymous_status" != "403" ]]; then
    printf 'Anonymous Jenkins management access returned HTTP %s instead of 403.\n' "$anonymous_status" >&2
    return 1
  fi
  if ! docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    exec --no-TTY jenkins test -f /var/jenkins_home/jenkins.install.InstallUtil.lastExecVersion; then
    printf 'Jenkins initialization state is unavailable.\n' >&2
    return 1
  fi
  persisted_admin_accounts=$(docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    exec --no-TTY jenkins sh -c \
      'find /var/jenkins_home/users -mindepth 2 -maxdepth 2 -name config.xml -exec grep -lF "<id>$1</id>" {} + | wc -l' \
      sh "${JENKINS_ADMIN_ID:-admin}")
  if [[ "$persisted_admin_accounts" != "1" ]]; then
    printf 'Expected one persisted Jenkins administrator account, found %s.\n' "$persisted_admin_accounts" >&2
    return 1
  fi
  if docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    logs --no-color jenkins | grep -Fq \
      'Cannot collect disk usage data because plugin CloudBees Disk Usage Simple is not installed'; then
    printf 'Jenkins emitted a known recurring configuration warning.\n' >&2
    return 1
  fi
  if ! docker compose \
    --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" \
    exec --no-TTY jenkins sh -c \
      "grep -Fq '<id>github-token</id>' /var/jenkins_home/credentials.xml && grep -Fq '<id>github-scm</id>' /var/jenkins_home/credentials.xml && grep -Fq '<id>github-registry</id>' /var/jenkins_home/credentials.xml"; then
    printf 'Jenkins managed credentials were not provisioned.\n' >&2
    return 1
  fi
  controller_jobs=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/api/json?tree=jobs[name,_class,jobs[name,_class]]")
  if ! managed_jobs_ready <<< "$controller_jobs"; then
    printf 'Jenkins managed repository job topology is invalid.\n' >&2
    return 1
  fi
  if ! systemctl is-enabled --quiet jenkins-controller-backup.timer || \
    ! systemctl is-active --quiet jenkins-controller-backup.timer; then
    printf 'Jenkins backup timer is not enabled and active.\n' >&2
    return 1
  fi
  if [[ -f "$install_root/current/systemd/jenkins-controller-health.timer" ]]; then
    if ! systemctl is-enabled --quiet jenkins-controller-health.timer || \
      ! systemctl is-active --quiet jenkins-controller-health.timer; then
      printf 'Jenkins health timer is not enabled and active.\n' >&2
      return 1
    fi
    printf 'jenkins_health_timer=ready\n'
  fi
  printf 'jenkins_service=ready\n'
  printf 'jenkins_version=%s\n' "$running_controller_version"
  printf 'jenkins_authentication=ready\n'
  printf 'jenkins_metrics=ready\n'
  printf 'jenkins_security_headers=ready\n'
  printf 'jenkins_resource_root=ready\n'
  printf 'jenkins_known_warnings=clear\n'
  printf 'jenkins_configuration=ready\n'
  printf 'jenkins_jobs=ready\n'
  printf 'jenkins_legacy_jobs=clear\n'
  printf 'jenkins_backup_timer=ready\n'
  printf 'jenkins_verify=ready\n'
}

#==============================================================================
# CONTROLLER BACKUP
#==============================================================================

backup_controller() {
  (
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local archive_staging_path
  local busy_executors
  local controller_container_id=""
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local cookie_jar
  local crumb
  local crumb_field
  local crumb_response
  local attempt

  require_root
  install -d -m 0700 "$backup_directory"
  archive_path="$backup_directory/jenkins-home-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  archive_staging_path="${archive_path}.partial"
  volume_path=$(docker volume inspect jenkins-controller_jenkins-home --format '{{ .Mountpoint }}')
  wait_for_endpoint "$controller_origin/login"
  cookie_jar=$(mktemp)
  chmod 0600 "$cookie_jar"
  trap 'rm -f "$cookie_jar"' EXIT
  crumb_response=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    --cookie "$cookie_jar" \
    --cookie-jar "$cookie_jar" \
    "$controller_origin/crumbIssuer/api/json")
  crumb_field=$(jq -r '.crumbRequestField' <<< "$crumb_response")
  crumb=$(jq -r '.crumb' <<< "$crumb_response")
  if [[ -z "$crumb_field" || "$crumb_field" == "null" || -z "$crumb" || "$crumb" == "null" ]]; then
    printf 'Jenkins did not return a valid CSRF crumb for backup.\n' >&2
    return 1
  fi

  touch "$maintenance_file"
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'if [[ -n "${controller_container_id:-}" ]]; then docker unpause "$controller_container_id" >/dev/null 2>&1 || true; fi; if curl --fail --silent --show-error --connect-timeout 10 --max-time 30 --output /dev/null --request POST --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" --cookie "$cookie_jar" --header "$crumb_field:$crumb" "$controller_origin/cancelQuietDown"; then rm -f "$maintenance_file"; else printf "jenkins_backup_resume=failed maintenance_marker=retained\n" >&2; fi; rm -f "$archive_staging_path" "$cookie_jar"' EXIT
  curl --fail --silent --show-error --connect-timeout 10 --max-time 30 --output /dev/null --request POST \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    --cookie "$cookie_jar" \
    --header "$crumb_field:$crumb" \
    "$controller_origin/quietDown"

  for (( attempt = 1; attempt <= 120; attempt++ )); do
    busy_executors=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
      --cookie "$cookie_jar" \
      "$controller_origin/computer/api/json?tree=busyExecutors" | jq -r '.busyExecutors')
    if [[ "$busy_executors" == "0" ]]; then
      break
    fi
    sleep 5
  done
  if [[ "$busy_executors" != "0" ]]; then
    printf 'Jenkins executors did not become idle before backup.\n' >&2
    return 1
  fi

  controller_container_id=$(docker compose --project-directory "$install_root/current" \
    --file "$install_root/current/compose.yaml" ps --quiet jenkins)
  [[ -n "$controller_container_id" ]]
  docker pause "$controller_container_id" >/dev/null
  tar --create --gzip --file "$archive_staging_path" --directory "$volume_path" .
  docker unpause "$controller_container_id" >/dev/null
  controller_container_id=""
  tar --list --gzip --file "$archive_staging_path" >/dev/null
  chmod 0600 "$archive_staging_path"
  mv "$archive_staging_path" "$archive_path"
  curl --fail --silent --show-error --connect-timeout 10 --max-time 30 --output /dev/null --request POST \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    --cookie "$cookie_jar" \
    --header "$crumb_field:$crumb" \
    "$controller_origin/cancelQuietDown"
  rm -f "$cookie_jar" "$maintenance_file"
  trap - EXIT
  find "$backup_directory" -maxdepth 1 -type f -name 'jenkins-home-*.tar.gz' \
    -mtime "+$backup_retention_days" -delete
  printf 'jenkins_backup_archive=%s\n' "$archive_path"
  printf 'jenkins_backup=ready\n'
  )
}

#==============================================================================
# OFF-HOST BACKUP
#==============================================================================

install_oci_cli() {
  local cli_root=/opt/oci-cli/3.94.0
  local cli_path="$cli_root/bin/oci"
  local installer
  local installer_checksum=079dcc9a3e2a61ec692400e30169c9996b2998ac8c4e205198ed5863283fcb76

  if [[ -x "$cli_path" && "$($cli_path --version 2>&1)" == "3.94.0" ]]; then
    printf '%s\n' "$cli_path"
    return 0
  fi

  installer=$(mktemp)
  trap 'rm -f "$installer"' RETURN
  curl --fail --silent --show-error --location \
    https://raw.githubusercontent.com/oracle/oci-cli/v3.94.0/scripts/install/install.sh \
    --output "$installer"
  printf '%s  %s\n' "$installer_checksum" "$installer" | sha256sum --check --status
  rm -rf "$cli_root"
  bash "$installer" \
    --accept-all-defaults \
    --oci-cli-version 3.94.0 \
    --install-dir "$cli_root/lib" \
    --exec-dir "$cli_root/bin" \
    --script-dir "$cli_root/scripts" >/dev/null
  "$cli_path" --version >/dev/null
  printf '%s\n' "$cli_path"
}

upload_backup_archive() {
  local archive_path="$1"
  local object_prefix="$2"
  local archive_name
  local archive_sha256
  local cli_path
  local metadata
  local namespace
  local object_name
  local verification_archive

  if [[ ! "$backup_bucket" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'JENKINS_BACKUP_BUCKET must identify the managed OCI backup bucket.\n' >&2
    return 1
  fi
  tar --list --gzip --file "$archive_path" >/dev/null
  archive_name=$(basename "$archive_path")
  archive_sha256=$(sha256sum "$archive_path" | awk '{print $1}')
  object_name="$object_prefix/$archive_name"
  cli_path=$(install_oci_cli)
  namespace=$($cli_path os ns get --auth instance_principal --query data --raw-output)
  metadata=$(jq -cn --arg sha256 "$archive_sha256" '{sha256: $sha256}')
  $cli_path os object put \
    --auth instance_principal \
    --namespace-name "$namespace" \
    --bucket-name "$backup_bucket" \
    --name "$object_name" \
    --file "$archive_path" \
    --metadata "$metadata" \
    --force >/dev/null

  verification_archive=$(mktemp "$backup_directory/.jenkins-offsite-verification.XXXXXX.tar.gz")
  trap 'rm -f "$verification_archive"' RETURN
  $cli_path os object get \
    --auth instance_principal \
    --namespace-name "$namespace" \
    --bucket-name "$backup_bucket" \
    --name "$object_name" \
    --file "$verification_archive" >/dev/null
  printf '%s  %s\n' "$archive_sha256" "$verification_archive" | sha256sum --check --status
  tar --list --gzip --file "$verification_archive" >/dev/null
  rm -f "$verification_archive"
  trap - RETURN
  printf 'jenkins_offsite_backup_object=%s\n' "$object_name"
  printf 'jenkins_offsite_backup_sha256=%s\n' "$archive_sha256"
  printf 'jenkins_offsite_backup=ready\n'
}

archive_controller() {
  local archive_output
  local archive_path

  require_root
  install_oci_cli >/dev/null
  archive_output=$(backup_controller)
  printf '%s\n' "$archive_output"
  archive_path=$(sed -n 's/^jenkins_backup_archive=//p' <<< "$archive_output")
  if [[ ! -f "$archive_path" ]]; then
    printf 'Jenkins backup did not produce a managed archive.\n' >&2
    return 1
  fi
  upload_backup_archive "$archive_path" jenkins/verified
  printf 'jenkins_archive=ready\n'
}

#==============================================================================
# PERMANENT CONTROLLER RETIREMENT
#==============================================================================

assert_controller_idle() {
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local busy_executors
  local queued_items

  busy_executors=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/computer/api/json?tree=busyExecutors" | jq -r '.busyExecutors')
  queued_items=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/queue/api/json?tree=items[id]" | jq -r '.items | length')
  if [[ "$busy_executors" != "0" || "$queued_items" != "0" ]]; then
    printf 'Jenkins retirement requires zero busy executors and an empty queue.\n' >&2
    return 1
  fi
  printf 'jenkins_retirement_idle=ready\n'
}

set_controller_scheduling() {
  local endpoint="$1"
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local cookie_jar
  local crumb
  local crumb_field
  local crumb_response

  cookie_jar=$(mktemp)
  chmod 0600 "$cookie_jar"
  trap 'rm -f "$cookie_jar"' RETURN
  crumb_response=$(curl --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    --cookie "$cookie_jar" \
    --cookie-jar "$cookie_jar" \
    "$controller_origin/crumbIssuer/api/json")
  crumb_field=$(jq -r '.crumbRequestField' <<< "$crumb_response")
  crumb=$(jq -r '.crumb' <<< "$crumb_response")
  curl --fail --silent --show-error --output /dev/null --request POST \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    --cookie "$cookie_jar" \
    --header "$crumb_field:$crumb" \
    "$controller_origin/$endpoint"
  rm -f "$cookie_jar"
  trap - RETURN
}

quiet_controller() {
  touch "$maintenance_file"
  set_controller_scheduling quietDown
}

resume_controller() {
  set_controller_scheduling cancelQuietDown
  rm -f "$maintenance_file"
}

retire_controller() {
  local archive_output
  local archive_path
  local compose_file="$install_root/current/compose.yaml"
  local image
  local images=()

  require_root
  if [[ "$retire_confirmation" != "RETIRE-JENKINS" ]]; then
    printf 'JENKINS_RETIRE_CONFIRMATION must equal RETIRE-JENKINS.\n' >&2
    return 1
  fi
  verify_controller || return 1
  assert_controller_idle || return 1
  install_oci_cli >/dev/null || return 1
  while IFS= read -r image; do
    images+=("$image")
  done < <(docker compose --project-directory "$install_root/current" \
    --file "$compose_file" config --images | sort -u)
  archive_output=$(backup_controller) || return 1
  printf '%s\n' "$archive_output"
  archive_path=$(sed -n 's/^jenkins_backup_archive=//p' <<< "$archive_output")
  if [[ ! -f "$archive_path" ]]; then
    printf 'Jenkins retirement backup was not created.\n' >&2
    return 1
  fi
  upload_backup_archive "$archive_path" jenkins/final || return 1

  quiet_controller || return 1
  trap 'resume_controller || true' EXIT
  assert_controller_idle || return 1
  systemctl disable --now jenkins-controller-backup.timer jenkins-controller-health.timer || return 1
  systemctl stop jenkins-controller-backup.service jenkins-controller-health.service || return 1
  systemctl disable --now jenkins-controller.service || return 1
  trap - EXIT
  docker compose --project-directory "$install_root/current" --file "$compose_file" \
    down --volumes --remove-orphans || return 1
  for image in "${images[@]}"; do
    docker image rm --force "$image"
  done
  rm -f \
    /etc/systemd/system/jenkins-controller.service \
    /etc/systemd/system/jenkins-controller-backup.service \
    /etc/systemd/system/jenkins-controller-backup.timer \
    /etc/systemd/system/jenkins-controller-health.service \
    /etc/systemd/system/jenkins-controller-health.timer \
    "$health_failure_file" \
    "$maintenance_file"
  rm -rf "$install_root" "$backup_directory" /opt/oci-cli/3.94.0
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true
  printf 'jenkins_retirement=ready\n'
}

retirement_status() {
  local unexpected_assets=0

  if systemctl is-active --quiet jenkins-controller.service || \
    systemctl is-active --quiet jenkins-controller-backup.timer || \
    systemctl is-active --quiet jenkins-controller-health.timer; then
    printf 'A Jenkins systemd component remains active.\n' >&2
    unexpected_assets=1
  fi
  if [[ -e "$install_root" || -e "$backup_directory" || -e /opt/oci-cli/3.94.0 ]]; then
    printf 'A Jenkins host data directory remains.\n' >&2
    unexpected_assets=1
  fi
  if docker ps --all --quiet --filter label=com.docker.compose.project=jenkins-controller | grep -q . || \
    docker volume ls --quiet --filter label=com.docker.compose.project=jenkins-controller | grep -q . || \
    docker image ls --format '{{.Repository}}' | grep -Eq '^jenkins-(controller|platform-agent)$'; then
    printf 'A Jenkins Docker asset remains.\n' >&2
    unexpected_assets=1
  fi
  if (( unexpected_assets != 0 )); then
    return 1
  fi
  printf 'jenkins_retirement_status=ready\n'
}

#==============================================================================
# CONTROLLER RESTORE
#==============================================================================

restore_controller() {
  local start_log

  require_root
  archive_path="${JENKINS_RESTORE_ARCHIVE:-}"
  if [[ ! "$archive_path" =~ ^${backup_directory}/jenkins-home-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ || ! -f "$archive_path" ]]; then
    printf 'JENKINS_RESTORE_ARCHIVE must identify an existing managed backup.\n' >&2
    exit 1
  fi
  volume_path=$(docker volume inspect jenkins-controller_jenkins-home --format '{{ .Mountpoint }}')
  touch "$maintenance_file"
  systemctl stop jenkins-controller.service
  printf 'jenkins_restore_stop=ready\n'
  start_log=$(mktemp)
  trap 'systemctl start --no-block jenkins-controller.service >/dev/null 2>&1 || true; rm -f "$maintenance_file" "${start_log:-}"' EXIT
  find "$volume_path" -mindepth 1 -delete
  printf 'jenkins_restore_reset=ready\n'
  tar --extract --gzip --file "$archive_path" --directory "$volume_path"
  printf 'jenkins_restore_extract=ready\n'
  if ! systemctl start --no-block jenkins-controller.service > "$start_log" 2>&1; then
    cat "$start_log"
    systemctl status jenkins-controller.service --no-pager 2>&1 | tail -n 40 || true
    journalctl --unit jenkins-controller.service --no-pager --lines 40 2>&1 || true
    show_controller_diagnostics 2>&1
    return 1
  fi
  for _ in {1..45}; do
    if systemctl is-active --quiet jenkins-controller.service ||
      systemctl is-failed --quiet jenkins-controller.service; then
      break
    fi
    sleep 2
  done
  if ! systemctl is-active --quiet jenkins-controller.service; then
    cat "$start_log"
    systemctl status jenkins-controller.service --no-pager 2>&1 | tail -n 40 || true
    journalctl --unit jenkins-controller.service --no-pager --lines 40 2>&1 || true
    show_controller_diagnostics 2>&1
    return 1
  fi
  rm -f "$start_log"
  printf 'jenkins_restore_start=ready\n'
  rm -f "$maintenance_file"
  trap - EXIT
  verify_controller
  printf 'jenkins_restore=ready\n'
}

#==============================================================================
# CONTROLLED RESTORE TEST
#==============================================================================

test_restore_controller() {
  local archive_output
  local archive_path

  archive_output=$(backup_controller)
  printf '%s\n' "$archive_output"
  archive_path=$(sed -n 's/^jenkins_backup_archive=//p' <<< "$archive_output")
  if [[ ! -f "$archive_path" ]]; then
    printf 'Jenkins restore test backup was not created.\n' >&2
    return 1
  fi
  printf 'jenkins_test_restore=ready\n'
  JENKINS_RESTORE_ARCHIVE="$archive_path" restore_controller
  printf 'jenkins_test_restore=ready\n'
}

#==============================================================================
# CONTROLLER HEALTH RECOVERY
#==============================================================================

recover_controller() {
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local failures=0

  require_root
  if [[ -f "$maintenance_file" ]]; then
    rm -f "$health_failure_file"
    printf 'jenkins_health=maintenance\n'
    return 0
  fi
  if curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
    "$controller_origin/login" >/dev/null 2>&1; then
    rm -f "$health_failure_file"
    printf 'jenkins_health=ready\n'
    return 0
  fi

  if [[ -f "$health_failure_file" ]]; then
    failures=$(<"$health_failure_file")
    if [[ ! "$failures" =~ ^[0-9]+$ ]]; then
      failures=0
    fi
  fi
  failures=$((failures + 1))
  printf '%s\n' "$failures" > "$health_failure_file"

  if (( failures < 3 )); then
    printf 'jenkins_health=degraded failure_count=%s\n' "$failures"
    return 0
  fi

  printf 'jenkins_health=restarting failure_count=%s\n' "$failures"
  systemctl restart jenkins-controller.service
  wait_for_endpoint "$controller_origin/login"
  rm -f "$health_failure_file"
  printf 'jenkins_health=recovered\n'
}

#==============================================================================
# CONTROLLER STATUS
#==============================================================================

status_controller() {
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local service_state
  local backup_timer_state
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local health_timer_state
  local running_controller_version

  service_state=$(systemctl is-active jenkins-controller.service || true)
  backup_timer_state=$(systemctl is-active jenkins-controller-backup.timer || true)
  health_timer_state=unavailable
  if [[ -f "$install_root/current/systemd/jenkins-controller-health.timer" ]]; then
    health_timer_state=$(systemctl is-active jenkins-controller-health.timer || true)
  fi

  printf 'jenkins_status=ready\n'
  printf 'jenkins_systemd=%s\n' "$service_state"
  printf 'jenkins_backup_timer=%s\n' "$backup_timer_state"
  printf 'jenkins_health_timer=%s\n' "$health_timer_state"
  running_controller_version=$(curl --connect-timeout 3 --max-time 10 --silent --show-error \
    --dump-header - --output /dev/null "$controller_origin/login" 2>/dev/null | \
    tr -d '\r' | sed -n 's/^X-Jenkins:[[:space:]]*//Ip' | tail -n 1)
  printf 'jenkins_version=%s\n' "${running_controller_version:-unavailable}"
  if [[ -r "$admin_password_file" ]]; then
    curl --connect-timeout 3 --max-time 10 --silent --show-error \
      --output /dev/null \
      --write-out $'jenkins_metrics_http_code=%{http_code}\njenkins_metrics_content_type=%{content_type}\njenkins_metrics_size=%{size_download}\njenkins_metrics_redirect=%{redirect_url}\n' \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
      "$controller_origin/prometheus/" 2>/dev/null || printf 'jenkins_metrics_probe=failed\n'
  else
    printf 'jenkins_metrics_probe=missing_password_file\n'
  fi
  show_controller_diagnostics

  if [[ "$service_state" != "active" || "$backup_timer_state" != "active" || \
    "$health_timer_state" == "inactive" || "$health_timer_state" == "failed" ]]; then
    printf 'Jenkins controller or a managed timer is not active.\n' >&2
    return 1
  fi
}

#==============================================================================
# REPOSITORY VALIDATION SCAN
#==============================================================================

scan_repositories() {
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local cookie_jar
  local crumb
  local crumb_field
  local crumb_response
  local repository
  local repositories=(
    bharath-oci-host-config
    github-pipeline-templates
    jenkins-controller-automation
    jenkins-pipeline-templates
    monitoring-stack-automation
    shared-host-automation
    terraform-oci-modules
    tf-bharath-oci-infra
  )

  require_root
  wait_for_endpoint "$controller_origin/api/json" "$admin_password_file"
  cookie_jar=$(mktemp)
  chmod 0600 "$cookie_jar"
  crumb_response=$(curl --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    --cookie "$cookie_jar" \
    --cookie-jar "$cookie_jar" \
    "$controller_origin/crumbIssuer/api/json")
  crumb_field=$(jq -r '.crumbRequestField' <<< "$crumb_response")
  crumb=$(jq -r '.crumb' <<< "$crumb_response")
  if [[ -z "$crumb_field" || "$crumb_field" == "null" || -z "$crumb" || "$crumb" == "null" ]]; then
    rm -f "$cookie_jar"
    printf 'Jenkins did not return a valid CSRF crumb for repository scans.\n' >&2
    return 1
  fi

  for repository in "${repositories[@]}"; do
    curl --fail --silent --show-error --output /dev/null --request POST \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
      --cookie "$cookie_jar" \
      --header "$crumb_field:$crumb" \
      "$controller_origin/job/$repository/job/validate/build?delay=0sec"
  done
  printf 'jenkins_repository_scans=scheduled\n'

  for repository in "${repositories[@]}"; do
    curl --fail --silent --show-error --output /dev/null --request POST \
      --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
      --cookie "$cookie_jar" \
      --header "$crumb_field:$crumb" \
      "$controller_origin/job/$repository/job/validate/job/main/build?delay=0sec"
  done

  rm -f "$cookie_jar"
  printf 'jenkins_main_builds=scheduled\n'
  printf 'jenkins_scan=ready\n'
}

#==============================================================================
# REPOSITORY VALIDATION DIAGNOSTICS
#==============================================================================

diagnose_validation_jobs() {
  local admin_password_file="$install_root/current/secrets/jenkins-admin-password"
  local controller_origin="http://${JENKINS_BIND_ADDRESS:-127.0.0.1}:8080"
  local diagnostic_branch
  local diagnostic_build
  local diagnostic_console
  local diagnostic_error
  local diagnostic_report
  local diagnostic_repository
  local diagnostic_target
  local controller_jobs
  local controller_queue
  local controller_nodes

  require_root
  wait_for_endpoint "$controller_origin/api/json" "$admin_password_file"
  controller_jobs=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/api/json?tree=jobs[name,jobs[name,jobs[name,lastBuild[number,result,building]]]]")
  controller_queue=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/queue/api/json?tree=items[id]")
  controller_nodes=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/computer/api/json?tree=computer[displayName,offline,executors[currentExecutable[url]]]")

  diagnostic_target=$(jq -r '
    [
      .jobs[] |
      .name as $repository |
      (.jobs[]? | select(.name == "validate")) |
      .jobs[] |
      select(.name == "main" and (.lastBuild.number // 0) > 0) |
      {
        repository: $repository,
        branch: .name,
        build: .lastBuild.number,
        priority: (if .lastBuild.result == "FAILURE" then 0 elif .lastBuild.building then 1 else 2 end)
      }
    ] |
    sort_by(.priority, .repository) |
    (.[0] // {repository: "github-pipeline-templates", branch: "main", build: "lastBuild"}) |
    [.repository, .branch, (.build | tostring)] |
    @tsv
  ' <<< "$controller_jobs")
  IFS=$'\t' read -r diagnostic_repository diagnostic_branch diagnostic_build <<< "$diagnostic_target"
  diagnostic_console=$(curl --globoff --fail --silent --show-error \
    --user "${JENKINS_ADMIN_ID:-admin}:$(<"$admin_password_file")" \
    "$controller_origin/job/$diagnostic_repository/job/validate/job/$diagnostic_branch/$diagnostic_build/consoleText")
  diagnostic_error=$(grep -Ei \
    'curl:|docker:|error response|permission denied|not found|no such file|unable to|failed to|is not latest|must support' \
    <<< "$diagnostic_console" | head -n 2 | cut -c 1-140 || true)
  if [[ -z "$diagnostic_error" ]]; then
    diagnostic_error=$(grep -Ei 'error|exception|exit code|failed|failure' \
      <<< "$diagnostic_console" | head -n 1 | cut -c 1-140 || true)
  fi
  diagnostic_report=$(
    jq -r '
      .computer[] |
      select(.displayName == "platform-agent") |
      "jenkins_platform_agent=" + (if .offline then "offline" else "online" end) +
      " executors=" + (.executors | length | tostring) +
      " busy=" + ([.executors[] | select(.currentExecutable != null)] | length | tostring)
    ' <<< "$controller_nodes"
    printf 'jenkins_queue=%s\n' "$(jq '.items | length' <<< "$controller_queue")"
    jq -r '
      .jobs[] |
      .name as $repository |
      (.jobs[]? | select(.name == "validate")) |
      if ((.jobs // []) | length) == 0 then
        "jenkins_validation=" + $repository + "/unindexed"
      else
        .jobs[] |
        "jenkins_validation=" + $repository + "/" + .name + "#" +
        ((.lastBuild.number // 0) | tostring) + ":" +
        (if (.lastBuild.building // false) then "running" else (.lastBuild.result // "never" | ascii_downcase) end)
      end
    ' <<< "$controller_jobs"
    printf 'jenkins_console=%s/validate/%s#%s\n' "$diagnostic_repository" "$diagnostic_branch" "$diagnostic_build"
    printf '%s\n' "$diagnostic_error"
  )
  printf '%.900s\n' "$diagnostic_report"
  printf 'jenkins_diagnose=ready\n'
}

#==============================================================================
# CONTROLLER ROLLBACK
#==============================================================================

rollback_controller() {
  require_root
  if [[ ! -L "$install_root/previous" ]]; then
    printf 'No previous Jenkins release is available.\n' >&2
    exit 1
  fi
  previous_release=$(readlink -f "$install_root/previous")
  current_release=$(readlink -f "$install_root/current")
  systemctl disable --now jenkins-controller-health.timer >/dev/null 2>&1 || true
  ln -sfn "$previous_release" "$install_root/current"
  ln -sfn "$current_release" "$install_root/previous"

  if [[ -f "$previous_release/systemd/jenkins-controller-health.service" && \
    -f "$previous_release/systemd/jenkins-controller-health.timer" ]]; then
    install -m 0644 "$previous_release/systemd/jenkins-controller-health.service" /etc/systemd/system/jenkins-controller-health.service
    install -m 0644 "$previous_release/systemd/jenkins-controller-health.timer" /etc/systemd/system/jenkins-controller-health.timer
    systemctl daemon-reload
    systemctl enable --now jenkins-controller-health.timer
  else
    rm -f /etc/systemd/system/jenkins-controller-health.service /etc/systemd/system/jenkins-controller-health.timer
    systemctl daemon-reload
  fi

  systemctl restart jenkins-controller.service
  verify_controller
  printf 'jenkins_rollback=ready\n'
}

#==============================================================================
# ACTION ROUTING
#==============================================================================

case "$action" in
  validate)
    validate_controller
    printf 'jenkins_validate=ready\n'
    ;;
  dry-run)
    validate_controller
    printf 'Would deploy release %s to %s.\n' "$release_ref" "$release_path"
    printf 'jenkins_dry_run=ready\n'
    ;;
  deploy|upgrade)
    deploy_controller
    ;;
  verify)
    verify_controller
    ;;
  status)
    status_controller
    ;;
  scan)
    scan_repositories
    ;;
  diagnose)
    diagnose_validation_jobs
    ;;
  recover)
    recover_controller
    ;;
  backup)
    backup_controller
    ;;
  archive)
    archive_controller
    ;;
  restore)
    restore_controller
    ;;
  rollback)
    rollback_controller
    ;;
  test-restore)
    test_restore_controller
    ;;
  retire)
    retire_controller
    ;;
  retirement-status)
    retirement_status
    ;;
  *)
    printf 'Unsupported Jenkins lifecycle action: %s\n' "$action" >&2
    exit 2
    ;;
esac