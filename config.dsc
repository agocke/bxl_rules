// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Workspace `config.dsc` for running the bxl_rules test suite.
 *
 * Resolves three modules:
 *   - Sdk.Transformers   (shipped with bxl)        — needed transitively
 *   - Sdk.Rules          (this repo, Rules/)       — code under test
 *   - Sdk.Rules.Tests    (this repo, Tests/)       — assertions
 *
 * Run via `./run-tests.sh`, which sets BUILDXL_BIN to point at the bxl
 * dotnet-tool's deployment directory before invoking bxl.
 */

config({
    resolvers: [
        {
            kind: "DScript",
            modules: [
                f`Rules/module.config.dsc`,
                f`Tests/module.config.dsc`,
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
