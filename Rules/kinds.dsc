// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import {Cmd, Transformer} from "Sdk.Transformers";

/**
 * "Kinds" — first-class library / binary / test primitives.
 *
 * Background
 * ----------
 * Bazel exposes three pip kinds — `*_library`, `*_binary`, `*_test` — and
 * surfaces them everywhere: `bazel test //...`, `bazel run //x:bin`,
 * `--test_tag_filters`, the typed `TestInfo`/`RunInfo` providers, and so
 * on. Without an equivalent contract, every BuildXL rule set (and every
 * CI driver consuming one) ends up inventing per-project conventions —
 * `find -name '*.test.stamp' | wc -l`, hand-rolled `grep` against
 * `BUILD.dsc`, ad-hoc filter strings — to answer "how many tests passed"
 * or "run all tests".
 *
 * Scope of this module
 * --------------------
 * This module provides the cross-language pieces needed to keep that
 * contract uniform across `bxl_rules_dotnet`, `bxl_rules_<language>`,
 * and downstream CI tooling:
 *
 *   - The `kind: "library" | "binary" | "test"` field on
 *     `Rules.rule({...})` (declared in providers.dsc). The Actions
 *     adapter uses it to drive framework behaviour:
 *
 *       kind        | ctx.actions auto-tag | ctx.runActions
 *       ------------|----------------------|--------------------------------
 *       "library"   | (none)               | (not provided)
 *       (undefined) | (none)               | (not provided)
 *       "binary"    | (none)               | provided; pips auto-tagged
 *                   |                      | bxl-kind:binary
 *       "test"      | (none)               | provided; pips auto-tagged
 *                   |                      | bxl-kind:test
 *
 *     This split is the key to the Bazel build-vs-run/test benefit:
 *
 *       bazel build //...     → bxl /f:~(tag='bxl-kind:binary')and
 *                                    ~(tag='bxl-kind:test')
 *       bazel test  //...     → bxl /f:tag='bxl-kind:test'
 *       bazel run   //x:bin   → bxl /f:tag='bxl-kind:binary'
 *
 *     BuildXL's default filter (no `/f:`) runs *every* pip in the
 *     graph, so a bare `bxl` is "build + run everything", with no
 *     Bazel direct analog. The `bazel build //...` form requires an
 *     *exclusion* filter that drops the `bxl-kind:*` tags — the run-
 *     time pips are then skipped, and only the rules' build-time
 *     outputs (`ctx.actions`, in `DefaultInfo.files`) materialise.
 *     Conversely, the positive `/f:tag='...'` filters are transitive
 *     in BuildXL: they pull in the build-time pips the selected run-
 *     time pip depends on, so a `bazel run`-style selection builds
 *     the binary too.
 *
 *     Wrap the exclusion filter in a CI driver / shell alias so
 *     end users get `bazel build`-like ergonomics from a single
 *     command.
 *
 *   - `TestInfo`     — typed provider every `*_test` rule returns
 *                      alongside `DefaultInfo`. Carries the stamp +
 *                      runat artifacts (run-time outputs, produced
 *                      through `ctx.runActions`), declared timeout,
 *                      and user tags (`"manual"`, `"integration"`, ...).
 *   - `BinaryInfo`   — typed provider every `*_binary` rule returns
 *                      alongside `DefaultInfo`. Carries the compiled
 *                      binary (build-time, in `DefaultInfo.files`) and
 *                      a generated invocation shim produced via
 *                      `ctx.runActions` (run-time, deferred).
 *
 *   - `test_suite()` — aggregator macro that collects `TestInfo`
 *                      providers and emits a `<name>.tests.json`
 *                      manifest. CI drivers read the manifest instead
 *                      of grepping `BUILD.dsc` files.
 *
 * Design notes
 * ------------
 *  - The `bxl-kind:*` tag vocabulary is *not* public. It is applied by
 *    the Actions adapter (see providers.dsc / `createActionsForRule`)
 *    using the package-private `kindTagFor()` / `runTagFor()` helpers
 *    below. Rule authors declare kind once on
 *    `Rules.rule({ kind: "binary", ... })` and let the framework do
 *    the tagging — this keeps the tag string an implementation detail
 *    that can evolve without breaking callers.
 *  - For `kind: "binary"` and `kind: "test"`, the framework hands the
 *    rule impl a second `Actions` instance (`ctx.runActions`). It
 *    shares the target's output directory and single-binding claim-set
 *    with `ctx.actions`, but everything scheduled through it is tagged
 *    with the matching `bxl-kind:*` value. Rule authors schedule the
 *    compile via `ctx.actions` (and include the result in
 *    `DefaultInfo.files`); they schedule runfiles tree staging — and,
 *    for tests, the runner invocation that produces stamp / runat —
 *    via `ctx.runActions` (and expose those Artifacts only on the
 *    per-kind provider, never in `DefaultInfo.files`).
 *  - Provider fields use `Artifact` (not raw `File`), in line with the
 *    rest of the rules SDK (see Rules/artifact.dsc). The stamp and
 *    runat outputs are produced by the test runner pip the rule author
 *    schedules, then handed to `testInfo(...)` already bound.
 *  - There is intentionally **no** `LibraryInfo` here. A library has no
 *    kind-specific metadata beyond its files, so `DefaultInfo` is
 *    sufficient. (Bazel itself folds library outputs into `DefaultInfo`
 *    + language-specific providers — there is no generic `LibraryInfo`.)
 *  - There is intentionally **no** `kind=test` filter syntax or `bxl
 *    test` verb here — those would require BuildXL engine changes. The
 *    tag convention rides on the existing `/f:tag=...` syntax instead.
 *
 * `runat` and cached-vs-executed reporting
 * ----------------------------------------
 * Each test runner is expected to write **two** outputs:
 *   - `<name>.test.stamp` — empty success marker.
 *   - `<name>.test.runat` — captures `date +%s%N` at the moment the pip
 *                           body runs.
 * BuildXL replays cached outputs byte-identically, so on a cache hit
 * `runat` still contains the *original* execution timestamp. A CI driver
 * compares each `runat` against the build start time to derive a
 * reliable "N cached, M ran" line without parsing the XLG. This trick
 * is documented here so every language's test rule benefits from it.
 */

