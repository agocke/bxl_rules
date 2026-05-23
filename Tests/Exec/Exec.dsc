// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Execution-level test for the build-vs-run split.
 *
 * Defines one binary-kind rule that schedules:
 *
 *   - a build-time pip on ctx.actions, writing "BUILD-RAN"
 *     to <targetDir>/build.txt. The file is wrapped in
 *     DefaultInfo.files, so it's transitively reachable from
 *     the top-level @@public value and a plain `bxl` materialises it.
 *
 *   - a run-time pip on ctx.runActions, writing "RUN-RAN"
 *     to <targetDir>/run.txt. This file is exposed only via
 *     BinaryInfo.runScript — NOT in DefaultInfo.files. The pip
 *     carries the framework's `bxl-kind:binary` tag.
 *
 * The bash driver (run-exec-tests.sh) then runs:
 *
 *   Scenario A: `bxl`                                  ⇒ build.txt only.
 *   Scenario B: `bxl /f:tag='bxl-kind:binary'`         ⇒ run.txt also.
 *
 * If a plain `bxl` build also materialises run.txt, the deferral
 * contract is broken — exactly the regression these tests guard
 * against.
 */

import * as Rules from "Sdk.Rules";

const noopToolchain: Rules.Toolchain = {
    kind: "Toolchain",
    name: "exec-test-toolchain",
};

interface ExecAttrs {
    name: string;
}

interface ExecResult extends Rules.DefaultInfo {
    binaryInfo: Rules.BinaryInfo;
}

const execBin = Rules.rule<ExecAttrs, ExecAttrs, Rules.Toolchain, ExecResult>({
    kind: "binary",
    impl: (ctx) => {
        // Build-time: write a small payload.
        const buildOut = ctx.actions.declareOutput("build.txt");
        const bBuild = ctx.actions.writeFile(buildOut, ["BUILD-RAN"]);

        Contract.assert(ctx.runActions !== undefined,
            "kind: \"binary\" must receive ctx.runActions");
        // Run-time: copyFile(bBuild, ...) — the copy pip CONSUMES bBuild,
        // creating a real dependency edge from the run pip to the build
        // pip. This matters because BuildXL's tag-selection filter pulls
        // in transitive dependencies of the selected pip, mirroring
        // `bazel run` (which builds the binary as part of "run").
        const runOut = ctx.runActions.declareOutput("run.txt");
        const bRun = ctx.runActions.copyFile(bBuild, runOut);

        return {
            kind: "DefaultInfo",
            files: [bBuild],                           // build-time only
            binaryInfo: Rules.binaryInfo({
                name: ctx.args.name,
                binary: bBuild,
                runScript: bRun,                       // run-time, deferred
            }),
        };
    },
    resolve: (a, _r) => a,
    toolchain: noopToolchain,
});

// Single top-level value — driver greps Out/Bin/ for build.txt / run.txt
// to determine which pips executed.
@@public
export const split = execBin({ name: "exec-split" });
