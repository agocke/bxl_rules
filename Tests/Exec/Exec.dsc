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

const execBin = Rules.rule<ExecAttrs, ExecAttrs, Rules.Toolchain>({
    kind: "binary",
    impl: (ctx) => {
        const buildOut = ctx.actions.declareOutput("build.txt");
        const bBuild = ctx.actions.writeFile(buildOut, ["BUILD-RAN"]);

        Contract.assert(ctx.runActions !== undefined,
            "kind: \"binary\" must receive ctx.runActions");
        const runOut = ctx.runActions.declareOutput("run.txt");
        const bRun = ctx.runActions.copyFile(bBuild, runOut);

        return [
            Rules.defaultInfo({ files: [bBuild] }),
            Rules.binaryInfo({
                name: ctx.args.name,
                binary: bBuild,
                runScript: bRun,
            }),
        ];
    },
    resolve: (a, _r) => a,
    toolchain: noopToolchain,
});

// Single top-level value — driver greps Out/Bin/ for build.txt / run.txt
// to determine which pips executed.
@@public
export const split = execBin({ name: "exec-split" });