// ============================================================================
//  Package-private kind-tag vocabulary
// ============================================================================

/**
 * The kind discriminator a rule author declares on `Rules.rule({...})`.
 * Re-exported under this name from providers.dsc as the type of the
 * `RuleDefinition.kind` field.
 */
@@public
export type RuleKind = "library" | "binary" | "test";

/**
 * Well-known pip-tag values for differentiating rule kinds.
 *
 * Intentionally **not** `@@public`: the tag vocabulary is an SDK
 * implementation detail. The Actions adapter applies these via the
 * `kindTagFor` / `runTagFor` helpers below; CI drivers select by
 * kind using BuildXL's existing tag filter syntax against the
 * *string literal* — e.g. `bxl /f:tag='bxl-kind:test'` — never via
 * this constant.
 */
const kindTags = {
    test: "bxl-kind:test",
    binary: "bxl-kind:binary",
};

/**
 * Tag the framework attaches to every pip scheduled through the rule's
 * **primary** Actions adapter (`ctx.actions`).
 *
 * Currently always `undefined` — every kind's build-time pips are
 * intentionally untagged so they're scheduled by a plain `bxl` build
 * alongside everything else's default outputs. Run-time pips get
 * their tag from `runTagFor` below.
 *
 * Kept as a separate function (rather than inlined / removed) so that
 * if a future kind needs to tag its build pips, the change has a
 * single sanctioned site.
 *
 * Package-private — called from providers.dsc / `createActionsForRule`.
 */
export function kindTagFor(kind?: RuleKind): string {
    return undefined;
}

/**
 * Tag the framework attaches to every pip scheduled through the rule's
 * **run-time** Actions adapter (`ctx.runActions`).
 *
 *   "binary" → `bxl-kind:binary`
 *   "test"   → `bxl-kind:test`
 *   anything else → undefined  (only binary and test rules get a
 *                               run-time adapter; for libraries the
 *                               framework does not surface one at all).
 *
 * Package-private — called from providers.dsc / `createActionsForRule`.
 */
