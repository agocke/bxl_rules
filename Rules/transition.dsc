// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Transitions — pure functions from Configuration to Configuration.
 *
 * A `Transition` describes how a dependency should be re-configured
 * relative to its consumer. Modelled after Buck2's `Transition` value
 * (see https://buck2.build/docs/rule_authors/configuration_transitions/),
 * adapted for DScript:
 *
 *   - Transitions are *values*, never strings. There is no `cfg = "host"`.
 *   - `apply` is a pure function; calling it twice produces the same
 *     result (idempotency contract).
 *   - The new Configuration is constructed by feeding a synthetic
 *     qualifier through `fromQualifier`. There is no back door that
 *     produces a Configuration any other way — `fromQualifier` is the
 *     single sanctioned entry point.
 *
 * Scope — what Transitions do and don't do:
 *   BuildXL's `withQualifier` is a *syntactic* construct on namespace
 *   imports (`import * as M from "X" withQualifier({...})`), not a
 *   value-level call. A `Transition` therefore produces the new
 *   Configuration but cannot itself invoke `withQualifier`. The
 *   division of labour is:
 *
 *     // SDK side: compute the new Configuration as a value.
 *     const newCfg = MyTransition.apply(currentCfg);
 *
 *     // Call site: write the import yourself.
 *     import * as Dep from "Dep" withQualifier(newCfg.underlyingQualifier);
 *
 *   Transition values exist to encapsulate the *math* of "given this
 *   target configuration, what's the new qualifier" — host detection,
 *   axis flipping, idempotence. Applying the result to a dep import is
 *   always a manual step in rule code.
 */

// ============================================================================
//  Transition — value-shaped configuration transformer
// ============================================================================

/**
 * A pure function from Configuration to Configuration.
 *
 * Idempotency: `t.apply(t.apply(cfg))` must equal `t.apply(cfg)`. This
 * matches Buck2's enforced transition contract and ensures that
 * re-applying a transition (e.g. an exec dep of an exec dep) doesn't
 * keep migrating the configuration.
 */
@@public
export interface Transition {
    /** Tagged-interface brand. Do not set or read. */
    __transitionBrand: any;

    /** Human-readable name; appears in debug output and error messages. */
    name: string;

    /** Compute the new Configuration. Must be a pure function and idempotent. */
    apply: (cfg: Configuration) => Configuration;
}

// ============================================================================
//  Predefined transitions
// ============================================================================

/**
 * The no-op transition: returns the input Configuration unchanged.
 *
 * Use this when a dep should be evaluated under the same Configuration
 * as its consumer (the default for ordinary target deps).
 */
@@public
export const IdentityTransition: Transition = <Transition>{
    __transitionBrand: undefined,
    name: "identity",
    apply: (cfg: Configuration) => cfg,
};

/**
 * Alias for `IdentityTransition`. Provided for readability when a rule
 * explicitly wants to document "this dep stays in the target config."
 *
 * In Buck2, `target` is a distinct cfg keyword; in our model both
 * collapse to "no-op" because there is no separate target/host axis.
 */
@@public
export const TargetTransition: Transition = IdentityTransition;

/**
 * Switch the Configuration to a fixed exec platform.
 *
 * Used for build tools (compilers, codegen, etc.) that must run on
 * the machine performing the build, regardless of the target the
 * consuming rule produces. This is the analog of Buck2's `cfg.exec`
 * transition (and Bazel's `cfg = "exec"` after the 2019 redesign).
 *
 * Behaviour:
 *   - `os` constraint  ← `host.os`.
 *   - `cpu` constraint ← `host.cpu`.
 *   - `mode` constraint is preserved (so debug/release status of the
 *     target build still drives debug/release of the tools — usually
 *     desirable for matched symbol shapes).
 *   - All other constraints are dropped (they're target-specific by
 *     definition and have no meaning on the exec side).
 *   - `cfg.platform` reflects the supplied host as `<os>-<cpu>`.
 *
 * Idempotency: applying twice is a no-op because the second application
 * sees a Configuration whose `os`/`cpu` already equal the supplied host's.
 *
 * Why a factory instead of a singleton: workspaces vary in the
 * vocabulary they use for host labels (some say `os: "linux"`, others
 * say `os: "unix"` to match BuildXL's three-bucket `OsType`). The SDK
 * doesn't know which vocabulary your qualifier matrix declares —
 * picking one would silently misalign with workspaces using the other.
 * The workspace owner constructs `makeExecTransition` once with their
 * own labels, typically near the qualifier declaration. See also the
 * convenience `ExecTransition` singleton, which is `makeExecTransition`
 * applied to BuildXL's auto-detected labels.
 *
 * @param host  The host platform's `os` and `cpu` labels. These must
 *              match values that the workspace's qualifier type accepts
 *              (otherwise the `withQualifier(...)` import at the call
 *              site will be rejected by BuildXL's qualifier checker).
 */
@@public
export function makeExecTransition(host: { os: string; cpu: string; }): Transition {
    return <Transition>{
        __transitionBrand: undefined,
        name: "exec(" + host.os + "-" + host.cpu + ")",
        apply: (cfg: Configuration) => {
            const mode = getConstraint(cfg, ConstraintSettings.mode);
            const q = mode !== undefined
                ? <Qualifier><any>{ os: host.os, cpu: host.cpu, configuration: mode }
                : <Qualifier><any>{ os: host.os, cpu: host.cpu };
            return fromQualifier(q);
        },
    };
}

/**
 * Auto-host `ExecTransition`: applies `makeExecTransition` to the
 * labels BuildXL itself detects via `Context.getCurrentHost()`.
 *
 * Convenient for workspaces whose qualifier vocabulary matches
 * BuildXL's own (`os: "windows" | "macos" | "unix"`). Workspaces that
 * use finer-grained labels (e.g. `"linux"`, `"freebsd"`, `"haiku"`) or
 * that need to set CPU explicitly must construct their own transition
 * via `makeExecTransition({os, cpu})` — BuildXL's detection is only
 * three-way on OS and `"x64" | "x86"` on CPU, so any other label is
 * the workspace's call.
 *
 * Caveat: BuildXL reports `"unix"` for all non-Windows non-macOS hosts,
 * so on Linux this transition produces `os: "unix"`. If your qualifier
 * matrix declares `os: "linux" | ...`, you want `makeExecTransition`,
 * not this singleton.
 */
@@public
export const ExecTransition: Transition = makeExecTransition({ os: hostOs(), cpu: hostCpu() });
