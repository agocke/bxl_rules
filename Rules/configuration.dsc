// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Configuration as a typed value, modelled after Buck2's `ConfigurationInfo`
 * but implemented as a façade over BuildXL's existing qualifier system.
 *
 * Why this exists:
 *   BuildXL already supports per-target build parameters via qualifiers
 *   (typed dicts of string-literal unions, accessed via the ambient
 *   `qualifier` keyword). The qualifier is the *runtime* identity of a
 *   build configuration; this module wraps it in a value-shaped
 *   `Configuration` so rules can reason about platform/constraints
 *   without grepping qualifier fields by name.
 *
 * What it does NOT do:
 *   - It does not replace qualifiers; it observes them.
 *   - It does not compute its own "exec platform" — Configuration is a
 *     read-only view; transitions (see transition.dsc) own the
 *     business of producing a new Configuration.
 *   - It does not introduce a registry: there is no "platform()" rule
 *     here. Platforms are logical names (strings) that callers attach
 *     to qualifier instances via `fromQualifier(...)`.
 *
 * DScript constraints honoured:
 *   - Nominal identity is expressed via a single mandatory marker field
 *     (`__configurationBrand`) — DScript has no intersection types and
 *     no `unique symbol`, so this is the canonical workaround used
 *     elsewhere in the BuildXL prelude (see `Map.__mapKeyBrand`,
 *     `IpcMoniker.__ipcMonikerBrand`).
 *   - All Configuration values are immutable (DScript object semantics).
 */

// ============================================================================
//  Configuration — value-shaped view over a qualifier instance
// ============================================================================

/**
 * A typed, value-shaped representation of how a target should be built.
 *
 * Backed by a BuildXL `Qualifier` (the ambient `qualifier` keyword); the
 * `platform` and `constraints` fields are typed projections over that
 * qualifier. `hash` gives Configuration value-equality semantics: two
 * Configurations are interchangeable iff their hashes match.
 *
 * Configurations are values — pass them by parameter, store them in
 * providers, and return them from transitions. Never mutate.
 */
@@public
export interface Configuration {
    /**
     * Tagged-interface brand. Do not set or read.
     * Present so `Configuration` is nominal — a bare `{platform, ...}`
     * literal will not satisfy the type without going through `fromQualifier`.
     */
    __configurationBrand: any;

    /**
     * The underlying BuildXL qualifier instance this Configuration views.
     *
     * Named `underlyingQualifier` rather than `qualifier` because the bare
     * identifier `qualifier` is reserved by DScript (it refers to the
     * ambient qualifier keyword) and a member access `cfg.qualifier`
     * triggers DX9058 from the type checker.
     *
     * Pass this to `withQualifier(...)` at the call site:
     *   import * as Dep from "Dep" withQualifier(cfg.underlyingQualifier);
     */
    underlyingQualifier: Qualifier;

    /** Logical platform label (e.g., "linux-x64", "windows-arm64"). */
    platform: PlatformLabel;

    /** Constraint settings/values; like Bazel's `@platforms//...` constraints. Sorted by setting name. */
    constraints: ConstraintEntry[];

    /** Stable identity hash. Two Configurations are equal iff their hashes match. */
    hash: string;
}

/**
 * A logical name for a build platform (e.g., "linux-x64").
 *
 * Strings, by design — DScript has no template-literal types, so a
 * narrower compile-time shape isn't possible. Use the constants in
 * `Platforms.*` for the well-known names.
 */
@@public
export type PlatformLabel = string;

/** A single constraint setting + value pair. */
@@public
export interface ConstraintEntry {
    /** The setting name (e.g., "os", "cpu", "mode"). */
    setting: string;

    /** The chosen value (e.g., "linux", "x64", "debug"). */
    value: string;
}

// ============================================================================
//  Well-known constraint setting names
// ============================================================================

/**
 * Predefined constraint setting names. Use these instead of bare strings
 * when reading/writing Configuration constraints to avoid typos.
 */
