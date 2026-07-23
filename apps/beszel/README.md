# Beszel

Lightweight host monitoring dashboard for the VPS. The hub runs in k3s and the
agent runs directly on the VPS host so it can see real host resources.

```text
https://beszel.tools.nitishsrivastava.dev
```

| Resource   | Name                           |
| ---------- | ------------------------------ |
| Namespace  | `apps`                         |
| Deployment | `beszel` (1 replica, Recreate) |
| Service    | `beszel` (80 -> 8090)          |
| Ingress    | `beszel`                       |
| PVC        | `beszel-data` (5Gi)            |
| Image      | `henrygd/beszel:latest`        |

## Deployment steps

### 1. Deploy the hub

```bash
kubectl apply -f bootstrap/beszel-argocd-app.yaml
```

Sync it in Argo CD, then open:

```text
https://beszel.tools.nitishsrivastava.dev
```

Create the first Beszel account in the web UI.

### 2. Add your VPS as a system

In the Beszel web UI:

1. Create a universal token in `Settings -> Tokens`
2. Add a new system
3. Copy the generated public key shown in the UI

Then run the script in [scripts/install-beszel-agent.sh](/Users/nitish.s/PersonalProjects/my-vps-deployments/scripts/install-beszel-agent.sh:1)
on the VPS host with:

- `--hub-url https://beszel.tools.nitishsrivastava.dev`
- `--token <your token>`
- `--key '<public key from Beszel UI>'`

The script installs the official `beszel-agent` binary and creates a `systemd`
service so the agent survives reboots.

## Things worth knowing

The agent runs on the host rather than as a normal app pod because Beszel's own
docs recommend host-level networking / direct host access for accurate network
and container stats.

The hub persists data in `/beszel_data` on a `local-path` PVC. That PVC is
marked `Prune=false` and `helm.sh/resource-policy: keep`, so deleting the Argo CD
app will not wipe the Beszel database automatically.
