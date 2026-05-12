// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Tests for Rules/artifact.dsc (Artifact / SourceArtifact / OutputArtifact).
 *
 * Same harness as Test.Config.dsc and Test.Transition.dsc: each test
 * returns "ok" on success; a `Contract.assert` failure aborts evaluation
 * and bxl reports a non-zero exit code.
 */

import * as Rules from "Sdk.Rules";
import {Transformer} from "Sdk.Transformers";

// ----------------------------------------------------------------------------
// declareArtifact — basic shape
// ----------------------------------------------------------------------------

function test_declareArtifact_basic(): string {
    const dir = Context.getNewOutputDirectory("test-decl-basic");
    const art = Rules.declareArtifact(dir, "MyLib.dll");

    Contract.assert(art.shortPath === "MyLib.dll",
        "declareArtifact(name) must set shortPath = name");
    Contract.assert(art.extension === ".dll",
        `extension must be ".dll" for "MyLib.dll", got "${art.extension}"`);
    Contract.assert(art.kind === "unbound",
        `declared artifact must have kind === "unbound"; got "${art.kind}"`);

    return "ok";
}

function test_declareArtifact_withSubdir_includesItInShortPath(): string {
    const dir = Context.getNewOutputDirectory("test-decl-subdir");
    const art = Rules.declareArtifact(dir, "foo.o", { subdir: "obj" });

    Contract.assert(art.shortPath === "obj/foo.o",
        `subdir must be folded into shortPath; got "${art.shortPath}"`);
    Contract.assert(art.extension === ".o",
        "extension extraction must work even with subdir");

    return "ok";
}

function test_declareArtifact_noExtension_yieldsEmptyString(): string {
    const dir = Context.getNewOutputDirectory("test-decl-noext");
    const art = Rules.declareArtifact(dir, "Makefile");

    Contract.assert(art.extension === "",
        `no-extension file must yield "", got "${art.extension}"`);
    Contract.assert(art.shortPath === "Makefile",
        "shortPath must equal name when there is no extension");

    return "ok";
}

function test_declareArtifact_pathIsUnderTargetDir(): string {
    const dir = Context.getNewOutputDirectory("test-decl-path");
    const art = Rules.declareArtifact(dir, "thing.txt");

    Contract.assert(art.path.isWithin(dir),
        "declared artifact's path must be within the supplied targetDir");

    return "ok";
}

function test_declareArtifact_pathIsUnderTargetDir_withSubdir(): string {
    const dir = Context.getNewOutputDirectory("test-decl-path-subdir");
    const art = Rules.declareArtifact(dir, "thing.txt", { subdir: "nested/inner" });

    Contract.assert(art.path.isWithin(dir),
        "declared artifact's path must be within targetDir even with subdir");
    Contract.assert(art.shortPath === "nested/inner/thing.txt",
        "nested subdir must be preserved in shortPath");

    return "ok";
}

function test_declareArtifact_undefinedOpts_isOK(): string {
    const dir = Context.getNewOutputDirectory("test-decl-undef-opts");
    const art = Rules.declareArtifact(dir, "x.bin", undefined);

    Contract.assert(art.shortPath === "x.bin", "undefined opts must behave as no opts");

    return "ok";
}

// ----------------------------------------------------------------------------
// sourceArtifact
// ----------------------------------------------------------------------------

function test_sourceArtifact_basic(): string {
    const f = f`Test.Artifact.dsc`;
    const src = Rules.sourceArtifact(f);

    Contract.assert(src.kind === "source",
        `sourceArtifact must have kind === "source"; got "${src.kind}"`);
    Contract.assert(src.file === f,
        "sourceArtifact must carry the original File reference");
    Contract.assert(src.shortPath === "Test.Artifact.dsc",
        `sourceArtifact shortPath must be the leaf name; got "${src.shortPath}"`);
    Contract.assert(src.extension === ".dsc",
        `sourceArtifact extension must include the dot; got "${src.extension}"`);

    return "ok";
}