export namespace ConstraintSettings {
    @@public export const os:   string = "os";
    @@public export const cpu:  string = "cpu";
    @@public export const mode: string = "mode";
}

/**
 * Common platform label constants.
 *
 * These are workspace-side label suggestions for callers who like
 * Bazel-platforms ergonomics. They are *not* anchored to what
 * BuildXL's `Context.getCurrentHost()` detects — that helper reports
 * only `"windows" | "macos" | "unix"` for OS and `"x64" | "x86"` for
 * CPU, so on Linux it returns `"unix"`, never `"linux"`. Workspaces
 * are free to use any string they like; these constants only exist
 * to avoid typos in the common cases.
 *
 * Note in particular that `Platforms.linuxX64 !== hostExecPlatform()`
 * on a Linux build host. If you want the host's label, call
 * `hostExecPlatform()` (BuildXL vocabulary) or branch on `hostOs()`
 * and remap to your workspace vocabulary.
 */
export namespace Platforms {
    @@public export const linuxX64:    PlatformLabel = "linux-x64";
    @@public export const linuxArm64:  PlatformLabel = "linux-arm64";
    @@public export const windowsX64:  PlatformLabel = "windows-x64";
    @@public export const windowsArm64: PlatformLabel = "windows-arm64";
    @@public export const macosX64:    PlatformLabel = "macos-x64";
    @@public export const macosArm64:  PlatformLabel = "macos-arm64";
}

// ============================================================================
//  Factories
// ============================================================================

/**
 * Build a Configuration from a BuildXL qualifier instance.
 *
 * Usage from a rule module:
 *   import * as Config from "Sdk.Rules";
 *   const cfg = Config.fromQualifier(qualifier);
 *
 * Derivations (the qualifier IS the source of truth — there are no overrides):
 *   - `platform` ← independent `os`+`cpu` axes (joined as `<os>-<cpu>`),
 *     then `qualifier.platform`, then `qualifier.targetRuntime`, else the
 *     host's exec platform. This is a diagnostic/output-directory label
 *     only; it does not influence Configuration identity beyond what the
 *     underlying axes already contribute.
 *   - `constraints` ← *every* field on the qualifier becomes a
 *     `ConstraintEntry`. The setting names `os`, `cpu`, and `mode`
 *     (the latter renamed from `configuration`) are well-known and
 *     have constants in `ConstraintSettings`; any other axis the
 *     workspace declares (`tfm`, `runtime`, `libc`, `abi`, ...) is
 *     passed through verbatim with the qualifier field name as the
 *     setting name. Two qualifiers that differ on *any* field will
 *     produce Configurations with different hashes.
 *
 * Configuration is a pure projection of the qualifier — it cannot disagree
 * with what the rest of BuildXL sees. To produce a *different* Configuration
 * (e.g. for a cross-compile dep), apply a Transition (transition.dsc); the
 * SDK is responsible for re-entering the corresponding qualifier via
 * `withQualifier` at the call site.
 */
@@public
export function fromQualifier(q: Qualifier): Configuration {
    const platform = derivePlatformFromQualifier(q);
    const constraints = sortConstraints(deriveConstraintsFromQualifier(q));

    return <Configuration>{
        __configurationBrand: undefined,
        underlyingQualifier: q,
        platform: platform,
        constraints: constraints,
        hash: computeHash(platform, constraints),
    };
}

/**
 * Returns the logical platform label of the host machine running BuildXL,
 * in BuildXL's three-bucket vocabulary (`unix-x64`, `windows-x64`,
 * `macos-x64`, etc.).
 *
 * Useful as the input to `makeExecTransition` when the workspace's
 * qualifier matrix uses BuildXL's vocabulary directly. Workspaces using
 * Bazel-style labels (`linux`, `freebsd`, ...) must remap `hostOs()`
 * themselves — BuildXL doesn't expose finer detection.
 */
@@public
export function hostExecPlatform(): PlatformLabel {
    return hostOs() + "-" + hostCpu();
}

