# Open WebUI

ChatGPT-like UI hosted on the cluster and preconfigured to talk to OmniRoute.

```text
https://openwebui.tools.nitishsrivastava.dev
```

| Resource    | Name                                      |
| ----------- | ----------------------------------------- |
| Namespace   | `apps`                                    |
| Deployment  | `open-webui` (1 replica, Recreate)        |
| Service     | `open-webui` (80 -> 8080)                 |
| Ingress     | `open-webui`                              |
| Certificate | `open-webui-tls`                          |
| PVC         | `open-webui-data` (10Gi, local-path)      |
| Secret      | `open-webui-secrets` (manual)             |
| Image       | `ghcr.io/open-webui/open-webui:main`      |

## Deployment steps

### 1. Create an OmniRoute endpoint API key

Open OmniRoute and create an endpoint key that Open WebUI will use as its
OpenAI-compatible backend credential.

```text
https://omniroute.tools.nitishsrivastava.dev
```

### 2. Create the Secret

`open-webui-secrets` is not in Git and must exist before the first sync.

```bash
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -

kubectl -n apps create secret generic open-webui-secrets \
  --from-literal=webui-secret-key="$(openssl rand -hex 32)" \
  --from-literal=openai-api-key='<your omniroute endpoint api key>' \
  --from-literal=admin-email='you@example.com' \
  --from-literal=admin-password='<a strong admin password>'
```

### 3. Add the DNS record

```text
A openwebui.tools -> <your VPS public IP>
```

### 4. Deploy

```bash
kubectl apply -f bootstrap/open-webui-argocd-app.yaml
```

Then sync in Argo CD and open:

```text
https://openwebui.tools.nitishsrivastava.dev
```

## Things worth knowing

Open WebUI persists users, chats, and app config in its local database under
`/app/backend/data`. This chart intentionally runs a single replica on `local-path`
storage. If you ever want multiple replicas, move it to Postgres first.

The first boot seeds the OpenAI-compatible connection to OmniRoute via
`OPENAI_API_BASE_URL` and `OPENAI_API_KEY`. These are `ConfigVar` settings in Open
WebUI, which means their initial values are stored in the app database and later
changes are normally best made through the admin UI.

When `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` are set on a fresh install,
Open WebUI creates the admin user automatically on startup. You can still enable
extra signups later from the admin panel if you want more users.
