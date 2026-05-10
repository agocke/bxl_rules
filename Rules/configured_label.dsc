// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/**
 * ConfiguredLabel — a target reference paired with the Configuration
 * under which it should be evaluated.
 *
 * Modelled after Buck2's `ConfiguredTargetLabel`, adapted for DScript.
 * In Buck2/Bazel, every dep edge in the analysis graph is a configured
 * label: the label says *which* target, the Configuration says *how* it
 * should be built. Two configured labels with the same target string
 * but different Configurations are distinct nodes in the graph.
 *
 * DScript constraints:
 *   - No phantom type parameters that the checker enforces structurally,
 *     so `ConfiguredLabel` is a runtime-only carrier (no `<C extends
 *     Configuration>` — the Configuration is just a field).
 *   - Labels are plain strings (no template-literal types in DScript).
 *
 * Drift hazard avoidance:
 *   - `ConfiguredLabel` is brand-tagged so a bare `{label, configuration}`
 *     literal cannot accidentally satisfy the type — callers must go
 *     through `withConfiguration`.
 *   - A `ConfiguredLabel`'s Configuration must itself have come from
 *     `fromQualifier` or `Transition.apply` (the only Configuration
 *     factories), so it is structurally impossible to attach an
 *     unverified Configuration to a label.
 */

// ============================================================================
//  ConfiguredLabel
// ============================================================================

/**
 * A target reference + the Configuration under which it should be evaluated.
 *
 * Always construct via `withConfiguration(label, cfg)`; never via an
 * object literal (the `__configuredLabelBrand` field is enforced).
 */
@@public
export interface ConfiguredLabel {
    /** Tagged-interface brand. Do not set or read. */
    __configuredLabelBrand: any;

    /**
     * Target label (e.g., "//foo/bar:baz"). Free-form string — DScript
     * has no template-literal types so a tighter shape isn't expressible.
     */
    label: string;

    /** The Configuration under which this target should be evaluated. */
    configuration: Configuration;
}

// ============================================================================
//  Factory
// ============================================================================

/**
 * Construct a `ConfiguredLabel` pairing a target string with a Configuration.
 *
 * Example:
 *   const cfg = Rules.fromQualifier(qualifier);
 *   const dep = Rules.withConfiguration("//tools:codegen",
 *                                       Rules.ExecTransition.apply(cfg));
 *
 * The Configuration argument must come from `fromQualifier` or
 * `Transition.apply` — those are the only sanctioned factories.
 * Constructing one any other way (e.g. via `<Configuration>{...}`)
 * is structurally blocked by the brand on `Configuration`.
 */
@@public
export function withConfiguration(label: string, cfg: Configuration): ConfiguredLabel {
    return <ConfiguredLabel>{
        __configuredLabelBrand: undefined,
        label: label,
        configuration: cfg,
    };
}

/**
 * True iff two ConfiguredLabels reference the same configured target,
 * i.e. same label string AND configurationally equal Configurations.
 *
 * Useful for de-duplication in dep-graph construction.
 */
@@public
export function configuredLabelsEqual(a: ConfiguredLabel, b: ConfiguredLabel): boolean {
    return a !== undefined
        && b !== undefined
        && a.label === b.label
        && configurationsEqual(a.configuration, b.configuration);
}