/**
 * Returns the host OS as a constraint value.
 *
 * Output domain: `"windows" | "macos" | "unix"` — matching BuildXL's
 * own three-way `OsType` (`"win" | "macOS" | "unix"`), modulo the
 * casing normalisation. BuildXL itself does not distinguish Linux,
 * FreeBSD, OpenBSD, or any other Unix flavour — `getCurrentHost().os`
 * returns `"unix"` for all of them. Workspaces that need finer
 * granularity must remap `hostOs()` themselves (or accept `unix` as
 * their host label).
 *
 * Typical use: `makeExecTransition({ os: hostOs(), cpu: hostCpu() })`
 * for a workspace whose qualifier matrix uses BuildXL's vocabulary.
 */
@@public
export function hostOs(): string {
    const host = Context.getCurrentHost();
    return host.os === "win"   ? "windows"
         : host.os === "macOS" ? "macos"
         :                       "unix";
}

/**
 * Returns the host CPU as a constraint value.
 *
 * Output domain: `"x64" | "x86"` — BuildXL's `cpuArchitecture` is
 * statically that union, so `hostCpu()` will never return arm64.
 * Workspaces targeting arm64 host machines must remap themselves.
 *
 * Typical use: paired with `hostOs()` as input to `makeExecTransition`.
 */
@@public
export function hostCpu(): string {
    return Context.getCurrentHost().cpuArchitecture;
}

// ============================================================================
//  Queries
// ============================================================================

/**
 * Return the value of a named constraint, or undefined if unset.
 *
 * Example:
 *   const os = Config.getConstraint(cfg, Config.ConstraintSettings.os);
 *   if (os === "linux") { ... }
 */
@@public
export function getConstraint(cfg: Configuration, settingName: string): string {
    if (cfg === undefined) return undefined;
    const found = cfg.constraints.find(e => e.setting === settingName);
    return found !== undefined ? found.value : undefined;
}

/**
 * True iff two Configurations have the same identity (matching hashes).
 *
 * Use this rather than `===` on Configuration values: BuildXL re-evaluates
 * specs on demand, so two structurally-equal Configurations may not be
 * the same object reference.
 */
@@public
export function configurationsEqual(a: Configuration, b: Configuration): boolean {
    return a !== undefined && b !== undefined && a.hash === b.hash;
}

// ============================================================================
//  Internal helpers
// ============================================================================

/**
 * Best-effort platform derivation, for diagnostics and output-directory
 * naming only. Three shapes are recognised, in priority order:
 *
 *   1. Independent `os` + `cpu` axes — the *Bazel-shaped* qualifier.
 *      Synthesises a combined label `<os>-<cpu>`.
 *   2. Combined `platform` field — the *legacy bundle* shape.
 *   3. `targetRuntime` — older BuildXL conventions.
 *
 * Falling back to the host exec platform if none of the above are set.
 *
 * The combined `cfg.platform` is a *derived convenience field*; the
 * genuine independent dimensions live in `cfg.constraints` (which now
 * carries every qualifier field, not just the three the platform
 * derivation knows about). Query with
 * `getConstraint(cfg, ConstraintSettings.os)` etc.
 */
function derivePlatformFromQualifier(q: Qualifier): PlatformLabel {
    const anyQ = <{platform?: string; targetRuntime?: string; os?: string; cpu?: string;}>q;
    if (anyQ.os !== undefined && anyQ.cpu !== undefined) return anyQ.os + "-" + anyQ.cpu;
    if (anyQ.platform      !== undefined) return anyQ.platform;
    if (anyQ.targetRuntime !== undefined) return anyQ.targetRuntime;
    return hostExecPlatform();
}

