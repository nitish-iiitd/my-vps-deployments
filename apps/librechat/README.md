# LibreChat

ChatGPT-like UI hosted on the cluster and configured to use OmniRoute as a
custom OpenAI-compatible endpoint.

```text
https://librechat.tools.nitishsrivastava.dev
```

| Resource   | Name                                  |
| ---------- | ------------------------------------- |
| Namespace  | `apps`                                |
| Deployment | `librechat`                           |
| Service    | `librechat` (80 -> 3080)              |
| Ingress    | `librechat`                           |
| PVC        | `librechat-mongodb-data` (10Gi)       |
| MongoDB    | `librechat-mongodb` (internal only)   |
| Secret     | `librechat-secrets` (manual)          |
| Image      | `ghcr.io/danny-avila/librechat:latest`|

## Deployment steps

### 1. Create an OmniRoute endpoint API key

LibreChat uses OmniRoute as a custom endpoint, so create an endpoint API key in:

```text
https://omniroute.tools.nitishsrivastava.dev
```

### 2. Create the Secret

`librechat-secrets` is not in Git and must exist before the first sync.

```bash
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -

kubectl -n apps create secret generic librechat-secrets \
  --from-literal=creds-key="$(openssl rand -hex 32)" \
  --from-literal=creds-iv="$(openssl rand -hex 16)" \
  --from-literal=omniroute-api-key='<your omniroute endpoint api key>'
```

### 3. Add the DNS record

```text
A librechat.tools -> <your VPS public IP>
```

### 4. Deploy

```bash
kubectl apply -f bootstrap/librechat-argocd-app.yaml
```

Then sync in Argo CD and open:

```text
https://librechat.tools.nitishsrivastava.dev
```

The first account you register becomes the admin account. After you create it,
you may want to disable registration by setting `app.allowRegistration: false`.

## Things worth knowing

This chart intentionally skips Meilisearch, RAG, and vector databases so the
stack stays lightweight. That means you get chat first, and can add search or
document features later only if you need them.

MongoDB is internal-only and is not exposed through an Ingress or public
service. Chat history and accounts live there, so the PVC is marked `Prune=false`
and `helm.sh/resource-policy: keep`.
