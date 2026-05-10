#!/usr/bin/env bash
# Run the bxl_rules DScript test suite.
#
# Tests live under Tests/ as top-level `const` exports; each invokes a test
# function whose body uses Contract.assert(...). Successful spec evaluation
# = all tests passed; a non-zero exit means at least one assertion failed
# (or there was a type error).
#
# Requires:
#   - `bxl` on PATH (install via `dotnet tool install -g Microsoft.BuildXL.Tool`)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Detect the platform-specific dotnet-tool runtime directory name.
case "$(uname -s)" in
    Linux*)   ARCH_DIR="linux-x64" ;;
    Darwin*)  ARCH_DIR="osx-x64"   ;;
    MINGW*|MSYS*|CYGWIN*) ARCH_DIR="win-x64" ;;
    *) echo "ERROR: unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

# Locate the dotnet-tool deployment directory of bxl. The shim under
# ~/.dotnet/tools/ is a single-file apphost; the actual SDK files live under
# the .store. We resolve via the dotnet-tools shim store path.
BXL_BIN_HINT="$(dirname "$(realpath "$(command -v bxl)")")"
if [[ ! -d "$BXL_BIN_HINT/Sdk/Sdk.Transformers" ]]; then
    # Fallback: search the dotnet-tool store for the host-platform deployment.
    BXL_BIN_HINT="$(find "$HOME/.dotnet/tools/.store" -type d -name "$ARCH_DIR" -path '*microsoft.buildxl.tool*' 2>/dev/null | head -1)"
fi

if [[ ! -d "$BXL_BIN_HINT/Sdk/Sdk.Transformers" ]]; then
    echo "ERROR: could not locate the bxl SDK directory (looked under $BXL_BIN_HINT)." >&2
    echo "Install bxl: dotnet tool install -g Microsoft.BuildXL.Tool" >&2
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
