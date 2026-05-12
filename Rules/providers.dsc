// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Core rules-engine primitives modelled after Bazel's provider/depset system.
 *
 * These abstractions let rule authors define structured outputs (providers)
 * and efficiently accumulate transitive dependencies (depsets) without
 * manual path bookkeeping.
 */

import {Artifact as Tx, Cmd, Transformer} from "Sdk.Transformers";

// ============================================================================
//  Provider — base interface for all rule outputs
// ============================================================================

/**
 * Base interface for all rule output providers.
 *
 * Every rule returns one or more interfaces that extend `Provider`.
 * The `kind` discriminator enables runtime dispatch when a function
 * receives a heterogeneous collection of providers.
 *
 * Visibility mapping (for Bazel authors):
 *   @@public export  = visibility = ["//visibility:public"]
 *   export (no @@public) = package-visible
 *   bare const/function  = file-private
 */
@@public
export interface Provider {
    /** Discriminator tag for runtime type dispatch. */
    kind: string;
}

// ============================================================================
//  DefaultInfo — the universal provider every rule should return
// ============================================================================

/**
 * The standard output descriptor for any rule, analogous to Bazel's
 * built-in `DefaultInfo`.
 *
 * Rules return this so that generic infrastructure (test runners,
 * deployment, IDE integration) can consume outputs without knowing
 * the specific rule type.
 */
@@public
export interface DefaultInfo extends Provider {
    /** The default output files of the rule. */
    files: File[];

    /** Files needed at runtime (Bazel's "runfiles"). */
    runfiles?: File[];
}

/**
 * Convenience constructor for DefaultInfo.
 */
@@public
export function defaultInfo(args: {
    files: File[],
    runfiles?: File[],
}): DefaultInfo {
    return {
        kind: "DefaultInfo",
        files: args.files,
        runfiles: args.runfiles,
    };
}


// ============================================================================
//  Depset — transitive dependency accumulation
// ============================================================================

/**
 * Walk a provider graph and collect a transitive closure.
 *
 * Modelled after Bazel's `depset`.  Given a root provider and a function
 * that extracts its direct dependencies, returns a deduplicated flat list
 * of all transitively reachable providers (post-order: deps before root).
 *
 * Example:
 *   interface CsInfo extends Provider {
 *       assembly: File;
 *       deps: CsInfo[];
 *   }
 *
 *   const allDeps = depset(myLib, lib => lib.deps);
 *   // Returns all transitive CsInfo nodes, deduplicated.
 */
@@public
export function depset<T extends Provider>(root: T, getDeps: (item: T) => T[]): T[] {
    const seen = MutableSet.empty<T>();
    return collectTransitive(root, getDeps, seen);
}

/** Recursive post-order walker with deduplication. */
function collectTransitive<T extends Provider>(node: T, getDeps: (item: T) => T[], seen: MutableSet<T>): T[] {
    if (seen.contains(node)) {
        return [];
    }
    seen.add(node);

    let result: T[] = [];
    const deps = getDeps(node);
    for (let dep of deps) {
        result = [...result, ...collectTransitive(dep, getDeps, seen)];
    }
    // Post-order: deps before self.
    result = result.push(node);
    return result;
}

/**
 * Flatten multiple roots into a single deduplicated transitive closure.
 */
@@public
export function depsetAll<T extends Provider>(roots: T[], getDeps: (item: T) => T[]): T[] {
    const seen = MutableSet.empty<T>();
    let result: T[] = [];
    for (let root of roots) {
        result = [...result, ...collectTransitive(root, getDeps, seen)];
    }
    return result;
}


// ============================================================================
//  Toolchain — decouples rules from tool locations
// ============================================================================

/**
 * Base interface for toolchain providers.
 *
 * A toolchain encapsulates the tools needed by a family of rules
 * (e.g., the C# compiler, linker, runtime). Rules declare which
 * toolchain type they need; the workspace configuration provides
 * the concrete instance.
 *
 * Analogous to Bazel's `toolchain_type` + `toolchain()`.
 */
