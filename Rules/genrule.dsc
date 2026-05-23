// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import {Artifact as Tx, Cmd, Transformer} from "Sdk.Transformers";

// ============================================================================
//  native_test — run any executable as a test
// ============================================================================

/**
 * Arguments for `native_test`.
 *
 * Analogous to Bazel's `native_test` / `sh_test`: wraps an arbitrary
 * executable as a test target. The executable is invoked under
 * `timeout`, and the pip is auto-tagged `bxl-kind:test` by the
 * framework so `bxl /f:tag='bxl-kind:test'` selects it.
 */
@@public
export interface NativeTestArguments {
    /** Test name — used for output paths, diagnostics, and `TestInfo.name`. */
    name: string;

    /** The executable to run (source file or bound artifact from a prior action). */
    src: Artifact;

    /** Command-line arguments passed to the executable. */
    args?: Argument[];

    /**
     * Data files the test needs at runtime. Staged (copied) into the
     * test's output directory before running, ensuring co-location
     * with the test process. Equivalent to Bazel's `data` attribute
     * on test rules.
     */
    data?: Artifact[];

    /** Environment variables. */
    env?: {name: string, value: string}[];

    /** Working directory for the test process. */
    workingDirectory?: Directory;

    /**
     * Exit codes that indicate success. Default: `[0]`.
     *
     * CoreCLR standalone tests use exit code 100 for pass; set
     * `successExitCodes: [100]` for those.
     */
    successExitCodes?: number[];

    /** Wall-clock timeout in seconds. Default: 60. */
    timeoutSec?: number;

    /** T-shirt sizing — drives the default timeout when `timeoutSec` is not set. */
    size?: TestSize;

    /** Whether the test is known-flaky. */
    flaky?: boolean;

    /** User tags (e.g. `"manual"`, `"integration"`). */
    tags?: string[];
}

@@public
export interface NativeTestResult extends Provider {
    testInfo: TestInfo;
    defaultInfo: DefaultInfo;
}

/**
 * Run an arbitrary executable as a test.
 *
 * Equivalent to Bazel's `native_test`: wraps any executable (a compiled
 * binary, a shell script, corerun + DLL, etc.) as a test target with
 * `TestInfo`. The test runner pip is scheduled via `ctx.runActions`
 * (auto-tagged `bxl-kind:test`); `DefaultInfo.files` is empty so a
 * plain `bxl` build compiles but does not execute the test.
 *
 * Usage:
 *   const result = Rules.native_test({
 *       name: "my_test",
 *       src: Rules.sourceArtifact(f`test_binary`),
 *       successExitCodes: [0],
 *   });
 */
@@public
export function native_test(args: NativeTestArguments): NativeTestResult {
    const result = rule<NativeTestArguments, NativeTestArguments, Toolchain, NativeTestResult>({
        doc: `native_test: ${args.name}`,
        kind: "test",
        resolve: (attrs, _resolver) => attrs,
        impl: (ctx) => {
            const ti = scheduleTestRunner(ctx.args.name, testRunInfo({
                executable: ctx.args.src,
                successExitCodes: ctx.args.successExitCodes,
                env: ctx.args.env,
                deps: ctx.args.data,
                size: ctx.args.size,
                timeoutSec: ctx.args.timeoutSec,
                flaky: ctx.args.flaky,
                tags: ctx.args.tags,
            }), ctx.runActions);

            return {
                kind: "NativeTestResult",
                testInfo: ti,
                defaultInfo: defaultInfo({ files: [] }),
            };
        },
    })(args);

    return result;
}