export function runTagFor(kind?: RuleKind): string {
    if (kind === "binary") return kindTags.binary;
    if (kind === "test")   return kindTags.test;
    return undefined;
}

// ============================================================================
//  TestInfo — provider returned by `*_test` rules
// ============================================================================

/**
 * Bazel-shaped t-shirt sizing for tests. Each size implies a default
 * timeout wall clock and a rough resource bucket. An explicit
 * `timeoutSec` on `testInfo(...)` always wins; otherwise the size's
 * default is used; otherwise the implementation falls back to
 * `medium` (300s).
 *
 * Defaults match Bazel:
 *   small     →   60s
 *   medium    →  300s   (5 min)
 *   large     →  900s   (15 min)
 *   enormous  → 3600s   (1 hour)
 */
@@public
export type TestSize = "small" | "medium" | "large" | "enormous";

/**
 * Resolve a `TestSize` to its default timeout in seconds. Internal
 * helper for the `testInfo` constructor.
 */
function defaultTimeoutForSize(size: TestSize): number {
    if (size === "small")    return 60;
    if (size === "medium")   return 300;
    if (size === "large")    return 900;
    if (size === "enormous") return 3600;
    return 300;
}

/**
 * Typed provider every `*_test` rule should return alongside its
 * `DefaultInfo`. Lets generic infrastructure (the `test_suite` macro,
 * CI drivers, IDE integrations) discover tests without knowing the
 * specific rule type.
 *
 * Bazel equivalent: `TestInfo` (built-in) plus the `size` / `timeout` /
 * `flaky` attribute family from `*_test` rules.
 *
 * Build-vs-test split (mirrors Bazel)
 * -----------------------------------
 * - The compiled test binary is the **build-time** output. The rule
 *   schedules it through `ctx.actions` and includes it in
 *   `DefaultInfo.files`, so the `bazel build //...` analog
 *   (`bxl /f:~(tag='bxl-kind:binary')and~(tag='bxl-kind:test')`)
 *   compiles the test without running it.
 * - `stamp` and `runat` are **run-time** outputs, produced by the
 *   test-runner pip the rule schedules through `ctx.runActions` (which
 *   auto-tags `bxl-kind:test`). They must **not** appear in
 *   `DefaultInfo.files`. The exclusion filter above drops the tagged
 *   pip; `bxl /f:tag='bxl-kind:test'` (the `bazel test //...` analog)
 *   — or referencing a `test_suite` value that aggregates them —
 *   schedules execution. Note that a bare `bxl` with no filter runs
 *   *all* pips (BuildXL's default), so it executes the test too; the
 *   build-vs-test distinction is filter-driven, not default-driven.
 *
 * Both `stamp` and `runat` must be **bound** Artifacts produced by the
 * test runner pip. The runner writes an empty stamp on success and
 * captures `date +%s%N` into the runat file at execution time; the
 * cached-vs-executed trick described at the top of this module
 * relies on the runat byte-replay.
 */
@@public
export interface TestInfo extends Provider {
    /** Narrowed discriminator. */
    kind: "TestInfo";

    /** Logical test name (typically the rule's `name` attribute). */
    name: string;

    /**
     * Success marker file written by the runner (bound Artifact).
     * **Run-time** output — produced via `ctx.runActions`; the
     * underlying pip is tagged `bxl-kind:test`. Must not appear in
     * the rule's `DefaultInfo.files`.
     */
    stamp: Artifact;

    /**
     * Run-at-timestamp file written by the runner. Contents are the
     * nanosecond-precision wall time captured at execution. Cached
     * replays preserve the original timestamp byte-for-byte.
     * **Run-time** output — same scheduling rules as `stamp`.
     */
    runat: Artifact;

    /**
     * T-shirt size that drove the default timeout bucket. Optional —
     * a test may carry just an explicit `timeoutSec` with no size, or
     * neither (in which case the constructor falls back to "medium").
     * Promoted to a first-class field (rather than a `tags[]` string)
     * because CI dashboards and shard schedulers routinely group by
     * size, and a typed value rules out `"smol"`-style typos.
     */
    size?: TestSize;

