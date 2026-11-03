#!/usr/bin/env bash
# About: one-time host-side preparation for the SEPA order validator on the
# local OrbStack cluster. Builds the validator and SFTP server images into the
# shared Docker image store and creates every credential the manifests
# reference - PostgreSQL password, SFTP host key, SFTP client key and the
# known_hosts ConfigMap - so no secret is ever committed to Git. Keys are
# ECDSA P-256: the validator's SSH client does not load ed25519 private keys.
# The validator image is tagged with the checkout's short commit id; set that
# tag in clusters/local/sepa-order-validator.yaml (spec.images) to roll it out.
# Usage: apps/sepa/prepare-local.sh <path to sepa-order-validator checkout>
set -euo pipefail

SRC="${1:?usage: $0 <path to sepa-order-validator checkout>}"
NS=sepa
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TAG="$(git -C "$SRC" rev-parse --short=7 HEAD)"
docker build -t "payment-order-validator:$TAG" "$SRC"
docker build -t sepa-sftp-server:local \
  --build-arg SFTP_USER=sepa \
  --build-arg SFTP_PASSWORD="$(openssl rand -hex 24)" \
  "$SRC/src/test/resources/sftp"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

exists() { kubectl -n "$NS" get "$1" "$2" >/dev/null 2>&1; }

if ! exists secret postgres; then
  password="$(openssl rand -hex 24)"
  kubectl -n "$NS" create secret generic postgres --from-literal=password="$password"
  kubectl -n "$NS" create secret generic payment-order-validator-db \
    --from-literal=SPRING_DATASOURCE_USERNAME=sepa \
    --from-literal=SPRING_DATASOURCE_PASSWORD="$password"
fi

if ! exists secret sftp-server-keys; then
  ssh-keygen -q -t ecdsa -b 256 -N '' -C sftp-server -f "$TMP/host"
  ssh-keygen -q -t ecdsa -b 256 -N '' -C payment-order-validator -f "$TMP/client"
  kubectl -n "$NS" create secret generic sftp-server-keys \
    --from-file=host-key="$TMP/host" --from-file=authorized-key="$TMP/client.pub"
  kubectl -n "$NS" create secret generic payment-order-validator-sftp \
    --from-file=private-key="$TMP/client"
  echo "sftp-server.$NS.svc $(cut -d' ' -f1,2 "$TMP/host.pub")" > "$TMP/known_hosts"
  kubectl -n "$NS" create configmap payment-order-validator-sftp-known-hosts \
    --from-file=known_hosts="$TMP/known_hosts" --dry-run=client -o yaml | kubectl apply -f -
fi

echo "Built payment-order-validator:$TAG - set newTag: $TAG in clusters/local/sepa-order-validator.yaml"
