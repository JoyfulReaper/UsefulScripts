# Useful Scripts

Useful Scripts contains small administration helpers and the Docker Compose
configuration used for the services on the JoyfulReaper VPS. It is deployment
configuration, not a source-of-truth repository for the applications it runs.

## Repository layout

| Path | Purpose |
| --- | --- |
| `VPS/docker-compose.yaml` | Production-oriented Compose model for the VPS service stack. |
| `VPS/<application>/` | Dockerfiles, NuGet configuration, and build-context support files staged for individual applications. |
| `VPS/Beszel/compose.yaml` | Separate Beszel deployment configuration. |
| `bash/memory.sh` | Linux host, systemd service, container, memory, and disk usage snapshot. |
| `powershell/iis_error_search.ps1` | Searches application logs and parsed IIS W3C logs for recent errors. |

Application source and deployment-only files may be supplied to the VPS build
contexts separately. Confirm each referenced Dockerfile and source tree is
present before building.

## VPS stack

`VPS/docker-compose.yaml` defines these services:

- RabbitMQ, MissionControl Gateway, Archive, GitActivity, and Dashboard
- HappyQOTD, HappyDaytime, HappyEcho, HappyFinger, and HappyGopher
- RandomSteamGame
- ntfy

Services on the `backend` network communicate by Compose service name. Several
host ports bind only to `127.0.0.1`; any public routing or TLS termination is
managed outside this repository. Some protocol services intentionally use host
networking or bind their protocol ports directly.

Persistent named volumes hold RabbitMQ, Archive, GitActivity, and Dashboard
state. Additional bind mounts under `/var/lib` hold application-specific data.
Back up persistent application data before destructive deployment changes.

## Configuration

Run Compose from the `VPS` directory. The checked-in `VPS/.env` is an empty
variable-name template. Supply real values through a deployment-local copy, the
shell environment, or the deployment secret store, and never commit populated
credentials.

The main Compose model references these variables:

```text
DASHBOARD_MOBILE_API_TOKEN_HASH
GITACTIVITY_API_KEY
GITHUB_WEBHOOK_SECRET
HAPPYDAYTIME_MISSION_CONTROL_KEY
HAPPYECHO_MISSION_CONTROL_KEY
HAPPYFINGER_MISSION_CONTROL_KEY
HAPPYGOPHER_MISSION_CONTROL_KEY
HAPPYQOTD_ADMIN_API_KEY
HAPPYQOTD_MISSION_CONTROL_KEY
KGIVLER_API_MISSION_CONTROL_KEY
MISSIONCONTROL_AGENT_MISSION_CONTROL_KEY
MISSIONCONTROL_DASHBOARD_MISSION_CONTROL_KEY
RABBITMQ_PASSWORD
RABBITMQ_USER
RANDOMSTEAM_COMMIT_SHA
RANDOMSTEAM_IMAGE_TAG
RANDOMSTEAM_MISSION_CONTROL_KEY
RANDOMSTEAM_STEAM_API_KEY
```

The Dashboard reaches GitActivity through the private Compose network at
`http://gitactivity:8080/` and reuses `GITACTIVITY_API_KEY` server-side. Mobile
clients authenticate to the Dashboard Mobile API with their existing bearer
token; they never receive the GitActivity key. An independently configured,
API-key-protected public GitActivity route may remain available to other trusted
server-side consumers.

## Validate and deploy

From `VPS`:

```bash
docker compose config --quiet
docker compose build
docker compose up -d
docker compose ps
```

Inspect a service without dumping the resolved Compose configuration, which may
contain secrets:

```bash
docker compose logs --tail=100 dashboard
docker compose logs --tail=100 gitactivity
```

Avoid sharing the output of `docker compose config` without `--quiet`; Compose
interpolates environment values into that output.

## Utility scripts

On the Linux host, run the resource summary from the repository root:

```bash
bash bash/memory.sh
```

The script samples overall CPU usage, selected systemd services, Docker
containers, system memory, and the primary disk. Adjust its `services` array and
disk path when the host layout changes.

Run the IIS/application error search from PowerShell:

```powershell
.\powershell\iis_error_search.ps1
.\powershell\iis_error_search.ps1 -NewestFilesOnly -NewestFileCount 5 -Last 50
```

Use `-AppLogPaths`, `-IisLogPaths`, `-AppPatterns`, and `-IisStatusCodes` to
override the defaults.

## Security notes

- Keep `.env`, API keys, bearer tokens, signing material, and database files out
  of source control.
- Keep RabbitMQ and application databases on private networks and persistent
  storage.
- Treat reverse-proxy and tunnel configuration as part of the security boundary.
- Rotate a compromised credential in both its producer and consumer
  configuration.
- Review image tags and configuration diffs before every deployment.

## License

This repository is licensed under the [MIT License](LICENSE).