    /**
     * Wall-clock timeout in seconds. Always populated by the
     * constructor — either explicit, derived from `size`, or the
     * fallback "medium" default (300s).
     */
    timeoutSec: number;

    /**
     * Retry-on-failure policy intent. Optional; absent ≡ false. A
     * language-specific test runner consumes this to decide whether
     * to re-invoke the inner test process; the wrapping pip still
     * produces a single stamp / runat pair regardless.
     */
    flaky?: boolean;

    /**
     * User tags. Used by CI drivers for selection (e.g. `"manual"`,
     * `"exclusive"`, `"integration"`, `"smoke"`). These are *not* the
     * same as the framework-applied `bxl-kind:test` pip tag — the
     * latter is attached automatically when the rule declares
     * `kind: "test"` on `Rules.rule({...})`.
     *
     * Bazel's well-known conventional tags (`"manual"`, `"exclusive"`,
     * `"external"`, `"requires-network"`, ...) are intentionally not
     * promoted to typed fields: they round-trip cleanly as strings,
     * and BuildXL's `/f:tag='...'` filter matches them directly
     * without a translation layer.
     */
    tags: string[];
}

/**
 * Convenience constructor for `TestInfo`. Sets the `kind` discriminator
 * and resolves `timeoutSec` from `size` when not given explicitly.
 *
 * Timeout precedence: explicit `args.timeoutSec` > `args.size`'s
 * default > `"medium"` default (300s).
 */
@@public
export function testInfo(args: {
    name: string,
    stamp: Artifact,
    runat: Artifact,
    size?: TestSize,
    timeoutSec?: number,
    flaky?: boolean,
    tags?: string[],
}): TestInfo {
    Contract.requires(args.stamp !== undefined, "testInfo: stamp must not be undefined");
    Contract.requires(args.stamp.kind !== "unbound",
        `testInfo: stamp Artifact must be bound (kind !== "unbound"); got "${args.stamp.kind}"`);
    Contract.requires(args.runat !== undefined, "testInfo: runat must not be undefined");
    Contract.requires(args.runat.kind !== "unbound",
        `testInfo: runat Artifact must be bound (kind !== "unbound"); got "${args.runat.kind}"`);

    const resolvedTimeout =
        args.timeoutSec !== undefined ? args.timeoutSec :
        args.size       !== undefined ? defaultTimeoutForSize(args.size) :
        /* fallback: */                 defaultTimeoutForSize("medium");

    return {
        kind: "TestInfo",
        name: args.name,
        stamp: args.stamp,
        runat: args.runat,
        size: args.size,
        timeoutSec: resolvedTimeout,
        flaky: args.flaky,
        tags: args.tags || [],
    };
}

// ============================================================================
//  TestRunInfo — rule-facing test descriptor (framework generates runner)
// ============================================================================

/**
 * Descriptor a `kind: "test"` rule returns to tell the framework
 * **what** to run. The framework takes this and automatically:
 *
 *   1. Generates a runner script (timeout, stamp, runat capture)
 *   2. Schedules the runner pip on `runActions` (auto-tagged `bxl-kind:test`)
 *   3. Constructs a `TestInfo` provider with the produced stamp/runat
 *
 * This mirrors Bazel's model where a `test = True` rule returns `RunInfo`
 * (the executable) and the framework handles everything else. Rule authors
 * never write timeout/stamp/runat boilerplate.
 *
 * The `executable` field is the test script or binary to invoke. It will
 * be `chmod +x`'d by the runner. `deps` are staged (copied) into the
 * runner's output directory before execution.
 */
@@public
export interface TestRunInfo extends Provider {
    kind: "TestRunInfo";

    /** The test executable (script or binary) to run. */
    executable: Artifact;

    /**
     * Exit codes that indicate success. Default: `[0]`.
     * CoreCLR tests use `[100]`.
     */
    successExitCodes?: number[];

