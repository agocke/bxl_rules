// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

import {Artifact as Tx} from "Sdk.Transformers";

/**
 * Artifact model — the Buck2-shape replacement for `DeclaredOutput`.
 *
 * Background
 * ----------
 * Bazel's `ctx.actions.declare_file("foo.o")` returns a single `File`
 * value that is *immediately* a referenceable input but only becomes
 * "real" once some `ctx.actions.run(outputs=[that_file])` *binds* it.
 * There is no static distinction; if you forget to bind, you get a
 * confusing analysis-time error.
 *
 * Buck2 splits the type:
 *   - `Artifact`        — referenceable handle. May be unbound.
 *   - `OutputArtifact`  — binding handle obtained via `.as_output()`,
 *                         which is consumed by exactly one action.
 *
 * This file ports that split to DScript. Because DScript has no classes
 * and no method-on-interface syntax that captures `this`, the projection
 * is exposed as the free function `Rules.asOutput(art)` rather than as
 * an `Artifact.asOutput()` method.
 *
 * Type taxonomy
 * -------------
 *   Artifact         — base, branded. Carries `shortPath`, `extension`,
 *                      `kind` (one of "unbound" | "bound" | "source"),
 *                      and the underlying `Path`.
 *   SourceArtifact   — extends Artifact; wraps a workspace `File`. Has
 *                      `kind === "source"`. May not be passed to
 *                      `asOutput`.
 *   OutputArtifact   — binding handle; holds the `Artifact` it backs.
 *                      Carry semantics: feed to an action's `outputs`.
 *
 * Why a `kind` discriminator (not paired booleans)
 * ------------------------------------------------
 * Bound vs unbound is *value-level* state — a freshly declared output is
 * unbound; the value returned from `Actions.run` is the same logical
 * output but bound. DScript's checker does not yet narrow union types
 * based on a field's runtime value (the way TypeScript narrows a
 * discriminated union inside an `if (x.kind === "bound")` block), so
 * `getFile` / `bindArtifact` / `asOutput` continue to enforce
 * preconditions through `Contract.requires(...)` rather than via
 * static narrowing. The shape, however, is forward-compatible: the
 * day DScript narrows discriminated unions, redefining
 *
 *     type Artifact = UnboundArtifact | BoundArtifact | SourceArtifact;
 *
 * (where each variant pins `kind` to a single literal) becomes a
 * near-trivial change — the `kind` field is already the discriminant
 * the union would pivot on, and call sites already branch on it.
 *
 * Construction discipline
 * -----------------------
 *   - All three types are tagged-interface-branded, so a bare object
 *     literal cannot satisfy them; callers must go through the factories
 *     `declareArtifact`, `sourceArtifact`, and `asOutput`.
 *   - `path: Path` is exposed because the `Actions.run` adapter needs
 *     it to call `Transformer.execute({outputs: [...]})`, but rule
 *     authors must not stringify it — `path` is marked `@internal` and
 *     the command-line bridges (`cmdInput`/`cmdOutput`) are the only
 *     sanctioned way to reference an artifact on a tool invocation.
 */

// ============================================================================
//  Artifact — referenceable handle
// ============================================================================

/**
 * Discriminator for the three Artifact states.
 *
 *   "unbound" — declared output, no producing action registered yet.
 *   "bound"   — declared output with a registered producing action;
 *               `boundFile` is populated.
 *   "source"  — wraps an existing workspace `File`; the `SourceArtifact`
 *               narrows `kind` to this single literal.
 *
 * This is a string-literal union rather than a `boolean` pair so that
 * a future static discriminated-union refactor (UnboundArtifact |
 * BoundArtifact | SourceArtifact) is a near-trivial change — the
 * discriminant is already in place and call sites already pivot on it.
 */
@@public
export type ArtifactKind = "unbound" | "bound" | "source";

/**
 * A referenceable handle to a file or directory in the build graph.
 *
 * An `Artifact` is the unit rule code passes around when wiring inputs
 * and outputs. An Artifact is "bound" when a producing action has been
 * registered for it; source files are bound by definition.
 *
 * Always construct via `declareArtifact` or `sourceArtifact`; never via
 * an object literal (the `__artifactBrand` field is enforced).
 */
