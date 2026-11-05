# Sourced by every script in this folder: loads config.env and works out where the bundle lives.
_a="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$_a/.." && pwd)"; export ROOT
. "$ROOT/config.env"
if [ -d "$ROOT/tars" ] || [ -d "$ROOT/images" ]; then export BUNDLE_DIR="$ROOT"; else export BUNDLE_DIR="${BUNDLE_DIR:-$ROOT/bundle}"; fi   # unpacked bundle vs. working tree
export REPO="${REPO:-$ROOT/ai-gateway-platform}"
export KUBECONFIG="${KUBECONFIG_FILE:-$HOME/.kube/config}"
if [ "$(uname -s)" = Linux ] && [ -d "$BUNDLE_DIR/tools" ]; then export PATH="$BUNDLE_DIR/tools:$PATH"; fi   # linux helm/kubectl shipped in the bundle (never on the Mac)

# envsub VAR1 VAR2 ... < in > out : replaces ${VAR} for the listed variables only (needs only perl; replaces envsubst)
envsub() { LIST="$*" perl -pe 'BEGIN{ %a = map { $_ => 1 } split " ", $ENV{LIST} } s/\$\{(\w+)\}/ $a{$1} ? ($ENV{$1} \/\/ "") : "\${$1}" /ge'; }
