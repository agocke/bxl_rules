// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Tests for Rules/kinds.dsc — the cross-language kind primitives
 * (RuleKind on `rule()`, TestInfo / TestSize / BinaryInfo, test_suite).
 *
 * Same harness as the other Tests/*.dsc specs: each test returns "ok"
 * on success; a `Contract.assert` failure aborts evaluation and bxl
 * reports a non-zero exit code.
 *
 * The `bxl-kind:*` tag vocabulary is intentionally NOT public — we test
 * the visible contract here (declare `kind: "test"` on rule(), get
 * back a TestInfo provider with the documented fields) rather than
 * asserting the specific tag string the framework attaches behind the
 * scenes.
 */

import * as Rules from "Sdk.Rules";

// ----------------------------------------------------------------------------
// Fixture: a no-op toolchain + a kind-aware test rule and binary rule.
// Both declare `kind:` on `Rules.rule({...})`; the Actions adapter
// auto-tags the scheduled pip with the matching `bxl-kind:*` tag.
// ----------------------------------------------------------------------------

const noopToolchain: Rules.Toolchain = {
    kind: "Toolchain",
    name: "noop-test-toolchain",
};

interface FakeTestAttrs {
    name: string;
    size?: Rules.TestSize;
    timeoutSec?: number;
    flaky?: boolean;
    tags?: string[];
}

const fakeTest = Rules.rule<FakeTestAttrs, FakeTestAttrs, Rules.Toolchain>({
    kind: "test",
    impl: (ctx) => {
        const exe  = ctx.actions.declareOutput(`${ctx.args.name}.test.exe`);
        const bExe = ctx.actions.writeFile(exe, ["fake test exe"]);

        Contract.assert(ctx.runActions !== undefined,
            "runActions must be provided for kind: \"test\"");
        const stamp = ctx.runActions.declareOutput(`${ctx.args.name}.test.stamp`);
        const runat = ctx.runActions.declareOutput(`${ctx.args.name}.test.runat`);
        const boundStamp = ctx.runActions.writeFile(stamp, []);
        const boundRunat = ctx.runActions.writeFile(runat, ["0"]);

        const info = Rules.testInfo({
            name: ctx.args.name,
            stamp: boundStamp,
            runat: boundRunat,
            size: ctx.args.size,
            timeoutSec: ctx.args.timeoutSec,
            flaky: ctx.args.flaky,
            tags: ctx.args.tags,
        });
        return [
            Rules.defaultInfo({ files: [bExe] }),
            info,
        ];
    },
    resolve: (attrs, _r) => attrs,
    toolchain: noopToolchain,
});

interface FakeBinAttrs {
    name: string;
}

const fakeBin = Rules.rule<FakeBinAttrs, FakeBinAttrs, Rules.Toolchain>({
    kind: "binary",
    impl: (ctx) => {
        const bin  = ctx.actions.declareOutput(`${ctx.args.name}.exe`);
        const bBin = ctx.actions.writeFile(bin, ["fake binary"]);

        Contract.assert(ctx.runActions !== undefined,
            "runActions must be provided for kind: \"binary\"");
        const shim  = ctx.runActions.declareOutput(`${ctx.args.name}.run.sh`);
        const bShim = ctx.runActions.writeFile(shim,
            ["#!/bin/sh", `exec ./${ctx.args.name}.exe "$@"`]);

        return [
            Rules.defaultInfo({ files: [bBin] }),
            Rules.binaryInfo({
                name: ctx.args.name,
                binary: bBin,
                runScript: bShim,
            }),
        ];
    },
    resolve: (attrs, _r) => attrs,
    toolchain: noopToolchain,
});

interface FakeLibAttrs {
    name: string;
}

const fakeLib = Rules.rule<FakeLibAttrs, FakeLibAttrs, Rules.Toolchain>({
    impl: (ctx) => {
        Contract.assert(ctx.runActions === undefined,
            "runActions must be undefined when kind is omitted");
        const out  = ctx.actions.declareOutput(`${ctx.args.name}.lib`);
        const bOut = ctx.actions.writeFile(out, ["fake library"]);
        return [
            Rules.defaultInfo({ files: [bOut] }),
        ];
    },
    resolve: (attrs, _r) => attrs,
    toolchain: noopToolchain,
});

// ----------------------------------------------------------------------------
// testInfo / binaryInfo constructors
// ----------------------------------------------------------------------------

