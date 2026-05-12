// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Tests for Rules/transition.dsc.
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
    // ExecTransition rewrites os/cpu to the host bucket and preserves the
    // mode (which is the only target-side constraint that should survive an
    // exec transition). Constraints that don't come from a qualifier axis
    // the SDK recognises (i.e., anything beyond os/cpu/mode) are not
    // representable through `fromQualifier`, so the post-conditions below
    // are: os == hostOs(), cpu == hostCpu(), no mode entry.
    const cfg     = Rules.fromQualifier({ platform: "linux-arm64" });
    const execCfg = Rules.ExecTransition.apply(cfg);

    Contract.assert(execCfg.platform === Rules.hostExecPlatform(),
        "platform should be host");
    Contract.assert(Rules.getConstraint(execCfg, Rules.ConstraintSettings.os) === Rules.hostOs(),
        "exec config must carry the host os as a constraint");
    Contract.assert(Rules.getConstraint(execCfg, Rules.ConstraintSettings.cpu) === Rules.hostCpu(),
        "exec config must carry the host cpu as a constraint");
    Contract.assert(Rules.getConstraint(execCfg, Rules.ConstraintSettings.mode) === undefined,
        "no mode constraint in the input => no mode constraint in the output");

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

    const q = <{ os?: string; cpu?: string; configuration?: string; }><any>execCfg.underlyingQualifier;
    // ExecTransition (singleton) uses BuildXL's detected host labels, so
    // we compare with the helpers rather than hard-coding "linux"/etc.
    Contract.assert(q.os === Rules.hostOs(),
        "execCfg.underlyingQualifier.os must equal the host os label");
    Contract.assert(q.cpu === Rules.hostCpu(),
        "execCfg.underlyingQualifier.cpu must equal the host cpu label");
    Contract.assert(q.configuration === "debug",
        "execCfg.underlyingQualifier.configuration must carry the preserved mode");

    return "ok";
}

// ----------------------------------------------------------------------------
// makeExecTransition — factory with explicit host labels
// ----------------------------------------------------------------------------

function test_makeExecTransition_usesSuppliedLabels(): string {
    // The factory's purpose: a workspace whose qualifier matrix uses
    // labels other than BuildXL's three-bucket vocabulary
    // (e.g. "linux" instead of "unix") constructs its own transition
    // with those labels.
    const myExec = Rules.makeExecTransition({ os: "linux", cpu: "x64" });

    const cfg     = Rules.fromQualifier({ os: "linux", cpu: "arm64", configuration: "debug" });
    const execCfg = myExec.apply(cfg);

    Contract.assert(Rules.getConstraint(execCfg, Rules.ConstraintSettings.os) === "linux",
        "makeExecTransition must use the supplied os label, not the BuildXL-detected one");
    Contract.assert(Rules.getConstraint(execCfg, Rules.ConstraintSettings.cpu) === "x64",
        "makeExecTransition must use the supplied cpu label");
    Contract.assert(execCfg.platform === "linux-x64",
        "platform must reflect the supplied <os>-<cpu> bundle");

    return "ok";
}

function test_makeExecTransition_preservesMode(): string {
    const myExec = Rules.makeExecTransition({ os: "linux", cpu: "x64" });
    const cfg    = Rules.fromQualifier({ os: "linux", cpu: "arm64", configuration: "release" });

    const execCfg = myExec.apply(cfg);
    Contract.assert(Rules.getConstraint(execCfg, Rules.ConstraintSettings.mode) === "release",
        "makeExecTransition must preserve the mode constraint just like the singleton");

    return "ok";
}

function test_makeExecTransition_isIdempotent(): string {
    const myExec = Rules.makeExecTransition({ os: "linux", cpu: "x64" });
    const cfg    = Rules.fromQualifier({ os: "linux", cpu: "arm64", configuration: "debug" });

    const once  = myExec.apply(cfg);
    const twice = myExec.apply(once);

    Contract.assert(Rules.configurationsEqual(once, twice),
        "makeExecTransition produces an idempotent transition");

    return "ok";
}

// ----------------------------------------------------------------------------
// Multi-axis qualifier (os/cpu/mode independently switchable)
// ----------------------------------------------------------------------------

function test_fromQualifier_readsOsAndCpuIndependently(): string {
    const cfg = Rules.fromQualifier({ os: "linux", cpu: "arm64", configuration: "debug" });

    Contract.assert(Rules.getConstraint(cfg, Rules.ConstraintSettings.os) === "linux",
        "fromQualifier must read qualifier.os into a constraint");
    Contract.assert(Rules.getConstraint(cfg, Rules.ConstraintSettings.cpu) === "arm64",
        "fromQualifier must read qualifier.cpu into a constraint");
    Contract.assert(Rules.getConstraint(cfg, Rules.ConstraintSettings.mode) === "debug",
        "fromQualifier must read qualifier.configuration into a 'mode' constraint");

    return "ok";
}

function test_fromQualifier_osPlusCpuSynthesisesPlatform(): string {
    const cfg = Rules.fromQualifier({ os: "haiku", cpu: "x64" });

    Contract.assert(cfg.platform === "haiku-x64",
        "os + cpu together must synthesise platform as '<os>-<cpu>' — even for OS labels BuildXL doesn't know about");

    return "ok";
}

function test_fromQualifier_legacyPlatformFieldStillWorks(): string {
    // Workspaces with the old combined-platform shape continue to work.
    // Switching on "is this arm64" is uglier without an os/cpu split
    // (you have to substring-match), but the basic projection is intact.
    const cfg = Rules.fromQualifier({ platform: "linux-arm64" });

    Contract.assert(cfg.platform === "linux-arm64",
        "legacy qualifier.platform field still projects through");
    Contract.assert(Rules.getConstraint(cfg, Rules.ConstraintSettings.os) === undefined,
        "legacy shape doesn't synthesise os/cpu constraints — they live only in the combined platform string");

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
@@public export const tt10 = test_makeExecTransition_usesSuppliedLabels();
@@public export const tt11 = test_makeExecTransition_preservesMode();
@@public export const tt12 = test_makeExecTransition_isIdempotent();
@@public export const tt13 = test_fromQualifier_readsOsAndCpuIndependently();
@@public export const tt14 = test_fromQualifier_osPlusCpuSynthesisesPlatform();
@@public export const tt15 = test_fromQualifier_legacyPlatformFieldStillWorks();
