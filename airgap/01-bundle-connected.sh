#!/usr/bin/env bash
# RUN ON THE INTERNET-CONNECTED MAC/LAPTOP, from the package root. Builds ./bundle/ : image TAR files + charts + CRDs + jar + helm.
# Needs: skopeo, crane (only for docker manifest lists), helm, curl, tar, perl, python3.  Logins first:  skopeo login docker.io   skopeo login ghcr.io  (ghcr needs a READ token for infinia-technology)
set -euo pipefail
cd "$(dirname "$0")/.."
. airgap/env.sh
# The bundle and the chart checkout must live INSIDE this package folder (DEPLOY.md A6 copies this folder). A stale BUNDLE_DIR / REPO in the terminal would put them elsewhere.
if [ "${ALLOW_EXTERNAL:-0}" != 1 ]; then
  case "$BUNDLE_DIR" in "$PWD"/*) ;; *) echo "ERROR: BUNDLE_DIR=$BUNDLE_DIR is outside the package folder $PWD. Run:  unset ROOT BUNDLE_DIR REPO   and start this script again (ALLOW_EXTERNAL=1 overrides this check)."; exit 1;; esac
  case "$REPO" in "$PWD"/*) ;; *) echo "ERROR: REPO=$REPO is outside the package folder $PWD. Run:  unset ROOT BUNDLE_DIR REPO   and start this script again."; exit 1;; esac
fi
mkdir -p "$BUNDLE_DIR"/{tars,charts,crds,jars,repo,tools}
case "$TF_TAG$BRAND_TAG" in *REPLACE*) echo "set TF_TAG and BRAND_TAG in config.env first"; exit 1;; esac
command -v skopeo >/dev/null || { echo "skopeo missing (brew install skopeo)"; exit 1; }

# Some Docker Hub images (openfga, curl) are DOCKER manifest lists: skopeo cannot write those to an OCI archive without changing the digest
# ("Manifest list must be converted ... Instructed to preserve digests"). crane keeps the original manifest bytes, so the @sha256 reference
# the chart uses still resolves. Anonymous pull (public images only); needs `brew install crane`.
pull_with_crane(){ # SRC REF OUTTAR
  command -v crane >/dev/null || return 1
  local src="$1" ref="$2" out="$3" d; d=$(mktemp -d); mkdir -p "$d/dc"
  DOCKER_CONFIG="$d/dc" crane pull --format oci "$src" "$d/layout" >/dev/null 2>&1 || { rm -rf "$d"; return 1; }
  REF="$ref" LAYOUT="$d/layout" python3 - <<'PY'
import json, os
p = os.path.join(os.environ["LAYOUT"], "index.json"); ref = os.environ["REF"]
i = json.load(open(p))
for m in i["manifests"]:
    m["annotations"] = {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[-1]}
json.dump(i, open(p, "w"))
PY
  COPYFILE_DISABLE=1 tar -C "$d/layout" -cf "$out" oci-layout index.json blobs && rm -rf "$d"   # no ./ prefix: what ctr/containerd expects
}

echo "== images -> tar files (one per image, named $REGISTRY/<path>) =="
: > "$BUNDLE_DIR/tars/INDEX"; FAILED=""
while IFS='|' read -r src dst mode; do
  src=$(echo $src); dst=$(echo $dst); mode=$(echo $mode)
  name=$(echo "$dst" | tr '/:@' '___'); tar="$BUNDLE_DIR/tars/$name.tar"
  case "$dst" in *@sha256:*) base="${dst%@*}"; case "${base##*/}" in *:*) base="${base%:*}";; esac; ref="$REGISTRY/$base:pinned-${dst##*:}"; digest="${dst##*:}";; *) ref="$REGISTRY/$dst"; digest="";; esac
  printf '%s|%s|%s|%s\n' "$name.tar" "$ref" "$digest" "${ref#"$REGISTRY"/}" >> "$BUNDLE_DIR/tars/INDEX"   # 4th column = image path without the registry prefix
  if [ -s "$tar" ]; then echo "skip  $name (already built)"; continue; fi
  from="$src"; case "$src" in *@sha256:*) r="${src%@*}"; r="${r%:*}"; from="$r@${src##*@}";; esac   # skopeo rejects tag+digest: use repo@digest
  flags="--override-os linux --override-arch ${PLATFORM#linux/}"; [ "$mode" = all ] && flags="--all --preserve-digests"
  echo "pull  $from"; rm -f "$tar.part"
  if skopeo copy $flags "docker://$from" "oci-archive:$tar.part:$ref"; then mv "$tar.part" "$tar"
  elif [ "$mode" = all ] && rm -f "$tar.part" && pull_with_crane "$from" "$ref" "$tar.part"; then mv "$tar.part" "$tar"; echo "      (built with crane: docker manifest list, digest preserved)"
  else rm -f "$tar.part"; FAILED="$FAILED\n  $src"; fi