function test_testInfo_setsKindAndDefaults(): string {
    const t = fakeTest({ name: "kinds-t-defaults" });
    const ti = Rules.getProvider<Rules.TestInfo>(t, "TestInfo");
    Contract.assert(ti.kind === "TestInfo",
        `testInfo.kind must be "TestInfo"; got "${ti.kind}"`);
    Contract.assert(ti.name === "kinds-t-defaults",
        "testInfo.name must mirror constructor name");
    Contract.assert(ti.timeoutSec === 300,
        `default timeout (no size, no timeoutSec) must be 300; got ${ti.timeoutSec}`);
    Contract.assert(ti.size === undefined,
        `size must be undefined when not supplied; got "${ti.size}"`);
    Contract.assert(ti.flaky === undefined,
        `flaky must be undefined when not supplied; got "${ti.flaky}"`);
    Contract.assert(ti.tags.length === 0,
        "default tags must be empty");
    Contract.assert(ti.stamp.kind === "bound",
        "testInfo.stamp must be bound");
    Contract.assert(ti.runat.kind === "bound",
        "testInfo.runat must be bound");
    return "ok";
}

function test_testInfo_sizeDerivesTimeout(): string {
    const small    = fakeTest({ name: "kinds-t-small",    size: "small"    });
    const medium   = fakeTest({ name: "kinds-t-medium",   size: "medium"   });
    const large    = fakeTest({ name: "kinds-t-large",    size: "large"    });
    const enormous = fakeTest({ name: "kinds-t-enormous", size: "enormous" });

    const tiSmall    = Rules.getProvider<Rules.TestInfo>(small,    "TestInfo");
    const tiMedium   = Rules.getProvider<Rules.TestInfo>(medium,   "TestInfo");
    const tiLarge    = Rules.getProvider<Rules.TestInfo>(large,    "TestInfo");
    const tiEnormous = Rules.getProvider<Rules.TestInfo>(enormous, "TestInfo");

    Contract.assert(tiSmall.timeoutSec    === 60,
        `size "small" must yield timeoutSec 60; got ${tiSmall.timeoutSec}`);
    Contract.assert(tiMedium.timeoutSec   === 300,
        `size "medium" must yield timeoutSec 300; got ${tiMedium.timeoutSec}`);
    Contract.assert(tiLarge.timeoutSec    === 900,
        `size "large" must yield timeoutSec 900; got ${tiLarge.timeoutSec}`);
    Contract.assert(tiEnormous.timeoutSec === 3600,
        `size "enormous" must yield timeoutSec 3600; got ${tiEnormous.timeoutSec}`);

    Contract.assert(tiSmall.size === "small",
        `size must be preserved; got "${tiSmall.size}"`);
    return "ok";
}

function test_testInfo_explicitTimeoutOverridesSize(): string {
    const t = fakeTest({ name: "kinds-t-override", size: "small", timeoutSec: 1234 });
    const ti = Rules.getProvider<Rules.TestInfo>(t, "TestInfo");
    Contract.assert(ti.timeoutSec === 1234,
        `explicit timeoutSec must win over size default; got ${ti.timeoutSec}`);
    Contract.assert(ti.size === "small",
        "size must still be recorded even when timeout is overridden");
    return "ok";
}

function test_testInfo_flakyIsRecorded(): string {
    const flaky    = fakeTest({ name: "kinds-t-flaky",    flaky: true  });
    const reliable = fakeTest({ name: "kinds-t-reliable", flaky: false });

    const tiFlaky    = Rules.getProvider<Rules.TestInfo>(flaky,    "TestInfo");
    const tiReliable = Rules.getProvider<Rules.TestInfo>(reliable, "TestInfo");

    Contract.assert(tiFlaky.flaky === true,
        `flaky: true must be preserved; got "${tiFlaky.flaky}"`);
    Contract.assert(tiReliable.flaky === false,
        `flaky: false must be preserved; got "${tiReliable.flaky}"`);
    return "ok";
}

function test_testInfo_preservesUserTags(): string {
    const t = fakeTest({ name: "kinds-t-tags", timeoutSec: 30, tags: ["manual", "integration"] });
    const ti = Rules.getProvider<Rules.TestInfo>(t, "TestInfo");
    Contract.assert(ti.timeoutSec === 30,
        "timeout must be preserved");
    Contract.assert(ti.tags.length === 2,
        `tags length must be 2; got ${ti.tags.length}`);
    Contract.assert(ti.tags[0] === "manual",
        "first user tag must be preserved");
    Contract.assert(ti.tags[1] === "integration",
        "second user tag must be preserved");
    return "ok";
}

function test_binaryInfo_setsKindAndArtifacts(): string {
    const t = fakeBin({ name: "kinds-b-1" });
    const bi = Rules.getProvider<Rules.BinaryInfo>(t, "BinaryInfo");
    Contract.assert(bi.kind === "BinaryInfo",
        `binaryInfo.kind must be "BinaryInfo"; got "${bi.kind}"`);
    Contract.assert(bi.name === "kinds-b-1",
        "binaryInfo.name must mirror constructor name");
    Contract.assert(bi.binary.kind === "bound",
        "binaryInfo.binary must be bound");
    Contract.assert(bi.runScript.kind === "bound",
        "binaryInfo.runScript must be bound");
    return "ok";
}