@@public
export interface Toolchain extends Provider {
    /** Human-readable name for log messages. */
    name: string;
}

// ============================================================================
//  Actions — type-safe action API (like Bazel's ctx.actions)
// ============================================================================

/**
 * Action helpers scoped to a rule target. Analogous to Bazel's
 * `ctx.actions` (and Buck2's `ctx.actions`).
 *
 * All output creation and process execution goes through this interface,
 * ensuring the framework controls output placement and tracking. The
 * interface speaks in `Artifact` / `OutputArtifact` (see Rules/artifact.dsc),
 * never `File` / `Path`, so rule authors cannot smuggle raw filesystem
 * paths into the build graph.
 */
@@public
export interface Actions {
    /**
     * Declare an output this rule will produce.
     * Analogous to `actions.declare_file("foo.dll")` in Bazel and
     * `ctx.actions.declare_output` in Buck2.
     *
     * The framework decides where the file goes — the rule author only
     * specifies the filename (and optional `subdir` for organisation).
     * The returned Artifact has `kind === "unbound"`; pass `Rules.asOutput(art)`
     * to one of the action methods below to bind it.
     */
    declareOutput(name: string, opts?: DeclareArtifactOpts): Artifact;

    /**
     * Execute a process, analogous to `actions.run()` in Bazel.
     *
     * `outputs` is a list of `OutputArtifact` binding handles obtained
     * via `Rules.asOutput(declaredArtifact)`; raw paths cannot be passed.
     *
     * Returns the bound Artifacts in the same order as `outputs`. Each
     * returned Artifact has `kind === "bound"` and a populated `boundFile`;
     * downstream rules should use these (not the unbound originals)
     * when wiring dependencies.
     */
    run(args: RunArgs): Artifact[];

    /**
     * Write a text file, analogous to `actions.write()` in Bazel.
     *
     * `output` must be an `OutputArtifact` from `Rules.asOutput`.
     * Returns the bound Artifact.
     */
    writeFile(output: OutputArtifact, lines: string[]): Artifact;

    /**
     * Copy an Artifact into a declared output location.
     *
     * `source` must be a bound Artifact (source or previously-produced).
     * `dest` must be an `OutputArtifact` from `Rules.asOutput`.
     * Returns the bound destination Artifact.
     */
    copyFile(source: Artifact, dest: OutputArtifact): Artifact;
}

/**
 * Arguments to `actions.run()`.
 *
 * `outputs` are `OutputArtifact[]` — single-use binding handles produced
 * by `Rules.asOutput(declaredArtifact)`. `dependencies` are `Artifact[]`
 * (source or bound); their underlying files are extracted via
 * `Rules.getFile`.
 */
@@public
export interface RunArgs {
    /** The executable to run. */
    tool: File;

    /** Command-line arguments. Use Cmd helpers for output references. */
    arguments: Argument[];

    /** Declared outputs this action will produce. */
    outputs: OutputArtifact[];

    /** Additional input dependencies (beyond those in arguments). */
    dependencies?: Artifact[];

    /** Environment variables. */
    environmentVariables?: {name: string, value: string}[];

    /** Description for build logs. */
    description?: string;

    /** Working directory. If omitted, uses the target's output directory. */
    workingDirectory?: Directory;
}

// ============================================================================
//  RuleContext — what an implementation function receives
// ============================================================================

/**
 * Context passed to a rule implementation function.
 *
 * Analogous to Bazel's `ctx` — provides access to resolved attributes,
 * the toolchain, and action helpers.
 *
 * TResolved is the post-resolution type: label fields have been
 * transformed to File[] before impl is called.
 */
@@public
export interface RuleContext<TResolved, TToolchain extends Toolchain> {
    /** The resolved rule attributes. Label fields are already File[]. */
    args: TResolved;

    /** The resolved toolchain instance. */
    toolchain: TToolchain;

    /** Action helpers for declaring outputs and running processes. */
    actions: Actions;
}

// ============================================================================
//  rule() — declarative rule factory
// ============================================================================

