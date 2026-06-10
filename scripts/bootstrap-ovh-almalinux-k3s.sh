#!/usr/bin/env bash
set -Eeuo pipefail

# bootstrap-ovh-almalinux-k3s.sh
# Fresh AlmaLinux/RHEL-like VPS bootstrap for:
# Docker + k3s + Helm + Argo CD + cert-manager + firewalld k3s rules.
#
# Intended for a single-node OVH VPS running AlmaLinux 10.
# Run as a sudo-capable user, not necessarily root.
#
# Optional environment variables:
#   LETSENCRYPT_EMAIL="you@example.com"
#   ARGOCD_HOST="argocd.nitishsrivastava.dev"
#   CREATE_ARGOCD_INGRESS="true" | "false"
#   INSTALL_DOCKER="true" | "false"
#   INSTALL_ARGOCD="true" | "false"
#   INSTALL_CERT_MANAGER="true" | "false"
#   CERT_MANAGER_VERSION="v1.20.2"
#   K3S_CHANNEL="stable"
#   SUDO_USER_TO_CONFIGURE="almalinux"
#
# Example:
#   export LETSENCRYPT_EMAIL="nitish@example.com"
#   export ARGOCD_HOST="argocd.nitishsrivastava.dev"
#   export CREATE_ARGOCD_INGRESS="true"
#   ./bootstrap-ovh-almalinux-k3s.sh

log() {
  echo -e "\n[INFO] $*"
}

warn() {
  echo -e "\n[WARN] $*" >&2
}

