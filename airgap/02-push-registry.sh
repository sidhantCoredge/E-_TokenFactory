#!/usr/bin/env bash
# IMAGE_MODE=registry: push every image tar of the bundle into the internal registry $REGISTRY
# (alternative to loading the tars straight into the nodes). Run on the install VM (needs skopeo + `kubectl`-independent).
# Target of each image = $REGISTRY/<path>, e.g. registry.etisalat.com/tokenfactory/keycloak/keycloak:pinned-<digest>
# $REGISTRY may carry a project path (Harbor/Nexus: "harbor.example.com/tokenfactory"); the project must already exist.
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
: "${DEST_TLS_VERIFY:=true}"
T="$BUNDLE_DIR/tars"; [ -s "$T/INDEX" ] || { echo "no $T/INDEX - bundle missing"; exit 1; }
command -v skopeo >/dev/null || { echo "skopeo missing on this host (registry mode needs it)"; exit 1; }
CREDS=(); [ -n "${REGISTRY_USER:-}" ] && CREDS=(--dest-creds "$REGISTRY_USER:$REGISTRY_PASS")
n=0
while IFS='|' read -r file ref digest path; do
  [ -n "$path" ] || { echo "INDEX has no path column - rebuild the bundle with the current 01 script"; exit 1; }
  flags=(); [ -n "$digest" ] && flags=(--all --preserve-digests)   # @sha256 images must keep their manifest-list digest
  echo "push  $REGISTRY/$path"
  skopeo copy "${flags[@]}" --dest-tls-verify="$DEST_TLS_VERIFY" "${CREDS[@]}" "oci-archive:$T/$file" "docker://$REGISTRY/$path"
  n=$((n+1))
done < "$T/INDEX"
echo "pushed $n images; verifying the digest-pinned ones resolve BY DIGEST:"
VCREDS=(); [ -n "${REGISTRY_USER:-}" ] && VCREDS=(--creds "$REGISTRY_USER:$REGISTRY_PASS")
while IFS='|' read -r file ref digest path; do
  [ -n "$digest" ] || continue
  base="${path%:pinned-*}"
  skopeo inspect --tls-verify="$DEST_TLS_VERIFY" "${VCREDS[@]}" --raw "docker://$REGISTRY/$base@sha256:$digest" >/dev/null && echo "  ok  $base@sha256:${digest:0:12}…" || { echo "  MISSING $base@sha256:$digest"; exit 1; }
done < "$T/INDEX"
echo "registry push complete"
