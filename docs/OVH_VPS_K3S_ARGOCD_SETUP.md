# OVH VPS Kubernetes Platform Setup

This document captures the final working setup for my OVHcloud VPS running AlmaLinux, k3s, Argo CD, Traefik, cert-manager, and Docker.

It is intended as a future reference for rebuilding the server, debugging issues, and deploying new applications using GitOps.

---

## 1. Server Details

Current VPS:

```text
Provider: OVHcloud
OS: AlmaLinux 10
Region: Singapore / SGP
Public IP: 15.235.207.142
CPU: 4 vCores
Memory: 8 GB
Storage: 75 GB
Hostname: vps-706086c3.vps.ovh.ca
```

Primary use case:

```text
Personal deployment platform for containerized apps using Kubernetes, Helm, Argo CD, Docker Hub, and custom domains.
```

---

## 2. Final Architecture

```text
GitHub app repo
  ↓
GitHub Actions builds Docker image
  ↓
Docker Hub image registry
  ↓
Separate deployment repo with Helm charts
  ↓
Argo CD watches deployment repo
  ↓
k3s deploys app on OVH VPS
  ↓
Traefik routes domain traffic
  ↓
cert-manager issues Let's Encrypt HTTPS certificates
```

Runtime traffic flow:

```text
Browser
  ↓ HTTPS
app-subdomain.nitishsrivastava.dev
  ↓
VPS public IP: 15.235.207.142
  ↓
k3s Traefik LoadBalancer
  ↓
Kubernetes Ingress
  ↓
Kubernetes Service
  ↓
Application Pod
```

---

## 3. Installed Components

### 3.1 Docker

Docker was installed using the Docker repository for RHEL-compatible systems.

Purpose:

```text
- Useful for local image testing/building on the VPS if needed.
- k3s itself uses containerd internally to run Kubernetes workloads.
```

Useful commands:

```bash
docker version
docker compose version
docker ps
```

The user was added to the Docker group:

```bash
sudo usermod -aG docker almalinux
```

After adding a user to the Docker group, logout/login is required.

---

### 3.2 k3s

k3s is the lightweight Kubernetes distribution running on this VPS.

Installed using:

```bash
curl -sfL https://get.k3s.io | sh -
```

Important paths:

```text
k3s binary: /usr/local/bin/k3s
kubectl symlink: /usr/local/bin/kubectl
kubeconfig: /etc/rancher/k3s/k3s.yaml
```

kubectl was configured for the `almalinux` user:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown almalinux:almalinux ~/.kube/config
chmod 600 ~/.kube/config
```

If kubectl tries to read `/etc/rancher/k3s/k3s.yaml` directly and gives permission errors, set:

```bash
export KUBECONFIG=$HOME/.kube/config
```

Optional permanent setting:

```bash
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

Useful commands:

```bash
kubectl get nodes
kubectl get pods -A
sudo systemctl status k3s --no-pager
```

---

### 3.3 Helm

Helm is used to package and deploy applications into Kubernetes.

Installed using:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Useful commands:

```bash
helm version
helm lint apps/hello-fastapi
helm template hello-fastapi apps/hello-fastapi
```

---

### 3.4 Argo CD

Argo CD is used for GitOps-based deployment.

Namespace:

```text
argocd
```

Installed using:

```bash
kubectl create namespace argocd
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Why server-side apply?

The normal `kubectl apply` may fail for large Argo CD CRDs, especially `applicationsets.argoproj.io`, with:

```text
metadata.annotations: Too long: may not be more than 262144 bytes
```

Server-side apply avoids this client-side last-applied annotation size problem.

Useful commands:

```bash
kubectl get pods -n argocd
kubectl get svc -n argocd
kubectl get applications -n argocd
```

Initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo
```

Argo CD UI:

```text
https://argocd.nitishsrivastava.dev
```

---

### 3.5 Argo CD Behind Traefik

Argo CD was exposed permanently using Traefik Ingress.

Important config:

```bash
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge \
  -p '{"data":{"server.insecure":"true"}}'

kubectl rollout restart deployment argocd-server -n argocd
```

Reason:

```text
Public browser → HTTPS via Traefik
Traefik → HTTP to argocd-server service internally
```

Ingress used for Argo CD:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - argocd.nitishsrivastava.dev
      secretName: argocd-server-tls
  rules:
    - host: argocd.nitishsrivastava.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

DNS record:

```text
A argocd → 15.235.207.142
```

---

### 3.6 Traefik Ingress

