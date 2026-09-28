<!--
==============================================================================
JENKINS CONTROLLER AUTOMATION
==============================================================================
-->

# Jenkins Controller Automation

Deploy a small Jenkins controller on AMD64 or ARM64 Ubuntu with a pinned container image, Configuration as Code, native Jenkins authentication, Docker-based build tooling, systemd lifecycle management, and explicit recovery operations.

<!--
==============================================================================
CONTROLLER PROFILE
==============================================================================
-->

## Controller Profile

| Setting | Default |
| --- | --- |
| Jenkins | `2.568.2-lts-jdk21` |
| Docker Engine and CLI | `29.8.0` |
| containerd | `2.3.3` |
| Docker Buildx | `0.36.1` |
| Docker Compose | `5.5.1` |
| OCI CLI | `3.94.0` |
| Java heap | 512 MB initial, 1 GB maximum |
| Controller limit | 0.70 CPU and 2 GB memory |
| Platform agent limit | 0.50 CPU and 2 GB memory |
| Controller executors | 0 |
| Platform agent executors | 1 |
| HTTP port | 8080 |
| Resource root URL | `http://jenkins-resources.localhost:8080` |
| Prometheus collection period | 120 seconds |

The controller is designed for the one-OCPU, 6 GB `platform` host. A separate inbound agent container on that host provides one sequential executor. Toolchains run in short-lived Docker containers through the socket mounted only into the agent; the controller has no Docker socket and cannot execute builds.

<!--
==============================================================================
SECURITY MODEL
==============================================================================
-->

## Security Model

- Jenkins' setup wizard is disabled only because JCasC creates the administrator account.
- Anonymous access and user signup are disabled.
- Native Jenkins login remains required behind any identity-aware proxy.
- The administrator password and GitHub token are stored under a root-only host directory and mounted as Docker secrets readable only by the non-root Jenkins container user.
- A one-shot bootstrap container exchanges the administrator credential for the `platform-agent` remoting secret. The long-running agent receives only that remoting secret and runs as UID/GID 1000 with the Docker socket's supplemental group.
- JCasC installs a `github-token` secret-text credential for API operations and a `github-scm` username/token credential for private repository checkout.
- JCasC pins `jenkins-pipeline-templates v1.4.0`, installs the pinned AnsiColor plugin, and creates all production and validation jobs from repository pipeline definitions.
- Jenkins UI Content Security Policy enforcement is enabled through JCasC.
- Workspace and artifact content is isolated on `JENKINS_RESOURCE_ROOT_URL`; production must use a different protected hostname that routes to the same private controller service.
- The legacy `hudson.model.DirectoryBrowserSupport.CSP` override is forbidden so Jenkins retains its default user-content policy and does not raise the resource-root recommendation.
- The HTTP listener should bind to a private address and be published only through authenticated outbound ingress.

The deployment secret is a single-line JSON object supplied by a secret manager:

```json
{"admin_password":"replace-with-strong-password","github_token":"replace-with-token"}
```

Use a fine-grained GitHub token with only the repository metadata, contents, pull request, commit status, and checks permissions required by the managed repositories.

<!--
==============================================================================
VALIDATION AND DRY RUN
==============================================================================
-->

## Validate And Dry Run

These commands do not mutate the host:

```bash
shellcheck scripts/*.sh
bash scripts/validate.sh
bash scripts/manage.sh dry-run
bash scripts/install-docker.sh dry-run
```

Jenkins publishes the required `continuous-integration/jenkins` check. The retained GitHub Actions validation workflow runs on pull requests, `main`, its daily schedule, or manual dispatch. Both validators build the complete controller image, resolving every pinned plugin against the pinned Jenkins core.
It checks Jenkins LTS, every explicit plugin, and the complete Docker package set against official upstream metadata. A daily scheduled run reports version drift while production continues to use immutable tags.

<!--
==============================================================================
VERSIONED DEPLOYMENT
==============================================================================
-->

## Versioned Deployment

`bootstrap.sh` stays below the OCI Run Command 4,096-byte payload limit. It downloads an immutable semantic-version archive, validates it, installs pinned Docker packages only for `deploy`, and invokes the lifecycle manager.

```bash
bash scripts/bootstrap.sh \
  dry-run \
  owner/jenkins-controller-automation \
  v1.0.29 \
  https://jenkins.example.com \
  https://jenkins-resources.example.com \
  10.0.0.20 \
  ""
```

Use `deploy` explicitly and append the secret-manager JSON as the final argument for mutation.

<!--
==============================================================================
LIFECYCLE OPERATIONS
==============================================================================
-->

## Operations