@@public
export interface Artifact {
    /** Tagged-interface brand. Do not set or read. */
    __artifactBrand: any;

    /**
     * User-visible logical name for diagnostics and command-line use.
     *
     * For declared outputs: the name passed to `declareArtifact`,
     * optionally prefixed by `subdir`. For source artifacts: the file's
     * leaf name.
     *
     * `shortPath` is *not* a filesystem path. Do not feed it to a tool
     * expecting an absolute or workspace-rooted path; use `path` (and
     * even then, only via the Cmd/Artifact helpers — never stringified).
     */
    shortPath: string;

    /** File extension including the dot (e.g. ".dll"); empty if none. */
    extension: string;

    /**
     * Discriminator: "unbound" | "bound" | "source".
     *
     *   - "unbound": freshly declared output; no producing action yet.
     *     `getFile` will reject; pass to `Actions.run` (via `asOutput`)
     *     to produce a bound version.
     *   - "bound":   declared output with a registered producing action.
     *     `boundFile` is populated; `getFile` returns it.
     *   - "source":  wraps a workspace source file. `SourceArtifact`
     *                narrows this field to the single literal "source".
     *
     * See `ArtifactKind` for the rationale behind a discriminator field
     * over the older paired-boolean (`isSource`/`isBound`) shape.
     */
    kind: ArtifactKind;

    /**
     * Underlying BuildXL `Path`. **@internal — SDK adapters only.**
     *
     * Used by `createActions.run`, `genrule`, `copy_file`, etc. to
     * populate `Transformer.execute({outputs:[...]})`. Rule
     * implementations must not read this field — instead use
     * `Rules.cmdInput(art)` and `Rules.cmdOutput(out)`, which wrap the
     * sanctioned `Sdk.Transformers.Artifact.input/output` boundary.
     *
     * Stringifying this Path before the producing action runs would
     * give you a path the file system cannot resolve; the helpers above
     * route through BuildXL's Cmd-line plumbing, which preserves the
     * "produced at execution time" invariant.
     */
    path: Path;

    /**
     * The bound `DerivedFile` once a producing action has been registered.
     * Always `undefined` immediately after `declareArtifact`. After
     * `Actions.run` returns, the SDK produces a *new* Artifact value
     * (via `bindArtifact`) carrying this field; the original unbound
     * Artifact remains as it was (DScript values are immutable).
     *
     * For `SourceArtifact`, the bound file is exposed via `.file`
     * (typed `File`) instead, since source files are not derived.
     */
    boundFile?: DerivedFile;
}

/**
 * An artifact that wraps an existing workspace source file.
 *
 * `SourceArtifact` extends `Artifact` with the bound `File` handle and
 * its own brand. `kind` is narrowed to the single literal `"source"`;
 * this is the only Artifact subtype whose binding state is statically
 * known at the type level.
 *
 * Always construct via `sourceArtifact(file)`.
 */
@@public
export interface SourceArtifact extends Artifact {
    /** Tagged-interface brand. Do not set or read. */
    __sourceArtifactBrand: any;

    /** Narrowed discriminator — always `"source"` for SourceArtifact. */
    kind: "source";

    /** The bound source `File` this artifact wraps. */
    file: File;
}

/**
 * A binding handle for an `Artifact`. Obtained via `Rules.asOutput(art)`
 * and consumed by exactly one action's `outputs` slot.
 *
 * Holding an `OutputArtifact` represents the *intent* to bind the
 * underlying `Artifact` to a producing action. The single-use semantics
 * (one action per Output) are runtime-enforced by the `Actions.run`
 * adapter.
 *
 * Always construct via `asOutput`; never via an object literal (the
 * `__outputArtifactBrand` field is enforced).
 */
@@public
export interface OutputArtifact {
    /** Tagged-interface brand. Do not set or read. */
    __outputArtifactBrand: any;

    /**
     * The `Artifact` this binding handle is backing.
     *
     * **@internal** — SDK adapters only. Rule code should pass the
     * `OutputArtifact` directly to `Actions.run`'s `outputs:` list (or
     * use `Rules.cmdOutput(out)` to reference it on a command line)
     * rather than reaching through `.artifact.path`.
     */
    artifact: Artifact;
}

// ============================================================================
//  Factories
// ============================================================================

