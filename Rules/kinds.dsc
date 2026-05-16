// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import {Transformer} from "Sdk.Transformers";

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
 *     `Rules.rule({...})` (declared in providers.dsc). Every pip an
 *     impl schedules through `ctx.actions.run` is automatically tagged
 *     with the framework-owned `bxl-kind:*` tag for that kind. Rule
 *     authors do not see the tag string. Mapping to the Bazel CLI:
 *
 *         bazel test //...
 *           → bxl /f:tag='bxl-kind:test'
 *         bazel build //...
 *           → bxl   (default top-level)
 *
 *   - `TestInfo`     — typed provider every `*_test` rule returns
 *                      alongside `DefaultInfo`. Carries the stamp +
 *                      runat artifacts, declared timeout, and user tags
 *                      (`"manual"`, `"long"`, `"flaky"`, ...).
 *   - `BinaryInfo`   — typed provider every `*_binary` rule returns
 *                      alongside `DefaultInfo`. Carries the runnable
 *                      binary and a generated invocation shim.
 *
 *   - `test_suite()` — aggregator macro that collects `TestInfo`
 *                      providers and emits a `<name>.tests.json`
 *                      manifest. CI drivers read the manifest instead
 *                      of grepping `BUILD.dsc` files.
 *
 * Design notes
 * ------------
 *  - The `bxl-kind:*` tag vocabulary is *not* public. It is applied by
 *    the Actions adapter (see providers.dsc / `createActions`) using
 *    the package-private `kindTagFor()` helper below. Rule authors
 *    declare kind once on `Rules.rule({ kind: "test", ... })` and let
 *    the framework do the tagging — this keeps the tag string an
 *    implementation detail that can evolve without breaking callers.
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
 * implementation detail. The Actions adapter (createActions in
 * providers.dsc) applies one of these to every pip a kind-aware rule
 * schedules, using `kindTagFor()` below. CI drivers select by kind
 * using BuildXL's existing tag filter syntax against the *string
 * literal* — e.g. `bxl /f:tag='bxl-kind:test'` — never via this
 * constant.
 */
const kindTags = {
    test: "bxl-kind:test",
    binary: "bxl-kind:binary",
};

/**
 * Map a declared `RuleKind` to the `bxl-kind:*` pip tag that the
 * Actions adapter should auto-apply to every pip the rule schedules.
 * Returns `undefined` for `"library"` (libraries are the default and
 * carry no kind tag) and for `undefined` input.
 *
 * Package-private — called from providers.dsc / `createActions` only.
 */
export function kindTagFor(kind?: RuleKind): string {
    if (kind === "test")   return kindTags.test;
    if (kind === "binary") return kindTags.binary;
    return undefined;
}

// ============================================================================
//  TestInfo — provider returned by `*_test` rules
// ============================================================================

/**
 * Typed provider every `*_test` rule should return alongside its
 * `DefaultInfo`. Lets generic infrastructure (the `test_suite` macro,
 * CI drivers, IDE integrations) discover tests without knowing the
 * specific rule type.
 *
 * Bazel equivalent: `TestInfo` (built-in).
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

    /** Success marker file written by the runner (bound Artifact). */
    stamp: Artifact;

    /**
     * Run-at-timestamp file written by the runner. Contents are the
     * nanosecond-precision wall time captured at execution. Cached
     * replays preserve the original timestamp byte-for-byte.
     */
    runat: Artifact;

    /** Declared timeout in seconds. */
    timeoutSec: number;

    /**
     * User tags. Used by CI drivers for selection
     * (e.g. `"manual"`, `"long"`, `"flaky"`). These are *not* the same
     * as the framework-applied `bxl-kind:test` pip tag — the latter is
     * attached automatically when the rule declares `kind: "test"` on
     * `Rules.rule({...})`.
     */
    tags: string[];
}

/**
 * Convenience constructor for `TestInfo`. Sets the `kind` discriminator
 * so call sites don't repeat the literal.
 */
@@public
export function testInfo(args: {
    name: string,
    stamp: Artifact,
    runat: Artifact,
    timeoutSec: number,
    tags?: string[],
}): TestInfo {
    Contract.requires(args.stamp !== undefined, "testInfo: stamp must not be undefined");
    Contract.requires(args.stamp.kind !== "unbound",
        `testInfo: stamp Artifact must be bound (kind !== "unbound"); got "${args.stamp.kind}"`);
    Contract.requires(args.runat !== undefined, "testInfo: runat must not be undefined");
    Contract.requires(args.runat.kind !== "unbound",
        `testInfo: runat Artifact must be bound (kind !== "unbound"); got "${args.runat.kind}"`);
    return {
        kind: "TestInfo",
        name: args.name,
        stamp: args.stamp,
        runat: args.runat,
        timeoutSec: args.timeoutSec,
        tags: args.tags || [],
    };
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
 */
@@public
export interface BinaryInfo extends Provider {
    /** Narrowed discriminator. */
    kind: "BinaryInfo";

    /** Logical binary name (typically the rule's `name` attribute). */
    name: string;

    /** The runnable artifact (bound). */
    binary: Artifact;

    /**
     * Generated shim that invokes the binary correctly (e.g. picks up
     * the right runtime / interpreter). A driver script `bxl-run`
     * conceptually does: build this shim via
     * `bxl /f:value='<label>'`, then exec it with the user's args.
     */
    runScript: Artifact;
}

/**
 * Convenience constructor for `BinaryInfo`.
 */
@@public
export function binaryInfo(args: {
    name: string,
    binary: Artifact,
    runScript: Artifact,
}): BinaryInfo {
    Contract.requires(args.binary !== undefined, "binaryInfo: binary must not be undefined");
    Contract.requires(args.binary.kind !== "unbound",
        `binaryInfo: binary Artifact must be bound (kind !== "unbound"); got "${args.binary.kind}"`);
    Contract.requires(args.runScript !== undefined, "binaryInfo: runScript must not be undefined");
    Contract.requires(args.runScript.kind !== "unbound",
        `binaryInfo: runScript Artifact must be bound (kind !== "unbound"); got "${args.runScript.kind}"`);
    return {
        kind: "BinaryInfo",
        name: args.name,
        binary: args.binary,
        runScript: args.runScript,
    };
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
    let files: File[] = [getFile(manifestArt)];
    for (let t of args.tests) {
        files = files.push(getFile(t.stamp));
        files = files.push(getFile(t.runat));
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
        const entry =
            `{"name":"${jsonEscape(t.name)}",` +
            `"stamp":"${jsonEscape(stampPath)}",` +
            `"runat":"${jsonEscape(runatPath)}",` +
            `"timeoutSec":${t.timeoutSec.toString()},` +
            `"tags":${tagsJson}}`;
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