| Action | Mutation | Result |
| --- | --- | --- |
| `validate` | No | Checks pinned images, plugins, JCasC inputs, and Compose |
| `dry-run` | No | Validates and reports the release path |
| `deploy` | Yes | Builds and starts the controller through systemd |
| `upgrade` | Yes | Deploys a new release and retains the prior release |
| `verify` | No | Checks the running core version, zero controller executors, online platform agent, Docker socket isolation, authentication, metrics, UI CSP, resource-domain isolation, persisted administrator uniqueness, known recurring warnings, managed jobs, backup timer, and health watchdog |
| `status` | No | Reports controller version, bounded metrics response metadata, backup timer, health watchdog, and Compose state; exits nonzero for an inactive component |
| `backup` | Yes | Pauses new builds, drains executors, archives `JENKINS_HOME`, and resumes scheduling; the controller stays online |
| `archive` | Yes | Creates a backup, uploads it to the versioned OCI bucket, downloads it, and verifies its SHA-256 and tar contents |
| `restore` | Yes | Restores `JENKINS_RESTORE_ARCHIVE` |
| `rollback` | Yes | Exchanges current and previous releases |
| `test-restore` | Yes | Creates a fresh backup, restores it, and runs comprehensive verification |
| `retire` | Yes | Requires an exact confirmation, verifies an idle controller and off-host backup, then removes every Jenkins service, container, volume, image, secret, release, and local backup |
| `retirement-status` | No | Confirms that no Jenkins systemd, Docker, or host data assets remain |

`jenkins-controller-backup.timer` runs daily at 03:00 with a random delay of up to 15 minutes. Backups are written root-only under `/var/backups/jenkins-controller` and archives older than seven days are removed. The `archive` and `retire` actions upload to the versioned OCI backup bucket with instance-principal authentication and verify a fresh download before reporting success.

## 🧹 Permanent Retirement

Run `test-restore`, then `archive`, before the final retirement workflow. The
`retire` action accepts only `RETIRE-JENKINS`, refuses an active build
or queue, creates a new final off-host archive, and starts deletion only after
downloaded checksum and tar verification pass. Record the emitted object name
and SHA-256, then run `retirement-status` after removal.

Backup HTTP requests have a 10-second connection timeout and a 30-second total timeout. Exit cleanup runs inside the backup subshell, including on archive failure or termination. If scheduling cannot resume, the service reports `jenkins_backup_resume=failed` and retains the maintenance sentinel for investigation. Changed-file archive errors remain failures; partial archives are not promoted to completed backups. Run `bash scripts/test-backup-cleanup.sh` to check isolated success, archive failure, termination, and rejected-resume paths.

On 24 September 2026, the daily backup failed with `tar: .: file changed as we read it`, followed by an exit-trap `admin_password_file: unbound variable` error. After confirming the backup service had stopped and the queue contained only scans and validation jobs, scheduling was resumed through the authenticated Jenkins `cancelQuietDown` endpoint with owner authorisation. Deploy the versioned cleanup fix through the controller pipeline; do not treat the failed archive as a verified backup.

`jenkins-controller-health.timer` runs every minute. After three consecutive failed login-page checks, its watchdog restarts the systemd service and verifies recovery. Deploy, backup, and restore operations create a maintenance sentinel so intentional downtime and extended post-upgrade startup cannot trigger the watchdog.

<!--
==============================================================================
CONFIGURATION AS CODE
==============================================================================
-->

## Configuration As Code

`jcasc/jenkins.yaml` sets the controller to zero executors and creates one permanent inbound node named `platform-agent` with labels `platform docker`. It also controls local authentication, authorization, UI CSP enforcement, the resource root URL, environment defaults, GitHub credentials, the pinned shared library, managed production jobs, and controller URL. Jenkins core provides its default CSRF crumb issuer; the deprecated JCasC `crumbIssuer` section is forbidden because Jenkins 2.555.1 and newer cancel startup when it is present. Change controller configuration in source and redeploy an immutable release; do not edit production settings in the Jenkins UI.

The managed jobs read organised definitions under `.jenkins/pipelines/` in their source repositories. They use the controller's OCI instance principal, resolve immutable automation tags from production JSON, execute remote validation before mutations, and require Jenkins approval for mutating actions. Jenkins controller mutations run in a detached sibling tool container so they survive the controller restart; run the non-mutating `verify` action after Jenkins returns. Monitoring deployment verifies its protected public route in the same pipeline.

The plugin catalogue in `plugins.txt` is explicit and duplicate-checked. Update Jenkins core and plugins together, validate the image build, back up `JENKINS_HOME`, then deploy through `upgrade`.

<!--
==============================================================================
RECOVERY BOUNDARY
==============================================================================
-->

## Recovery Boundary

Jenkins is the primary production pipeline executor, but it cannot be its own only bootstrap mechanism. Preserve the versioned GitHub Actions workflow as an external recovery path that can:

1. Provision or recover the host.
2. Retrieve this repository by immutable tag.
3. Retrieve the secret bundle from a secret manager.
4. Execute `dry-run` and then `deploy` through the cloud remote-command service.

The one-time migration requires the Terraform-managed automation-controller IAM policy before Jenkins can dispatch Run Commands with its instance principal. Emergency manual bootstrap actions must match merged repository code and must be followed by the same verification performed by the managed Jenkins jobs.