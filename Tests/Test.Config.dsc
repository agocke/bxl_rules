// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Tests for Rules/config.dsc (Configuration as a value).
 *
 * Test discipline:
 *   Each test is a top-level function returning the literal "ok" (so the
 *   exported sentinel const is visible in `bxl` output). Assertions use
 *   `Contract.assert(condition, message)`; a false condition aborts
 *   evaluation of the spec, which `bxl` reports as an error and a
 *   non-zero exit code.
 *
 *   Successful evaluation = all tests passed.
 */

import * as Rules from "Sdk.Rules";

// ----------------------------------------------------------------------------
// fromQualifier — derivations
// ----------------------------------------------------------------------------

function test_fromQualifier_emptyDefaultsToHost(): string {
    const cfg = Rules.fromQualifier({});

    Contract.assert(cfg !== undefined,
        "fromQualifier must return a Configuration");
    Contract.assert(cfg.platform === Rules.hostExecPlatform(),
        "empty qualifier => platform falls back to host exec platform");
    Contract.assert(cfg.constraints.length === 0,
        "empty qualifier => no derived constraints");
    Contract.assert(cfg.hash === Rules.computeHash(Rules.hostExecPlatform(), []),
        "Configuration.hash must equal computeHash(platform, constraints) — the encoding contract");

    return "ok";
}

function test_hashIsCollisionResistantToDelimiters(): string {
    // Regression test for an injectivity bug: without length-prefix encoding,
    // these two (platform, constraints) tuples produced identical hashes
    // because `;` and `=` were not escaped inside constraint values.
    //
    // We test the encoding directly because (post-`opts`-removal) the
    // `fromQualifier` API can't construct multi-constraint configurations
    // — the qualifier projects to at most one constraint. The injectivity
    // contract is a property of the encoding, independent of which API
    // produces the inputs.
    //
    // A: one constraint whose VALUE happens to contain ";os=linux"
    const hashA = Rules.computeHash("linux", [
        { setting: "mode", value: "x;os=linux" },
    ]);
    // B: two constraints, the second of which IS os=linux
    const hashB = Rules.computeHash("linux", [
        { setting: "mode", value: "x"     },
        { setting: "os",   value: "linux" },
    ]);

    Contract.assert(hashA !== hashB,
        "delimiter chars in constraint values must not collide with multi-constraint configurations");

    return "ok";
}

function test_fromQualifier_readsPlatformField(): string {
    const cfg = Rules.fromQualifier({ platform: "linux-arm64" });

    Contract.assert(cfg.platform === "linux-arm64",
        "qualifier.platform takes precedence over host");

    return "ok";
}

function test_fromQualifier_readsTargetRuntimeField(): string {
    const cfg = Rules.fromQualifier({ targetRuntime: "win-x64" });

    Contract.assert(cfg.platform === "win-x64",
        "qualifier.targetRuntime is the fallback when .platform is absent");

    return "ok";
}

function test_fromQualifier_readsConfigurationField(): string {
    const cfg = Rules.fromQualifier({ configuration: "release" });
    const mode = Rules.getConstraint(cfg, Rules.ConstraintSettings.mode);

    Contract.assert(mode === "release",
        "qualifier.configuration => derives a 'mode' constraint");

    return "ok";
}

// ----------------------------------------------------------------------------
// Constraint ordering & hash determinism (encoding-level contracts)
// ----------------------------------------------------------------------------

function test_constraintsAreSortedBySettingName(): string {
    // Tested against `sortConstraints` directly — `fromQualifier` only
    // produces single-constraint configs, so multi-element ordering is a
    // pure encoding-layer property.
    const sorted = Rules.sortConstraints([
        { setting: "zebra", value: "z" },
        { setting: "apple", value: "a" },
        { setting: "mango", value: "m" },
    ]);

    Contract.assert(sorted[0].setting === "apple",
        "sorted[0] should be the alphabetically-first setting");
    Contract.assert(sorted[1].setting === "mango",
        "sorted[1] should be 'mango'");
    Contract.assert(sorted[2].setting === "zebra",
        "sorted[2] should be 'zebra'");

    return "ok";
}

function test_hashIsStableUnderInsertionOrder(): string {
    // The contract is: `computeHash` requires its constraints to already be
    // sorted (the Configuration factory enforces this). So we sort both
    // inputs and verify equal hashes — i.e. permutations canonicalise.
    const a = Rules.computeHash("linux-x64", Rules.sortConstraints([
        { setting: "zebra", value: "z" },
        { setting: "apple", value: "a" },
    ]));
    const b = Rules.computeHash("linux-x64", Rules.sortConstraints([
        { setting: "apple", value: "a" },
        { setting: "zebra", value: "z" },
    ]));

    Contract.assert(a === b,
        "permutations of the same constraint set must hash equal after sorting");

    return "ok";
}

function test_hashDistinguishesPlatform(): string {
    const x64 = Rules.fromQualifier({ platform: "linux-x64"   });
    const a64 = Rules.fromQualifier({ platform: "linux-arm64" });

    Contract.assert(x64.hash !== a64.hash,
        "different platforms must produce different hashes");
    Contract.assert(!Rules.configurationsEqual(x64, a64),
        "configurations differing in platform must not be equal");

    return "ok";
}

