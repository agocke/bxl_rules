// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * Sdk.Rules — A language-agnostic Bazel-style rules engine for BuildXL.
 *
 * Core primitives (providers.dsc):
 *   - depset<T>()    — tree-structured, deduplicated transitive collection
 *   - provider<T>()  — typed key for extensible rule outputs
 *   - DefaultInfo    — universal output descriptor (files + data + providers)
 *   - ProviderMap    — bag of typed providers attached to a rule result
 *   - RuleResult     — standard return type wrapping DefaultInfo + providers
 *
 * General-purpose rules (genrule.dsc):
 *   - genrule        — run any tool, declare inputs/outputs by name
 *   - filegroup      — group files under a logical name
 *   - copy_file      — copy a single file
 *   - copy_files     — copy a set of files
 *
 * Language-specific rules live in separate modules:
 *   - Sdk.Rules.CSharp  — csharp_library, csharp_binary, csharp_test
 */

// All exports are defined in providers.dsc and genrule.dsc.
// This file serves as the module documentation entry point.