/**
 * Label resolver function, passed to the resolve callback by rule().
 * This is the only way to resolve labels — it's not exported publicly.
 *
 * Returns `SourceArtifact` (not raw `File`) so rule implementations
 * speak in Artifacts end-to-end. Use `Rules.getFile(art)` if you need
 * the underlying `File` (e.g. for a `Transformer.execute` call that
 * expects `File` rather than Artifact).
 */
@@public
export interface LabelResolver {
    /** Resolve a single label to a SourceArtifact. */
    resolve(label: Label): SourceArtifact;

    /** Resolve multiple labels to SourceArtifacts. */
    resolveAll(labels: Label[]): SourceArtifact[];
}

@@public
export interface RuleDefinition<TAttrs, TResolved, TToolchain extends Toolchain, TResult extends Provider> {
    /** The implementation function. Receives resolved context. */
    impl: (ctx: RuleContext<TResolved, TToolchain>) => TResult;

    /**
     * Resolve caller attrs to impl attrs.
     * Analogous to Bazel's attr declarations — maps label fields to files.
     * The resolver is provided by the framework — use it to resolve labels.
     */
    resolve: (attrs: TAttrs, resolver: LabelResolver) => TResolved;

    /** Documentation string. */
    doc?: string;

    /** The toolchain instance to use. */
    toolchain: TToolchain;
}

/**
 * Create a rule from a declaration.
 *
 * Returns a function that callers invoke with TAttrs (labels).
 * The framework creates a LabelResolver scoped to the caller's
 * directory, passes it to `resolve`, then calls `impl` with the
 * resolved attrs. Neither resolve nor impl can access the raw
 * resolveLabel function — it's fully encapsulated.
 */
@@public
export function rule<TAttrs extends { name: string }, TResolved, TToolchain extends Toolchain, TResult extends Provider>(
    defn: RuleDefinition<TAttrs, TResolved, TToolchain, TResult>
): (args: TAttrs) => TResult {
    return (args: TAttrs) => {
        const currentDir = d`${Context.getLastActiveUsePath().parent}`;
        const resolver: LabelResolver = {
            resolve: (label: Label) => sourceArtifact(resolveLabel(label, currentDir)),
            resolveAll: (labels: Label[]) => resolveLabels(labels, currentDir).map(f => sourceArtifact(f))
        };
        const resolved = defn.resolve(args, resolver);
        const actions = createActions(args.name);
        return defn.impl({ args: resolved, toolchain: defn.toolchain, actions: actions });
    };
}

// ============================================================================
//  Label — type-safe target references (like Bazel labels)
// ============================================================================

/**
 * A logical target reference, analogous to Bazel's label syntax.
 *
 * Label formats:
 *   "BasicTest.cs"                     — local file in current package
 *   ":BasicTest.cs"                    — explicit local file reference
 *   "//path/to/pkg:filename"           — workspace-relative file reference
 *
 * Resolution is purely mechanical — labels encode paths directly:
 *   "//artifacts/bin/System.Runtime/ref/Release/net11.0:System.Runtime.dll"
 *   → {workspace_root}/artifacts/bin/System.Runtime/ref/Release/net11.0/System.Runtime.dll
 *
 * Labels are strings, so File literals CANNOT be passed where Labels are
 * expected. This enforces that all file references go through the label
 * resolution system.
 */
@@public
export type Label = string;

// ============================================================================
//  Label resolution — purely mechanical, no registry needed
// ============================================================================

/**
 * Resolve a label to a File. Internal — only accessible via LabelResolver.
 */
function resolveLabel(label: Label, currentDir: Directory): File {
    const workspaceRoot = d`${Context.getMount("SourceRoot").path}`;

    // //path/to/pkg:filename — workspace-relative
    if (label.startsWith("//")) {
        const rest = label.slice(2);
        const colonIdx = rest.indexOf(":");
        if (colonIdx >= 0) {
            const pkg = rest.slice(0, colonIdx);
            const target = rest.slice(colonIdx + 1);
            return f`${workspaceRoot}/${pkg}/${target}`;
        }
        // //path/to/file (no colon — entire thing is a path)
        return f`${workspaceRoot}/${rest}`;
    }

    // :filename — local reference
    if (label.startsWith(":")) {
        const localName = label.slice(1);
        return f`${currentDir}/${localName}`;
    }

    // bare name — local file
    return f`${currentDir}/${label}`;
}