    /** Environment variables for the test process. */
    env?: {name: string, value: string}[];

    /**
     * Data files staged into the runner's output directory before
     * execution. The executable can reference them by leaf name
     * relative to its own location.
     */
    deps?: Artifact[];

    /** T-shirt sizing — drives the default timeout. */
    size?: TestSize;

    /** Explicit wall-clock timeout in seconds. */
    timeoutSec?: number;

    /** Whether the test is known-flaky. */
    flaky?: boolean;

    /** User tags. */
    tags?: string[];
}

/**
 * Convenience constructor for `TestRunInfo`.
 */
@@public
export function testRunInfo(args: {
    executable: Artifact,
    successExitCodes?: number[],
    env?: {name: string, value: string}[],
    deps?: Artifact[],
    size?: TestSize,
    timeoutSec?: number,
    flaky?: boolean,
    tags?: string[],
}): TestRunInfo {
    Contract.requires(args.executable !== undefined,
        "testRunInfo: executable must not be undefined");
    return {
        kind: "TestRunInfo",
        executable: args.executable,
        successExitCodes: args.successExitCodes,
        env: args.env,
        deps: args.deps,
        size: args.size,
        timeoutSec: args.timeoutSec,
        flaky: args.flaky,
        tags: args.tags,
    };
}

const testRunnerBash = sourceArtifact(f`/bin/bash`);

/**
 * Schedule a test runner pip from a `TestRunInfo`.
 *
 * Call this from a `kind: "test"` rule's impl to let the framework
 * handle test execution boilerplate (timeout, stamp, runat, exit-code
 * checking). The rule provides `TestRunInfo` (what to run); this
 * function handles how (generates the runner script, stages deps,
 * schedules the pip on `runActions`).
 *
 * Returns a `TestInfo` provider with the produced stamp/runat artifacts.
 */
@@public
export function scheduleTestRunner(
    name: string,
    runInfo: TestRunInfo,
    runActions: Actions
): TestInfo {
    const timeoutSec =
        runInfo.timeoutSec !== undefined ? runInfo.timeoutSec :
        runInfo.size !== undefined ? defaultTimeoutForSize(runInfo.size) :
        60;

    const successCodes = runInfo.successExitCodes || [0];
    const successCodesStr = successCodes.map(code => `${code}`);
    const successChecks = successCodesStr
        .map(code => `[[ "$exit_code" -eq ${code} ]]`)
        .join(" || ");

    // Stage the executable if it's a source artifact. If it's already
    // bound (produced by an earlier action, e.g. writeFile on the same
    // runActions), it's already in the output directory — skip the copy.
    const stagedExe = runInfo.executable.kind === "source"
        ? runActions.copyFile(
            runInfo.executable,
            runActions.declareOutput(runInfo.executable.path.name.toString()))
        : runInfo.executable;

    // Stage data deps alongside the executable.
    const rawDeps: Artifact[] = runInfo.deps || [];
    const stagedDeps: Artifact[] = rawDeps.map(a =>
        runActions.copyFile(a, runActions.declareOutput(a.path.name.toString())));

    const stamp = runActions.declareOutput(`${name}.test.stamp`);
    const runat = runActions.declareOutput(`${name}.test.runat`);
    const script = runActions.writeFile(
        runActions.declareOutput(`${name}.test.sh`),
        [
            "#!/usr/bin/env bash",
            "set -euo pipefail",
            `date +%s%N > "$1"`,
            "shift",
            `stamp="$1"`,
            "shift",
            `chmod +x "$1"`,
            "set +e",
            `timeout --foreground --kill-after=10 ${timeoutSec} "$@"`,
            "exit_code=$?",
            "set -e",
            `if ${successChecks}; then`,
            `  printf 'passed\\n' > "$stamp"`,
            "  exit 0",
            "fi",
            `if [[ "$exit_code" -eq 124 || "$exit_code" -eq 137 ]]; then`,
            `  echo "Test timed out after ${timeoutSec}s" >&2`,
            "fi",
            `echo "Test failed with exit code $exit_code (expected: ${successCodesStr.join(", ")})" >&2`,
            `exit "$exit_code"`,
        ]);

    const produced = runActions.run({
        tool: testRunnerBash,
        arguments: [
            Cmd.argument(cmdInput(script)),
            Cmd.argument(cmdOutput(runat)),
            Cmd.argument(cmdOutput(stamp)),
            Cmd.argument(cmdInput(stagedExe)),
        ],
        outputs: [stamp, runat],
        dependencies: stagedDeps,
        environmentVariables: runInfo.env,
        description: `run test: ${name}`,
    });

    return testInfo({
        name: name,
        stamp: produced[0],
        runat: produced[1],
        size: runInfo.size,
        timeoutSec: runInfo.timeoutSec,
        flaky: runInfo.flaky,
        tags: runInfo.tags,
    });
}

