#!/usr/bin/env bash
# RUN INSIDE THE AIR-GAP (needs skopeo + `skopeo login $REGISTRY`). Pushes bundle/images/* to $REGISTRY/<target>.
set -euo pipefail
cd "$(dirname "$0")"; . ./env.sh
: "${DEST_TLS_VERIFY:=true}"
while IFS='|' read -r name dst mode; do
  flags=""; [ "$mode" = all ] && flags="--all --preserve-digests"
  tgt="$REGISTRY/$dst"
  case "$dst" in *@sha256:*)   # digest refs: store under a tag; the manifest-list digest is preserved, so @sha256 pulls resolve
    base="${dst%@*}"; case "${base##*/}" in *:*) base="${base%:*}";; esac
    tgt="$REGISTRY/$base:pinned-${dst##*:}";; esac
  echo "push  $tgt"
  skopeo copy $flags --dest-tls-verify="$DEST_TLS_VERIFY" ${REGISTRY_USER:+--dest-creds "$REGISTRY_USER:$REGISTRY_PASS"} "oci:$BUNDLE_DIR/images/$name:img" "docker://$tgt"
done < "$BUNDLE_DIR/images/INDEX"
echo "verify (digest-pinned refs must resolve BY DIGEST):"
for d in keycloak/keycloak@sha256:37dbaf6f0722c9ec246335f36e1ef8b2e6cb960f7c27e0d8c615121a3d475a85 \
         busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 \
         openmeterio/openmeter@sha256:f3bc8075ebad57a0b02edf5f173892a9bcfbbda97af5481713fed892ef679f5f; do
  skopeo inspect --tls-verify="$DEST_TLS_VERIFY" ${REGISTRY_USER:+--creds "$REGISTRY_USER:$REGISTRY_PASS"} --raw "docker://$REGISTRY/$d" >/dev/null && echo "  ok  $d" || { echo "  MISSING $d"; exit 1; }
done