function test_sourceArtifact_pathMatchesFilePath(): string {
    const f = f`Test.Artifact.dsc`;
    const src = Rules.sourceArtifact(f);

    Contract.assert(src.path === f.path,
        "sourceArtifact.path must equal the underlying File's path");

    return "ok";
}

// ----------------------------------------------------------------------------
// asOutput
// ----------------------------------------------------------------------------

function test_asOutput_wrapsArtifact(): string {
    const dir = Context.getNewOutputDirectory("test-asoutput-wrap");
    const art = Rules.declareArtifact(dir, "out.bin");
    const out = Rules.asOutput(art);

    Contract.assert(out.artifact === art,
        "asOutput must reference the supplied Artifact");

    return "ok";
}

function test_asOutput_returnsFreshInstancePerCall(): string {
    const dir = Context.getNewOutputDirectory("test-asoutput-fresh");
    const art = Rules.declareArtifact(dir, "out.bin");
    const o1 = Rules.asOutput(art);
    const o2 = Rules.asOutput(art);

    Contract.assert(o1 !== o2,
        "each asOutput call must return a fresh OutputArtifact instance");
    Contract.assert(o1.artifact === o2.artifact,
        "both OutputArtifacts must back the same underlying Artifact");

    return "ok";
}

// ----------------------------------------------------------------------------
// SourceArtifact is structurally an Artifact (can be passed where Artifact expected)
// ----------------------------------------------------------------------------

function test_sourceArtifact_isUsableAsArtifact(): string {
    const src = Rules.sourceArtifact(f`Test.Artifact.dsc`);
    // If SourceArtifact does not extend Artifact, this assignment fails to type-check.
    const asBase: Rules.Artifact = src;

    Contract.assert(asBase.kind === "source",
        `SourceArtifact widened to Artifact must retain kind === "source"; got "${asBase.kind}"`);

    return "ok";
}

// ----------------------------------------------------------------------------
// artifactsEqual
// ----------------------------------------------------------------------------

function test_artifactsEqual_sameInstance(): string {
    const dir = Context.getNewOutputDirectory("test-eq-same");
    const a = Rules.declareArtifact(dir, "x.dll");

    Contract.assert(Rules.artifactsEqual(a, a),
        "an artifact must equal itself");

    return "ok";
}

function test_artifactsEqual_samePathDifferentInstances(): string {
    const dir = Context.getNewOutputDirectory("test-eq-samepath");
    const a = Rules.declareArtifact(dir, "x.dll");
    const b = Rules.declareArtifact(dir, "x.dll");

    Contract.assert(Rules.artifactsEqual(a, b),
        "two artifacts with the same underlying path must compare equal");

    return "ok";
}

function test_artifactsEqual_differentPaths(): string {
    const dir = Context.getNewOutputDirectory("test-eq-diff");
    const a = Rules.declareArtifact(dir, "x.dll");
    const b = Rules.declareArtifact(dir, "y.dll");

    Contract.assert(!Rules.artifactsEqual(a, b),
        "two artifacts with different paths must compare unequal");

    return "ok";
}

function test_artifactsEqual_undefinedReturnsFalse(): string {
    const dir = Context.getNewOutputDirectory("test-eq-undef");
    const a = Rules.declareArtifact(dir, "x.dll");

    Contract.assert(!Rules.artifactsEqual(a, undefined),
        "artifactsEqual(a, undefined) must be false");
    Contract.assert(!Rules.artifactsEqual(undefined, a),
        "artifactsEqual(undefined, a) must be false");
    Contract.assert(!Rules.artifactsEqual(undefined, undefined),
        "artifactsEqual(undefined, undefined) must be false");

    return "ok";
}

