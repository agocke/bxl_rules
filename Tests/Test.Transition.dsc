// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Tests for Rules/transition.dsc and Rules/configured_label.dsc.
 *
 * Same harness as Test.Config.dsc: each test returns "ok" on success;
 * a `Contract.assert` failure aborts evaluation and bxl reports a
 * non-zero exit code.
 */

import * as Rules from "Sdk.Rules";

// ----------------------------------------------------------------------------
// IdentityTransition / TargetTransition
// ----------------------------------------------------------------------------

function test_identityTransition_returnsInputUnchanged(): string {
    const cfg = Rules.fromQualifier({ platform: "linux-x64", configuration: "debug" });
    const out = Rules.IdentityTransition.apply(cfg);

    Contract.assert(Rules.configurationsEqual(cfg, out),
        "IdentityTransition.apply(cfg) must equal cfg");

    return "ok";
}

function test_identityTransition_isIdempotent(): string {
    const cfg = Rules.fromQualifier({ platform: "linux-x64" });
    const once  = Rules.IdentityTransition.apply(cfg);
    const twice = Rules.IdentityTransition.apply(once);

    Contract.assert(Rules.configurationsEqual(once, twice),
        "Identity transition applied twice must equal applied once");

    return "ok";
}

function test_targetTransition_isIdentityAlias(): string {
    Contract.assert(Rules.TargetTransition === Rules.IdentityTransition,
        "TargetTransition must be the same value as IdentityTransition");

    return "ok";
}

// ----------------------------------------------------------------------------
// ExecTransition
// ----------------------------------------------------------------------------

function test_execTransition_producesHostPlatform(): string {
    // Start from a non-host platform so we can observe the switch.
    const targetCfg = Rules.fromQualifier({ platform: "linux-arm64" });
    const execCfg   = Rules.ExecTransition.apply(targetCfg);

    Contract.assert(execCfg.platform === Rules.hostExecPlatform(),
        "ExecTransition must switch the platform to hostExecPlatform()");

    return "ok";
}

function test_execTransition_isIdempotent(): string {
    const cfg   = Rules.fromQualifier({ platform: "linux-arm64", configuration: "release" });
    const once  = Rules.ExecTransition.apply(cfg);
    const twice = Rules.ExecTransition.apply(once);

    Contract.assert(Rules.configurationsEqual(once, twice),
        "ExecTransition applied twice must equal applied once (idempotency contract)");

    return "ok";
}

function test_execTransition_preservesModeConstraint(): string {
    const cfg     = Rules.fromQualifier({ platform: "linux-arm64", configuration: "debug" });
    const execCfg = Rules.ExecTransition.apply(cfg);

    Contract.assert(Rules.getConstraint(execCfg, Rules.ConstraintSettings.mode) === "debug",
        "ExecTransition must preserve the mode constraint (debug/release of the build)");

    return "ok";
}

function test_execTransition_dropsTargetSpecificConstraints(): string {
    // Compose a Configuration whose only constraint comes from a qualifier
    // field — the SDK's `fromQualifier` only derives `mode` from
    // qualifier.configuration, so this is the only path to construct a
    // multi-attribute configuration through the public API. ExecTransition
    // should drop everything that isn't mode/platform.
    const cfg     = Rules.fromQualifier({ platform: "linux-arm64" });
    const execCfg = Rules.ExecTransition.apply(cfg);

    Contract.assert(execCfg.platform === Rules.hostExecPlatform(),
        "platform should be host");
    Contract.assert(execCfg.constraints.length === 0,
        "no mode constraint in the input => no constraints in the output");

    return "ok";
}

function test_execTransition_doesNotMutateInput(): string {
    const cfg = Rules.fromQualifier({ platform: "linux-arm64", configuration: "release" });
    const beforeHash = cfg.hash;

    Rules.ExecTransition.apply(cfg); // discard result

    Contract.assert(cfg.hash === beforeHash,
        "ExecTransition.apply must not mutate its input Configuration");
    Contract.assert(cfg.platform === "linux-arm64",
        "input Configuration's platform must be unchanged");

    return "ok";
}