Traefik was installed automatically by k3s.

Namespace:

```text
kube-system
```

Useful commands:

```bash
kubectl get pods -n kube-system | grep traefik
kubectl get svc -n kube-system | grep traefik
kubectl get ingressclass
kubectl logs -n kube-system deployment/traefik --tail=100
```

Traefik is responsible for routing public HTTP/HTTPS traffic to Kubernetes services.

---

### 3.7 cert-manager

cert-manager is used to issue and renew Let's Encrypt certificates.

Installed using Helm:

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.20.2 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

ClusterIssuer:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: YOUR_EMAIL_HERE
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-private-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
```

Useful commands:

```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer
kubectl get certificate -A
kubectl get challenges -A
kubectl get orders -A
```

---

## 4. Important firewalld Fix for k3s on AlmaLinux

This was the most important troubleshooting point.

Symptoms:

```text
- App pod was running.
- Service worked from inside the cluster.
- DNS resolved correctly.
- Traefik returned 502 Bad Gateway.
- Traefik logs showed:
  dial tcp 10.42.x.x:8000: connect: no route to host
```

Root cause:

```text
firewalld was blocking k3s pod/service networking.
```

Fix:

```bash
sudo firewall-cmd --permanent --zone=public --add-masquerade
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
sudo firewall-cmd --reload
sudo systemctl restart k3s
```

Why these CIDRs?

```text
10.42.0.0/16 = k3s pod network
10.43.0.0/16 = k3s service network
```

Check firewall:

```bash
sudo firewall-cmd --list-all
sudo firewall-cmd --zone=trusted --list-all
```

Expected:

```text
public zone: masquerade enabled
trusted zone: 10.42.0.0/16 and 10.43.0.0/16 added as sources
```

---

## 5. Current Working Domains

### hello-fastapi

```text
https://hello.nitishsrivastava.dev
```

Kubernetes resources:

```text
Namespace: apps
Deployment: hello-fastapi
Service: hello-fastapi
Ingress: hello-fastapi
Certificate: hello-fastapi-tls
```

Docker image:

```text
nitish2794/hello-fastapi:latest
```

Service mapping:

```text
Service port 80 → container targetPort 8000
```

### Argo CD

```text
https://argocd.nitishsrivastava.dev
```

Kubernetes resources:

```text
Namespace: argocd
Service: argocd-server
Ingress: argocd-server
Certificate: argocd-server-tls
```

---

## 6. Recommended GitOps Repo Structure

### Application repo

Example:

```text
hello-fastapi/
  main.py
  requirements.txt
  Dockerfile
  .github/
    workflows/
      docker-build.yml
```

Purpose:

```text
- Contains app code.
- GitHub Actions builds Docker image.
- Image is pushed to Docker Hub.
```

### Deployment repo

Example:

```text
my-vps-deployments/
  bootstrap/
    cluster-issuer.yaml
    argocd-ingress.yaml

  apps/
    hello-fastapi/
      Chart.yaml
      values.yaml
      templates/
        deployment.yaml
        service.yaml
        ingress.yaml
```

Purpose:

```text
- Contains Helm charts and Kubernetes deployment configuration.
- Argo CD watches this repo.
- This repo is the source of truth for the VPS cluster.
```

---

## 7. Important GitOps Rule

Once Argo CD manages an app, avoid manual changes like:

```bash
kubectl patch ...
kubectl edit ...
kubectl delete/recreate managed objects manually
```

Argo CD may revert manual changes because the Git repo is the source of truth.

Correct flow:

```text
Edit Helm chart / values.yaml
  ↓
git commit
  ↓
git push
  ↓
Argo CD refresh/sync
  ↓
Kubernetes state changes
```

---

## 8. Template: Basic App Helm Chart

### values.yaml

```yaml
replicaCount: 1

image:
  repository: nitish2794/hello-fastapi
  tag: latest
  pullPolicy: Always

service:
  type: ClusterIP
  port: 80
  targetPort: 8000

ingress:
  enabled: true
  className: traefik
  host: hello.nitishsrivastava.dev
  tlsSecretName: hello-fastapi-tls

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 300m
    memory: 256Mi