// ============================================================================
//  BinaryInfo — provider returned by `*_binary` rules
// ============================================================================

/**
 * Typed provider every `*_binary` rule should return alongside its
 * `DefaultInfo`. Lets a generic `bxl-run` driver script find the
 * invocation shim for a label without knowing the specific rule type.
 *
 * Bazel equivalent: `RunInfo` (which Bazel uses to power `bazel run`).
 *
 * Build-vs-run split (mirrors Bazel)
 * ----------------------------------
 * - `binary` is the **build-time** output. The rule schedules it
 *   through `ctx.actions` and includes it in `DefaultInfo.files`, so
 *   the `bazel build //...` analog
 *   (`bxl /f:~(tag='bxl-kind:binary')and~(tag='bxl-kind:test')`)
 *   materialises the executable without staging runfiles.
 * - `runScript` is the **run-time** output. The rule schedules it (and
 *   any runfiles-tree staging) through `ctx.runActions`, whose pips
 *   carry the framework-owned `bxl-kind:binary` tag. It must **not**
 *   appear in `DefaultInfo.files`. The exclusion filter above drops
 *   the tagged pip; `bxl /f:tag='bxl-kind:binary'` (the `bazel run`
 *   analog) — or `bxl /f:value='<label>'` driven by a `bxl-run`
 *   wrapper that asks for `binaryInfo.runScript` directly — schedules
 *   it. (Both `bazel run`-style and the bare `bxl` default pull in
 *   the binary's build-time pip transitively, so the shim is always
 *   wired to a real, built executable.)
 */
@@public
export interface BinaryInfo extends Provider {
    /** Narrowed discriminator. */
    kind: "BinaryInfo";

    /** Logical binary name (typically the rule's `name` attribute). */
    name: string;

    /**
     * The compiled executable (bound). **Build-time** output —
     * produced via `ctx.actions`; goes into `DefaultInfo.files` so
     * the exclusion-filtered build (and any positive filter that
     * selects the target transitively) materialises it.
     */
    binary: Artifact;

    /**
     * Generated shim that invokes the binary correctly (e.g. picks
     * up the right runtime / interpreter), plus any runfiles-tree
     * staging the binary needs. **Run-time** output — produced via
     * `ctx.runActions`; the underlying pip is tagged
     * `bxl-kind:binary` and is *not* listed in `DefaultInfo.files`.
     * Selected by `bxl /f:tag='bxl-kind:binary'` (or anything that
     * references the Artifact directly); dropped by the
     * `bxl /f:~(tag='bxl-kind:binary')…` build filter.
     */
    runScript: Artifact;

    /**
     * Sibling files the run-shim dereferences at runtime — e.g. a
     * .NET `runtimeconfig.json`, a Python wheel, a config blob the
     * shim's hardcoded paths point at. Bazel's analog is the target's
     * "runfiles tree" merged into `FilesToRunProvider`.
     *
     * The shim itself is tracked when its consumer references it via
     * `getFile(runScript)`, but bxl can't infer the shim's internal
     * file references. Callers that schedule a pip invoking the
     * binary (e.g. `Rules.genrule` with `tool: { exe: /bin/sh }`)
     * should depend on these so the build graph is complete and
     * cache invalidation is correct.
     *
     * Use `Rules.runfilesOf(info)` to expand a `BinaryInfo` into the
     * full `Transformer.InputArtifact[]` set (run-script + binary +
     * runfiles) suitable for splatting into `genrule({ deps: [...] })`.
     *
     * Always present; empty when the binary needs no auxiliary files
     * (mirrors Bazel's `DefaultInfo.default_runfiles`, which is always
     * a `runfiles()` object — possibly empty — never absent).
     */
    runfiles: Artifact[];
}