function test_execTransition_carriesUsableQualifier(): string {
    // Contract: the .underlyingQualifier field on the new Configuration is what
    // the call site will pass to `withQualifier(...)`. It must reflect
    // the new platform, not the old one.
    const cfg     = Rules.fromQualifier({ platform: "linux-arm64", configuration: "debug" });
    const execCfg = Rules.ExecTransition.apply(cfg);

    const q = <{ platform?: string; configuration?: string; }><any>execCfg.underlyingQualifier;
    Contract.assert(q.platform === Rules.hostExecPlatform(),
        "execCfg.underlyingQualifier.platform must equal the new platform");
    Contract.assert(q.configuration === "debug",
        "execCfg.underlyingQualifier.configuration must carry the preserved mode");

    return "ok";
}

// ----------------------------------------------------------------------------
// ConfiguredLabel
// ----------------------------------------------------------------------------

function test_withConfiguration_carriesBothFields(): string {
    const cfg = Rules.fromQualifier({ platform: "linux-x64" });
    const cl  = Rules.withConfiguration("//foo:bar", cfg);

    Contract.assert(cl.label === "//foo:bar",
        "ConfiguredLabel.label must equal the input label string");
    Contract.assert(Rules.configurationsEqual(cl.configuration, cfg),
        "ConfiguredLabel.configuration must equal the input Configuration");

    return "ok";
}

function test_configuredLabelsEqual_reflexive(): string {
    const cfg = Rules.fromQualifier({ platform: "linux-x64" });
    const cl  = Rules.withConfiguration("//foo:bar", cfg);

    Contract.assert(Rules.configuredLabelsEqual(cl, cl),
        "configuredLabelsEqual must be reflexive");

    return "ok";
}

function test_configuredLabelsEqual_distinguishesLabels(): string {
    const cfg = Rules.fromQualifier({ platform: "linux-x64" });
    const a   = Rules.withConfiguration("//foo:bar",  cfg);
    const b   = Rules.withConfiguration("//foo:quux", cfg);

    Contract.assert(!Rules.configuredLabelsEqual(a, b),
        "ConfiguredLabels with different label strings must not be equal");

    return "ok";
}

function test_configuredLabelsEqual_distinguishesConfigurations(): string {
    const targetCfg = Rules.fromQualifier({ platform: "linux-arm64" });
    const execCfg   = Rules.ExecTransition.apply(targetCfg);

    const target = Rules.withConfiguration("//foo:bar", targetCfg);
    const exec   = Rules.withConfiguration("//foo:bar", execCfg);

    Contract.assert(!Rules.configuredLabelsEqual(target, exec),
        "same label under different configurations must not be equal");

    return "ok";
}

function test_configuredLabelsEqual_undefinedSafety(): string {
    const cfg = Rules.fromQualifier({});
    const cl  = Rules.withConfiguration("//x:y", cfg);

    Contract.assert(!Rules.configuredLabelsEqual(cl, undefined),
        "configuredLabelsEqual(cl, undefined) === false");
    Contract.assert(!Rules.configuredLabelsEqual(undefined, cl),
        "configuredLabelsEqual(undefined, cl) === false");
    Contract.assert(!Rules.configuredLabelsEqual(undefined, undefined),
        "configuredLabelsEqual(undefined, undefined) === false");

    return "ok";
}

// ============================================================================
// Test exports
// ============================================================================

@@public export const tt01 = test_identityTransition_returnsInputUnchanged();
@@public export const tt02 = test_identityTransition_isIdempotent();
@@public export const tt03 = test_targetTransition_isIdentityAlias();
@@public export const tt04 = test_execTransition_producesHostPlatform();
@@public export const tt05 = test_execTransition_isIdempotent();
@@public export const tt06 = test_execTransition_preservesModeConstraint();
@@public export const tt07 = test_execTransition_dropsTargetSpecificConstraints();
@@public export const tt08 = test_execTransition_doesNotMutateInput();
@@public export const tt09 = test_execTransition_carriesUsableQualifier();
@@public export const tt10 = test_withConfiguration_carriesBothFields();
@@public export const tt11 = test_configuredLabelsEqual_reflexive();
@@public export const tt12 = test_configuredLabelsEqual_distinguishesLabels();
@@public export const tt13 = test_configuredLabelsEqual_distinguishesConfigurations();
@@public export const tt14 = test_configuredLabelsEqual_undefinedSafety();