/**
 * Resolve multiple labels to Files. Internal — only accessible via LabelResolver.
 */
function resolveLabels(labels: Label[], currentDir: Directory): File[] {
    return labels.map(l => resolveLabel(l, currentDir));
}
// ============================================================================
//  select() — configuration-based dispatch
// ============================================================================

/**
 * Choose a value based on the current qualifier/configuration.
 *
 * Analogous to Bazel's `select()` macro.  Takes a map of condition keys
 * to values and a matcher function that tests whether a key matches the
 * current build configuration.
 *
 * Example:
 *   const runtime = select(
 *       [
 *           ["windows", [f`native_win.dll`]],
 *           ["linux",   [f`native_linux.so`]],
 *       ],
 *       (key) => qualifier.targetRuntime.indexOf(key) !== -1,
 *       []  // default
 *   );
 */
@@public
export function select<T>(conditions: [string, T][], matches: (key: string) => boolean, defaultValue: T): T {
    for (let entry of conditions) {
        if (matches(entry[0])) {
            return entry[1];
        }
    }
    return defaultValue;
}

// ============================================================================
//  createActions — internal factory for the Actions object
// ============================================================================

/**
 * Create an Actions instance scoped to a target name.
 *
 * All outputs are placed under a directory named after the target,
 * preventing collisions between targets. This is the implementation
 * backing `ctx.actions` in rule implementations.
 *
 * Output binding model: `declareOutput` returns an *unbound* Artifact;
 * `run` / `writeFile` / `copyFile` return *bound* Artifacts (carrying
 * the produced `DerivedFile`). Rule code passes the bound result
 * downstream when wiring deps.
 */
function createActions(targetName: string): Actions {
    const targetDir = Context.getNewOutputDirectory(targetName);

    return {
        declareOutput: (name: string, opts?: DeclareArtifactOpts): Artifact => {
            return declareArtifact(targetDir, name, opts);
        },

        run: (args: RunArgs): Artifact[] => {
            const outputArts = args.outputs.map(o => o.artifact);
            const outputPaths = outputArts.map(a => a.path);
            const workDir = args.workingDirectory || targetDir;

            const depFiles = args.dependencies !== undefined
                ? args.dependencies.map(a => getFile(a))
                : undefined;

            const execResult = Transformer.execute({
                tool: {
                    exe: args.tool,
                    dependsOnCurrentHostOSDirectories: true
                },
                arguments: args.arguments,
                workingDirectory: workDir,
                implicitOutputs: outputPaths,
                dependencies: depFiles,
                environmentVariables: args.environmentVariables !== undefined
                    ? args.environmentVariables.map(e => ({name: e.name, value: e.value}))
                    : undefined,
                description: args.description || targetName
            });

            return outputArts.map(a => bindArtifact(a, execResult.getOutputFile(a.path)));
        },

        writeFile: (output: OutputArtifact, lines: string[]): Artifact => {
            const f = Transformer.writeAllLines(output.artifact.path, lines);
            // SAFETY: BuildXL's Transformer.writeAllLines is typed `File` but in
            // practice always produces a DerivedFile (the pip output). DScript
            // casts are erased, so this cannot be runtime-validated; if BuildXL
            // ever returns a non-DerivedFile, downstream `getFile` will return
            // a File where a DerivedFile was expected.
            return bindArtifact(output.artifact, <DerivedFile>f);
        },

        copyFile: (source: Artifact, dest: OutputArtifact): Artifact => {
            const sourceFile = getFile(source);
            const f = Transformer.copyFile(sourceFile, dest.artifact.path);
            // SAFETY: same as writeFile above — Transformer.copyFile is typed
            // `File` but always produces a DerivedFile in practice.
            return bindArtifact(dest.artifact, <DerivedFile>f);
        }
    };
}
