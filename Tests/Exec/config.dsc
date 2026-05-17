// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Standalone workspace for the build-vs-run *execution* tests. Driven
 * by run-exec-tests.sh, which runs `bxl` (no /phase:Schedule) and then
 * inspects the filesystem under Out/Bin/ to verify which pips actually
 * ran.
 *
 * Kept separate from the main config.dsc because the regular test
 * suite stops at /phase:Schedule — the assertions there are pure
 * evaluation. The framework's deferral contract ("ctx.runActions
 * pips don't run under a plain `bxl`") can only be verified by
 * actually executing pips, which is what this workspace does.
 */

config({
    resolvers: [
        {
            kind: "DScript",
            modules: [
                f`../../Rules/module.config.dsc`,
                f`module.config.dsc`,
                f`${Environment.getPathValue("BUILDXL_BIN")}/Sdk/Sdk.Transformers/package.config.dsc`,
            ],
        },
    ],
    mounts: [
        {
            name: a`Out`,
            path: p`Out/Bin`,
            trackSourceFileChanges: true,
            isWritable: true,
            isReadable: true,
            isScrubbable: true,
        },
    ],
});
