// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Tests for Rules/kinds.dsc — the cross-language kind primitives
 * (KindTags, TestInfo / BinaryInfo, test_suite).
 *
 * Same harness as the other Tests/*.dsc specs: each test returns "ok"
 * on success; a `Contract.assert` failure aborts evaluation and bxl
 * reports a non-zero exit code.
 */

import * as Rules from "Sdk.Rules";

// ----------------------------------------------------------------------------
// Fixture: a no-op toolchain + a rule that schedules a fake test runner
// pip producing the stamp / runat outputs and returns TestInfo.
// ----------------------------------------------------------------------------

const noopToolchain: Rules.Toolchain = {
    kind: "Toolchain",
    name: "noop-test-toolchain",
};

interface FakeTestAttrs {
    name: string;
    timeoutSec?: number;
    tags?: string[];
}

interface FakeTestResult extends Rules.DefaultInfo {
    testInfo: Rules.TestInfo;
}

const fakeTest = Rules.rule<FakeTestAttrs, FakeTestAttrs, Rules.Toolchain, FakeTestResult>({
    impl: (ctx) => {
        const stamp = ctx.actions.declareOutput(`${ctx.args.name}.test.stamp`);
        const runat = ctx.actions.declareOutput(`${ctx.args.name}.test.runat`);
        const boundStamp = ctx.actions.writeFile(stamp, []);            // empty success marker
        const boundRunat = ctx.actions.writeFile(runat, ["0"]);          // fake timestamp
        const info = Rules.testInfo({
            name: ctx.args.name,
            stamp: boundStamp,
            runat: boundRunat,
            timeoutSec: ctx.args.timeoutSec || 60,
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
// KindTags — well-known tag namespace
// ----------------------------------------------------------------------------

function test_kindTags_haveStableValues(): string {
    Contract.assert(Rules.KindTags.test === "bxl-kind:test",
        `KindTags.test must be "bxl-kind:test"; got "${Rules.KindTags.test}"`);
    Contract.assert(Rules.KindTags.binary === "bxl-kind:binary",
        `KindTags.binary must be "bxl-kind:binary"; got "${Rules.KindTags.binary}"`);
    return "ok";
}

// ----------------------------------------------------------------------------
// testInfo / binaryInfo constructors
// ----------------------------------------------------------------------------

function test_testInfo_setsKindAndDefaults(): string {
    const r = fakeTest({ name: "kinds-t-defaults" });
    Contract.assert(r.testInfo.kind === "TestInfo",
        `testInfo.kind must be "TestInfo"; got "${r.testInfo.kind}"`);
    Contract.assert(r.testInfo.name === "kinds-t-defaults",
        "testInfo.name must mirror constructor name");
    Contract.assert(r.testInfo.timeoutSec === 60,
        `default timeout must be 60; got ${r.testInfo.timeoutSec}`);
    Contract.assert(r.testInfo.tags.length === 0,
        "default tags must be empty");
    Contract.assert(r.testInfo.stamp.kind === "bound",
        "testInfo.stamp must be bound");
    Contract.assert(r.testInfo.runat.kind === "bound",
        "testInfo.runat must be bound");
    return "ok";
}

function test_testInfo_preservesUserTags(): string {
    const r = fakeTest({ name: "kinds-t-tags", timeoutSec: 30, tags: ["manual", "flaky"] });
    Contract.assert(r.testInfo.timeoutSec === 30,
        "timeout must be preserved");
    Contract.assert(r.testInfo.tags.length === 2,
        `tags length must be 2; got ${r.testInfo.tags.length}`);
    Contract.assert(r.testInfo.tags[0] === "manual",
        "first user tag must be preserved");
    Contract.assert(r.testInfo.tags[1] === "flaky",
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
    const a = fakeTest({ name: "kinds-suite-a" });
    const b = fakeTest({ name: "kinds-suite-b", tags: ["long"] });

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

@@public export const k01 = test_kindTags_haveStableValues();
@@public export const k02 = test_testInfo_setsKindAndDefaults();
@@public export const k03 = test_testInfo_preservesUserTags();
@@public export const k04 = test_binaryInfo_setsKindAndArtifacts();
@@public export const k05 = test_testSuite_emptyTests_yieldsManifestAlone();
@@public export const k06 = test_testSuite_aggregatesStampAndRunatPerTest();