fail() {
  echo -e "\n[ERROR] $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

run_as_root_check() {
  if [[ "${EUID}" -ne 0 ]]; then
    require_command sudo
    sudo -v || fail "This script requires sudo privileges."
  fi
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

get_target_user() {
  if [[ -n "${SUDO_USER_TO_CONFIGURE:-}" ]]; then
    echo "${SUDO_USER_TO_CONFIGURE}"
  elif [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  else
    whoami
  fi
}

wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-300s}"
  kubectl rollout status "deployment/${deployment}" -n "${namespace}" --timeout="${timeout}"
}

wait_for_pods() {
  local namespace="$1"
  local selector="$2"
  local timeout="${3:-300s}"
  kubectl wait --for=condition=Ready pod -n "${namespace}" -l "${selector}" --timeout="${timeout}" || true
}

install_base_packages() {
  log "Installing base packages"
  as_root dnf update -y
  as_root dnf install -y \
    curl wget git vim nano unzip tar htop ncdu lsof net-tools bind-utils \
    bash-completion firewalld dnf-plugins-core ca-certificates openssl
}

configure_firewalld_base() {
  log "Configuring firewalld base rules"
  as_root systemctl enable --now firewalld
  as_root firewall-cmd --permanent --add-service=ssh || true
  as_root firewall-cmd --permanent --add-service=http || true
  as_root firewall-cmd --permanent --add-service=https || true
  as_root firewall-cmd --reload
}

install_docker() {
  if [[ "${INSTALL_DOCKER:-true}" != "true" ]]; then
    warn "Skipping Docker install because INSTALL_DOCKER=false"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed"
  else
    log "Installing Docker Engine"
    as_root dnf install -y dnf-plugins-core

    # Prefer RHEL repo. Fallback to CentOS repo if needed.
    if as_root dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo; then
      log "Docker RHEL repo added"
    else
      warn "Docker RHEL repo failed; trying CentOS repo"
      as_root dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    fi

    as_root dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  as_root systemctl enable --now docker

  local target_user
  target_user="$(get_target_user)"
  if id "${target_user}" >/dev/null 2>&1; then
    log "Adding ${target_user} to docker group"
    as_root usermod -aG docker "${target_user}" || true
  else
    warn "Target user ${target_user} does not exist; skipping docker group update"
  fi
}

install_k3s() {
  if command -v k3s >/dev/null 2>&1; then
    log "k3s already installed"
  else
    log "Installing k3s"
    curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${K3S_CHANNEL:-stable}" sh -
  fi

  as_root systemctl enable --now k3s

  log "Waiting for Kubernetes node readiness"
  local attempts=60
  until as_root /usr/local/bin/k3s kubectl get nodes >/dev/null 2>&1; do
    attempts=$((attempts - 1))
    [[ "$attempts" -le 0 ]] && fail "k3s did not become ready in time"
    sleep 5
  done

  if [[ ! -e /usr/bin/kubectl ]]; then
    as_root ln -s /usr/local/bin/kubectl /usr/bin/kubectl || true
  fi
}

configure_kubectl_for_user() {
  local target_user
  target_user="$(get_target_user)"

  if ! id "${target_user}" >/dev/null 2>&1; then
    warn "Target user ${target_user} does not exist; skipping kubeconfig setup"
    return
  fi

  local home_dir
  home_dir="$(getent passwd "${target_user}" | cut -d: -f6)"

  log "Configuring kubectl for user ${target_user} at ${home_dir}/.kube/config"
  as_root mkdir -p "${home_dir}/.kube"
  as_root cp /etc/rancher/k3s/k3s.yaml "${home_dir}/.kube/config"
  as_root chown -R "${target_user}:${target_user}" "${home_dir}/.kube"
  as_root chmod 700 "${home_dir}/.kube"
  as_root chmod 600 "${home_dir}/.kube/config"

  if ! grep -q 'export KUBECONFIG=$HOME/.kube/config' "${home_dir}/.bashrc" 2>/dev/null; then
    echo 'export KUBECONFIG=$HOME/.kube/config' | as_root tee -a "${home_dir}/.bashrc" >/dev/null
    as_root chown "${target_user}:${target_user}" "${home_dir}/.bashrc"
  fi

  export KUBECONFIG="${home_dir}/.kube/config"
}

configure_firewalld_for_k3s() {
  log "Configuring firewalld rules for k3s pod/service networking"

  as_root systemctl enable --now firewalld

  # Public ingress ports.
  as_root firewall-cmd --permanent --add-service=ssh || true
  as_root firewall-cmd --permanent --add-service=http || true
  as_root firewall-cmd --permanent --add-service=https || true

  # Critical for k3s on firewalld-based systems.
  as_root firewall-cmd --permanent --zone=public --add-masquerade || true
  as_root firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 || true
  as_root firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16 || true

  as_root firewall-cmd --reload

  log "Restarting k3s after firewall changes"
  as_root systemctl restart k3s
  sleep 10
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    log "Helm already installed"
  else
    log "Installing Helm"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}

install_argocd() {
  if [[ "${INSTALL_ARGOCD:-true}" != "true" ]]; then
    warn "Skipping Argo CD install because INSTALL_ARGOCD=false"
    return
  fi

  log "Installing Argo CD"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  # Server-side apply avoids large CRD client-side annotation issues.
  kubectl apply --server-side --force-conflicts -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  log "Waiting for Argo CD pods"
  wait_for_deployment argocd argocd-server 600s || true
  wait_for_deployment argocd argocd-repo-server 600s || true
  wait_for_deployment argocd argocd-redis 600s || true

  log "Configuring Argo CD server for ingress TLS termination"
  kubectl patch configmap argocd-cmd-params-cm -n argocd \
    --type merge \
    -p '{"data":{"server.insecure":"true"}}'

  kubectl rollout restart deployment argocd-server -n argocd
  wait_for_deployment argocd argocd-server 600s || true
}

install_cert_manager() {
  if [[ "${INSTALL_CERT_MANAGER:-true}" != "true" ]]; then
    warn "Skipping cert-manager install because INSTALL_CERT_MANAGER=false"
    return
  fi

  log "Installing cert-manager"
  helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version "${CERT_MANAGER_VERSION:-v1.20.2}" \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait \
    --timeout 10m \
    || helm upgrade cert-manager oci://quay.io/jetstack/charts/cert-manager \
      --version "${CERT_MANAGER_VERSION:-v1.20.2}" \
      --namespace cert-manager \
      --create-namespace \
      --set crds.enabled=true \
      --wait \
      --timeout 10m
}

create_cluster_issuer() {
  if [[ "${INSTALL_CERT_MANAGER:-true}" != "true" ]]; then
    return
  fi

  if [[ -z "${LETSENCRYPT_EMAIL:-}" ]]; then
    warn "LETSENCRYPT_EMAIL is not set. Skipping ClusterIssuer creation."
    warn "Set LETSENCRYPT_EMAIL and rerun, or create ClusterIssuer manually."
    return
  fi

  log "Creating Let's Encrypt production ClusterIssuer"
  cat <<YAML | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${LETSENCRYPT_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-private-key
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
YAML
}

create_argocd_ingress() {
  if [[ "${CREATE_ARGOCD_INGRESS:-false}" != "true" ]]; then
    warn "Skipping Argo CD ingress because CREATE_ARGOCD_INGRESS is not true"
    return
  fi

  if [[ -z "${ARGOCD_HOST:-}" ]]; then
    warn "ARGOCD_HOST is not set. Skipping Argo CD ingress."
    return
  fi

  log "Creating Argo CD ingress for ${ARGOCD_HOST}"
  cat <<YAML | kubectl apply -f -
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
        - ${ARGOCD_HOST}
      secretName: argocd-server-tls
  rules:
    - host: ${ARGOCD_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
YAML
}

print_summary() {
  local target_user
  target_user="$(get_target_user)"

  log "Bootstrap complete"
  echo ""
  echo "Summary:"
  echo "  User configured: ${target_user}"
  echo "  k3s:            $(/usr/local/bin/k3s --version | head -n 1 || true)"
  echo "  Helm:           $(helm version --short 2>/dev/null || true)"
  echo "  Docker:         $(docker --version 2>/dev/null || true)"
  echo ""
  echo "Check cluster:"
  echo "  kubectl get nodes"
  echo "  kubectl get pods -A"
  echo ""
  echo "Check firewalld:"
  echo "  sudo firewall-cmd --list-all"
  echo "  sudo firewall-cmd --zone=trusted --list-all"
  echo ""
  if [[ "${INSTALL_ARGOCD:-true}" == "true" ]]; then
    echo "Argo CD initial admin password:"
    echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
    echo ""
    if [[ "${CREATE_ARGOCD_INGRESS:-false}" == "true" && -n "${ARGOCD_HOST:-}" ]]; then
      echo "Argo CD URL:"
      echo "  https://${ARGOCD_HOST}"
      echo ""
    else
      echo "Access Argo CD using port-forward:"
      echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
      echo "  https://localhost:8080"
      echo ""
    fi
  fi
  echo "IMPORTANT: If Docker was newly installed, logout/login may be required for docker group permissions."
}

main() {
  run_as_root_check

  log "Starting AlmaLinux VPS Kubernetes bootstrap"
  install_base_packages
  configure_firewalld_base
  install_docker
  install_k3s
  configure_kubectl_for_user
  configure_firewalld_for_k3s
  install_helm
  install_cert_manager
  create_cluster_issuer
  install_argocd
  create_argocd_ingress
  print_summary
}

main "$@"