/**
 * genrule — run an arbitrary command and capture its declared outputs.
 *
 * Modelled after Bazel's `genrule`.  The caller names the rule, provides
 * source inputs, declares output file names (just atoms — the SDK picks
 * the output directory), and supplies the command line.
 *
 * Usage:
 *   import * as Rules from "Sdk.Rules";
 *
 *   const generated = Rules.genrule({
 *       name: "codegen",
 *       srcs: [Rules.sourceArtifact(f`schema.proto`)],
 *       outs: [a`schema.pb.cs`],
 *       tool: {
 *           exe: f`tools/protoc`,
 *       },
 *       cmd: (ctx) => [
 *           Cmd.argument(Rules.cmdInput(ctx.srcs[0])),
 *           Cmd.option("--csharp_out=", Rules.cmdOutput(ctx.outs[0])),
 *       ],
 *   });
 *
 *   // Use generated.outs[0] (a bound Artifact) downstream.
 *
 * Single-binding within a single genrule call: `args.outs` must not
 * contain duplicate atoms — declaring the same output name twice would
 * produce two unbound Artifacts pointing at the same path, both passed
 * to BuildXL as implicit outputs of one pip. The SDK rejects this at
 * call time. Cross-target collisions still fall to BuildXL's
 * pip-graph layer.
 */

// ============================================================================
//  genrule
// ============================================================================

/**
 * Context passed to the `cmd` callback so callers can reference the
 * resolved input/output artifacts without constructing paths manually.
 *
 * `srcs` mirrors the SourceArtifacts supplied in `GenruleArguments.srcs`.
 * `outs` are the unbound declared Artifacts the SDK created for
 * `GenruleArguments.outs` — pass each one to `Rules.cmdOutput(...)` for
 * command-line use.
 */
@@public
export interface GenruleCmdContext {
    /** The source artifacts in the same order as `GenruleArguments.srcs`. */
    srcs: SourceArtifact[];

    /** Unbound output Artifacts in the same order as `GenruleArguments.outs`. */
    outs: Artifact[];

    /** The output directory chosen for this rule. */
    outDir: Directory;
}

@@public
export interface GenruleArguments {
    /** Rule name — used to derive the output directory and for diagnostics. */
    name: string;

    /** Input source files the command reads. */
    srcs?: SourceArtifact[];

    /** Output file names (atoms only — the directory is chosen automatically). */
    outs: PathAtom[];

    /** The tool to run. At minimum `{ exe: <file> }`. */
    tool: Transformer.ToolDefinition;

    /**
     * Build the command-line arguments.
     *
     * Receives a `GenruleCmdContext` so you can reference resolved input
     * and output artifacts without ever touching raw paths directly.
     *
     * Example:
     *   cmd: (ctx) => [
     *       Cmd.argument(Rules.cmdInput(ctx.srcs[0])),
     *       Cmd.option("--out=", Rules.cmdOutput(ctx.outs[0])),
     *   ]
     */
    cmd: (ctx: GenruleCmdContext) => Argument[];

    /** Additional input dependencies not listed in `srcs`. */
    deps?: Transformer.InputArtifact[];

    /** Extra output directories (opaque). */
    outDirs?: Directory[];

    /** Environment variables. */
    env?: Transformer.EnvironmentVariable[];

    /** Custom success exit codes. Default: [0]. */
    successExitCodes?: number[];

    /** Tags for filtering. */
    tags?: string[];

    /** Description shown in build logs. */
    description?: string;
}

@@public
export interface GenruleResult {
    /** The underlying Transformer.ExecuteResult for advanced use. */
    executeResult: Transformer.ExecuteResult;

    /** The bound output artifacts, in the same order as `outs`. */
    outs: Artifact[];

    /** Standard rule output info for composition with other rules. */
    defaultInfo: DefaultInfo;
}

/**
 * Run an arbitrary command and capture declared outputs.
 *
 * This is the BuildXL equivalent of Bazel's `genrule`.
 */
