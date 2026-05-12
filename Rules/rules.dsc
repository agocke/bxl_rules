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
 *   - IdentityTransition / TargetTransition / ExecTransition — predefined
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
 *   - depset<T>()         — tree-structured, deduplicated transitive collection
 *   - provider<T>()       — typed key for extensible rule outputs
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
 * Language-specific rules live in separate modules:
 *   - Sdk.Rules.CSharp    — csharp_library, csharp_binary, csharp_test
 */

// All exports are defined in their respective .dsc files.
// This file serves as the module documentation entry point.
