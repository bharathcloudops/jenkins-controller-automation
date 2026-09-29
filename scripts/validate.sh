#!/usr/bin/env bash

#==============================================================================
# JENKINS CONTROLLER VALIDATION
#==============================================================================

#==============================================================================
# SHELL SAFETY
#==============================================================================

set -euo pipefail

#==============================================================================
# REQUIRED CONTROLLER FILES
#==============================================================================

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
required_files=(
  .jenkins/pipelines/validate.groovy
  Dockerfile
  Dockerfile.agent
  compose.yaml
  plugins.txt
  jcasc/jenkins.yaml
  scripts/agent-entrypoint.sh
  scripts/check-latest-versions.sh
  scripts/test-retirement.sh
  systemd/jenkins-controller-backup.service
  systemd/jenkins-controller-backup.timer
  systemd/jenkins-controller-health.service
  systemd/jenkins-controller-health.timer
  systemd/jenkins-controller.service
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$repository_root/$required_file" ]]; then
    printf 'Missing required file: %s\n' "$required_file" >&2
    exit 1
  fi
done

#==============================================================================
# CONTAINER IMAGE VALIDATION
#==============================================================================

if grep -R --line-number --extended-regexp '(FROM|image:)[[:space:]]+[^[:space:]]+:latest([[:space:]]|$)' \
  "$repository_root/Dockerfile" "$repository_root/Dockerfile.agent" "$repository_root/compose.yaml"; then
  printf 'Container images must use pinned version tags.\n' >&2
  exit 1
fi

if ! grep -Fq 'USER jenkins' "$repository_root/Dockerfile" || \
  ! grep -Fq 'chown 1000:1000 ' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'chmod 0400 ' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'secrets/jenkins-admin-password' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'secrets/github-token' "$repository_root/scripts/manage.sh"; then
  printf 'Root-managed Jenkins secret files must be readable only by container UID 1000.\n' >&2
  exit 1
fi

if ! grep -Fq 'COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-buildx' \
  "$repository_root/Dockerfile.agent" || \
  ! grep -Fq 'jq=1.7.1-6+deb13u4' "$repository_root/Dockerfile.agent" || \
  ! grep -Fq 'rm -rf /var/lib/apt/lists/*' "$repository_root/Dockerfile.agent"; then
  printf 'The platform agent must include Buildx and pinned jq with package metadata cleanup.\n' >&2
  exit 1
fi

if ! grep -Fq 'export HOME=/home/jenkins' "$repository_root/scripts/agent-entrypoint.sh"; then
  printf 'The platform agent must use the Jenkins home after dropping root privileges.\n' >&2
  exit 1
fi

if ! grep -Fq "chown -R 1000:1000 \"\$agent_workdir\"" "$repository_root/scripts/agent-entrypoint.sh"; then
  printf 'The platform agent must restore persistent workspace ownership before startup.\n' >&2
  exit 1
fi

#==============================================================================
# PLUGIN CATALOGUE VALIDATION
#==============================================================================

if ! awk -F: '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  NF != 2 || $1 !~ /^[a-z0-9-]+$/ || $2 !~ /^[A-Za-z0-9._-]+$/ { invalid = 1 }
  END { exit invalid }
' "$repository_root/plugins.txt"; then
  printf 'Every Jenkins plugin must use an explicit version.\n' >&2
  exit 1
fi

if [[ "$(grep -vE '^[[:space:]]*(#|$)' "$repository_root/plugins.txt" | cut -d: -f1 | sort | uniq -d | wc -l | tr -d ' ')" != "0" ]]; then
  printf 'Duplicate Jenkins plugin identifiers are not allowed.\n' >&2
  exit 1
fi

#==============================================================================
# CONTROLLER AND AGENT ISOLATION VALIDATION
#==============================================================================

if ! grep -Fq 'numExecutors: 0' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'name: platform-agent' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'numExecutors: 1' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'labelString: platform docker' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq '.displayName == "platform-agent" and .numExecutors == 1 and .offline == false' "$repository_root/scripts/manage.sh"; then
  printf 'Build execution must use the single platform Docker agent, not the controller.\n' >&2
  exit 1
fi

controller_compose=$(sed -n '/^[[:space:]]*jenkins:/,/^[[:space:]]*platform-agent:/p' "$repository_root/compose.yaml")
agent_compose=$(sed -n '/^[[:space:]]*platform-agent:/,/^secrets:/p' "$repository_root/compose.yaml")
if grep -Fq '/var/run/docker.sock' <<< "$controller_compose" || \
  ! grep -Fq '/var/run/docker.sock' <<< "$agent_compose" || \
  ! grep -Fq 'cpus: "0.50"' <<< "$agent_compose" || \
  ! grep -Fq 'memory: 2048M' <<< "$agent_compose" || \
  ! grep -Fq -- "--groups \"\$docker_socket_gid\"" "$repository_root/scripts/agent-entrypoint.sh" || \
  ! grep -Fq -- '--reuid 1000' "$repository_root/scripts/agent-entrypoint.sh"; then
  printf 'Docker access and constrained resources must belong only to the platform agent.\n' >&2
  exit 1
fi

if grep -Fq 'hudson.model.DirectoryBrowserSupport.CSP=' "$repository_root/compose.yaml" || \
  ! grep -Fq 'JENKINS_RESOURCE_ROOT_URL:' "$repository_root/compose.yaml" || \
  ! grep -Fq 'contentSecurityPolicy:' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'enforce: true' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'resourceRoot:' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq "url: \${JENKINS_RESOURCE_ROOT_URL}" "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'COLLECTING_METRICS_PERIOD_IN_SECONDS: "120"' "$repository_root/compose.yaml" || \
  ! grep -Eq '^ansicolor:[A-Za-z0-9._-]+$' "$repository_root/plugins.txt" || \
  ! grep -Eq '^cloudbees-disk-usage-simple:[A-Za-z0-9._-]+$' "$repository_root/plugins.txt" || \
  ! grep -Eq '^github-branch-source:[A-Za-z0-9._-]+$' "$repository_root/plugins.txt" || \
  ! grep -Eq '^pipeline-stage-view:[A-Za-z0-9._-]+$' "$repository_root/plugins.txt"; then
  printf 'Jenkins UI CSP, resource isolation, stage visualization, disk metrics, and ANSI rendering must be explicitly configured.\n' >&2
  exit 1
fi

#==============================================================================
# SECRET BUNDLE VALIDATION
#==============================================================================

valid_secret_bundle='{"admin_password":"0123456789abcdef","github_token":"github-token-at-least-twenty","registry_token":"registry-token-at-least-twenty"}'
invalid_secret_bundle='{"admin_password":"short","github_token":"short","registry_token":"short"}'
secret_filter='
  type == "object" and
  (.admin_password | type == "string" and length >= 16 and (contains("\n") | not)) and
  (.github_token | type == "string" and length >= 20 and (contains("\n") | not)) and
  (.registry_token | type == "string" and length >= 20 and (contains("\n") | not))
'

jq -e "$secret_filter" <<< "$valid_secret_bundle" >/dev/null
if jq -e "$secret_filter" <<< "$invalid_secret_bundle" >/dev/null; then
  printf 'Invalid Jenkins secret bundle was accepted.\n' >&2
  exit 1
fi

#==============================================================================
# DOCKER COMPOSE VALIDATION
#==============================================================================

if docker compose version >/dev/null 2>&1; then
  temporary_directory=$(mktemp -d)
  trap 'rm -rf "$temporary_directory"' EXIT
  printf 'validation-only\n' > "$temporary_directory/admin"
  printf 'validation-only\n' > "$temporary_directory/github"
  printf 'validation-only\n' > "$temporary_directory/registry"
  JENKINS_ADMIN_PASSWORD_FILE="$temporary_directory/admin" \
  GITHUB_REGISTRY_TOKEN_FILE="$temporary_directory/registry" \
  GITHUB_TOKEN_FILE="$temporary_directory/github" \
    docker compose --file "$repository_root/compose.yaml" config --quiet
fi

#==============================================================================
# MANAGED BACKUP VALIDATION
#==============================================================================

bash "$repository_root/scripts/test-backup-cleanup.sh"
bash "$repository_root/scripts/test-retirement.sh"

if ! grep -Fq 'jenkins-controller-backup.timer' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'JENKINS_BACKUP_RETENTION_DAYS' "$repository_root/scripts/manage.sh"; then
  printf 'Jenkins backup scheduling and retention must be managed in versioned automation.\n' >&2
  exit 1
fi

if ! grep -Fq 'RETIRE-JENKINS' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins/final' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq -- '--auth instance_principal' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'sha256sum --check --status' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'tar --list --gzip' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'down --volumes --remove-orphans' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "printf 'jenkins_retirement_status=ready" "$repository_root/scripts/manage.sh"; then
  printf 'Permanent retirement must verify an off-host backup before deleting every Jenkins runtime asset.\n' >&2
  exit 1
fi

backup_function=$(sed -n '/backup_controller()/,/^}/p' "$repository_root/scripts/manage.sh")
if grep -Fq 'systemctl stop jenkins-controller.service' <<< "$backup_function" || \
  ! grep -Fq 'quietDown' <<< "$backup_function" || \
  ! grep -Fq 'cancelQuietDown' <<< "$backup_function" || \
  ! grep -Fq "docker pause \"\$controller_container_id\"" <<< "$backup_function" || \
  ! grep -Fq "docker unpause \"\$controller_container_id\"" <<< "$backup_function" || \
  ! grep -Fq "tar --list --gzip --file \"\$archive_staging_path\"" <<< "$backup_function" || \
  ! grep -Fq "cookie_jar=\$(mktemp)" <<< "$backup_function" || \
  ! grep -Fq -- "--cookie \"\$cookie_jar\"" <<< "$backup_function" || \
  ! grep -Fq -- "--cookie-jar \"\$cookie_jar\"" <<< "$backup_function" || \
  ! grep -Fq '.partial' <<< "$backup_function" || \
  ! grep -Fq 'EnvironmentFile=/opt/jenkins-controller/current/.env' "$repository_root/systemd/jenkins-controller-backup.service"; then
  printf 'Scheduled backups must remain online, preserve the CSRF session, drain executors, and publish archives atomically.\n' >&2
  exit 1
fi

if ! grep -Fq 'systemctl reload-or-restart jenkins-controller.service' "$repository_root/scripts/manage.sh"; then
  printf 'Deployment must reconcile Jenkins without stopping an unchanged container.\n' >&2
  exit 1
fi

if ! grep -Fq 'deployment.sha256' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "printf 'jenkins_deploy=unchanged" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "dpkg-query --show --showformat='\${Version}' docker-ce" "$repository_root/scripts/install-docker.sh" || \
  ! grep -Fq "printf 'docker_install=unchanged" "$repository_root/scripts/install-docker.sh"; then
  printf 'Jenkins deployments must skip unchanged healthy state and matching Docker packages.\n' >&2
  exit 1
fi

if ! grep -Fq "printf 'jenkins_restore_extract=ready" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'journalctl --unit jenkins-controller.service' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'systemctl status jenkins-controller.service' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'systemctl start --no-block jenkins-controller.service' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'for _ in {1..45}' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'systemctl is-failed --quiet jenkins-controller.service' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'show_controller_diagnostics' "$repository_root/scripts/manage.sh"; then
  printf 'Restore failures must identify the completed phase and report controller diagnostics.\n' >&2
  exit 1
fi

if ! grep -Fq 'systemctl enable --now jenkins-controller-health.timer' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'failures < 3' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins-controller-maintenance' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'systemctl restart jenkins-controller.service' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'EnvironmentFile=/opt/jenkins-controller/current/.env' "$repository_root/systemd/jenkins-controller-health.service" || \
  ! grep -Fq 'OnUnitInactiveSec=1m' "$repository_root/systemd/jenkins-controller-health.timer" || \
  grep -Fq 'Requires=jenkins-controller.service' "$repository_root/systemd/jenkins-controller-health.service"; then
  printf 'Jenkins health recovery must use a managed timer and consecutive failure threshold.\n' >&2
  exit 1
fi

if grep -Fq 'Requires=jenkins-controller.service' "$repository_root/systemd/jenkins-controller-backup.service"; then
  printf 'Jenkins backup must not be lifecycle-coupled to the controller service.\n' >&2
  exit 1
fi

if ! grep -Fq 'service_state" != "active' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'backup_timer_state" != "active' "$repository_root/scripts/manage.sh"; then
  printf 'Jenkins status must fail when the controller or backup timer is inactive.\n' >&2
  exit 1
fi

#==============================================================================
# OCI OUTPUT BUDGET VALIDATION
#==============================================================================

if ! grep -Fq 'apt-get update >/dev/null' "$repository_root/scripts/install-docker.sh" || \
  ! grep -Fq 'docker version >/dev/null' "$repository_root/scripts/install-docker.sh" || \
  ! grep -Fq 'docker compose version >/dev/null' "$repository_root/scripts/install-docker.sh" || \
  grep -Fq "printf 'jenkins_deploy=ready" "$repository_root/scripts/bootstrap.sh" || \
  ! grep -Fq "validation_output=\$(bash" "$repository_root/scripts/manage.sh"; then
  printf 'Routine installer output must remain quiet so OCI retains diagnostics.\n' >&2
  exit 1
fi

#==============================================================================
# OCI BOOTSTRAP PAYLOAD VALIDATION
#==============================================================================

sample_arguments=$(jq -cn '[
  "deploy",
  "bharathcloudops/jenkins-controller-automation",
  "v1.0.7",
  "https://jenkins.bharathcloudops.com",
  "https://jenkins-resources.bharathcloudops.com",
  "10.10.10.68",
  "bharathcloudops-prd-hyd-backups|RETIRE-JENKINS",
  "{\"admin_password\":\"AAAAAAAAAAAAAAAAAAAAAAAA\",\"github_token\":\"github-token-at-least-twenty\",\"registry_token\":\"registry-token-at-least-twenty\"}"
]')
argument_line=$(jq -r '[.[] | @sh] | "set -- " + join(" ")' <<< "$sample_arguments")
rendered_size=$(printf '%s\n%s' "$argument_line" "$(cat "$repository_root/scripts/bootstrap.sh")" | wc -c | tr -d ' ')
if (( rendered_size > 4096 )); then
  printf 'Rendered Jenkins bootstrap exceeds the OCI 4096-byte inline limit.\n' >&2
  exit 1
fi

#==============================================================================
# COMPREHENSIVE VERIFICATION VALIDATION
#==============================================================================

if grep -Eq '^[[:space:]]*(crumbIssuer:|excludeClientIPFromCrumb:)' \
  "$repository_root/jcasc/jenkins.yaml"; then
  printf 'Jenkins 2.555.1 and newer reject the deprecated JCasC crumbIssuer configuration.\n' >&2
  exit 1
fi

if ! grep -Fq 'defaultVersion: v1.5.0' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'credentials('"'"'github-scm'"'"')' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'id: github-registry' "$repository_root/jcasc/jenkins.yaml"; then
  printf 'JCasC must provision the pinned shared library and managed production jobs.\n' >&2
  exit 1
fi

for managed_repository in \
  bharath-oci-host-config \
  github-pipeline-templates \
  ignitox-wordpress \
  jenkins-controller-automation \
  jenkins-pipeline-templates \
  monitoring-stack-automation \
  shared-host-automation \
  terraform-oci-modules \
  tf-bharath-oci-infra \
  wordpress-kubernetes-automation; do
  if ! grep -Fq "[name: '$managed_repository'" "$repository_root/jcasc/jenkins.yaml"; then
    printf 'Missing repository-managed Jenkins folder: %s\n' "$managed_repository" >&2
    exit 1
  fi
done

for managed_job in \
  bharath-oci-host-config/configure-jenkins \
  bharath-oci-host-config/configure-monitoring \
  bharath-oci-host-config/operate-host-network \
  bharath-oci-host-config/operate-ingress-connector \
  tf-bharath-oci-infra/operate-infrastructure \
  ignitox-wordpress/publish-image \
  ignitox-wordpress/deploy-wordpress \
  jenkins-controller-automation/scheduled-validation \
  monitoring-stack-automation/scheduled-validation; do
  if ! grep -Fq "pipelineJob('$managed_job')" "$repository_root/jcasc/jenkins.yaml"; then
    printf 'Missing repository-managed Jenkins job: %s\n' "$managed_job" >&2
    exit 1
  fi
done

if ! grep -Fq "multibranchPipelineJob(repositoryConfig.name + '/validate')" "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq "includes('main PR-*')" "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'buildOriginBranchWithPR(false)' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'buildOriginPRHead(true)' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'buildOriginPRMerge(false)' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'buildForkPRHead(false)' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'buildForkPRMerge(false)' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq "interval('5m')" "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq 'numToKeep(20)' "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq "spec('17 3 * * *')" "$repository_root/jcasc/jenkins.yaml" || \
  ! grep -Fq "spec('29 3 * * *')" "$repository_root/jcasc/jenkins.yaml"; then
  printf 'Multibranch validation must use controlled origin PR discovery and scheduled polling.\n' >&2
  exit 1
fi

if grep -Eq "pipelineJob\\('(configure-production|operate-production|validate-(github|jenkins|shared|terraform))" \
  "$repository_root/jcasc/jenkins.yaml"; then
  printf 'Legacy flat Jenkins jobs must not remain in managed configuration.\n' >&2
  exit 1
fi

for pipeline_path in \
  .jenkins/pipelines/jenkins-controller.groovy \
  .jenkins/pipelines/monitoring-stack.groovy \
  .jenkins/pipelines/host-network.groovy \
  .jenkins/pipelines/ingress-connector.groovy \
  .jenkins/pipelines/publish.groovy \
  .jenkins/pipelines/production-infrastructure.groovy \
  .jenkins/pipelines/wordpress.groovy \
  .jenkins/pipelines/validate.groovy; do
  if ! grep -Fq "scriptPath('$pipeline_path')" "$repository_root/jcasc/jenkins.yaml"; then
    printf 'Missing organized Jenkins pipeline path: %s\n' "$pipeline_path" >&2
    exit 1
  fi
done

for readiness_marker in \
  jenkins_service=ready \
  jenkins_authentication=ready \
  jenkins_metrics=ready \
  jenkins_security_headers=ready \
  jenkins_resource_root=ready \
  jenkins_known_warnings=clear \
  jenkins_configuration=ready \
  jenkins_jobs=ready \
  jenkins_job_activation=ready \
  jenkins_legacy_jobs=clear \
  jenkins_backup_timer=ready \
  jenkins_health_timer=ready; do
  if ! grep -Fq "$readiness_marker" "$repository_root/scripts/manage.sh"; then
    printf 'Missing Jenkins verification marker: %s\n' "$readiness_marker" >&2
    exit 1
  fi
done

if ! grep -Fq -- '--user ' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'admin_password_file' "$repository_root/scripts/manage.sh" || \
  ! grep -F 'local controller_origin=' "$repository_root/scripts/manage.sh" | \
    grep -Fq 'JENKINS_BIND_ADDRESS'; then
  printf 'Protected Jenkins metrics must use the managed administrator credential.\n' >&2
  exit 1
fi

if ! grep -Fq 'controller_origin/prometheus/' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'application/openmetrics-text' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq '%{size_download}' "$repository_root/scripts/manage.sh" || \
  ! grep -F 'wait_for_metrics ' "$repository_root/scripts/manage.sh" | \
    grep -Fq 'controller_origin/prometheus/'; then
  printf 'Jenkins metrics verification must validate non-empty Prometheus content.\n' >&2
  exit 1
fi

if ! grep -Fq 'wait_for_agent_nodes()' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'controller_origin/computer/api/json' "$repository_root/scripts/manage.sh"; then
  printf 'Jenkins verification must wait for the platform agent topology.\n' >&2
  exit 1
fi

if ! sed -n '/test_restore_controller()/,/^}/p' "$repository_root/scripts/manage.sh" | \
  grep -Fq 'tail -c 700'; then
  printf 'Jenkins restore tests must retain bounded failure diagnostics.\n' >&2
  exit 1
fi

if ! sed -n '/upload_backup_archive()/,/^}/p' "$repository_root/scripts/manage.sh" | \
  grep -Fq 'transfer_output='; then
  printf 'Jenkins archive transfers must suppress progress and retain bounded failures.\n' >&2
  exit 1
fi

if ! grep -Fq 'X-Jenkins:' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_version=%s' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'journalctl --unit jenkins-controller.service' "$repository_root/scripts/manage.sh"; then
  printf 'Deployment must report build diagnostics and verify the running Jenkins version.\n' >&2
  exit 1
fi

if ! sed -n '/deploy_controller()/,/^}/p' "$repository_root/scripts/manage.sh" | \
  grep -Fq "touch \"\$maintenance_file\"" || \
  ! sed -n '/deploy_controller()/,/^}/p' "$repository_root/scripts/manage.sh" | \
    grep -Fq 'systemctl stop jenkins-controller-health.timer' || \
  ! sed -n '/deploy_controller()/,/^}/p' "$repository_root/scripts/manage.sh" | \
    grep -Fq "trap 'rm -f \"\$maintenance_file\"' EXIT"; then
  printf 'Deployment must suppress watchdog recovery until verification completes.\n' >&2
  exit 1
fi

if ! grep -Fq 'managed_jobs_ready()' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'activate_managed_jobs' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_job_activation=restart_required' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'New Jenkins job topology did not activate after the bounded restart.' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'reconcile_legacy_jobs' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'New Jenkins job topology is incomplete; legacy jobs will not be removed.' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_legacy_jobs=clear' "$repository_root/scripts/manage.sh"; then
  printf 'Folder migration must activate and validate the new topology before removing legacy jobs.\n' >&2
  exit 1
fi

if ! grep -Fq 'scan_repositories()' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_repository_scans=scheduled' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_main_builds=scheduled' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_scan=ready' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'job/validate/build?delay=0sec' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'job/validate/job/main/build?delay=0sec' "$repository_root/scripts/manage.sh"; then
  printf 'Repository scan lifecycle validation failed.\n' >&2
  exit 1
fi

if ! grep -Fq 'diagnose_validation_jobs()' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_platform_agent=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_queue=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_validation=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'priority: (if .lastBuild.result == "FAILURE" then 0' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "'curl:|docker:|error response|permission denied|not found|no such file|unable to|failed to|is not latest|must support'" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "printf '%.900s\\n' \"\$diagnostic_report\"" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_diagnose=ready' "$repository_root/scripts/manage.sh"; then
  printf 'Repository validation diagnostic checks failed.\n' >&2
  exit 1
fi

if ! grep -Fq 'jenkins_metrics_http_code=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_metrics_content_type=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_metrics_size=' "$repository_root/scripts/manage.sh" || \
  ! grep -Fq -- '--max-time 10' "$repository_root/scripts/manage.sh"; then
  printf 'Status must report bounded Jenkins metrics response diagnostics.\n' >&2
  exit 1
fi

if ! grep -Fq "printf 'jenkins_validate=ready" "$repository_root/scripts/manage.sh" || \
  (( $(grep -Fc "printf 'jenkins_deploy=ready" "$repository_root/scripts/manage.sh") < 2 )) || \
  [[ "$(grep -Fc "printf 'jenkins_test_restore=ready" "$repository_root/scripts/manage.sh")" != "2" ]] || \
  ! grep -Fq "archive_output=\$(backup_controller)" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq "archive_path=\$(sed -n 's/^jenkins_backup_archive=//p' <<< \"\$archive_output\")" "$repository_root/scripts/manage.sh" || \
  ! grep -Fq 'jenkins_metrics_wait=attempt_' "$repository_root/scripts/manage.sh"; then
  printf 'Long Jenkins lifecycle actions must retain required markers and bounded progress output.\n' >&2
  exit 1
fi

#==============================================================================
# VALIDATION RESULT
#==============================================================================

bash "$repository_root/scripts/test-job-topology.sh"
printf 'jenkins_validation=ready\n'