@@public
export function genrule(args: GenruleArguments): GenruleResult {
    const outDir = Context.getNewOutputDirectory(args.name);
    const srcs = args.srcs || [];

    const seenOuts = MutableSet.empty<string>();
    const declaredOuts = args.outs.map(name => {
        const k = name.toString();
        Contract.requires(!seenOuts.contains(k),
            `genrule "${args.name}": duplicate output "${k}" in outs[]; each declared output name must be unique within a single genrule call.`);
        seenOuts.add(k);
        return declareArtifact(outDir, k);
    });

    const ctx: GenruleCmdContext = {
        srcs: srcs,
        outs: declaredOuts,
        outDir: outDir,
    };

    const executeResult = Transformer.execute({
        tool: args.tool,
        arguments: args.cmd(ctx),
        workingDirectory: d`${outDir}`,
        dependencies: [
            ...srcs.map(s => s.file),
            ...(args.deps || []),
        ],
        implicitOutputs: declaredOuts.map(a => a.path),
        environmentVariables: args.env,
        successExitCodes: args.successExitCodes,
        tags: args.tags,
        description: args.description || `genrule: ${args.name}`,
    });

    const boundOuts = declaredOuts.map(a => bindArtifact(a, executeResult.getOutputFile(a.path)));

    return {
        executeResult: executeResult,
        outs: boundOuts,
        defaultInfo: defaultInfo({ files: boundOuts }),
    };
}

// ============================================================================
//  filegroup
// ============================================================================

@@public
export interface FilegroupArguments {
    /** Rule name — for diagnostics. */
    name: string;

    /** Files to include in the group. */
    srcs: SourceArtifact[];
}

@@public
export interface FilegroupResult {
    /** The grouped artifacts. */
    srcs: SourceArtifact[];

    /** Standard rule output info for composition with other rules. */
    defaultInfo: DefaultInfo;
}

/**
 * Group files under a logical name.
 *
 * Equivalent to Bazel's `filegroup`.  Provides a named handle that
 * other rules can depend on without knowing the individual paths.
 */
@@public
export function filegroup(args: FilegroupArguments): FilegroupResult {
    return {
        srcs: args.srcs,
        defaultInfo: defaultInfo({ files: args.srcs.map(s => <Artifact>s) }),
    };
}

// ============================================================================
//  copy_file / copy_files
// ============================================================================

@@public
export interface CopyFileArguments {
    name: string;
    src: Artifact;
    /** Output file name (atom). If omitted, the source file's leaf name is used. */
    out?: PathAtom;
}

/**
 * Copy a single Artifact to the output directory. Returns a bound
 * Artifact for downstream wiring.
 */
@@public
export function copy_file(args: CopyFileArguments): Artifact {
    const outDir = Context.getNewOutputDirectory(args.name);
    const outName = args.out !== undefined ? args.out.toString() : args.src.path.name.toString();
    const declared = declareArtifact(outDir, outName);
    const sourceFile = getFile(args.src);
    const f = Transformer.copyFile(sourceFile, declared.path);
    // SAFETY: Transformer.copyFile is typed `File` but always produces a
    // DerivedFile (the pip output). DScript casts are erased.
    return bindArtifact(declared, <DerivedFile>f);
}

@@public
export interface CopyFilesArguments {
    name: string;
    srcs: Artifact[];
}

/**
 * Copy a set of Artifacts to a shared output directory, preserving
 * their leaf names. Returns bound Artifacts.
 *
 * Two source paths with the same leaf name would collide on the same
 * destination path under the shared output directory; the SDK rejects
 * this at call time. If you need to copy two sources whose leaf names
 * collide, use `copy_file` separately (with explicit `out` atoms) or
 * split them into two `copy_files` calls with different `name`s.
 */
@@public
export function copy_files(args: CopyFilesArguments): Artifact[] {
    const outDir = Context.getNewOutputDirectory(args.name);
    const seenLeaves = MutableSet.empty<string>();
    return args.srcs.map(src => {
        const leafName = src.path.name.toString();
        Contract.requires(!seenLeaves.contains(leafName),
            `copy_files "${args.name}": two sources share the leaf name "${leafName}"; copies under a shared output directory must have unique leaf names. Use copy_file with explicit out atoms or split into multiple copy_files calls.`);
        seenLeaves.add(leafName);
        const declared = declareArtifact(outDir, leafName);
        const sourceFile = getFile(src);
        const f = Transformer.copyFile(sourceFile, declared.path);
        // SAFETY: see copy_file above.
        return bindArtifact(declared, <DerivedFile>f);
    });
}
