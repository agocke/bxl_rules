// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Sdk.Rules — A language-agnostic Bazel/Buck2-style rules engine for BuildXL.
 *
 * Configuration & transitions (configuration.dsc, transition.dsc):
 *   - Configuration       — the value-shaped, branded build configuration
 *                           (a view over a BuildXL qualifier)
 *   - fromQualifier       — the only sanctioned Configuration factory
 *   - Transition          — pure Configuration→Configuration function (branded)
 *   - IdentityTransition / TargetTransition — predefined transitions
 *   - makeExecTransition({os, cpu}) — factory for an exec transition
 *     with workspace-specific host labels
 *
 * Artifact model (artifact.dsc):
 *   - Artifact            — referenceable handle (may be unbound)
 *   - SourceArtifact      — wraps a workspace File; always bound
 *   - declareArtifact / sourceArtifact — factories
 *   - bindArtifact / getFile — binding helpers used by the Actions adapter
 *   - cmdInput / cmdOutput — sanctioned wrappers for tool command lines
 *                           (route around the `@internal` Artifact.path)
 *
 * Core rules-engine primitives (providers.dsc):
 *   - Provider             — base discriminator interface for rule outputs
 *   - depset<T>()         — tree-structured, deduplicated transitive collection
 *   - DefaultInfo         — universal output descriptor
 *   - Actions             — the action API (declareOutput / run / writeFile / copyFile);
 *                           enforces within-target single-binding via a path-keyed set
 *   - rule()              — the declarative rule factory
 *   - LabelResolver       — returns SourceArtifact (not raw File)
 *
 * General-purpose rules (genrule.dsc):
 *   - genrule             — run any tool, declare outputs by name
 *   - filegroup           — group SourceArtifacts under a logical name
 *   - copy_file           — copy a single Artifact
 *   - copy_files          — copy a set of Artifacts
 *
 * Kind primitives (kinds.dsc):
 *   - RuleKind            — `"library" | "binary" | "test"` (declare on
 *                           `Rules.rule({ kind: ... })`; the Actions
 *                           adapter auto-tags scheduled pips with the
 *                           framework-internal `bxl-kind:*` vocabulary)
 *   - TestInfo / testInfo — provider every `*_test` rule returns;
 *                           carries typed `size?: TestSize` and
 *                           `flaky?: boolean`, derives `timeoutSec`
 *                           from `size` when not given explicitly
 *   - TestSize            — `"small" | "medium" | "large" | "enormous"`
 *   - BinaryInfo / binaryInfo — provider every `*_binary` rule returns
 *   - test_suite          — aggregator macro emitting a JSON manifest
 *
 * Language-specific rules live in separate modules:
 *   - Sdk.Rules.CSharp    — csharp_library, csharp_binary, csharp_test
 */

// All exports are defined in their respective .dsc files.
// This file serves as the module documentation entry point.
