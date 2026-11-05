#!/usr/bin/env bash
# RUN INSIDE THE AIR-GAP on the extracted repo copy, ONCE, before the installs. Idempotent.
# Rewrites the 3 image references that are hardcoded in chart TEMPLATES (no value can reach them):
#   1. helm/services/tf-auth/templates/workload.yaml       busybox:1.36@sha256:...           (wait-for-keycloak init)
#   2. openmeter subchart  templates/_helpers.tpl          busybox:<init.busybox.tag>        (init containers)
#   3. openmeter subchart  templates/clickhouse.yaml       clickhouse/clickhouse-server:24.10
#   4. openmeter subchart  templates/clickhouse.yaml       ClickHouse PVC: hardcoded 3Gi data / 1Gi log and NO storageClassName
#      (-> CH_DATA_SIZE / CH_LOG_SIZE / STORAGE_CLASS from config.env). Without this ClickHouse fills a 3Gi disk and uses the default class.
# Usage: REPO=... REGISTRY=... STORAGE_CLASS=... CH_DATA_SIZE=50Gi CH_LOG_SIZE=5Gi ./03-patch-hardcoded-images.sh
set -euo pipefail
: "${REPO:?}"; : "${REGISTRY:?}"; : "${STORAGE_CLASS:?}"; : "${CH_DATA_SIZE:?}"; : "${CH_LOG_SIZE:?}"
BB='busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
f="$REPO/helm/services/tf-auth/templates/workload.yaml"
BB="$BB" REG="$REGISTRY" perl -pi -e 's#image: \Q$ENV{BB}\E#image: $ENV{REG}/$ENV{BB}#' "$f"
grep -qF "image: $REGISTRY/$BB" "$f" || { echo "FAILED: tf-auth busybox not patched"; exit 1; }
echo "ok tf-auth busybox"

tgz=$(ls "$REPO"/helm/infrastructure/openmeter/charts/openmeter-*.tgz); tmp=$(mktemp -d)
tar -xzf "$tgz" -C "$tmp"
perl -pi -e 's#image: "busybox:#image: "'"$REGISTRY"'/busybox:#' "$tmp/openmeter/templates/_helpers.tpl"
perl -pi -e 's#image: clickhouse/clickhouse-server:24\.10#image: '"$REGISTRY"'/clickhouse/clickhouse-server:24.10#' "$tmp/openmeter/templates/clickhouse.yaml"
[ "$(grep -c "$REGISTRY/busybox" "$tmp/openmeter/templates/_helpers.tpl")" -ge 1 ] || { echo "FAILED: openmeter busybox"; exit 1; }
grep -qF "$REGISTRY/clickhouse/clickhouse-server:24.10" "$tmp/openmeter/templates/clickhouse.yaml" || { echo "FAILED: openmeter clickhouse"; exit 1; }
echo "ok openmeter busybox + clickhouse"
echo "NEXT: (cd \$REPO/helm/tokenfactory && helm dependency build)   # re-vendors the patched tf-auth subchart; file:// only, works offline"
CHF="$tmp/openmeter/templates/clickhouse.yaml"
SC="$STORAGE_CLASS" DS="$CH_DATA_SIZE" LS="$CH_LOG_SIZE" perl -0pi -e '
  s{(- name: data-storage-vc-template\n\s+spec:\n)(\s+)(accessModes:)}{$1$2storageClassName: $ENV{SC}\n$2$3};
  s{(- name: log-storage-vc-template\n\s+spec:\n)(\s+)(accessModes:)}{$1$2storageClassName: $ENV{SC}\n$2$3};
  s{storage: 3Gi}{storage: $ENV{DS}}; s{storage: 1Gi}{storage: $ENV{LS}};' "$CHF"
grep -qF "storage: $CH_DATA_SIZE" "$CHF" && grep -qF "storage: $CH_LOG_SIZE" "$CHF" && [ "$(grep -c "storageClassName: $STORAGE_CLASS" "$CHF")" = 2 ] || { echo "FAILED: ClickHouse PVC patch"; exit 1; }
echo "ok openmeter clickhouse PVC ($CH_DATA_SIZE data / $CH_LOG_SIZE log, class $STORAGE_CLASS)"
COPYFILE_DISABLE=1 tar -C "$tmp" -czf "$tgz" openmeter && rm -rf "$tmp"
