# OmniRoute

Self-hosted LLM router and dashboard.

```text
https://omniroute.tools.nitishsrivastava.dev
```

| Resource    | Name                                  |
| ----------- | ------------------------------------- |
| Namespace   | `apps`                                |
| Deployment  | `omniroute` (1 replica, Recreate)     |
| Service     | `omniroute` (80 -> 20128)             |
| Ingress     | `omniroute`                           |
| Certificate | `omniroute-tls`                       |
| PVC         | `omniroute-data` (5Gi, local-path)    |
| Secret      | `omniroute-secrets` (manual)          |
| Image       | `diegosouzapw/omniroute:latest`       |

## Deployment steps

### 1. Create the Secret

`omniroute-secrets` is not in Git and must exist before the first sync.

```bash
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -

kubectl -n apps create secret generic omniroute-secrets \
  --from-literal=jwt-secret="$(openssl rand -hex 32)" \
  --from-literal=initial-password='<a strong password>' \
  --from-literal=api-key-secret="$(openssl rand -hex 32)" \
  --from-literal=storage-encryption-key="$(openssl rand -hex 32)" \
  --from-literal=storage-encryption-key-version='v1' \
  --from-literal=machine-id-salt="$(openssl rand -hex 32)"
```

To rotate a secret later:

```bash
kubectl -n apps create secret generic omniroute-secrets \
  --from-literal=... --dry-run=client -o yaml | kubectl apply -f -
kubectl -n apps rollout restart deployment/omniroute
```

### 2. Add the DNS record

```text
A omniroute.tools -> <your VPS public IP>
```

### 3. Deploy

```bash
kubectl apply -f bootstrap/omniroute-argocd-app.yaml
```

Then sync in Argo CD and open:

```text
https://omniroute.tools.nitishsrivastava.dev
```

Log in with the `initial-password` from the Secret, connect providers in the
dashboard, and create an endpoint API key for your clients.

## Things worth knowing

Single replica is intentional. OmniRoute uses SQLite in `/app/data`, backed by a
ReadWriteOnce `local-path` volume, so only one pod should mount it at a time.
That is why the chart uses `Recreate` rather than a rolling update.

The PVC is marked `Prune=false` and `helm.sh/resource-policy: keep`, so deleting
the Argo CD app will not remove the OmniRoute data automatically.

This chart keeps OmniRoute's management UI open behind its login screen and does
not force API keys on `/v1/*` by default. If you want to require bearer keys for
all API traffic, set `app.requireApiKey: true` in `values.yaml`.
