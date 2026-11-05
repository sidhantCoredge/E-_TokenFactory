# Sourced by every script in this folder: loads config.env and works out where the bundle lives.
_a="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$_a/.." && pwd)"; export ROOT
. "$ROOT/config.env"
if [ -d "$ROOT/images" ]; then export BUNDLE_DIR="$ROOT"; else export BUNDLE_DIR="${BUNDLE_DIR:-$ROOT/bundle}"; fi   # unpacked bundle vs. working tree
export REPO="${REPO:-$ROOT/ai-gateway-platform}"
