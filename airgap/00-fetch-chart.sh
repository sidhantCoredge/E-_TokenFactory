#!/usr/bin/env bash
# RUN ON THE INTERNET-CONNECTED MAC, from the package root, BEFORE 01-bundle-connected.sh.
# Fetches the private chart repo (Infinia-Technology/ai-gateway-platform, branch `stage`) at the PINNED commit into ./ai-gateway-platform/
# (git-ignored; it is copied to the install VM together with the bundle). Needs git access to the repo (SSH key or credential helper).
set -euo pipefail
cd "$(dirname "$0")/.."
. airgap/env.sh
[ -n "${CHART_REPO:-}" ] && [ -n "${CHART_REF:-}" ] || { echo "set CHART_REPO and CHART_REF in config.env"; exit 1; }
D="$REPO"
if [ -d "$D/.git" ] && [ "$(git -C "$D" rev-parse HEAD 2>/dev/null)" = "$CHART_REF" ]; then
  echo "already at $CHART_REF"
else
  rm -rf "$D"; mkdir -p "$D"; git -C "$D" init -q; git -C "$D" remote add origin "$CHART_REPO"
  git -C "$D" fetch -q --depth 1 origin "$CHART_REF"
  git -C "$D" checkout -q FETCH_HEAD
  echo "fetched $CHART_REPO @ $(git -C "$D" rev-parse --short HEAD)"
fi
ver=$(sed -n 's/^version:[[:space:]]*//p' "$D/helm/tokenfactory/Chart.yaml" | head -1 | tr -d '"')
echo "chart version: $ver   TF_TAG: $TF_TAG"
case "$TF_TAG" in "$ver"-*) ;; *) echo "ERROR: TF_TAG ($TF_TAG) does not start with the chart version ($ver). Image tags are <chart version>-<shortsha>."; exit 1;; esac
for f in helm/tokenfactory/values-tf-etisalat.yaml helm/tokenfactory/templates/ingress.yaml brands/etisalat/keycloak/theme.tar.gz.b64 helm/setup/scripts/install.sh; do
  [ -f "$D/$f" ] || { echo "ERROR: $f missing in the checkout"; exit 1; }
done
echo "ok: chart checkout complete"