/**
 * Convenience constructor for `BinaryInfo`.
 */
@@public
export function binaryInfo(args: {
    name: string,
    binary: Artifact,
    runScript: Artifact,
    runfiles?: Artifact[],
}): BinaryInfo {
    Contract.requires(args.binary !== undefined, "binaryInfo: binary must not be undefined");
    Contract.requires(args.binary.kind !== "unbound",
        `binaryInfo: binary Artifact must be bound (kind !== "unbound"); got "${args.binary.kind}"`);
    Contract.requires(args.runScript !== undefined, "binaryInfo: runScript must not be undefined");
    Contract.requires(args.runScript.kind !== "unbound",
        `binaryInfo: runScript Artifact must be bound (kind !== "unbound"); got "${args.runScript.kind}"`);
    const runfiles = args.runfiles || [];
    for (const rf of runfiles) {
        Contract.requires(rf !== undefined, "binaryInfo: runfiles entries must not be undefined");
        Contract.requires(rf.kind !== "unbound",
            `binaryInfo: runfiles Artifacts must be bound (kind !== "unbound"); got "${rf.kind}"`);
    }
    return {
        kind: "BinaryInfo",
        name: args.name,
        binary: args.binary,
        runScript: args.runScript,
        runfiles: runfiles,
    };
}

/**
 * Expand a `BinaryInfo` into the full set of input artifacts a
 * downstream pip needs to invoke the binary correctly.
 *
 * Returns `[runScript, binary, ...runfiles]` — the shim itself, the
 * binary it execs, and every runfile the shim dereferences at runtime
 * (e.g. a .NET runtimeconfig.json).
 *
 * Designed for splatting into `Rules.genrule({ deps: [...] })`.
 *
 * Example:
 *   Rules.genrule({
 *       name: "regen",
 *       tool: { exe: f`/bin/sh` },
 *       deps: [...Rules.runfilesOf(generator.binaryInfo), dotnetSdk],
 *       outs: [a`out.txt`],
 *       cmd: (ctx) => [
 *           Cmd.argument(Rules.cmdInput(generator.binaryInfo.runScript)),
 *           Cmd.option("--out=", Rules.cmdOutput(ctx.outs[0])),
 *       ],
 *   });
 */
@@public
export function runfilesOf(info: BinaryInfo): Artifact[] {
    Contract.requires(info !== undefined, "runfilesOf: info must not be undefined");
    Contract.requires(info.kind === "BinaryInfo",
        `runfilesOf: expected BinaryInfo, got "${info.kind}"`);
    return [info.runScript, info.binary, ...info.runfiles];
}

// ============================================================================
//  test_suite — aggregate TestInfo[] into a JSON manifest
// ============================================================================

@@public
export interface TestSuiteArguments {
    /** Suite name — used for the manifest file name and diagnostics. */
    name: string;

    /**
     * The tests to include. Pass the `TestInfo` providers returned by
     * `*_test` rules (typically `myTest.testInfo`). The macro takes
     * resolved providers — not labels — for the same reason
     * `filegroup` takes `SourceArtifact[]` rather than `Label[]`:
     * macros do not have access to the framework's `LabelResolver`.
     */
    tests: TestInfo[];
}

@@public
export interface TestSuiteResult {
    /** The generated `<name>.tests.json` manifest. */
    manifest: Artifact;

    /**
     * Standard rule output info. Includes the manifest *and* every
     * test stamp + runat, so requesting the suite via
     * `bxl /f:value='<suite>'` pulls all tests into the build.
     */
    defaultInfo: DefaultInfo;
}

