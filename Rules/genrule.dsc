// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import {Artifact, Cmd, Transformer} from "Sdk.Transformers";

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
 *       srcs: [f`schema.proto`],
 *       outs: [a`schema.pb.cs`],
 *       tool: {
 *           exe: f`tools/protoc`,
 *       },
 *       cmd: (ctx) => [
 *           Cmd.argument(Artifact.input(ctx.srcs[0])),
 *           Cmd.option("--csharp_out=", Artifact.output(ctx.outs[0])),
 *       ],
 *   });
 *
 *   // Use generated.getOutputFile(...)  or generated.outs[0] downstream.
 */

// ============================================================================
//  genrule
// ============================================================================

/**
 * Context passed to the `cmd` callback so callers can reference the
 * resolved input/output artifacts without constructing paths manually.
 */
@@public
export interface GenruleCmdContext {
    /** The source files in the same order as `GenruleArguments.srcs`. */
    srcs: File[];

    /** Output paths in the same order as `GenruleArguments.outs`. */
    outs: Path[];

    /** The output directory chosen for this rule. */
    outDir: Directory;
}

@@public
export interface GenruleArguments {
    /** Rule name — used to derive the output directory and for diagnostics. */
    name: string;

    /** Input files the command reads. */
    srcs?: File[];

    /** Output file names (atoms only — the directory is chosen automatically). */
    outs: PathAtom[];

    /** The tool to run. At minimum `{ exe: <file> }`. */
    tool: Transformer.ToolDefinition;

    /**
     * Build the command-line arguments.
     *
     * Receives a `GenruleCmdContext` so you can reference resolved input
     * and output artifacts without ever touching raw paths.
     *
     * Example:
     *   cmd: (ctx) => [
     *       Cmd.argument(Artifact.input(ctx.srcs[0])),
     *       Cmd.option("--out=", Artifact.output(ctx.outs[0])),
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

    /** The declared output files, in the same order as `outs`. */
    outs: DerivedFile[];

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
    const outPaths = args.outs.map(o => p`${outDir}/${o}`);

    const ctx: GenruleCmdContext = {
        srcs: args.srcs || [],
        outs: outPaths,
        outDir: outDir,
    };

    const executeResult = Transformer.execute({
        tool: args.tool,
        arguments: args.cmd(ctx),
        workingDirectory: d`${outDir}`,
        dependencies: [
            ...(args.srcs || []),
            ...(args.deps || []),
        ],
        implicitOutputs: outPaths,
        environmentVariables: args.env,
        successExitCodes: args.successExitCodes,
        tags: args.tags,
        description: args.description || `genrule: ${args.name}`,
    });

    const outs = outPaths.map(o => executeResult.getOutputFile(o));

    return {
        executeResult: executeResult,
        outs: outs,
        defaultInfo: defaultInfo({ files: outs }),
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
    srcs: File[];
}

@@public
export interface FilegroupResult {
    /** The grouped files. */
    srcs: File[];

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
        defaultInfo: defaultInfo({ files: args.srcs }),
    };
}

// ============================================================================
//  copy_file / copy_files
// ============================================================================

@@public
export interface CopyFileArguments {
    name: string;
    src: File;
    /** Output file name (atom). If omitted, the source file name is used. */
    out?: PathAtom;
}

/**
 * Copy a single file to the output directory.
 */
@@public
export function copy_file(args: CopyFileArguments): DerivedFile {
    const outDir = Context.getNewOutputDirectory(args.name);
    const outAtom = args.out || args.src.name;
    return Transformer.copyFile(args.src, p`${outDir}/${outAtom}`);
}

@@public
export interface CopyFilesArguments {
    name: string;
    srcs: File[];
}

/**
 * Copy a set of files to a shared output directory, preserving file names.
 */
@@public
export function copy_files(args: CopyFilesArguments): DerivedFile[] {
    const outDir = Context.getNewOutputDirectory(args.name);
    return args.srcs.map(src => Transformer.copyFile(src, p`${outDir}/${src.name}`));
}
