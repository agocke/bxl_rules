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
 * Why a factory and not a singleton: workspaces vary in the
 * vocabulary they use for host labels — some say `os: "linux"` (Bazel
 * shape), others say `os: "unix"` (BuildXL's three-bucket `OsType`).
 * The SDK doesn't know which vocabulary your qualifier matrix
 * declares; picking one in a global singleton would silently misalign
 * with the other half of consumers. A workspace owner constructs
 * `makeExecTransition` once near the qualifier declaration with the
 * matching labels — for BuildXL-vocabulary workspaces that's
 * `makeExecTransition({ os: Rules.hostOs(), cpu: Rules.hostCpu() })`;
 * for Bazel-vocabulary workspaces it's typically a small branch on
 * `Rules.hostOs()` ("unix" → "linux" / "freebsd" / etc.) before
 * passing to the factory.
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
