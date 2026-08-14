# CS2 Server Helm Chart

Reusable Helm chart for deploying a Counter-Strike 2 dedicated server on Kubernetes (ArgoCD friendly).

## Features
- **Auto-Update Watcher**: CronJob checks for game updates and restarts the server if empty.
- **Flexible Secrets**: Support for existing Kubernetes Secrets or Helm-managed ones.
- **Persistent Data**: HostPath mapping for server files and custom content.

## Prerequisites
- Kubernetes cluster
- Helm v3+
- Read/Write access to HostPaths (if using local storage)

## Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Docker image | `ghcr.io/kus/cs2-modded-server` |
| `image.tag` | Image tag | `latest` |
| `service.type` | Service type | `LoadBalancer` |
| `service.port` | Game port (TCP/UDP) | `27015` |
| `secrets.existingSecret` | Name of pre-created secret | `nil` |
| `persistence.dataHostPath` | Path to CS2 game files | `/path/to/local/data-cs2/game/` |
| `nodeSelector` | Pin pod to specific node | `{}` |
| `watcher.enabled` | Enable update checker | `true` |
| `watcher.schedule` | Cron schedule for update check | `*/15 * * * *` |
| `watcher.blindRestartAfterFailures` | Consecutive unreachable-RCON runs before restarting without a player count (`0` disables) | `4` |

## Update Watcher

The CronJob compares the installed build id against Steam's. When they differ it
asks the server over RCON how many humans are connected and only restarts an
empty server.

If RCON cannot be reached it defers and records a counter on the Deployment
(`cs2-watcher/rcon-fail-count`). After `watcher.blindRestartAfterFailures`
consecutive failures it restarts anyway, so a broken RCON does not mean the
server silently stops updating forever. Set the value to `0` to never restart
without a confirmed player count.

It also records `cs2-watcher/last-restart-build`. If it already restarted for a
given build and the install is still behind, the update is failing inside the
pod and it stops restarting rather than kicking players in a loop — check the
server pod log for `Error! App '730' state is 0x6` and
`/home/steam/Steam/logs/content_log.txt`.

### RCON ban penalty

CS2 bans an address for `sv_rcon_banpenalty` minutes after `sv_rcon_maxfailures`
bad auth attempts (default 10). If the watcher has been failing to authenticate,
the running server may still refuse it after a fix until the server pod is
restarted once. Because watcher pod IPs are ephemeral, per-address banning buys
nothing here — `sv_rcon_maxfailures 0` in your `custom_files` boot config
disables it.

## Workshop Collections

Set `env.workshopCollection` and the entrypoint resolves the collection to its
member maps, reads each map's real name out of its VPK, and writes a
`gamemodes_server.txt` mapgroup listing them. That mapgroup — not the collection
subscription — is what populates the end-of-match vote.

Downloads are incremental. Member maps live on the persisted data volume, and
`steamapps/workshop/.cs2_workshop_state.json` records the `time_updated` of each
one, so a restart only fetches maps that are new or have been updated on Steam.
If Steam's API is unreachable the entrypoint keeps what is on disk rather than
refetching everything.

### The server never boots on a workshop map

A CS2 dedicated server cannot start on a `workshop/<id>/<name>` path. Given one
it loads every engine module, reaches its idle frame loop, and then sits there
forever — no level loaded, no socket bound, no error, process still running.

So `env.map` is always a stock map name and is always what the server boots.
Workshop maps enter play through the generated mapgroup's rotation and vote. If
you need the server to jump to a specific workshop map right after boot, set
`env.workshopStartMap` to its publishedfileid; that becomes `+host_workshop_map`
alongside the stock boot map. Setting `env.map` to a workshop path is not an
error — the entrypoint boots a stock map and redirects the id to
`+host_workshop_map`, with a warning in the log.

`+host_workshop_collection` is not passed to the engine by default. Everything
it would do has already happened by then: steamcmd has downloaded every member
and the mapgroup is written. Steam also caps that argument at 100 items and
fails the entire collection above it. `env.passWorkshopCollection: true` restores
it.

### Filtering the collection

A Steam collection is a bookmark list, not a curated rotation — expect other
game modes, asset packs and items named `test` or `doortest`. `env.mapFilter` is
a POSIX ERE matched against each resolved map name; only matches enter the
mapgroup. An arms race server wants `"^ar_"`. `env.maxMapgroupEntries` caps the
result. Both default to off, keeping every member.

The filter runs after the download loop, because a map's real name only exists
once its VPK is on disk. A cold volume still fetches every member regardless of
the filter.

### Startup cost

Two settings will make the server re-verify or refetch its whole ~70 GB install
on every boot. Both default to off and should stay off outside of recovery:

- `env.performValidationOnStart` — runs `app_update 730 validate`, re-hashing
  the entire install each boot.
- `env.removeAppmanifestOnStart` — deletes Steam's record of what is installed,
  forcing a full verify and refetch.

When an update genuinely wedges (`Error! App '730' state is 0x6`), the
entrypoint escalates on its own: validate, then clear the pending download
state, and only then remove the appmanifest.

## Health Probes

All three probes are TCP checks against the game/RCON port, tunable under
`probes` in `values.yaml`. That port is the honest signal: the server opens it
only once it has a level loaded, so a server that never got there fails the
check while still looking perfectly alive to Kubernetes.

They do not self-heal a bad configuration — a restart re-runs the same
entrypoint and reproduces the same failure. What they buy is that the failure
becomes `CrashLoopBackOff`, with Warning events, a climbing restart count and a
`Degraded` ArgoCD app, instead of a pod sitting at `1/1 Running, 0 restarts`
serving nobody.

`probes.startup` allows 40 minutes by default, which covers a warm boot (~3 min)
and a workshop content refresh (~11 min). A first-ever install downloads ~70 GB
and will exceed it — set `probes.startup.enabled: false` for that one boot.

## Secret Management
Create a secret named `cs2-secret` manually:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cs2-secret
  namespace: cs2
type: Opaque
stringData:
  STEAM_ACCOUNT: "your-token"
  API_KEY: "your-key"
  RCON_PASSWORD: "rcon-password"
  SERVER_PASSWORD: "server-password"
```
Then set `secrets.existingSecret: cs2-secret` in `values.yaml`.

## Installation

### Via Helm CLI
```bash
helm install cs2-server . -f values.yaml
```

### Via ArgoCD
1. Add Git Repo to ArgoCD.
2. Create Application pointing to the chart folder.
3. Override `values.yaml` in ArgoCD UI/Manifest.

## CI/CD Pipeline
- **Lint**: Runs on Pull Requests to `templates/`, `values.yaml`, `Chart.yaml` or
  `scripts/`. Runs `helm lint`, plus `bash -n`/`shellcheck` on the shell scripts
  and `py_compile` on the Python helpers — those files ship verbatim inside a
  ConfigMap, so a syntax error there reaches the cluster.
- **Release**: Triggered by tags (e.g., `v1.0.0`). Packages Helm chart and pushes to GHCR as an OCI artifact.

### Using the Published Chart
```bash
helm pull oci://ghcr.io/crosenhain/charts/cs2-server
```
