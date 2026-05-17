#!/usr/bin/env bash
# Run the execution-level build-vs-run split tests.
#
# Unlike run-tests.sh (which uses /phase:Schedule and only exercises spec
# evaluation), this script ACTUALLY executes pips and inspects the
# filesystem to verify which pips ran under different filters.
#
# The Tests/Exec workspace defines one binary-kind rule that schedules:
#   - build.txt on ctx.actions     (untagged)
#   - run.txt   on ctx.runActions  (tagged bxl-kind:binary), depending on build.txt
#
# Three scenarios are exercised; the table below is the contract that
# downstream consumers can rely on.
#
#   Scenario  Filter                                       Expected files
#   --------  -------------------------------------------  --------------------
#   bazel-run /f:tag='bxl-kind:binary'                     build.txt, run.txt
#   bazel-bld /f:~(tag='bxl-kind:binary')...               build.txt
#   default   (no filter)                                  build.txt, run.txt
#
# A non-zero exit means the kind-tagging contract regressed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
EXEC_WS="$REPO_ROOT/Tests/Exec"

case "$(uname -s)" in
    Linux*)   ARCH_DIR="linux-x64" ;;
    Darwin*)  ARCH_DIR="osx-x64"   ;;
    MINGW*|MSYS*|CYGWIN*) ARCH_DIR="win-x64" ;;
    *) echo "ERROR: unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

BXL_SHIM="$(command -v bxl || true)"
if [[ -z "$BXL_SHIM" ]]; then
    echo "ERROR: 'bxl' not on PATH. Install with: dotnet tool install -g agtest.bxl.tool" >&2
    exit 1
fi
BXL_BIN_HINT="$(dirname "$(realpath "$BXL_SHIM")")"
if [[ ! -d "$BXL_BIN_HINT/Sdk/Sdk.Transformers" && -d "$HOME/.dotnet/tools/.store" ]]; then
    while IFS= read -r candidate; do
        if [[ -d "$candidate/Sdk/Sdk.Transformers" ]]; then
            BXL_BIN_HINT="$candidate"
            break
        fi
    done < <(find "$HOME/.dotnet/tools/.store" -type d -path "*/tools/net*/$ARCH_DIR" 2>/dev/null)
fi
export BUILDXL_BIN="$BXL_BIN_HINT"

cd "$EXEC_WS"

# Run bxl in the Exec workspace and report Build/run.txt presence.
# Args: <label> <filter>... (filter may be empty)
run_scenario() {
    local label="$1"; shift
    echo "==> [$label] bxl $*"
    rm -rf Out
    bxl /c:config.dsc /sandboxKind:None /enableLinuxEBPFSandbox- "$@" \
        >/tmp/bxl-exec-test.log 2>&1 \
        || { echo "    FAIL: bxl exit nonzero"; tail -40 /tmp/bxl-exec-test.log; exit 1; }
    local has_build="no" has_run="no"
    if find Out/Objects -type f -name build.txt 2>/dev/null | grep -q .; then has_build="yes"; fi
    if find Out/Objects -type f -name run.txt   2>/dev/null | grep -q .; then has_run="yes";   fi
    echo "    build.txt=$has_build  run.txt=$has_run"
    SCENARIO_BUILD="$has_build"
    SCENARIO_RUN="$has_run"
}

assert_eq() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "    FAIL: $what — expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

# Scenario 1: `bazel run` analog — tag selection pulls in run pip + its
# transitive build-pip dependency. Both files must materialise.
run_scenario "bazel-run"     "/f:tag='bxl-kind:binary'"
assert_eq "build.txt under tag=binary" "yes" "$SCENARIO_BUILD"
assert_eq "run.txt under tag=binary"   "yes" "$SCENARIO_RUN"

# Scenario 2: `bazel build //...` analog — exclusion filter drops the
# run-tagged pip, so only the build-time output materialises.
run_scenario "bazel-build"   "/f:~(tag='bxl-kind:binary')"
assert_eq "build.txt under ~tag=binary" "yes" "$SCENARIO_BUILD"
assert_eq "run.txt under ~tag=binary"   "no"  "$SCENARIO_RUN"

# Scenario 3: bare `bxl` — BuildXL's default filter runs ALL pips in
# the graph. This is the documented (non-Bazel-equivalent) baseline:
# both outputs materialise. Important to assert so a future framework
# change that silently filters by reachability is caught.
run_scenario "default"       # no filter
assert_eq "build.txt under default" "yes" "$SCENARIO_BUILD"
assert_eq "run.txt under default"   "yes" "$SCENARIO_RUN"

echo "All exec-split scenarios passed."
