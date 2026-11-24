#!/usr/bin/env bash
# Encrypt one secret value for an app, so it can be committed to git safely.
#
# Usage:   scripts/seal-secret.sh <app> <KEY> [cluster]      (cluster defaults to vps32gb)
# Example: scripts/seal-secret.sh hello-fastapi OPENAI_API_KEY
#
# It asks for the value (not shown on screen) and prints a line like
#   OPENAI_API_KEY: AgB4f...
# Paste that under `secrets:` in clusters/<cluster>/apps/<app>/values.yaml, commit and push.
#
# Needs kubeseal on your Mac: brew install kubeseal

set -euo pipefail

APP="${1:?usage: seal-secret.sh <app> <KEY> [cluster]}"
KEY="${2:?usage: seal-secret.sh <app> <KEY> [cluster]}"
CLUSTER="${3:-vps32gb}"
CERT="$(dirname "$0")/../clusters/$CLUSTER/sealed-secrets-cert.pem"

read -rsp "Value for $KEY: " VALUE
echo >&2

ENCRYPTED=$(printf '%s' "$VALUE" | kubeseal --raw --cert "$CERT" --namespace apps --name "$APP-secrets")
echo "  $KEY: $ENCRYPTED"
