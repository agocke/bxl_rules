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
 *     produces a Configuration any other way — the no-`opts` rule
 *     from Phase 1 still holds.
 *
 * Caveat — DScript language gap:
 *   BuildXL's `withQualifier` is a *syntactic* construct on namespace
 *   imports (`import * as M from "X" withQualifier({...})`), not a
 *   value-level call. A `Transition` therefore produces the new
 *   Configuration but cannot itself invoke `withQualifier`. The call
 *   site is responsible for:
 *
 *     const newCfg = MyTransition.apply(currentCfg);
 *     import * as Dep from "Dep" withQualifier(newCfg.underlyingQualifier);
 *
 *   When Phase 3 adds the rule-machinery wiring (`incomingTransition`,
 *   `attrs.dep(target, transition)`), the SDK will be the only thing
 *   that emits these imports — closing the drift hazard discussed in
 *   the design notes.
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
 * Switch the Configuration to the host's exec platform.
 *
 * Used for build tools (compilers, codegen, etc.) that must run on
 * the machine performing the build, regardless of the target the
 * consuming rule produces. This is the analog of Buck2's `cfg.exec`
 * transition (and Bazel's `cfg = "exec"` after the 2019 redesign).
 *
 * Behaviour:
 *   - `platform` ← `hostExecPlatform()`.
 *   - `mode` constraint is preserved (so debug/release status of the
 *     target build still drives debug/release of the tools — usually
 *     desirable for matched symbol shapes).
 *   - All other constraints are dropped (they're target-specific by
 *     definition and have no meaning on the exec side).
 *
 * Idempotency: applying twice is a no-op because the second application
 * sees a Configuration whose platform already equals `hostExecPlatform()`.
 */
@@public
export const ExecTransition: Transition = <Transition>{
    __transitionBrand: undefined,
    name: "exec",
    apply: (cfg: Configuration) => execApply(cfg),
};

function execApply(cfg: Configuration): Configuration {
    const mode = getConstraint(cfg, ConstraintSettings.mode);
    const q = mode !== undefined
        ? <Qualifier><any>{ platform: hostExecPlatform(), configuration: mode }
        : <Qualifier><any>{ platform: hostExecPlatform() };
    return fromQualifier(q);
}
