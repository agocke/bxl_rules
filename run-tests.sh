#!/usr/bin/env bash
# Run the bxl_rules DScript test suite.
#
# Tests live under Tests/ as top-level `const` exports; each invokes a test
# function whose body uses Contract.assert(...). Successful spec evaluation
# = all tests passed; a non-zero exit means at least one assertion failed
# (or there was a type error).
#
# Requires:
#   - `bxl` on PATH (install via
#     `dotnet tool install -g agtest.bxl.tool --version 0.2.0-ci.3.a5a8b51`)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Detect the platform-specific dotnet-tool runtime directory name.
case "$(uname -s)" in
    Linux*)   ARCH_DIR="linux-x64" ;;
    Darwin*)  ARCH_DIR="osx-x64"   ;;
    MINGW*|MSYS*|CYGWIN*) ARCH_DIR="win-x64" ;;
    *) echo "ERROR: unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

INSTALL_CMD="dotnet tool install -g agtest.bxl.tool --version 0.2.0-ci.3.a5a8b51"
BXL_SHIM="$(command -v bxl || true)"

if [[ -z "$BXL_SHIM" ]]; then
    echo "ERROR: could not find 'bxl' on PATH." >&2
    echo "Install bxl: $INSTALL_CMD" >&2
    exit 1
fi

# Locate the dotnet-tool deployment directory of bxl. The shim under
# ~/.dotnet/tools/ is a single-file apphost; the actual SDK files live under
# the .store. Resolve the real payload directory in a package-agnostic way so
# the script works with the bootstrap compiler tool package.
BXL_BIN_HINT="$(dirname "$(realpath "$BXL_SHIM")")"
if [[ ! -d "$BXL_BIN_HINT/Sdk/Sdk.Transformers" && -d "$HOME/.dotnet/tools/.store" ]]; then
    while IFS= read -r candidate; do
        if [[ -d "$candidate/Sdk/Sdk.Transformers" ]]; then
            BXL_BIN_HINT="$candidate"
            break
        fi
    done < <(find "$HOME/.dotnet/tools/.store" -type d -path "*/tools/net*/$ARCH_DIR" 2>/dev/null)
fi

if [[ ! -d "$BXL_BIN_HINT/Sdk/Sdk.Transformers" ]]; then
    echo "ERROR: could not locate the bxl SDK directory (looked under $BXL_BIN_HINT)." >&2
    echo "Install bxl: $INSTALL_CMD" >&2
    exit 1
fi

export BUILDXL_BIN="$BXL_BIN_HINT"

echo "BUILDXL_BIN = $BUILDXL_BIN"
echo "Running bxl on $REPO_ROOT/config.dsc ..."

# /phase:Schedule stops after spec evaluation + pip-graph construction — we
# don't need to execute pips since the tests assert at evaluation time.
# /sandboxKind:None and /enableLinuxEBPFSandbox- bypass eBPF sandbox setup
# (which would otherwise fail on systems without the deployment files).
cd "$REPO_ROOT"
bxl /c:config.dsc /phase:Schedule /sandboxKind:None /enableLinuxEBPFSandbox- "$@"