function test_hashDistinguishesConstraints(): string {
    const debug   = Rules.fromQualifier({ configuration: "debug"   });
    const release = Rules.fromQualifier({ configuration: "release" });

    Contract.assert(debug.hash !== release.hash,
        "different mode constraints must produce different hashes");

    return "ok";
}

// ----------------------------------------------------------------------------
// getConstraint
// ----------------------------------------------------------------------------

function test_getConstraint_returnsUndefinedForMissing(): string {
    const cfg = Rules.fromQualifier({});

    Contract.assert(Rules.getConstraint(cfg, "nonexistent") === undefined,
        "getConstraint must return undefined for a missing setting");

    return "ok";
}

function test_getConstraint_undefinedConfigIsSafe(): string {
    Contract.assert(Rules.getConstraint(undefined, Rules.ConstraintSettings.os) === undefined,
        "getConstraint must tolerate an undefined Configuration");

    return "ok";
}

// ----------------------------------------------------------------------------
// configurationsEqual
// ----------------------------------------------------------------------------

function test_configurationsEqual_undefinedSafety(): string {
    const cfg = Rules.fromQualifier({});

    Contract.assert(!Rules.configurationsEqual(cfg, undefined),
        "configurationsEqual(cfg, undefined) === false");
    Contract.assert(!Rules.configurationsEqual(undefined, cfg),
        "configurationsEqual(undefined, cfg) === false");
    Contract.assert(!Rules.configurationsEqual(undefined, undefined),
        "configurationsEqual(undefined, undefined) === false (no identity for absence)");

    return "ok";
}

// ----------------------------------------------------------------------------
// hostExecPlatform — sanity check
// ----------------------------------------------------------------------------

function test_hostExecPlatform_isWellFormed(): string {
    const p = Rules.hostExecPlatform();

    Contract.assert(p !== undefined && p.length > 0,
        "hostExecPlatform must return a non-empty label");
    Contract.assert(p.indexOf("-") > 0,
        "hostExecPlatform label must be of the form '<os>-<arch>'");

    return "ok";
}

// ----------------------------------------------------------------------------
// Pass-through of unknown qualifier axes
// ----------------------------------------------------------------------------

function test_fromQualifier_passesThroughUnknownAxes(): string {
    // Two qualifiers identical on the well-known axes (os/cpu) but
    // differing on an unknown axis (`tfm`) must produce Configurations
    // with different hashes — otherwise `select()`-style dispatch on the
    // unknown axis would silently collapse.
    const cfg8 = Rules.fromQualifier(<Qualifier><any>{ os: "linux", cpu: "x64", tfm: "net8.0" });
    const cfg9 = Rules.fromQualifier(<Qualifier><any>{ os: "linux", cpu: "x64", tfm: "net9.0" });

    Contract.assert(cfg8.hash !== cfg9.hash,
        "qualifiers differing on a non-well-known axis must produce distinct Configuration hashes");

    const tfm8 = Rules.getConstraint(cfg8, "tfm");
    const tfm9 = Rules.getConstraint(cfg9, "tfm");
    Contract.assert(tfm8 === "net8.0",
        `getConstraint should expose the unknown axis verbatim; got "${tfm8}"`);
    Contract.assert(tfm9 === "net9.0",
        `getConstraint should expose the unknown axis verbatim; got "${tfm9}"`);

    return "ok";
}

function test_fromQualifier_configurationFieldRenamesToMode(): string {
    // The qualifier-side field name `configuration` is renamed to the
    // constraint setting `mode` for backward compatibility — verify the
    // pass-through layer preserves that rename rather than emitting a
    // bare `configuration` constraint.
    const cfg = Rules.fromQualifier(<Qualifier><any>{ configuration: "release" });

    Contract.assert(Rules.getConstraint(cfg, Rules.ConstraintSettings.mode) === "release",
        "qualifier.configuration must surface as the 'mode' constraint");
    Contract.assert(Rules.getConstraint(cfg, "configuration") === undefined,
        "qualifier.configuration must NOT appear under the literal 'configuration' setting name");

    return "ok";
}



@@public export const t01 = test_fromQualifier_emptyDefaultsToHost();
@@public export const t02 = test_fromQualifier_readsPlatformField();
@@public export const t03 = test_fromQualifier_readsTargetRuntimeField();
@@public export const t04 = test_fromQualifier_readsConfigurationField();
@@public export const t05 = test_constraintsAreSortedBySettingName();
@@public export const t06 = test_hashIsStableUnderInsertionOrder();
@@public export const t07 = test_hashDistinguishesPlatform();
@@public export const t08 = test_hashDistinguishesConstraints();
@@public export const t09 = test_getConstraint_returnsUndefinedForMissing();
@@public export const t10 = test_getConstraint_undefinedConfigIsSafe();
@@public export const t11 = test_configurationsEqual_undefinedSafety();
@@public export const t12 = test_hostExecPlatform_isWellFormed();
@@public export const t13 = test_hashIsCollisionResistantToDelimiters();
@@public export const t14 = test_fromQualifier_passesThroughUnknownAxes();
@@public export const t15 = test_fromQualifier_configurationFieldRenamesToMode();
