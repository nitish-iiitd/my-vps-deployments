# AdScope

Multi-LLM ad placement recommendation tool. Sends a campaign briefing to Gemini, Groq, and
OpenRouter, and merges the answers into one ranked list of publishers.

```text
https://adscope.projects.nitishsrivastava.dev
```

| Resource   | Name                        |
| ---------- | --------------------------- |
| Namespace  | `apps`                      |
| Deployment | `adscope` (1 replica, Recreate) |
| Service    | `adscope` (80 → 8000)       |
| Ingress    | `adscope`                   |
| Certificate| `adscope-tls`               |
| PVC        | `adscope-data` (1Gi, local-path) |
| Secret     | `adscope-secrets` (manual)  |
| Image      | `nitish2794/adscope:latest` |

## Deployment steps

### 1. Build and push the image

The app repo has no CI yet, so build and push it by hand from the `adscope` project root:

```bash
docker build -t nitish2794/adscope:latest .
docker push nitish2794/adscope:latest
```

The image is `linux/amd64` on the VPS. If you build on an Apple Silicon Mac, cross-build or the
pod will crash-loop with an exec format error:

```bash
docker buildx build --platform linux/amd64 -t nitish2794/adscope:latest --push .
```

### 2. Create the Secret

`adscope-secrets` is **not** in Git and must exist before the first sync. Provider keys are
optional — include only the ones you use, and the app enables just those providers.

```bash
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -

kubectl -n apps create secret generic adscope-secrets \
  --from-literal=app-password='<a strong password>' \
  --from-literal=session-secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')" \
  --from-literal=gemini-api-key='<key or omit>' \
  --from-literal=groq-api-key='<key or omit>' \
  --from-literal=openrouter-api-key='<key or omit>'
```

`app-password` and `session-secret` are required; the pod will not start without them. Changing
`session-secret` logs everyone out.

To rotate a key later:

```bash
kubectl -n apps create secret generic adscope-secrets \
  --from-literal=... --dry-run=client -o yaml | kubectl apply -f -
kubectl -n apps rollout restart deployment/adscope
```

Env vars are read at startup, so a restart is required — Argo CD will not notice a Secret change
on its own.

### 3. Add the DNS A record

```text
A adscope.projects → 15.235.207.142
```

### 4. Deploy

```bash
kubectl apply -f bootstrap/adscope-argocd-app.yaml
```

Then sync in Argo CD and verify:

```bash
curl https://adscope.projects.nitishsrivastava.dev/health
```

Log in with `admin` and the `app-password` you set.

## Things worth knowing

**Single replica, by design.** Campaigns are stored in SQLite on a node-local `local-path`
volume. Only one pod can mount it, so the chart pins `replicas: 1` and uses the `Recreate`
strategy — a rolling update would deadlock waiting for the volume. There is deliberately no
`replicaCount` value: scaling this up would corrupt the database. Moving to Postgres (already in
the cluster) is the prerequisite for running more than one replica.

**Requests are slow and synchronous.** A campaign calls all three models during the HTTP request
and takes roughly 60–90 seconds. That is why `llmTimeoutSeconds` is 120 rather than the app's
default of 60 — OpenRouter's free tier needs about 70s to produce ten recommendations. Traefik
does not time out responses by default, so this works, but it is the first thing to check if
campaigns fail at a suspiciously round number of seconds.

**Data is protected from pruning.** The PVC carries `Prune=false` and `helm.sh/resource-policy:
keep`, so deleting the Argo CD app leaves campaign history intact. Deliberately delete the PVC if
you actually want the data gone.

**Backups.** `local-path` is a directory on the VPS with no redundancy. There is no backup of
campaign history; if that matters, snapshot the volume or move to Postgres.

## Security notes

This is an internal MVP with a single shared username and password, no SSO, no audit trail, and
no login rate limiting. It is fine behind a known-URL subdomain for a small team, but treat the
URL as semi-public: anyone who finds it can attempt logins. Add SSO before wider use — see the
app repo's README for the full list of limitations.
