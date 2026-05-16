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

interface FakeTestResult extends Rules.DefaultInfo {
    testInfo: Rules.TestInfo;
}

const fakeTest = Rules.rule<FakeTestAttrs, FakeTestAttrs, Rules.Toolchain, FakeTestResult>({
    kind: "test",
    impl: (ctx) => {
        const stamp = ctx.actions.declareOutput(`${ctx.args.name}.test.stamp`);
        const runat = ctx.actions.declareOutput(`${ctx.args.name}.test.runat`);
        const boundStamp = ctx.actions.writeFile(stamp, []);            // empty success marker
        const boundRunat = ctx.actions.writeFile(runat, ["0"]);          // fake timestamp
        const info = Rules.testInfo({
            name: ctx.args.name,
            stamp: boundStamp,
            runat: boundRunat,
            size: ctx.args.size,
            timeoutSec: ctx.args.timeoutSec,
            flaky: ctx.args.flaky,
            tags: ctx.args.tags,
        });
        return {
            kind: "DefaultInfo",
            files: [Rules.getFile(boundStamp), Rules.getFile(boundRunat)],
            testInfo: info,
        };
    },
    resolve: (attrs, _r) => attrs,
    toolchain: noopToolchain,
});

interface FakeBinAttrs {
    name: string;
}

interface FakeBinResult extends Rules.DefaultInfo {
    binaryInfo: Rules.BinaryInfo;
}

const fakeBin = Rules.rule<FakeBinAttrs, FakeBinAttrs, Rules.Toolchain, FakeBinResult>({
    kind: "binary",
    impl: (ctx) => {
        const bin   = ctx.actions.declareOutput(`${ctx.args.name}.exe`);
        const shim  = ctx.actions.declareOutput(`${ctx.args.name}.run.sh`);
        const bBin  = ctx.actions.writeFile(bin,  ["fake binary"]);
        const bShim = ctx.actions.writeFile(shim, ["#!/bin/sh", `exec ./${ctx.args.name}.exe "$@"`]);
        return {
            kind: "DefaultInfo",
            files: [Rules.getFile(bBin), Rules.getFile(bShim)],
            binaryInfo: Rules.binaryInfo({
                name: ctx.args.name,
                binary: bBin,
                runScript: bShim,
            }),
        };
    },
    resolve: (attrs, _r) => attrs,
    toolchain: noopToolchain,
});

// ----------------------------------------------------------------------------
// testInfo / binaryInfo constructors
// ----------------------------------------------------------------------------

function test_testInfo_setsKindAndDefaults(): string {
    const r = fakeTest({ name: "kinds-t-defaults" });
    Contract.assert(r.testInfo.kind === "TestInfo",
        `testInfo.kind must be "TestInfo"; got "${r.testInfo.kind}"`);
    Contract.assert(r.testInfo.name === "kinds-t-defaults",
        "testInfo.name must mirror constructor name");
    // No size, no timeoutSec → fall back to "medium" default (300s).
    Contract.assert(r.testInfo.timeoutSec === 300,
        `default timeout (no size, no timeoutSec) must be 300; got ${r.testInfo.timeoutSec}`);
    Contract.assert(r.testInfo.size === undefined,
        `size must be undefined when not supplied; got "${r.testInfo.size}"`);
    Contract.assert(r.testInfo.flaky === undefined,
        `flaky must be undefined when not supplied; got "${r.testInfo.flaky}"`);
    Contract.assert(r.testInfo.tags.length === 0,
        "default tags must be empty");
    Contract.assert(r.testInfo.stamp.kind === "bound",
        "testInfo.stamp must be bound");
    Contract.assert(r.testInfo.runat.kind === "bound",
        "testInfo.runat must be bound");
    return "ok";
}