/**
 * Options for `declareArtifact`.
 *
 * `subdir` places the output under a logical subdirectory of the rule's
 * output directory; it appears in `shortPath` (so command-line displays
 * are stable) and in the underlying `path`.
 *
 * Opaque/shared-opaque directories (a `dir?: boolean` flag) are not yet
 * supported here; they require a different underlying BuildXL primitive
 * (`Artifact.sharedOpaqueOutput`) and tighter integration with the
 * `Actions` API.
 */
@@public
export interface DeclareArtifactOpts {
    /** Optional logical subdirectory (e.g. "obj"). */
    subdir?: string;
}

/**
 * Declare a new (unbound) `Artifact` for a file the rule will produce.
 *
 * `targetDir` is normally the rule's output directory
 * (`Context.getNewOutputDirectory(targetName)` in the current Actions
 * impl). The returned Artifact has `kind === "unbound"` until a
 * producing action is registered (typically by `Actions.run`).
 */
@@public
export function declareArtifact(targetDir: Directory, name: string, opts?: DeclareArtifactOpts): Artifact {
    const subdir = opts !== undefined ? opts.subdir : undefined;
    const fullPath = subdir !== undefined
        ? p`${targetDir}/${subdir}/${name}`
        : p`${targetDir}/${name}`;
    const short = subdir !== undefined ? `${subdir}/${name}` : name;
    const ext = fullPath.hasExtension
        ? fullPath.extension.toString()
        : "";
    return <Artifact>{
        __artifactBrand: undefined,
        shortPath: short,
        extension: ext,
        kind: "unbound",
        path: fullPath,
        boundFile: undefined,
    };
}

/**
 * Wrap a workspace `File` as a `SourceArtifact`.
 *
 * Source files entering the framework via attribute resolution are
 * wrapped via this factory. Rule implementations should receive
 * `Artifact` (or `SourceArtifact`), never raw `File`.
 */
@@public
export function sourceArtifact(file: File): SourceArtifact {
    const fpath = file.path;
    const short = fpath.name.toString();
    const ext = fpath.hasExtension
        ? fpath.extension.toString()
        : "";
    return <SourceArtifact>{
        __artifactBrand: undefined,
        __sourceArtifactBrand: undefined,
        shortPath: short,
        extension: ext,
        kind: "source",
        path: fpath,
        boundFile: undefined,
        file: file,
    };
}

/**
 * Project an `Artifact` to an `OutputArtifact`, the binding handle that
 * an action's `outputs` slot consumes.
 *
 * Calling `asOutput` is purely a type-level projection: each call
 * returns a *fresh* `OutputArtifact` value; the underlying `Artifact`
 * is shared. The `Actions.run` adapter runtime-enforces the
 * single-binding rule by tracking which `OutputArtifact`s have been
 * consumed.
 *
 * `asOutput` rejects `SourceArtifact`s (a source file cannot be a
 * producing action's output).
 */
@@public
export function asOutput(art: Artifact): OutputArtifact {
    Contract.requires(art !== undefined, "asOutput: artifact must not be undefined");
    Contract.requires(art.kind !== "source",
        "asOutput: a SourceArtifact cannot be used as an action output");
    return <OutputArtifact>{
        __outputArtifactBrand: undefined,
        artifact: art,
    };
}

// ============================================================================
//  Equality
// ============================================================================

/**
 * True iff two Artifacts denote the same underlying path.
 *
 * Compares paths via reference equality first (BuildXL canonicalises
 * paths from the same source), falling back to diagnostic-string
 * comparison for paths constructed independently.
 *
 * Returns false if either argument is undefined.
 */
@@public
export function artifactsEqual(a: Artifact, b: Artifact): boolean {
    if (a === undefined || b === undefined) return false;
    if (a.path === b.path) return true;
    return a.path.toDiagnosticString() === b.path.toDiagnosticString();
}

/**
 * True iff two OutputArtifacts back the same underlying Artifact.
 *
 * Returns false if either argument is undefined.
 */
@@public
export function outputArtifactsEqual(a: OutputArtifact, b: OutputArtifact): boolean {
    if (a === undefined || b === undefined) return false;
    return artifactsEqual(a.artifact, b.artifact);
}

