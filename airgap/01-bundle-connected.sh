#!/usr/bin/env bash
# RUN ON AN INTERNET-CONNECTED HOST. Builds ./bundle/ (images + charts + CRDs + jar) to carry into the air-gap.
# Run from the package root (ethisalat/). Needs: skopeo, helm >=3.14, curl, tar, envsubst. `docker login` / `skopeo login` to docker.io (rate limit) and ghcr.io (private tf-* images) first.
set -euo pipefail
cd "$(dirname "$0")/.."                      # = ethisalat/
. airgap/env.sh
[ -d "$ROOT/images" ] || true
REPO="${REPO:-$PWD/ai-gateway-platform}"     # checkout used for the deploy (the same commit as TF_TAG)
mkdir -p "$BUNDLE_DIR"/{images,charts,crds,jars,repo,registry}
case "$TF_TAG$BRAND_TAG" in *REPLACE*) echo "set TF_TAG/BRAND_TAG in config.env"; exit 1;; esac
command -v skopeo >/dev/null || { echo "skopeo missing"; exit 1; }

echo "== images =="
grep -vE '^\s*(#|$)' airgap/images.txt | envsubst '${TF_TAG} ${BRAND_TAG}' | while IFS='|' read -r src dst mode; do
  src=$(echo $src); dst=$(echo $dst); mode=$(echo $mode)
  name=$(echo "$dst" | tr '/:@' '___')
  [ -d "$BUNDLE_DIR/images/$name" ] && { echo "skip  $dst"; continue; }
  flags="--override-os linux --override-arch ${PLATFORM#linux/}"; [ "$mode" = all ] && flags="--all --preserve-digests"
  echo "pull  $src"
  skopeo copy $flags "docker://$src" "oci:$BUNDLE_DIR/images/$name:img"
  printf '%s|%s|%s\n' "$name" "$dst" "$mode" >> "$BUNDLE_DIR/images/INDEX"
done

echo "== registry:2 (only used if you have no registry: airgap/02a-local-registry.sh) =="
[ -f "$BUNDLE_DIR/registry/registry2.tar" ] || skopeo copy --override-os linux --override-arch "${PLATFORM#linux/}" docker://docker.io/library/registry:2 docker-archive:"$BUNDLE_DIR/registry/registry2.tar":registry:2

echo "== helm charts =="
( cd "$REPO/helm/tokenfactory" && helm dependency build )
( cd "$REPO/helm/infrastructure/openmeter" && helm dependency build )        # vendors openmeter-1.0.0-beta.231.tgz into charts/
pullchart(){ # name version  (docker.io OCI)  -- via helm; fall back message if Docker Hub auth fails
  helm pull "oci://docker.io/envoyproxy/$1" --version "$2" -d "$BUNDLE_DIR/charts"; }
pullchart gateway-helm v1.8.1; pullchart ai-gateway-crds-helm v1.0.0; pullchart ai-gateway-helm v1.0.0
helm pull oci://ghcr.io/nginx/charts/nginx-ingress --version 1.3.2 -d "$BUNDLE_DIR/charts"     # F5 ingress controller (nginx-ingress-1.3.2.tgz)
curl -fsSL -o "$BUNDLE_DIR/crds/gateway-api-standard-install-v1.3.0.yaml" \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

echo "== keycloak SPI jar (otherwise fetched from Maven Central at pod start) =="
curl -fsSL -o "$BUNDLE_DIR/jars/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar" \
 https://repo1.maven.org/maven2/io/github/mesutpiskin/keycloak-2fa-email-authenticator/26.5.0-KC26.7.3/keycloak-2fa-email-authenticator-26.5.0-KC26.7.3.jar

echo "== repo snapshot (chart + setup scripts + brand theme; vendored charts/ included) =="
COPYFILE_DISABLE=1 tar --exclude=.git -C "$(dirname "$REPO")" -czf "$BUNDLE_DIR/repo/ai-gateway-platform.tgz" "$(basename "$REPO")"
cp -R zalando values airgap patches config.env "$BUNDLE_DIR/"
( cd "$BUNDLE_DIR" && find . -type f -not -path './images/*' -print0 | xargs -0 sha256sum > SHA256SUMS && du -sh . )
echo "DONE -> tar -cf etisalat-bundle.tar -C $(dirname "$BUNDLE_DIR") $(basename "$BUNDLE_DIR") and move it across"
