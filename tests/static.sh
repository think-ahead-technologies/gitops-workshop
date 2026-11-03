#!/usr/bin/env bash
# About: offline validation of the GitOps manifests. Renders every Kustomize
# entry point and renders every HelmRelease with `helm template`, using the
# chart, version, repository and inline values declared in Git. Catches broken
# kustomizations, wrong chart versions and invalid chart values before Flux sees them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

KUSTOMIZE_DIRS=(clusters/local infrastructure/sources infrastructure/kyverno monitoring apps/sepa)
RELEASE_DIRS=(infrastructure/kyverno monitoring)

for dir in "${KUSTOMIZE_DIRS[@]}"; do
  if [[ ! -f "$ROOT/$dir/kustomization.yaml" ]]; then
    echo "FAIL kustomize $dir: missing kustomization.yaml"; fail=1; continue
  fi
  if kubectl kustomize "$ROOT/$dir" > "$TMP/$(echo "$dir" | tr / _).yaml" 2> "$TMP/err"; then
    echo "PASS kustomize $dir"
  else
    echo "FAIL kustomize $dir: $(head -1 "$TMP/err")"; fail=1
  fi
done

sources="$TMP/infrastructure_sources.yaml"
for dir in "${RELEASE_DIRS[@]}"; do
  releases="$TMP/$(echo "$dir" | tr / _).yaml"
  [[ -s "$releases" && -s "$sources" ]] || continue
  names=$(yq -N 'select(.kind == "HelmRelease") | .metadata.name' "$releases")
  [[ -n "$names" ]] || { echo "FAIL no HelmRelease found in $dir"; fail=1; }
  for name in $names; do
    hr="select(.kind == \"HelmRelease\" and .metadata.name == \"$name\")"
    chart=$(yq -N "$hr | .spec.chart.spec.chart" "$releases")
    version=$(yq -N "$hr | .spec.chart.spec.version" "$releases")
    repo=$(yq -N "$hr | .spec.chart.spec.sourceRef.name" "$releases")
    url=$(yq -N "select(.kind == \"HelmRepository\" and .metadata.name == \"$repo\") | .spec.url" "$sources")
    ns=$(yq -N "$hr | .spec.targetNamespace // .metadata.namespace" "$releases")
    yq -N "$hr | .spec.values // {}" "$releases" > "$TMP/$name-values.yaml"
    if [[ -z "$url" ]]; then
      echo "FAIL helm $name: HelmRepository '$repo' not found"; fail=1; continue
    fi
    if helm template "$name" "$chart" --repo "$url" --version "$version" \
         --namespace "$ns" -f "$TMP/$name-values.yaml" > /dev/null 2> "$TMP/err"; then
      echo "PASS helm $name ($chart $version)"
    else
      echo "FAIL helm $name: $(grep -m1 -i error "$TMP/err" || head -1 "$TMP/err")"; fail=1
    fi
  done
done

exit $fail