/**
 * Aggregate `TestInfo` providers into a JSON manifest.
 *
 * Bazel equivalent: `test_suite()`. Emits `<name>.tests.json` with one
 * entry per test:
 *
 *     [
 *       {"name":"FooTest","stamp":"/abs/path/FooTest.test.stamp",
 *        "runat":"/abs/path/FooTest.test.runat",
 *        "timeoutSec":60,"tags":["long"]},
 *       ...
 *     ]
 *
 * CI drivers consume this manifest to know the *intended* test set
 * (replacing `find -name '*.test.stamp'` conventions) and to compute
 * cached-vs-executed counts from the per-test `runat` files.
 */
@@public
export function test_suite(args: TestSuiteArguments): TestSuiteResult {
    Contract.requires(args.tests !== undefined, "test_suite: tests must not be undefined");

    const outDir = Context.getNewOutputDirectory(args.name);
    const manifestName = `${args.name}.tests.json`;
    const manifestPath = p`${outDir}/${manifestName}`;

    const json = renderTestSuiteJson(args.tests);

    const manifestFile = Transformer.writeAllText({
        outputPath: manifestPath,
        text: json,
        description: `test_suite: ${args.name}`,
    });

    // SAFETY: Transformer.writeAllText is typed `DerivedFile`; the
    // declared/bind dance below mirrors what the Actions adapter does
    // internally so the result is a normal bound Artifact downstream
    // rules can wire through cmdInput / getFile.
    const declared = declareArtifact(outDir, manifestName);
    const manifestArt = bindArtifact(declared, manifestFile);

    // Pull every test's stamp + runat into defaultInfo so requesting
    // the suite via `bxl /f:value='<suite>'` schedules the underlying
    // test pips. The manifest itself is listed first.
    let files: Artifact[] = [manifestArt];
    for (let t of args.tests) {
        files = files.push(t.stamp);
        files = files.push(t.runat);
    }

    return {
        manifest: manifestArt,
        defaultInfo: defaultInfo({ files: files }),
    };
}

/**
 * Render a TestInfo[] as a JSON array. Internal — the format is part
 * of the cross-rule-set contract; if you change it, bump the consumer
 * docs in the README in the same change.
 *
 * Hand-rolled because DScript has no JSON.stringify and the schema is
 * fixed; we just need to escape any quotes/backslashes that show up in
 * names, tags, or stringified paths.
 *
 * `size` and `flaky` are omitted from the object when absent on the
 * source `TestInfo` (rather than emitted as JSON `null`), so consumers
 * can use simple presence checks.
 */
function renderTestSuiteJson(tests: TestInfo[]): string {
    if (tests.length === 0) {
        return "[]";
    }
    let body = "";
    for (let i = 0; i < tests.length; i = i + 1) {
        const t = tests[i];
        const stampPath = getFile(t.stamp).path.toDiagnosticString();
        const runatPath = getFile(t.runat).path.toDiagnosticString();
        const tagItems = t.tags.map(tg => `"${jsonEscape(tg)}"`);
        const tagsJson = `[${tagItems.join(",")}]`;
        const sizeFragment  = t.size  !== undefined ? `,"size":"${jsonEscape(t.size)}"` : "";
        const flakyFragment = t.flaky !== undefined ? `,"flaky":${t.flaky ? "true" : "false"}` : "";
        const entry =
            `{"name":"${jsonEscape(t.name)}",` +
            `"stamp":"${jsonEscape(stampPath)}",` +
            `"runat":"${jsonEscape(runatPath)}",` +
            `"timeoutSec":${t.timeoutSec.toString()}` +
            sizeFragment +
            flakyFragment +
            `,"tags":${tagsJson}}`;
        if (i === 0) {
            body = `  ${entry}`;
        } else {
            body = `${body},\n  ${entry}`;
        }
    }
    return `[\n${body}\n]\n`;
}

/**
 * Minimal JSON string escaper. Handles the two characters that would
 * actually break the manifest — `"` and `\` — plus the most common
 * control characters. Test names and tag strings are repo-controlled,
 * so this is sufficient.
 */
function jsonEscape(s: string): string {
    return s
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t");
}