function test_testInfo_sizeDerivesTimeout(): string {
    const small    = fakeTest({ name: "kinds-t-small",    size: "small"    });
    const medium   = fakeTest({ name: "kinds-t-medium",   size: "medium"   });
    const large    = fakeTest({ name: "kinds-t-large",    size: "large"    });
    const enormous = fakeTest({ name: "kinds-t-enormous", size: "enormous" });

    Contract.assert(small.testInfo.timeoutSec    === 60,
        `size "small" must yield timeoutSec 60; got ${small.testInfo.timeoutSec}`);
    Contract.assert(medium.testInfo.timeoutSec   === 300,
        `size "medium" must yield timeoutSec 300; got ${medium.testInfo.timeoutSec}`);
    Contract.assert(large.testInfo.timeoutSec    === 900,
        `size "large" must yield timeoutSec 900; got ${large.testInfo.timeoutSec}`);
    Contract.assert(enormous.testInfo.timeoutSec === 3600,
        `size "enormous" must yield timeoutSec 3600; got ${enormous.testInfo.timeoutSec}`);

    // size is preserved on the provider (typed, not encoded in tags).
    Contract.assert(small.testInfo.size === "small",
        `size must be preserved; got "${small.testInfo.size}"`);
    return "ok";
}

function test_testInfo_explicitTimeoutOverridesSize(): string {
    // Explicit timeoutSec wins over the size-derived default.
    const r = fakeTest({ name: "kinds-t-override", size: "small", timeoutSec: 1234 });
    Contract.assert(r.testInfo.timeoutSec === 1234,
        `explicit timeoutSec must win over size default; got ${r.testInfo.timeoutSec}`);
    Contract.assert(r.testInfo.size === "small",
        "size must still be recorded even when timeout is overridden");
    return "ok";
}

function test_testInfo_flakyIsRecorded(): string {
    const flaky    = fakeTest({ name: "kinds-t-flaky",    flaky: true  });
    const reliable = fakeTest({ name: "kinds-t-reliable", flaky: false });

    Contract.assert(flaky.testInfo.flaky === true,
        `flaky: true must be preserved; got "${flaky.testInfo.flaky}"`);
    Contract.assert(reliable.testInfo.flaky === false,
        `flaky: false must be preserved; got "${reliable.testInfo.flaky}"`);
    return "ok";
}

function test_testInfo_preservesUserTags(): string {
    const r = fakeTest({ name: "kinds-t-tags", timeoutSec: 30, tags: ["manual", "integration"] });
    Contract.assert(r.testInfo.timeoutSec === 30,
        "timeout must be preserved");
    Contract.assert(r.testInfo.tags.length === 2,
        `tags length must be 2; got ${r.testInfo.tags.length}`);
    Contract.assert(r.testInfo.tags[0] === "manual",
        "first user tag must be preserved");
    Contract.assert(r.testInfo.tags[1] === "integration",
        "second user tag must be preserved");
    return "ok";
}

function test_binaryInfo_setsKindAndArtifacts(): string {
    const r = fakeBin({ name: "kinds-b-1" });
    Contract.assert(r.binaryInfo.kind === "BinaryInfo",
        `binaryInfo.kind must be "BinaryInfo"; got "${r.binaryInfo.kind}"`);
    Contract.assert(r.binaryInfo.name === "kinds-b-1",
        "binaryInfo.name must mirror constructor name");
    Contract.assert(r.binaryInfo.binary.kind === "bound",
        "binaryInfo.binary must be bound");
    Contract.assert(r.binaryInfo.runScript.kind === "bound",
        "binaryInfo.runScript must be bound");
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
    const a = fakeTest({ name: "kinds-suite-a", size: "small", flaky: true });
    const b = fakeTest({ name: "kinds-suite-b", tags: ["integration"] });

    const suite = Rules.test_suite({
        name: "kinds-suite-agg",
        tests: [a.testInfo, b.testInfo],
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
@@public export const k07 = test_testSuite_emptyTests_yieldsManifestAlone();
@@public export const k08 = test_testSuite_aggregatesStampAndRunatPerTest();
