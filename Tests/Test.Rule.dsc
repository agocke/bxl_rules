// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Tests that exercise the Actions adapter through a real `Rules.rule(...)`
 * invocation rather than calling internals directly.
 *
 * Why a separate spec: `createActions` is intentionally not `@@public`
 * (each invocation owns its own claimed-paths set; exposing the factory
 * would let callers spin up siblings with the same target name and
 * quietly bypass the single-binding invariant). The only sanctioned way
 * to drive the adapter is through `Rules.rule({...})`, so test coverage
 * for `ctx.actions` lives here, scheduling real BuildXL pips at
 * analysis time (`/phase:Schedule`) without ever executing them.
 */

import * as Rules from "Sdk.Rules";

// ----------------------------------------------------------------------------
// Test fixture: a no-op toolchain and a tiny rule that writes a text file.
// ----------------------------------------------------------------------------

const noopToolchain: Rules.Toolchain = {
    kind: "Toolchain",
    name: "noop-test-toolchain",
};

interface WriteOneAttrs {
    name: string;
    lines: string[];
    outName: string;
}

interface WriteOneResult extends Rules.DefaultInfo {
    written: Rules.Artifact;
}

const writeOne = Rules.rule<WriteOneAttrs, WriteOneAttrs, Rules.Toolchain>({
    impl: (ctx) => {
        const declared = ctx.actions.declareOutput(ctx.args.outName);
        Contract.assert(declared.kind === "unbound",
            `declareOutput must return an unbound Artifact; got "${declared.kind}"`);

        const bound = ctx.actions.writeFile(declared, ctx.args.lines);
        Contract.assert(bound.kind === "bound",
            `writeFile must return a bound Artifact; got "${bound.kind}"`);

        return [
            <WriteOneResult>{
                kind: "WriteOneResult",
                files: [bound],
                written: bound,
            },
            Rules.defaultInfo({ files: [bound] }),
        ];
    },
    resolve: (attrs, _resolver) => attrs,
    toolchain: noopToolchain,
});

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

function test_actions_declareOutput_andWriteFile_throughRule(): string {
    const t = writeOne({
        name: "test-rule-write-one",
        lines: ["hello", "world"],
        outName: "greeting.txt",
    });

    Contract.assert(t !== undefined,
        "rule invocation must return a target");
    const result = Rules.getProvider<WriteOneResult>(t, "WriteOneResult");
    Contract.assert(result !== undefined,
        "target must contain WriteOneResult provider");
    Contract.assert(result.written !== undefined,
        "rule must surface a bound output Artifact");
    Contract.assert(result.written.kind === "bound",
        `result.written.kind should be "bound"; got "${result.written.kind}"`);
    Contract.assert(result.written.shortPath === "greeting.txt",
        `shortPath should mirror the declareOutput name; got "${result.written.shortPath}"`);
    Contract.assert(result.written.boundFile !== undefined,
        "bound Artifact must carry a boundFile");

    const defaultInfo = Rules.getProvider<Rules.DefaultInfo>(t, "DefaultInfo");
    Contract.assert(defaultInfo !== undefined,
        "target must contain DefaultInfo provider");
    Contract.assert(defaultInfo.files.length === 1,
        "DefaultInfo.files should have exactly one entry");
    Contract.assert(defaultInfo.files[0].kind === "bound",
        "DefaultInfo.files[0] should carry the bound Artifact");

    return "ok";
}

// ----------------------------------------------------------------------------
// Per-target output isolation
// ----------------------------------------------------------------------------

function test_actions_perTargetOutputIsolation(): string {
    // Two invocations of the same rule with distinct names must claim
    // disjoint output directories — declaring the same logical output
    // name in both must NOT collide on the same path.
    const tA = writeOne({ name: "iso-a", lines: ["a"], outName: "out.txt" });
    const tB = writeOne({ name: "iso-b", lines: ["b"], outName: "out.txt" });

    const a = Rules.getProvider<WriteOneResult>(tA, "WriteOneResult");
    const b = Rules.getProvider<WriteOneResult>(tB, "WriteOneResult");

    Contract.assert(a.written.shortPath === "out.txt", "rule a shortPath");
    Contract.assert(b.written.shortPath === "out.txt", "rule b shortPath");
    Contract.assert(!Rules.artifactsEqual(a.written, b.written),
        "outputs from two different rule invocations must live at different paths");

    return "ok";
}

// ============================================================================
// Test exports — top-level evaluation runs each test exactly once.
// ============================================================================

@@public export const r01 = test_actions_declareOutput_andWriteFile_throughRule();
@@public export const r02 = test_actions_perTargetOutputIsolation();
