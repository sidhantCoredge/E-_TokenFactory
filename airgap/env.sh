# Sourced by every script in this folder: loads config.env and works out where the bundle lives.
# ${BASH_SOURCE[0]} is empty in zsh (the macOS default shell): there $0 is the sourced file, so both shells work
_a="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"; ROOT="$(cd "$_a/.." && pwd)"; export ROOT
. "$ROOT/config.env"
# A BUNDLE_DIR / REPO left in your terminal by an earlier mistake silently redirects every script (the bundle once ended up in ~/Downloads/bundle). Say so.
for _v in BUNDLE_DIR REPO; do eval "_val=\${$_v:-}"; case "$_val" in ''|"$ROOT"|"$ROOT"/*) ;; *) echo "WARNING: $_v=$_val is outside the package folder $ROOT and is used as it is. To use the package folder: unset ROOT BUNDLE_DIR REPO" >&2;; esac; done
if [ -d "$ROOT/tars" ] || [ -d "$ROOT/images" ]; then export BUNDLE_DIR="$ROOT"; else export BUNDLE_DIR="${BUNDLE_DIR:-$ROOT/bundle}"; fi   # unpacked bundle vs. working tree
export REPO="${REPO:-$ROOT/ai-gateway-platform}"
export KUBECONFIG="${KUBECONFIG_FILE:-$HOME/.kube/config}"
if [ "$(uname -s)" = Linux ] && [ -d "$BUNDLE_DIR/tools" ]; then export PATH="$BUNDLE_DIR/tools:$PATH"; fi   # linux helm/kubectl shipped in the bundle (never on the Mac)

# envsub VAR1 VAR2 ... < in > out : replaces ${VAR} for the listed variables only (needs only perl; replaces envsubst)
envsub() { LIST="$*" perl -pe 'BEGIN{ %a = map { $_ => 1 } split " ", $ENV{LIST} } s/\$\{(\w+)\}/ $a{$1} ? ($ENV{$1} \/\/ "") : "\${$1}" /ge'; }
