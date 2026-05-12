// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import {Artifact as Tx, Cmd, Transformer} from "Sdk.Transformers";

/**
 * genrule — run an arbitrary command and capture its declared outputs.
 *
 * Modelled after Bazel's `genrule`.  The caller names the rule, provides
 * source inputs, declares output file names (just atoms — the SDK picks
 * the output directory), and supplies the command line.
 *
 * Usage:
 *   import * as Rules from "Sdk.Rules";
 *   import {Artifact, Cmd} from "Sdk.Transformers";
 *
 *   const generated = Rules.genrule({
 *       name: "codegen",
 *       srcs: [Rules.sourceArtifact(f`schema.proto`)],
 *       outs: [a`schema.pb.cs`],
 *       tool: {
 *           exe: f`tools/protoc`,
 *       },
 *       cmd: (ctx) => [
 *           Cmd.argument(Artifact.input(Rules.getFile(ctx.srcs[0]))),
 *           Cmd.option("--csharp_out=", Artifact.output(ctx.outs[0].artifact.path)),
 *       ],
 *   });
 *
 *   // Use generated.outs[0] (a bound Artifact) downstream.
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
    const declaredOuts = args.outs.map(name => declareArtifact(outDir, name.toString()));

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
        defaultInfo: defaultInfo({ files: boundOuts.map(a => getFile(a)) }),
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
        defaultInfo: defaultInfo({ files: args.srcs.map(s => s.file) }),
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
 */
@@public
export function copy_files(args: CopyFilesArguments): Artifact[] {
    const outDir = Context.getNewOutputDirectory(args.name);
    return args.srcs.map(src => {
        const declared = declareArtifact(outDir, src.path.name.toString());
        const sourceFile = getFile(src);
        const f = Transformer.copyFile(sourceFile, declared.path);
        // SAFETY: see copy_file above.
        return bindArtifact(declared, <DerivedFile>f);
    });
}

