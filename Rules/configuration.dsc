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
 *     read-only view; transitions (Phase 2, transition.dsc) own the
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
 * Free-form callers may use any string; these are provided for the
 * platforms BuildXL itself recognises.
 *
 * The `*X64` / `*X86` constants match what `hostExecPlatform()` can
 * produce — those are valid *exec* platforms (where build tools run).
 * The `*Arm64` constants are *target* platforms only (cross-compile
 * targets); BuildXL's `Context.getCurrentHost().cpuArchitecture` is
 * `"x64" | "x86"`, so `hostExecPlatform()` will never return arm64.
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
 *   - `platform` ← `qualifier.platform`, then `qualifier.targetRuntime`,
 *     else the host's exec platform.
 *   - `constraints` ← `[{setting: "mode", value: qualifier.configuration}]`
 *     when `qualifier.configuration` is present.
 *
 * Configuration is a pure projection of the qualifier — it cannot disagree
 * with what the rest of BuildXL sees. To produce a *different* Configuration
 * (e.g. for a cross-compile dep), apply a Transition (Phase 2); the SDK
 * is responsible for re-entering the corresponding qualifier via
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
 * Returns the logical platform label of the host machine running BuildXL.
 *
 * Used by `ExecTransition` (Phase 2) to produce the Configuration in
 * which build tools should run. This is BuildXL's analog of Buck2's
 * "default exec platform."
 */
@@public
export function hostExecPlatform(): PlatformLabel {
    const host = Context.getCurrentHost();
    const os = host.os === "win"   ? "windows"
             : host.os === "macOS" ? "macos"
             :                       "linux";
    return os + "-" + host.cpuArchitecture;
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

/** Best-effort platform derivation from common qualifier shapes. */
function derivePlatformFromQualifier(q: Qualifier): PlatformLabel {
    const anyQ = <{platform?: string; targetRuntime?: string;}>q;
    if (anyQ.platform      !== undefined) return anyQ.platform;
    if (anyQ.targetRuntime !== undefined) return anyQ.targetRuntime;
    return hostExecPlatform();
}

/** Best-effort constraint derivation from common qualifier shapes. */
function deriveConstraintsFromQualifier(q: Qualifier): ConstraintEntry[] {
    const anyQ = <{configuration?: string;}>q;
    if (anyQ.configuration !== undefined) {
        return [{setting: ConstraintSettings.mode, value: anyQ.configuration}];
    }
    return [];
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