function test_binary_defaultInfoExcludesRunScript(): string {
    const t = fakeBin({ name: "kinds-b-split" });
    const di = Rules.getProvider<Rules.DefaultInfo>(t, "DefaultInfo");
    Contract.assert(di.files.length === 1,
        `binary DefaultInfo.files must contain only the build-time binary; got ${di.files.length} files`);
    const onlyFile = Rules.getFile(di.files[0]);
    const expectedSuffix = "kinds-b-split.exe";
    Contract.assert(onlyFile.path.toDiagnosticString().endsWith(expectedSuffix),
        `DefaultInfo.files[0] must be the compiled binary ending in "${expectedSuffix}"; got "${onlyFile.path.toDiagnosticString()}"`);
    return "ok";
}

function test_test_defaultInfoExcludesStampAndRunat(): string {
    const t = fakeTest({ name: "kinds-t-split" });
    const di = Rules.getProvider<Rules.DefaultInfo>(t, "DefaultInfo");
    Contract.assert(di.files.length === 1,
        `test DefaultInfo.files must contain only the build-time test exe; got ${di.files.length} files`);
    const onlyFile = Rules.getFile(di.files[0]);
    const expectedSuffix = "kinds-t-split.test.exe";
    Contract.assert(onlyFile.path.toDiagnosticString().endsWith(expectedSuffix),
        `DefaultInfo.files[0] must be the compiled test exe ending in "${expectedSuffix}"; got "${onlyFile.path.toDiagnosticString()}"`);
    return "ok";
}

function test_library_hasNoRunActionsAdapter(): string {
    const t = fakeLib({ name: "kinds-l-default" });
    const di = Rules.getProvider<Rules.DefaultInfo>(t, "DefaultInfo");
    Contract.assert(di.files.length === 1,
        `library DefaultInfo.files must contain one file; got ${di.files.length}`);
    return "ok";
}

// ----------------------------------------------------------------------------
// test_suite — manifest pip wires the tests in via DefaultInfo
// ----------------------------------------------------------------------------

function test_testSuite_emptyTests_yieldsManifestAlone(): string {
    const suite = Rules.test_suite({ name: "kinds-suite-empty", tests: [] });
    Contract.assert(suite.manifest.kind === "bound",
        "test_suite.manifest must be bound");
    Contract.assert(suite.manifest.shortPath === "kinds-suite-empty.tests.json",
        `manifest shortPath must be "<name>.tests.json"; got "${suite.manifest.shortPath}"`);
    Contract.assert(suite.defaultInfo.files.length === 1,
        `empty suite defaultInfo must contain only the manifest; got ${suite.defaultInfo.files.length} files`);
    return "ok";
}

function test_testSuite_aggregatesStampAndRunatPerTest(): string {
    const tA = fakeTest({ name: "kinds-suite-a", size: "small", flaky: true });
    const tB = fakeTest({ name: "kinds-suite-b", tags: ["integration"] });

    const tiA = Rules.getProvider<Rules.TestInfo>(tA, "TestInfo");
    const tiB = Rules.getProvider<Rules.TestInfo>(tB, "TestInfo");

    const suite = Rules.test_suite({
        name: "kinds-suite-agg",
        tests: [tiA, tiB],
    });

    // 1 manifest + 2 stamps + 2 runats = 5 files
    Contract.assert(suite.defaultInfo.files.length === 5,
        `suite must wire manifest + stamp + runat per test; got ${suite.defaultInfo.files.length} files`);
    Contract.assert(suite.manifest.shortPath === "kinds-suite-agg.tests.json",
        "manifest name must follow <suite>.tests.json convention");
    return "ok";
}

// ============================================================================
// Test exports — top-level evaluation runs each test exactly once.
// ============================================================================

@@public export const k01 = test_testInfo_setsKindAndDefaults();
@@public export const k02 = test_testInfo_sizeDerivesTimeout();
@@public export const k03 = test_testInfo_explicitTimeoutOverridesSize();
@@public export const k04 = test_testInfo_flakyIsRecorded();
@@public export const k05 = test_testInfo_preservesUserTags();
@@public export const k06 = test_binaryInfo_setsKindAndArtifacts();
@@public export const k07 = test_binary_defaultInfoExcludesRunScript();
@@public export const k08 = test_library_hasNoRunActionsAdapter();
@@public export const k09 = test_testSuite_emptyTests_yieldsManifestAlone();
@@public export const k10 = test_testSuite_aggregatesStampAndRunatPerTest();
@@public export const k11 = test_test_defaultInfoExcludesStampAndRunat();
