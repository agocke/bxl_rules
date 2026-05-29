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
    /** The default output artifacts of the rule. */
    files: Artifact[];

    /** Artifacts needed at runtime (Bazel's "runfiles"). */
    runfiles?: Artifact[];
}

/**
 * Convenience constructor for DefaultInfo.
 */
@@public
export function defaultInfo(args: {
    files: Artifact[],
    runfiles?: Artifact[],
}): DefaultInfo {
    return {
        kind: "DefaultInfo",
        files: args.files,
        runfiles: args.runfiles,
    };
}

// ============================================================================
//  ExecutableInfo — an executable bundled with its runtime closure
// ============================================================================

/**
 * Pairs an executable Artifact with the additional files/directories it
 * needs at *runtime* (sibling shared libs the loader probes for, SDK
 * subtrees the app shells out to, etc.).
 *
 * Inspired by Bazel's executable-tool conventions, but structurally a
 * merger of two Bazel concepts rather than a 1:1 mirror of either:
 *
 *   - `FilesToRunProvider.executable` — the binary File. (Bazel's
 *     FilesToRunProvider also carries `runfiles_manifest` /
 *     `repo_mapping_manifest`; we don't model those.)
 *   - `DefaultInfo.default_runfiles.files` — the runfiles closure.
 *
 * Bazel keeps these on separate sister providers attached to the same
 * Target, and `ctx.actions.run(executable = …)` auto-stages the matching
 * runfiles via that target identity. We don't have a Target abstraction
 * (toolchains carry tool references, not addressable targets), so the
 * effect — "an executable plus the files it needs at runtime" — is
 * captured in a single record.
 *
 * `Actions.run` accepts `tool: Artifact | ExecutableInfo`. When given an
 * `ExecutableInfo`, the adapter unpacks `executable` for the process
 * binary and merges `runfiles` into the pip's input dependencies.
 *
 * Typical use: toolchain providers store their tools as `ExecutableInfo`
 * so that any runtime probing (e.g. the .NET apphost looking for
 * `<dotnet-dir>/host/fxr/<ver>/libhostfxr.so` sibling files) is satisfied
 * automatically wherever the tool is invoked.
 */
@@public
export interface ExecutableInfo extends Provider {
    /** The executable to invoke. */
    executable: Artifact;

    /** Sibling files / sealed directories required at runtime. */
    runfiles?: Artifact[];
}

/**
 * Convenience constructor for ExecutableInfo.
 */
@@public
export function executableInfo(args: {
    executable: Artifact,
    runfiles?: Artifact[],
}): ExecutableInfo {
    return {
        kind: "ExecutableInfo",
        executable: args.executable,
        runfiles: args.runfiles,
    };
}

/**
 * Normalise a tool reference to a `ExecutableInfo`. A bare `Artifact` is
 * treated as `{ executable: tool, runfiles: [] }`; an existing
 * `ExecutableInfo` is returned unchanged.
 */
function asExecutableInfo(tool: Artifact | ExecutableInfo): ExecutableInfo {
    // Discriminate on the Provider `kind` tag.
    if ((tool as ExecutableInfo).kind === "ExecutableInfo") {
        return tool as ExecutableInfo;
    }
    return { kind: "ExecutableInfo", executable: tool as Artifact, runfiles: undefined };
}

/**
 * Flatten a `ExecutableInfo` into an `Artifact[]` suitable for use as
 * `RunArgs.dependencies`. Returns `[executable, ...runfiles]`.
 *
 * Use this when an action uses a different tool (e.g. `/bin/sh`) but
 * still needs the bundled executable and its runtime closure staged as
 * inputs — e.g., a shim script that shells out to the dotnet host.
 */
