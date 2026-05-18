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
 * This SDK ports the discriminator (`kind: "unbound" | "bound" |
 * "source"`) but not the second type. Buck2's `OutputArtifact` carries
 * its weight in Starlark because Artifact binding is *mutable state*
 * on the Artifact itself — the type system needs a separate handle to
 * track "this Artifact is being claimed as an output." Our `Artifact`
 * is a value-shaped record (`bindArtifact` returns a *new* bound
 * Artifact; the input stays as it was), so the only legitimate work an
 * `OutputArtifact` wrapper would do is reject the wrong `kind` — which
 * `cmdOutput` and the `Actions` adapter do directly on the `Artifact`.
 * The within-target "at most one action binds this output" property is
 * enforced at runtime by the `Actions` adapter via a path-keyed set
 * (see `createActions` in providers.dsc).
 *
 * Type taxonomy
 * -------------
 *   Artifact         — base, branded. Carries `shortPath`, `extension`,
 *                      `kind` (one of "unbound" | "bound" | "source"),
 *                      and the underlying `Path`.
 *   SourceArtifact   — extends Artifact; wraps a workspace `File`. Has
 *                      `kind === "source"`. Rejected anywhere an
 *                      output Artifact is expected.
 *
 * Why a `kind` discriminator (not paired booleans)
 * ------------------------------------------------
 * Bound vs unbound is *value-level* state — a freshly declared output is
 * unbound; the value returned from `Actions.run` is the same logical
 * output but bound. DScript's checker does not yet narrow union types
 * based on a field's runtime value (the way TypeScript narrows a
 * discriminated union inside an `if (x.kind === "bound")` block), so
 * `getFile` / `bindArtifact` / `cmdOutput` continue to enforce
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
 *   - Both types are tagged-interface-branded, so a bare object literal
 *     cannot satisfy them; callers must go through `declareArtifact` or
 *     `sourceArtifact`.
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
     *     `getFile` will reject; pass to `Actions.run` (in `outputs:`)
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
 * An artifact that wraps an existing workspace source — either a `File`
 * or a sealed `StaticDirectory`.
 *
 * `SourceArtifact` extends `Artifact` with the bound source handle and
 * its own brand. `kind` is narrowed to the single literal `"source"`;
 * this is the only Artifact subtype whose binding state is statically
 * known at the type level.
 *
 * Files vs directories are discriminated by the `isDirectory` flag —
 * the same `is_directory` distinction Bazel models on a single
 * `File`/`Artifact` type rather than parallel branded interfaces.
 * Exactly one of `file` / `directory` is populated.
 *
 * Always construct via `sourceArtifact(file)` or
 * `sourceDirectoryArtifact(dir)`.
 */
@@public
export interface SourceArtifact extends Artifact {
    /** Tagged-interface brand. Do not set or read. */
    __sourceArtifactBrand: any;

    /** Narrowed discriminator — always `"source"` for SourceArtifact. */
    kind: "source";

    /** True iff this artifact wraps a directory rather than a file. */
    isDirectory: boolean;

    /** The bound source `File` (when `isDirectory === false`). */
    file?: File;

    /** The bound sealed `StaticDirectory` (when `isDirectory === true`). */
    directory?: StaticDirectory;
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
        isDirectory: false,
        file: file,
        directory: undefined,
    };
}

/**
 * Wrap a workspace `StaticDirectory` as a `SourceArtifact` with
 * `isDirectory === true`.
 *
 * Sealed/source directories entering the framework via attribute
 * resolution (e.g., extracted SDK trees) are wrapped via this factory.
 * Rule implementations should receive `Artifact` (or `SourceArtifact`),
 * never raw `StaticDirectory`.
 */
@@public
export function sourceDirectoryArtifact(dir: StaticDirectory): SourceArtifact {
    const dpath = dir.root.path;
    const short = dpath.name.toString();
    return <SourceArtifact>{
        __artifactBrand: undefined,
        __sourceArtifactBrand: undefined,
        shortPath: short,
        extension: "",
        kind: "source",
        path: dpath,
        boundFile: undefined,
        isDirectory: true,
        file: undefined,
        directory: dir,
    };
}

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
        const src = <SourceArtifact>art;
        Contract.requires(!src.isDirectory,
            "getFile: source artifact wraps a directory; use getDirectory instead");
        return src.file;
    }
    Contract.requires(art.boundFile !== undefined,
        "getFile: bound artifact missing boundFile (binding invariant violated)");
    return art.boundFile;
}

/**
 * Extract the underlying `StaticDirectory` for a source directory artifact.
 *
 * Asserts `kind === "source"` and `isDirectory === true`. Output
 * directories (opaque / shared-opaque) are not yet modelled.
 */
@@public
export function getDirectory(art: Artifact): StaticDirectory {
    Contract.requires(art !== undefined, "getDirectory: artifact must not be undefined");
    Contract.requires(art.kind === "source",
        `getDirectory: only source directory artifacts are supported; got kind "${art.kind}"`);
    const src = <SourceArtifact>art;
    Contract.requires(src.isDirectory,
        "getDirectory: source artifact wraps a file; use getFile instead");
    return src.directory;
}

/**
 * Internal bridge from `Artifact` to BuildXL's `InputArtifact` shape
 * (`File | StaticDirectory`), used by the Actions adapter when
 * building the `Transformer.execute({dependencies})` argument. Sources
 * may be either kind; bound outputs are always files.
 *
 * Not exported: rule authors should reference inputs via
 * `cmdInput(art)`. Punching this through to user code would leak the
 * raw BuildXL handle that `path` / `getFile` are deliberately keeping
 * inside the SDK.
 */
export function getInputArtifact(art: Artifact): File | StaticDirectory {
    Contract.requires(art !== undefined, "getInputArtifact: artifact must not be undefined");
    if (art.kind === "source") {
        const src = <SourceArtifact>art;
        return src.isDirectory ? <File | StaticDirectory>src.directory : <File | StaticDirectory>src.file;
    }
    return <File | StaticDirectory>getFile(art);
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
 * Wrap an unbound declared `Artifact` so it can be referenced on a tool
 * command line as an *output*. The Artifact does not need to be bound
 * yet — this is the wiring that lets BuildXL learn the producing pip's
 * output paths at command-line construction time.
 *
 * Equivalent to `Sdk.Transformers.Artifact.output(art.path)`, but hides
 * the `@internal` `Artifact.path` field. Symmetric with `cmdInput`:
 * `cmdInput` accepts any Artifact whose `kind !== "unbound"` (source or
 * bound); `cmdOutput` accepts only `kind === "unbound"` (the same
 * Artifact you'd hand to `Actions.run`'s `outputs:`).
 *
 * Pass the result to `Cmd.argument(...)` for a positional argument, or
 * to `Cmd.option("/out:", ...)` for an option value.
 */
@@public
export function cmdOutput(art: Artifact): ArgumentValue {
    Contract.requires(art !== undefined, "cmdOutput: artifact must not be undefined");
    Contract.requires(art.kind === "unbound",
        `cmdOutput: artifact must be unbound (kind === "unbound"); got "${art.kind}". A SourceArtifact cannot be an output, and a bound Artifact has already been produced by a prior action.`);
    return Tx.output(art.path);
}