done < <(grep -vE '^\s*(#|$)' airgap/images.txt | envsub TF_TAG BRAND_TAG)
[ -z "$FAILED" ] || printf "\nFAILED images (see DEPLOY.md, step A5 notes):$FAILED\n\n"

echo "== registry:2 (only used if the site has no registry at all: airgap/02a-local-registry.sh) =="
mkdir -p "$BUNDLE_DIR/registry"
[ -s "$BUNDLE_DIR/registry/registry2.tar" ] || skopeo copy --override-os linux --override-arch "${PLATFORM#linux/}" docker://docker.io/library/registry:2 docker-archive:"$BUNDLE_DIR/registry/registry2.tar":registry:2 || echo "WARNING: registry:2 not bundled"

echo "== helm charts =="
( cd "$REPO/helm/tokenfactory" && helm dependency build )
( cd "$REPO/helm/infrastructure/openmeter" && helm dependency build )
pullchart(){ tok=$(curl -s "https://auth.docker.io/token?scope=repository:envoyproxy/$1:pull&service=registry.docker.io" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
  m=$(curl -s -H "Authorization: Bearer $tok" -H "Accept: application/vnd.oci.image.manifest.v1+json" "https://registry-1.docker.io/v2/envoyproxy/$1/manifests/$2")
  d=$(echo "$m" | python3 -c 'import sys,json;m=json.load(sys.stdin);print([l["digest"] for l in m["layers"] if "chart" in l["mediaType"]][0])')
  curl -sfL -H "Authorization: Bearer $tok" -o "$BUNDLE_DIR/charts/$1-$2.tgz" "https://registry-1.docker.io/v2/envoyproxy/$1/blobs/$d"; echo "  $1-$2.tgz"; }
pullchart gateway-helm v1.8.1; pullchart ai-gateway-crds-helm v1.0.0; pullchart ai-gateway-helm v1.0.0
tok=$(curl -s "https://ghcr.io/token?scope=repository:nginx/charts/nginx-ingress:pull" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
m=$(curl -s -H "Authorization: Bearer $tok" -H "Accept: application/vnd.oci.image.manifest.v1+json" https://ghcr.io/v2/nginx/charts/nginx-ingress/manifests/1.3.2)
d=$(echo "$m" | python3 -c 'import sys,json;m=json.load(sys.stdin);print([l["digest"] for l in m["layers"] if "chart" in l["mediaType"]][0])')
curl -sfL -H "Authorization: Bearer $tok" -o "$BUNDLE_DIR/charts/nginx-ingress-1.3.2.tgz" "https://ghcr.io/v2/nginx/charts/nginx-ingress/blobs/$d"; echo "  nginx-ingress-1.3.2.tgz"
# Vault + Secrets Store CSI driver charts (phase `vault`)
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts >/dev/null 2>&1 || true
helm repo update hashicorp secrets-store-csi-driver >/dev/null 2>&1 || true
[ -s "$BUNDLE_DIR/charts/vault-0.32.0.tgz" ] || helm pull hashicorp/vault --version 0.32.0 -d "$BUNDLE_DIR/charts"
[ -s "$BUNDLE_DIR/charts/secrets-store-csi-driver-1.5.6.tgz" ] || helm pull secrets-store-csi-driver/secrets-store-csi-driver --version 1.5.6 -d "$BUNDLE_DIR/charts"
echo "  vault-0.32.0.tgz secrets-store-csi-driver-1.5.6.tgz"
# HPE CSI Driver chart (X10000 NFS storage, phase `storage`)
[ -s "$BUNDLE_DIR/charts/hpe-csi-driver-3.2.0.tgz" ] || { helm repo add hpe-storage https://hpe-storage.github.io/co-deployments/ >/dev/null 2>&1 || true; helm repo update hpe-storage >/dev/null 2>&1 || true; helm pull hpe-storage/hpe-csi-driver --version 3.2.0 -d "$BUNDLE_DIR/charts"; }
echo "  hpe-csi-driver-3.2.0.tgz"
curl -fsSL -o "$BUNDLE_DIR/crds/gateway-api-standard-install-v1.3.0.yaml" https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

echo "== keycloak SPI jar + helm (linux-amd64) =="
# chart 0.17.7 runs Keycloak 26.8.2 -> the jar must be the 26.8 build (chart default: keycloak.providers.plugins in values.yaml). 26.5.0-KC26.7.3 does NOT match.
JAR=keycloak-2fa-email-authenticator-26.6.1-KC26.8.0.jar
rm -f "$BUNDLE_DIR"/jars/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar   # stale jar from an older bundle (would be picked up otherwise)
[ -s "$BUNDLE_DIR/jars/$JAR" ] || curl -fsSL -o "$BUNDLE_DIR/jars/$JAR" "https://repo1.maven.org/maven2/io/github/mesutpiskin/keycloak-2fa-email-authenticator/26.6.1-KC26.8.0/$JAR"
echo "0185f6ead8913792fdb4045cc0aef2753feb5cb71b9204372bf0d882f9435eb4  $BUNDLE_DIR/jars/$JAR" | shasum -a 256 -c -
[ -x "$BUNDLE_DIR/tools/helm" ] || { curl -fsSL https://get.helm.sh/helm-v3.18.6-linux-amd64.tar.gz | tar -xz -C "$BUNDLE_DIR/tools" --strip-components=1 linux-amd64/helm; }

[ -x "$BUNDLE_DIR/tools/kubectl" ] || { curl -fsSL -o "$BUNDLE_DIR/tools/kubectl" https://dl.k8s.io/release/v1.35.7/bin/linux/amd64/kubectl && chmod +x "$BUNDLE_DIR/tools/kubectl"; }

echo "== done. total size:"; du -sh "$BUNDLE_DIR"
t=$(wc -l < "$BUNDLE_DIR/tars/INDEX" | tr -d ' '); n=0; STALE=""
while IFS='|' read -r f _; do [ -s "$BUNDLE_DIR/tars/$f" ] && n=$((n+1)) || echo "MISSING TAR: $f"; done < "$BUNDLE_DIR/tars/INDEX"
for f in "$BUNDLE_DIR"/tars/*.tar; do cut -d'|' -f1 "$BUNDLE_DIR/tars/INDEX" | grep -qxF "$(basename "$f")" || STALE="$STALE $(basename "$f")"; done
echo "image tars: $n of $t"; [ "$n" = "$t" ] && echo "bundle COMPLETE" || echo "NOT COMPLETE: re-run this script (finished images are skipped); see the FAILED list above"
[ -z "$STALE" ] || { echo "NOTE: $(echo $STALE | wc -w | tr -d ' ') stale tar(s) from an older release are not in INDEX (they are not loaded; delete them to keep the bundle small):"; for f in $STALE; do echo "  rm bundle/tars/$f"; done; }