```

### ingress.yaml

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: {{ .Values.ingress.className }}
  tls:
    - hosts:
        - {{ .Values.ingress.host }}
      secretName: {{ .Values.ingress.tlsSecretName }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

---

## 9. New App Deployment Checklist

For every new app:

```text
1. Create app Dockerfile.
2. Add GitHub Actions workflow to build and push Docker image.
3. Add Docker Hub repo/image.
4. Add Helm chart in my-vps-deployments repo.
5. Add DNS A record for app subdomain.
6. Add/commit Argo CD Application manifest or create app in UI.
7. Sync in Argo CD.
8. Verify HTTP/HTTPS.
```

Example DNS:

```text
A mealmitra → 15.235.207.142
A mcp       → 15.235.207.142
A auth      → 15.235.207.142
```

---

## 10. Debug Commands

### Cluster

```bash
kubectl get nodes
kubectl get pods -A
```

### Apps

```bash
kubectl get all -n apps
kubectl get ingress -n apps
kubectl get certificate -n apps
kubectl logs -n apps deployment/hello-fastapi
```

### Service connectivity

```bash
kubectl run curl-test -n apps --rm -it \
  --image=curlimages/curl \
  --restart=Never -- \
  curl -v http://hello-fastapi
```

From Traefik namespace:

```bash
kubectl run curl-test -n kube-system --rm -it \
  --image=curlimages/curl \
  --restart=Never -- \
  curl -v http://hello-fastapi.apps.svc.cluster.local
```

### Ingress

```bash
kubectl describe ingress hello-fastapi -n apps
kubectl get ingress hello-fastapi -n apps -o yaml
curl -v http://hello.nitishsrivastava.dev
curl -v https://hello.nitishsrivastava.dev
```

### Traefik

```bash
kubectl get pods -n kube-system | grep traefik
kubectl get svc -n kube-system | grep traefik
kubectl logs -n kube-system deployment/traefik --tail=200
```

### cert-manager

```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer
kubectl get certificate -A
kubectl get challenges -A
kubectl get orders -A
```

### Argo CD

```bash
kubectl get pods -n argocd
kubectl get ingress -n argocd
kubectl get certificate -n argocd
kubectl get applications -n argocd
```

---

## 11. Common Issues and Fixes

### Issue: Docker permission denied

Symptom:

```text
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

Fix:

```bash
sudo usermod -aG docker almalinux
exit
ssh almalinux@SERVER_IP
```

---

### Issue: kubectl reads `/etc/rancher/k3s/k3s.yaml` and gets permission denied

Fix:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown almalinux:almalinux ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=$HOME/.kube/config
```

---

### Issue: Argo CD CRD annotation too long

Symptom:

```text
metadata.annotations: Too long: may not be more than 262144 bytes
```

Fix:

```bash
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

---

### Issue: cert-manager challenge pending because DNS does not resolve

Check:

```bash
dig +short hello.nitishsrivastava.dev
kubectl describe challenge -n apps
```

Fix DNS A record:

```text
A hello → 15.235.207.142
```

---

### Issue: Traefik 502 Bad Gateway / no route to host

Symptom:

```text
502 Bad Gateway
Traefik log: dial tcp 10.42.x.x:8000: connect: no route to host
```

Fix firewalld:

```bash
sudo firewall-cmd --permanent --zone=public --add-masquerade
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16
sudo firewall-cmd --reload
sudo systemctl restart k3s
```

---

## 12. Fresh VPS Bootstrap Script

A companion script is included in this repo:

```text
bootstrap-ovh-almalinux-k3s.sh
```

It installs and configures:

```text
- Base packages
- Docker
- k3s
- kubectl config
- firewalld rules for k3s
- Helm
- Argo CD
- cert-manager
- Let's Encrypt ClusterIssuer
- Optional Argo CD Ingress
```

Run it on a fresh AlmaLinux VPS as the default sudo user:

```bash
chmod +x bootstrap-ovh-almalinux-k3s.sh
./bootstrap-ovh-almalinux-k3s.sh
```

Set variables before running:

```bash
export LETSENCRYPT_EMAIL="you@example.com"
export ARGOCD_HOST="argocd.nitishsrivastava.dev"
export CREATE_ARGOCD_INGRESS="true"
./bootstrap-ovh-almalinux-k3s.sh
```

---

## 13. Security Notes

Minimum security recommendations:

```text
- Use SSH key login.
- Disable root SSH login.
- Disable password SSH login after key login works.
- Keep firewalld enabled.
- Keep only SSH, HTTP, HTTPS open.
- Use strong Argo CD admin password.
- Consider restricting Argo CD by IP later.
- Keep VPS and cluster packages updated.
- Take OVH snapshot after clean setup.
```

Argo CD is publicly reachable at:

```text
https://argocd.nitishsrivastava.dev
```

So use a strong password and consider adding IP allowlisting later.