/**
 * Build the constraint list from *every* field on the qualifier.
 *
 * The qualifier is the source of truth for build identity: anything the
 * workspace declares as part of its qualifier matrix participates in
 * dispatch. Restricting the projection to a hand-picked allowlist
 * (`os`, `cpu`, `configuration`) silently collapsed Configurations that
 * differed only on an unknown axis (e.g. `tfm`, `runtime`, `libc`,
 * `abi`), so two qualifiers `{os, cpu, tfm: "net8.0"}` and
 * `{os, cpu, tfm: "net9.0"}` would hash equal.
 *
 * Naming conventions for setting names:
 *   - `qualifier.configuration` is renamed to the constraint setting
 *     `mode` for backward compatibility with rule code that already
 *     reads `getConstraint(cfg, ConstraintSettings.mode)`. (The
 *     qualifier-side name `configuration` is reserved by older
 *     BuildXL conventions; the constraint-side name `mode` is shorter
 *     and matches Bazel.)
 *   - All other fields pass through verbatim — the qualifier field
 *     name becomes the constraint setting name.
 *
 * Values are stringified via `toString()`. Qualifier fields are
 * declared as string-literal unions in DScript, so `toString()` always
 * produces a usable string.
 */
function deriveConstraintsFromQualifier(q: Qualifier): ConstraintEntry[] {
    const obj = <Object><any>q;
    const ks = obj.keys();
    let cs: ConstraintEntry[] = [];
    for (let k of ks) {
        const v = obj.get(k);
        if (v === undefined) continue;
        const setting = k === "configuration" ? ConstraintSettings.mode : k;
        cs = cs.push({setting: setting, value: v.toString()});
    }
    return cs;
}

/**
 * Stable sort by setting name; required for hash determinism.
 *
 * Exposed so tests can verify the sort contract directly without
 * having to construct Configurations through `fromQualifier` (which,
 * by design, only derives a single `mode` constraint per qualifier).
 *
 * Implemented as a hand-rolled selection sort because DScript's
 * `Array.sort` invokes the comparator with `undefined` arguments
 * for some inputs, which breaks any direct comparison.
 */
@@public
export function sortConstraints(entries: ConstraintEntry[]): ConstraintEntry[] {
    const n = entries.length;
    if (n <= 1) return entries;

    let remaining = entries;
    let sorted: ConstraintEntry[] = [];
    while (remaining.length > 0) {
        let minIdx = 0;
        for (let i = 1; i < remaining.length; i = i + 1) {
            if (remaining[i].setting.localeCompare(remaining[minIdx].setting) < 0) {
                minIdx = i;
            }
        }
        sorted = sorted.push(remaining[minIdx]);

        let next: ConstraintEntry[] = [];
        for (let j = 0; j < remaining.length; j = j + 1) {
            if (j !== minIdx) {
                next = next.push(remaining[j]);
            }
        }
        remaining = next;
    }
    return sorted;
}

/**
 * Compute a stable identity hash from platform + sorted constraints.
 *
 * Uses length-prefixed encoding (`<n>:<chars>`) so the result is injective
 * even when platform labels or constraint values contain `;`, `=`, `:`,
 * or other delimiter characters. Without length-prefixing, a constraint
 * value of `"x;os=linux"` would collide with two separate constraints
 * `mode=x` + `os=linux`.
 *
 * The qualifier object itself is intentionally excluded from the hash:
 * the platform + constraints projection is the canonical view of the
 * Configuration. Two qualifiers that project to the same platform and
 * constraints are equivalent for rule-evaluation purposes.
 *
 * Exposed so tests can verify injectivity directly without smuggling
 * arbitrary platform/constraint pairs through `fromQualifier`. Computing
 * a hash for a (platform, constraints) tuple that does not correspond
 * to any Configuration is harmless — it just returns a string.
 */
@@public
export function computeHash(platform: string, constraints: ConstraintEntry[]): string {
    let parts = "p" + lp(platform);
    for (let c of constraints) {
        parts = parts + ";" + lp(c.setting) + "=" + lp(c.value);
    }
    return parts;
}

/** Length-prefix a string as `<length>:<value>` for unambiguous serialization. */
function lp(s: string): string {
    return s.length.toString() + ":" + s;
}
