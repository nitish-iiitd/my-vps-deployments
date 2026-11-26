# vps32gb cluster

Everything running on vps32gb is defined in this folder. Argo CD watches it and applies
changes within ~3 minutes of a push to `main`.

The server itself (OS, firewall, k3s, Argo CD) is set up by the **vps-manager** repo (Ansible).

```
clusters/vps32gb/
├── argocd/       Argo CD apps: cert-manager, sealed-secrets, cloudnative-pg, platform, databases, "apps" ApplicationSet
├── databases/    the shared Postgres server, its users and databases
├── platform/     Let's Encrypt issuer, Argo CD's web address
├── apps/<name>/values.yaml   one folder per app
└── sealed-secrets-cert.pem   public key for encrypting secrets (safe to commit)
charts/app/       the shared chart every app uses (see its values.yaml for all options)
```

## Add an app

1. Create `clusters/vps32gb/apps/<name>/values.yaml`:
   ```yaml
   image: nitish2794/my-app
   tag: sha-abc1234        # CI updates this
   port: 8000
   domain: my-app.apps.nitishsrivastava.dev
   healthPath: /health     # optional
   env:
     LOG_LEVEL: info
   ```
2. Commit and push. It's live with HTTPS in a few minutes.

Any `*.apps.nitishsrivastava.dev` name works with no DNS change. For another domain
(e.g. `myapp.com`), point its A record at `209.182.234.168` first.

## Secrets

```bash
scripts/seal-secret.sh <app> <KEY>     # asks for the value, prints an encrypted line
```

Paste the output under `secrets:` in the app's `values.yaml`. The app gets it as an environment variable.

**Private images** from `ghcr.io/nitish-iiitd/...`: add `imagePullSecret: ghcr-pull` to the app's
`values.yaml`. That login lives in `platform/ghcr-pull.sealed.yaml` (same GitHub token as vps8gb's `ghcr-pull`).

## Postgres

One shared PostgreSQL 18 server (CloudNativePG), defined in `databases/postgres.yaml`.
Apps connect to `postgres-rw.databases.svc.cluster.local:5432`.

To give an app a database:
1. Seal a password for its user (namespace `databases`, secret `postgres-<app>`, type
   `kubernetes.io/basic-auth` with `username` + `password`) into `databases/postgres-<app>.sealed.yaml`.
2. Add the user under `managed.roles` and a `Database` in `databases/postgres.yaml`.
3. Put the connection URL in the app's `secrets:` (e.g. `DATABASE_URL`).

Admin shell: `ssh vps32gb sudo /usr/local/bin/kubectl exec -it -n databases postgres-1 -- psql`

Not yet backed up — see vps-manager's to-do list.

## Update / remove

- **Update:** change `tag` (CI does this automatically) and push. Rolling update, no downtime.
- **Roll back:** `git revert` the commit that changed the tag.
- **Remove:** delete the app's folder and push. Its disk (if any) is deleted too.

## Check status

Argo CD UI: https://argocd.apps.nitishsrivastava.dev — or `ssh vps32gb sudo /usr/local/bin/kubectl get pods -n apps`
