#!/usr/bin/env bash
# RUN ON THE INTERNET-CONNECTED MAC/LAPTOP, from the package root. Builds ./bundle/ : image TAR files + charts + CRDs + jar + helm.
# Needs: skopeo, helm, curl, tar, perl.  Logins first:  skopeo login docker.io   skopeo login ghcr.io  (ghcr needs a READ token for infinia-technology)
set -euo pipefail
cd "$(dirname "$0")/.."
. airgap/env.sh
mkdir -p "$BUNDLE_DIR"/{tars,charts,crds,jars,repo,tools}
case "$TF_TAG$BRAND_TAG" in *REPLACE*) echo "set TF_TAG and BRAND_TAG in config.env first"; exit 1;; esac
command -v skopeo >/dev/null || { echo "skopeo missing (brew install skopeo)"; exit 1; }

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
  if skopeo copy $flags "docker://$from" "oci-archive:$tar.part:$ref"; then mv "$tar.part" "$tar"; else FAILED="$FAILED\n  $src"; fi
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
curl -fsSL -o "$BUNDLE_DIR/crds/gateway-api-standard-install-v1.3.0.yaml" https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

echo "== keycloak SPI jar + helm (linux-amd64) =="
curl -fsSL -o "$BUNDLE_DIR/jars/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar" \
 https://repo1.maven.org/maven2/io/github/mesutpiskin/keycloak-2fa-email-authenticator/26.5.0-KC26.7.3/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar
[ -x "$BUNDLE_DIR/tools/helm" ] || { curl -fsSL https://get.helm.sh/helm-v3.18.6-linux-amd64.tar.gz | tar -xz -C "$BUNDLE_DIR/tools" --strip-components=1 linux-amd64/helm; }

[ -x "$BUNDLE_DIR/tools/kubectl" ] || { curl -fsSL -o "$BUNDLE_DIR/tools/kubectl" https://dl.k8s.io/release/v1.35.7/bin/linux/amd64/kubectl && chmod +x "$BUNDLE_DIR/tools/kubectl"; }

echo "== done. total size:"; du -sh "$BUNDLE_DIR"
n=$(ls "$BUNDLE_DIR"/tars/*.tar 2>/dev/null | wc -l); t=$(wc -l < "$BUNDLE_DIR/tars/INDEX"); echo "image tars: $n of $t"; [ "$n" = "$t" ] || echo "NOT COMPLETE: build the missing tars (minio: airgap/fetch-minio-from-acr.sh on the jumphost)"