// ============================================================================
//  Binding — helpers used by the Actions adapter
// ============================================================================

/**
 * Produce a *new* Artifact with `kind === "bound"` and the supplied
 * bound file attached. The original `unbound` value is unmodified
 * (DScript values are immutable); callers should treat the result as
 * the new canonical handle.
 *
 * Intended use: `Actions.run` and friends call this once per declared
 * output after `Transformer.execute` returns the produced files. Most
 * rule code does not call `bindArtifact` directly.
 *
 * Asserts that `unbound.kind === "unbound"`; rebinding an already-bound
 * Artifact (or a source) is a programming error.
 */
@@public
export function bindArtifact(unbound: Artifact, file: DerivedFile): Artifact {
    Contract.requires(unbound !== undefined, "bindArtifact: artifact must not be undefined");
    Contract.requires(unbound.kind === "unbound",
        "bindArtifact: artifact must be unbound (kind === 'unbound'); sources are bound at construction and bound outputs cannot be rebound");
    Contract.requires(file !== undefined, "bindArtifact: file must not be undefined");
    return <Artifact>{
        __artifactBrand: undefined,
        shortPath: unbound.shortPath,
        extension: unbound.extension,
        kind: "bound",
        path: unbound.path,
        boundFile: file,
    };
}

/**
 * Extract the underlying `File` (or `DerivedFile`) for a *bound* Artifact.
 *
 * For `SourceArtifact` (`kind === "source"`), returns the wrapped
 * `.file`. For a bound derived Artifact (`kind === "bound"`), returns
 * `.boundFile`. Rejects `kind === "unbound"`.
 *
 * This is the bridge from Artifact-typed rule code into the underlying
 * BuildXL pip graph (e.g. when assembling `Transformer.execute`'s
 * `dependencies` from a list of Artifacts).
 */
@@public
export function getFile(art: Artifact): File {
    Contract.requires(art !== undefined, "getFile: artifact must not be undefined");
    Contract.requires(art.kind !== "unbound",
        "getFile: artifact is not bound (no producing action has been registered)");
    if (art.kind === "source") {
        return (<SourceArtifact>art).file;
    }
    Contract.requires(art.boundFile !== undefined,
        "getFile: bound artifact missing boundFile (binding invariant violated)");
    return art.boundFile;
}

// ============================================================================
//  Command-line bridges — sanctioned wrappers around the
//  Sdk.Transformers.Artifact.input/output boundary.
//
//  Rule code should construct command lines using these helpers rather
//  than reaching through `Artifact.path` (an `@internal` field) or
//  calling `Sdk.Transformers.Artifact.input/output` directly. They are
//  the only public surface in the rules SDK that touches the
//  materialization boundary.
// ============================================================================

/**
 * Wrap an `Artifact` so it can be referenced on a tool command line as
 * an *input*. The Artifact must be bound — sources are bound at
 * construction; declared outputs become bound after `Actions.run`.
 *
 * Equivalent to `Sdk.Transformers.Artifact.input(Rules.getFile(art))`,
 * but does not require rule code to import `Sdk.Transformers` or call
 * `getFile` itself.
 *
 * Pass the result to `Cmd.argument(...)` for a positional argument, or
 * to `Cmd.option("/in:", ...)` for an option value.
 */
@@public
export function cmdInput(art: Artifact): ArgumentValue {
    Contract.requires(art !== undefined, "cmdInput: artifact must not be undefined");
    return Tx.input(getFile(art));
}

/**
 * Wrap an `OutputArtifact` so it can be referenced on a tool command
 * line as an *output*. The Artifact does not need to be bound — this is
 * the wiring that lets BuildXL learn the producing pip's output paths
 * at command-line construction time.
 *
 * Equivalent to `Sdk.Transformers.Artifact.output(out.artifact.path)`,
 * but hides the `@internal` `Artifact.path` field.
 *
 * Pass the result to `Cmd.argument(...)` for a positional argument, or
 * to `Cmd.option("/out:", ...)` for an option value.
 */
@@public
export function cmdOutput(out: OutputArtifact): ArgumentValue {
    Contract.requires(out !== undefined, "cmdOutput: OutputArtifact must not be undefined");
    return Tx.output(out.artifact.path);
}