@@public
export function executableDeps(info: ExecutableInfo): Artifact[] {
    const rf = info.runfiles || [];
    return [info.executable, ...rf];
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
//  Target — multi-provider rule result (like Bazel's provider list)
// ============================================================================

/**
 * A `Target` is the result of evaluating a rule — a map from provider
 * `kind` tags to provider instances, analogous to Bazel's provider list.
 *
 * In Bazel, a rule's `implementation` function returns a list of
 * providers (`[DefaultInfo(...), CcInfo(...), ...]`), and consumers
 * query by provider key (`dep[CcInfo]`).  Here, `Target` is a
 * `Map<string, Provider>` keyed by the `kind` discriminator, and
 * consumers query with `getProvider(target, "CcInfo")`.
 */
@@public
export type Target = Map<string, Provider>;

/**
 * Construct a `Target` from an array of providers.
 *
 * Each provider's `kind` becomes its key in the map.  Duplicate kinds
 * are rejected at construction time.
 *
 * Example:
 *   return Rules.target([
 *       { kind: "DefaultInfo", files: [out] },
 *       { kind: "CSharpCompileInfo", refs: [...] },
 *   ]);
 */
@@public
export function target(providers: Provider[]): Target {
    let m = Map.empty<string, Provider>();
    for (const p of providers) {
        Contract.requires(!m.containsKey(p.kind),
            `Duplicate provider kind "${p.kind}" in target; each provider must have a unique kind.`);
        m = m.add(p.kind, p);
    }
    return m;
}

/**
 * Extract a provider from a `Target` by its `kind` tag.
 *
 * Analogous to Bazel's `dep[ProviderKey]`.  Returns `undefined` if the
 * target does not carry a provider with the requested kind.
 *
 *     const compile = Rules.getProvider<DotnetAssemblyCompileInfo>(
 *         dep, "DotnetAssemblyCompileInfo");
 */
@@public
export function getProvider<T extends Provider>(t: Target, kind: string): T {
    return <T>t.get(kind);
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
 * interface speaks in `Artifact` (see Rules/artifact.dsc), never
 * `File` / `Path`, so rule authors cannot smuggle raw filesystem paths
 * into the build graph.
 *
 * Single-binding enforcement
 * --------------------------
 * The Actions adapter holds a per-target set of already-claimed output
 * paths. The first action method (`run` / `writeFile` / `copyFile`) that
 * names a given Artifact as an output claims it; a second claim — by
 * any method, in the same target — throws `Contract.fail` immediately
 * with the colliding path in the message. Cross-target double-binding
 * (two rules writing to the same path) is still BuildXL's job to catch
 * at pip-graph construction time.
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
     * The returned Artifact has `kind === "unbound"`; pass it to one of
     * the action methods below to bind it. The returned Artifact is the
     * only legal input to an `outputs:` slot.
     */
    declareOutput(name: string, opts?: DeclareArtifactOpts): Artifact;

    /**
     * Execute a process, analogous to `actions.run()` in Bazel.
     *
     * Each Artifact in `outputs` must have `kind === "unbound"` (i.e.
     * a freshly declared output that has not yet been claimed by any
     * action in this target). Reusing the same output across two action
     * calls — or naming it twice in the same `outputs:` list — throws.
     *
     * Returns the bound Artifacts in the same order as `outputs`. Each
     * returned Artifact has `kind === "bound"` and a populated
     * `boundFile`; downstream rules should use these (not the unbound
     * originals, which stay stale) when wiring dependencies.
     */
    run(args: RunArgs): Artifact[];

    /**
     * Write a text file, analogous to `actions.write()` in Bazel.
     *
     * `output` must be a freshly declared, unclaimed Artifact (same
     * rules as `run.outputs`). Returns the bound Artifact.
     */
    writeFile(output: Artifact, lines: string[]): Artifact;

    /**
     * Copy an Artifact into a declared output location.
     *
     * `source` must be a bound Artifact (source or previously-produced).
     * `dest` must be a freshly declared, unclaimed Artifact (same rules
     * as `run.outputs`). Returns the bound destination Artifact.
     */
    copyFile(source: Artifact, dest: Artifact): Artifact;
}

/**
 * An environment variable to set for `actions.run()`.
 *
 * Values may be plain strings or DScript path types. Path-typed values
 * are forwarded directly to `Transformer.execute`, which lets BuildXL
 * track and remap them across machines.
 */
@@public
export interface EnvironmentVariable {
    name: string;
    value: string | Path | Directory | File;
}

/**
 * Arguments to `actions.run()`.
 *
 * `outputs` are unbound `Artifact`s produced by `declareOutput`. Each
 * is claimed by the call and converted to a bound Artifact in the
 * returned array (same order). `dependencies` are `Artifact[]` (source
 * or bound); their underlying files are extracted via `Rules.getFile`.
 */
@@public
export interface RunArgs {
    /**
     * The executable to run.
     *
     * - A bare `Artifact` — typically a `SourceArtifact` (toolchain-
     *   provided tool) or a bound output of an earlier action
     *   (a freshly-built tool). Treated as having no extra runfiles.
     * - An `ExecutableInfo` — bundles the executable with sibling files
     *   and sealed directories that must be staged alongside it at
     *   runtime. The adapter merges those runfiles into the pip's input
     *   dependencies automatically (mirrors the effect of passing a
     *   Bazel `FilesToRunProvider` to `ctx.actions.run(executable = …)`).
     *
     * The adapter extracts the underlying `File` from the executable
     * via `getFile()` before handing it to `Transformer.execute`.
     */
    tool: Artifact | ExecutableInfo;

    /** Command-line arguments. Use Cmd helpers for output references. */
    arguments: Argument[];

    /** Declared outputs this action will produce. Each must be unbound. */
    outputs: Artifact[];

    /** Additional input dependencies (beyond those in arguments). */
    dependencies?: Artifact[];

    /**
     * Environment variables.
     *
     * Values may be plain strings or DScript path types (`Directory`,
     * `Path`, `File`).  Path-typed values are forwarded to
     * `Transformer.execute` as-is, so BuildXL can track them and
     * remap them across machines when caching is enabled.
     */
    environmentVariables?: EnvironmentVariable[];

    /** Description for build logs. */
    description?: string;

    /** Working directory. If omitted, uses the target's output directory. */
    workingDirectory?: Directory;

    /**
     * Sandbox relaxation options forwarded to `Transformer.execute`'s
     * `unsafe` bag.
     *
     * Use sparingly — these weaken BuildXL's sandboxing guarantees.
     * The primary use case is enabling shared compilation (compiler
     * server), which requires breaking the compiler service process
     * out of the sandbox and trusting statically declared accesses.
     */
    sandboxRelaxation?: SandboxRelaxation;
}

/**
 * Subset of `Transformer.ExecuteArguments.unsafe` sandbox options
 * that `actions.run` is willing to forward.
 */
@@public
export interface SandboxRelaxation {
    /**
     * Process names that will break away from the sandbox when
     * spawned by the main process. Accesses of breakaway processes
     * are not observed; they can outlive the pip.
     */
    childProcessesToBreakawayFromSandbox?: PathAtom[];

    /**
     * When true, all statically declared inputs and outputs are
     * added to the sandbox access report as if the process actually
     * accessed them. Compensates for unobserved accesses from
     * breakaway children. Only effective when
     * `childProcessesToBreakawayFromSandbox` is non-empty.
     */
    trustStaticallyDeclaredAccesses?: boolean;
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
 * `TResolved` is the post-resolution type: label fields have been
 * transformed by `defn.resolve` before `impl` is called. Labels become
 * `SourceArtifact[]` (via `LabelResolver.resolveAll`) — never raw
 * `File[]` — so rule implementations speak in Artifacts end-to-end.
 */
@@public
export interface RuleContext<TResolved, TToolchain extends Toolchain> {
    /**
     * The resolved rule attributes. Label fields are `SourceArtifact[]`
     * (or `SourceArtifact` for single-label fields) after `defn.resolve`
     * has been applied.
     */
    args: TResolved;

    /**
     * The resolved toolchain instance.
     * Undefined when the rule definition omits the toolchain.
     */
    toolchain?: TToolchain;

    /**
     * Action helpers for build-time outputs. Everything scheduled here
     * is what `bxl` (a `bazel build //...` analog) materialises — the
     * compiled assembly, generated headers, etc. Put the resulting
     * Artifacts in `DefaultInfo.files`.
     *
     * Build-time pips are intentionally untagged regardless of kind,
     * so a plain `bxl` build picks them up uniformly. Run-time pips
     * (binary runfiles staging, test-runner invocation) live on the
     * separate `runActions` adapter below.
     */
    actions: Actions;

    /**
     * Action helpers for run-time outputs — present **only** for
     * `kind: "binary"` and `kind: "test"`. Everything scheduled here
     * is what a `bazel run` / `bazel test`-style selection
     * materialises: for binaries, the invocation shim and runfiles
     * tree staging; for tests, the runner pip that produces stamp +
     * runat (plus any test-data staging). Pips scheduled through this
     * adapter are automatically tagged with the matching `bxl-kind:*`
     * value (`bxl-kind:binary` or `bxl-kind:test`).
     *
     * Crucially, the Artifacts produced here must **not** appear in
     * `DefaultInfo.files`. They should be exposed only via the
     * per-kind provider (`BinaryInfo.runScript`, `TestInfo.stamp`,
     * `TestInfo.runat`). A plain `bxl` build then skips run-time work
     * entirely; `bxl /f:tag='bxl-kind:binary'` or
     * `bxl /f:tag='bxl-kind:test'` (or anything that references the
     * run-time Artifacts directly) pulls them in along with the
     * build-time outputs they depend on.
     *
     * Shares the target's output directory and single-binding claim
     * set with `ctx.actions`, so the same path cannot be claimed
     * twice across the two adapters.
     */
    runActions?: Actions;
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
    /**
     * Resolve a single label to an Artifact.
     *
     * String labels are resolved to `SourceArtifact` against the
     * workspace, current directory, or external package map. An
     * `Artifact` value passed as the label is returned as-is, allowing
     * generated outputs from other actions to flow through.
     */
    resolve(label: Label): Artifact;

    /** Resolve multiple labels to Artifacts. See `resolve` for semantics. */
    resolveAll(labels: Label[]): Artifact[];
}

@@public
export interface RuleDefinition<TAttrs, TResolved, TToolchain extends Toolchain> {
    /**
     * The implementation function. Receives resolved context, returns
     * an array of providers (like Bazel's `return [DefaultInfo(...), ...]`).
     * The framework wraps the array into a `Target` map.
     */
    impl: (ctx: RuleContext<TResolved, TToolchain>) => Provider[];

    /**
     * Resolve caller attrs to impl attrs.
     * Analogous to Bazel's attr declarations — maps label fields to files.
     * The resolver is provided by the framework — use it to resolve labels.
     */
    resolve: (attrs: TAttrs, resolver: LabelResolver) => TResolved;

    /** Documentation string. */
    doc?: string;

    /**
     * The toolchain instance to use. Optional — omit for rules that
     * don't need external tools (e.g. write_file, copy_file).
     * When omitted, `ctx.toolchain` receives a default no-op Toolchain.
     */
    toolchain?: TToolchain;

    /**
     * External packages available for `@pkg//path:file` label resolution.
     *
     * Keys are package names (e.g. "DotNetSdk", "xunit.core"); values
     * are StaticDirectory contents from Download or NuGet resolvers.
     * Labels starting with `@` are resolved against this map.
     */
    externalPackages?: Map<string, StaticDirectory>;

    /**
     * Rule kind — drives framework behaviour, not exposed to callers.
     *
     *   "library" (default) — no kind tag; the catch-all. Bazel has no
     *                         `bazel build`-equivalent kind verb because
     *                         `bazel build` operates on every kind's
     *                         default outputs uniformly; `bxl` works the
     *                         same way.
     *   "binary"            — every pip the impl schedules is tagged
     *                         with the framework-owned `bxl-kind:binary`,
     *                         so `bxl /f:tag='bxl-kind:binary'` selects
     *                         the runnable executables (Bazel `bazel run`
     *                         target-selection analog — selects, not yet
     *                         executes).
     *   "test"              — every pip the impl schedules is tagged
     *                         with `bxl-kind:test`, so
     *                         `bxl /f:tag='bxl-kind:test'` picks it up
     *                         (Bazel `bazel test //...` analog).
     *
     * The tag string itself is an SDK implementation detail (see
     * `kindTagFor` in kinds.dsc); rule authors declare kind once here
     * and the Actions adapter handles tagging.
     *
     * Limitation (vs. Bazel): the Bazel `build` vs `run` split exists
     * partly to defer runfiles staging until `run` is asked for. We do
     * not yet model that. Today `BinaryInfo.runScript` is a regular
     * Artifact, and binary rule authors typically include it in
     * `DefaultInfo.files`, so a plain build already materialises
     * runfiles. A future change would split a binary's outputs into a
     * "build" set (just the executable) and a "run" set (shim +
     * runfiles tree) and have the framework schedule the latter only
     * when the binary kind is selected.
     */
    kind?: RuleKind;
}

/**
 * Create a rule from a declaration.
 *
 * Returns a function that callers invoke with TAttrs (labels).
 * The framework creates a LabelResolver scoped to the caller's
 * directory, passes it to `resolve`, then calls `impl` with the
 * resolved attrs. Neither resolve nor impl can access the raw
 * resolveLabel function — it's fully encapsulated.
 *
 * The impl returns `Provider[]` (like Bazel), and the framework
 * wraps it into a `Target` map keyed by provider `kind`.
 *
 * If `externalPackages` is provided in the definition, labels of
 * the form `@pkg//path:file` are resolved against the corresponding
 * StaticDirectory via `assertExistence`.
 */
@@public
export function rule<TAttrs extends { name: string }, TResolved, TToolchain extends Toolchain>(
    defn: RuleDefinition<TAttrs, TResolved, TToolchain>
): (args: TAttrs) => Target {
    return (args: TAttrs) => {
        const currentDir = d`${Context.getLastActiveUsePath().parent}`;
        const extPkgs = defn.externalPackages || Map.empty<string, StaticDirectory>();
        const resolver: LabelResolver = {
            resolve: (label: Label) => resolveLabel(label, currentDir, extPkgs),
            resolveAll: (labels: Label[]) => resolveLabels(labels, currentDir, extPkgs)
        };
        const resolved = defn.resolve(args, resolver);
        const rt = createActionsForRule(args.name, defn.kind);
        const providers = defn.impl({
            args: resolved,
            toolchain: defn.toolchain,
            actions: rt.actions,
            runActions: rt.runActions,
        });
        return target(providers);
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
 *   "@pkg//dir:file"                   — external package reference
 *   <Artifact>                         — generated output, passed through
 *
 * Cross-package file references (`"//path/to/pkg:file"`) are not
 * supported. To share source files across packages, declare a
 * `filegroup` in the owning package and pass its resolved artifacts
 * to downstream rules.
 *
 * An `Artifact` (e.g. the result of `sourceArtifact(file)` or an
 * unbound output handle) may also be used directly. The framework
 * passes it through without re-wrapping, so generated outputs from
 * other actions can flow through `srcs`/`refs`/etc. like a Bazel
 * `srcs = [":generated_target"]`.
 */
@@public
export type Label = string | Artifact;

// ============================================================================
//  Label resolution — purely mechanical, no registry needed
// ============================================================================

/**
 * Resolve a label to an Artifact. Internal — only accessible via LabelResolver.
 *
 * Supports four label forms:
 *   <Artifact>             — pass-through (generated outputs)
 *   "@pkg//dir:file"       — external package (StaticDirectory.assertExistence)
 *   ":file"                — current-directory-relative
 *   "file"                 — bare name (current directory)
 *
 * Workspace-relative labels ("//pkg:file") are rejected — use a
 * filegroup in the owning package instead.
 */
function resolveLabel(label: Label, currentDir: Directory, externalPkgs: Map<string, StaticDirectory>): Artifact {
    // Artifact pass-through (generated outputs from other actions, or
    // pre-wrapped source artifacts).
    if (typeof label !== "string") {
        return label as Artifact;
    }

    const labelStr = label as string;
    const workspaceRoot = d`${Context.getMount("SourceRoot").path}`;

    // @pkg//path:file — external package reference
    if (labelStr.startsWith("@")) {
        const slashIdx = labelStr.indexOf("//");
        Contract.requires(slashIdx > 1,
            `Invalid external label '${labelStr}': expected '@pkg//path:file' format`);
        const pkgName = labelStr.slice(1, slashIdx);
        const rest = labelStr.slice(slashIdx + 2);
        const colonIdx = rest.indexOf(":");
        const dir = colonIdx >= 0 ? rest.slice(0, colonIdx) : "";
        const file = colonIdx >= 0 ? rest.slice(colonIdx + 1) : rest;
        Contract.requires(externalPkgs.containsKey(pkgName),
            `External package '${pkgName}' not registered in externalPackages`);
        const pkg = externalPkgs.get(pkgName);
        if (dir !== "") {
            return sourceArtifact(pkg.assertExistence(r`${dir}/${file}`));
        }
        return sourceArtifact(pkg.assertExistence(r`${file}`));
    }

    // //path/to/pkg:filename — workspace-relative: REJECTED.
    // Cross-package file references must go through a filegroup target
    // in the owning package, mirroring Bazel's package visibility model.
    if (labelStr.startsWith("//")) {
        Contract.fail(
            `Cross-package label '${labelStr}' is not allowed. ` +
            `Export the file via a filegroup in the owning package and ` +
            `reference the filegroup's artifacts instead.`);
    }

    // :filename — local reference
    if (labelStr.startsWith(":")) {
        const localName = labelStr.slice(1);
        return sourceArtifact(f`${currentDir}/${localName}`);
    }

    // bare name — local file
    return sourceArtifact(f`${currentDir}/${labelStr}`);
}

/**
 * Resolve multiple labels to Artifacts. Internal — only accessible via LabelResolver.
 */
function resolveLabels(labels: Label[], currentDir: Directory, externalPkgs: Map<string, StaticDirectory>): Artifact[] {
    return labels.map(l => resolveLabel(l, currentDir, externalPkgs));
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
 * Per-rule bundle returned by `createActionsForRule` — the build-time
 * Actions adapter plus, for binary and test kinds, a run-time Actions
 * adapter. `runActions` is `undefined` for library kind / unspecified.
 */
interface RuleActions {
    actions: Actions;
    runActions?: Actions;
}

/**
 * Build the per-rule Actions bundle for a `kind`. Centralises the
 * kind→tag mapping (via `kindTagFor` / `runTagFor`) so the rest
 * of providers.dsc never inspects `RuleKind` directly.
 *
 *   kind        | actions auto-tag | runActions
 *   ------------|------------------|-----------------------------
 *   "library"   | (none)           | (not provided)
 *   undefined   | (none)           | (not provided)
 *   "binary"    | (none)           | provided (auto-tag bxl-kind:binary)
 *   "test"      | (none)           | provided (auto-tag bxl-kind:test)
 *
 * For binary and test kinds the two adapters share a single output
 * directory and a single `claimedPaths` set, so an output path claimed
 * via `ctx.actions` cannot be re-claimed via `ctx.runActions` (or
 * vice versa).
 */
function createActionsForRule(targetName: string, kind?: RuleKind): RuleActions {
    const targetDir = Context.getNewOutputDirectory(targetName);
    const claimedPaths = MutableSet.empty<string>();

    const buildTag = kindTagFor(kind);
    const buildTags = buildTag !== undefined ? [buildTag] : undefined;
    const actions = createActions(targetName, targetDir, claimedPaths, buildTags);

    const runTag = runTagFor(kind);
    if (runTag !== undefined) {
        const runActions = createActions(targetName, targetDir, claimedPaths, [runTag]);
        return { actions: actions, runActions: runActions };
    }

    return { actions: actions };
}

/**
 * Create an Actions instance scoped to a target name.
 *
 * `targetDir` and `claimedPaths` are passed in (rather than allocated
 * here) so a single rule can have multiple Actions adapters — see
 * `createActionsForRule` above — that share the target's output
 * directory and the single-binding claim set, while differing in the
 * auto-applied pip tags.
 *
 * Output binding model: `declareOutput` returns an *unbound* Artifact;
 * `run` / `writeFile` / `copyFile` return *bound* Artifacts (carrying
 * the produced `DerivedFile`). Rule code passes the bound result
 * downstream when wiring deps.
 *
 * Not exported: spawning siblings would let callers attach an
 * arbitrary tag list to a rule's pips, bypassing the
 * kind-driven tagging that the build-vs-run filter contract relies
 * on. The sole entry point is `createActionsForRule`.
 */
function createActions(
    targetName: string,
    targetDir: Directory,
    claimedPaths: MutableSet<string>,
    autoTags?: string[]
): Actions {
    const claim = (a: Artifact, opName: string): Artifact => {
        Contract.requires(a !== undefined,
            `${opName}: output Artifact must not be undefined`);
        Contract.requires(a.kind === "unbound",
            `${opName}: output Artifact must be unbound (kind === "unbound"); got "${a.kind}". A SourceArtifact cannot be an output, and a bound Artifact has already been produced by a prior action — declare a fresh output with actions.declareOutput.`);
        const key = a.path.toDiagnosticString();
        Contract.requires(!claimedPaths.contains(key),
            `${opName}: output "${key}" has already been claimed by an earlier action in target "${targetName}". Each declared output may be produced by exactly one action.`);
        claimedPaths.add(key);
        return a;
    };

    return {
        declareOutput: (name: string, opts?: DeclareArtifactOpts): Artifact => {
            return declareArtifact(targetDir, name, opts);
        },

        run: (args: RunArgs): Artifact[] => {
            const outputArts = args.outputs.map(o => claim(o, "Actions.run"));
            const outputPaths = outputArts.map(a => a.path);
            const workDir = args.workingDirectory || targetDir;

            const toolInfo = asExecutableInfo(args.tool);
            const toolRunfiles: (File | StaticDirectory)[] = toolInfo.runfiles !== undefined
                ? toolInfo.runfiles.map(a => getInputArtifact(a))
                : [];
            const depFiles: (File | StaticDirectory)[] = args.dependencies !== undefined
                ? args.dependencies.map(a => getInputArtifact(a))
                : [];
            const allDeps: (File | StaticDirectory)[] = toolRunfiles
                .reduce((acc, d) => acc.concat([d]), depFiles);

            // When trustStaticallyDeclaredAccesses is set (shared compilation),
            // dependsOnCurrentHostOSDirectories must be false — the engine
            // creates sealed source directories that are incompatible with
            // trusted-access pips.
            const hasBreakaway = args.sandboxRelaxation !== undefined
                && args.sandboxRelaxation.childProcessesToBreakawayFromSandbox !== undefined
                && args.sandboxRelaxation.childProcessesToBreakawayFromSandbox.length > 0;

            const execResult = Transformer.execute({
                tool: {
                    exe: getFile(toolInfo.executable),
                    dependsOnCurrentHostOSDirectories: !hasBreakaway
                },
                arguments: args.arguments,
                workingDirectory: workDir,
                implicitOutputs: outputPaths,
                dependencies: allDeps.length > 0 ? allDeps : undefined,
                environmentVariables: args.environmentVariables !== undefined
                    ? args.environmentVariables.map(e => ({name: e.name, value: e.value}))
                    : undefined,
                unsafe: args.sandboxRelaxation,
                tags: autoTags,
                description: args.description || targetName
            });

            return outputArts.map(a => bindArtifact(a, execResult.getOutputFile(a.path)));
        },

        writeFile: (output: Artifact, lines: string[]): Artifact => {
            claim(output, "Actions.writeFile");
            const f = Transformer.writeAllLines(output.path, lines, autoTags);
            // SAFETY: BuildXL's Transformer.writeAllLines is typed `File` but in
            // practice always produces a DerivedFile (the pip output). DScript
            // casts are erased, so this cannot be runtime-validated; if BuildXL
            // ever returns a non-DerivedFile, downstream `getFile` will return
            // a File where a DerivedFile was expected.
            return bindArtifact(output, <DerivedFile>f);
        },

        copyFile: (source: Artifact, dest: Artifact): Artifact => {
            claim(dest, "Actions.copyFile");
            const sourceFile = getFile(source);
            const f = Transformer.copyFile(sourceFile, dest.path, autoTags);
            // SAFETY: same as writeFile above — Transformer.copyFile is typed
            // `File` but always produces a DerivedFile in practice.
            return bindArtifact(dest, <DerivedFile>f);
        }
    };
}
