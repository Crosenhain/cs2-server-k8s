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
| `image.repository` | Docker image | `ghcr.io/joedwards32/cs2` |
| `image.tag` | Image tag | `latest` |
| `service.type` | Service type | `LoadBalancer` |
| `service.port` | Game port (TCP/UDP) | `27015` |
| `secrets.existingSecret` | Name of pre-created secret | `nil` |
| `persistence.dataHostPath` | Path to CS2 game files | `/path/to/local/data-cs2/game/` |
| `nodeSelector` | Pin pod to specific node | `{}` |
| `watcher.enabled` | Enable update checker | `true` |
| `watcher.schedule` | Cron schedule for update check | `*/15 * * * *` |

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
- **Lint**: Runs on Pull Requests to `templates/`, `values.yaml`, or `Chart.yaml`.
- **Release**: Triggered by tags (e.g., `v1.0.0`). Packages Helm chart and pushes to GHCR as an OCI artifact.

### Using the Published Chart
```bash
helm pull oci://ghcr.io/crosenhain/charts/cs2-server
```