function test_artifactsEqual_sourceVsDeclaredAtSamePathWouldBeEqual(): string {
    // Document the chosen semantics: artifactsEqual compares paths only,
    // not kind. (That is, two artifacts at the same logical location
    // are equal regardless of provenance — useful for graph dedup.)
    const src = Rules.sourceArtifact(f`Test.Artifact.dsc`);
    const src2 = Rules.sourceArtifact(f`Test.Artifact.dsc`);

    Contract.assert(Rules.artifactsEqual(src, src2),
        "two SourceArtifacts at the same path must compare equal");

    return "ok";
}

// ----------------------------------------------------------------------------
// outputArtifactsEqual
// ----------------------------------------------------------------------------

function test_outputArtifactsEqual_delegatesToArtifactsEqual(): string {
    const dir = Context.getNewOutputDirectory("test-oeq");
    const a = Rules.declareArtifact(dir, "x.dll");
    const b = Rules.declareArtifact(dir, "x.dll");
    const oa = Rules.asOutput(a);
    const ob = Rules.asOutput(b);

    Contract.assert(Rules.outputArtifactsEqual(oa, ob),
        "OutputArtifacts backing equal Artifacts must compare equal");

    const c = Rules.declareArtifact(dir, "y.dll");
    const oc = Rules.asOutput(c);
    Contract.assert(!Rules.outputArtifactsEqual(oa, oc),
        "OutputArtifacts backing unequal Artifacts must compare unequal");

    return "ok";
}

function test_outputArtifactsEqual_undefinedReturnsFalse(): string {
    const dir = Context.getNewOutputDirectory("test-oeq-undef");
    const a = Rules.declareArtifact(dir, "x.dll");
    const oa = Rules.asOutput(a);

    Contract.assert(!Rules.outputArtifactsEqual(oa, undefined),
        "outputArtifactsEqual(oa, undefined) must be false");
    Contract.assert(!Rules.outputArtifactsEqual(undefined, oa),
        "outputArtifactsEqual(undefined, oa) must be false");

    return "ok";
}

// ----------------------------------------------------------------------------
// boundFile field shape
// ----------------------------------------------------------------------------

function test_declareArtifact_boundFileIsUndefined(): string {
    const dir = Context.getNewOutputDirectory("test-bound-undef");
    const art = Rules.declareArtifact(dir, "x.dll");

    Contract.assert(art.boundFile === undefined,
        "freshly declared Artifact must have boundFile === undefined");

    return "ok";
}

function test_sourceArtifact_boundFileIsUndefined(): string {
    // For SourceArtifact, the bound handle is exposed as `.file` (typed
    // `File`), not `.boundFile` (typed `DerivedFile`). The latter stays
    // undefined.
    const src = Rules.sourceArtifact(f`Test.Artifact.dsc`);

    Contract.assert(src.boundFile === undefined,
        "SourceArtifact.boundFile must be undefined; the bound handle is .file");

    return "ok";
}

// ----------------------------------------------------------------------------
// getFile
// ----------------------------------------------------------------------------

function test_getFile_returnsUnderlyingFile_forSource(): string {
    const f = f`Test.Artifact.dsc`;
    const src = Rules.sourceArtifact(f);
    const out = Rules.getFile(src);

    Contract.assert(out === f,
        "getFile(sourceArtifact(f)) must return the original File");

    return "ok";
}

function test_getFile_returnsBoundFile_forDerived(): string {
    // Synthesize a DerivedFile by scheduling a writeAllLines pip; this
    // does not execute during analysis but yields a typed DerivedFile
    // handle suitable for `bindArtifact`. We then exercise the
    // non-source branch of `getFile` and confirm it returns the same
    // file we bound.
    const dir = Context.getNewOutputDirectory("test-getfile-derived");
    const declared = Rules.declareArtifact(dir, "out.txt");
    const df = Transformer.writeAllLines(declared.path, ["hello"]);
    const bound = Rules.bindArtifact(declared, <DerivedFile>df);

    Contract.assert(bound.kind === "bound", `bindArtifact must produce kind === "bound"; got "${bound.kind}"`);
    Contract.assert(bound.boundFile === df, "bindArtifact must attach the supplied DerivedFile");

    const out = Rules.getFile(bound);
    Contract.assert(out === df,
        "getFile must return the same DerivedFile that was bound");

    return "ok";
}

// ----------------------------------------------------------------------------
// cmdInput / cmdOutput — sanctioned command-line wrappers
// ----------------------------------------------------------------------------

function test_cmdInput_returnsDefinedForSource(): string {
    // We can't introspect the BuildXL Artifact value (it's opaque), but
    // we can confirm the helper accepts a SourceArtifact and returns
    // something defined (i.e. doesn't throw the getFile kind check
    // and doesn't return undefined).
    const src = Rules.sourceArtifact(f`Test.Artifact.dsc`);
    const arg = Rules.cmdInput(src);

    Contract.assert(arg !== undefined, "cmdInput must return a defined value for SourceArtifact");

    return "ok";
}

function test_cmdInput_returnsDefinedForBound(): string {
    // Bound declared artifact via writeAllLines, same trick as the
    // getFile-on-bound test.
    const dir = Context.getNewOutputDirectory("test-cmdinput-bound");
    const declared = Rules.declareArtifact(dir, "out.txt");
    const df = Transformer.writeAllLines(declared.path, ["hello"]);
    const bound = Rules.bindArtifact(declared, <DerivedFile>df);

    const arg = Rules.cmdInput(bound);
    Contract.assert(arg !== undefined, "cmdInput must return a defined value for bound Artifact");

    return "ok";
}

function test_cmdOutput_returnsDefined(): string {
    // cmdOutput accepts an unbound declared output; it does not require
    // a producing action because it IS the wiring that registers one.
    const dir = Context.getNewOutputDirectory("test-cmdoutput");
    const declared = Rules.declareArtifact(dir, "out.dll");
    const handle = Rules.asOutput(declared);

    const arg = Rules.cmdOutput(handle);
    Contract.assert(arg !== undefined, "cmdOutput must return a defined value");

    return "ok";
}


@@public export const tartA01 = test_declareArtifact_basic();
@@public export const tartA02 = test_declareArtifact_withSubdir_includesItInShortPath();
@@public export const tartA03 = test_declareArtifact_noExtension_yieldsEmptyString();
@@public export const tartA04 = test_declareArtifact_pathIsUnderTargetDir();
@@public export const tartA05 = test_declareArtifact_pathIsUnderTargetDir_withSubdir();
@@public export const tartA06 = test_declareArtifact_undefinedOpts_isOK();
@@public export const tartA07 = test_sourceArtifact_basic();
@@public export const tartA08 = test_sourceArtifact_pathMatchesFilePath();
@@public export const tartA09 = test_asOutput_wrapsArtifact();
@@public export const tartA10 = test_asOutput_returnsFreshInstancePerCall();
@@public export const tartA11 = test_sourceArtifact_isUsableAsArtifact();
@@public export const tartA12 = test_artifactsEqual_sameInstance();
@@public export const tartA13 = test_artifactsEqual_samePathDifferentInstances();
@@public export const tartA14 = test_artifactsEqual_differentPaths();
@@public export const tartA15 = test_artifactsEqual_undefinedReturnsFalse();
@@public export const tartA16 = test_artifactsEqual_sourceVsDeclaredAtSamePathWouldBeEqual();
@@public export const tartA17 = test_outputArtifactsEqual_delegatesToArtifactsEqual();
@@public export const tartA18 = test_outputArtifactsEqual_undefinedReturnsFalse();
@@public export const tartA19 = test_declareArtifact_boundFileIsUndefined();
@@public export const tartA20 = test_sourceArtifact_boundFileIsUndefined();
@@public export const tartA21 = test_getFile_returnsUnderlyingFile_forSource();
@@public export const tartA22 = test_getFile_returnsBoundFile_forDerived();
@@public export const tartA23 = test_cmdInput_returnsDefinedForSource();
@@public export const tartA24 = test_cmdInput_returnsDefinedForBound();
@@public export const tartA25 = test_cmdOutput_returnsDefined();
