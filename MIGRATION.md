# Migration guide — bxl_rules consumers

This guide lists the breaking changes shipped by the Buck2-shaped redesign of `bxl_rules` and shows the call-site updates needed to keep a consuming repo (e.g. `bxl_rules_csharp`) working.

If a section says "no change required", it's listed only so you can verify your assumptions.

---

## Quick checklist

- [ ] Replace `qualifier.<field>` reads with `Rules.fromQualifier(qualifier)` + `Rules.getConstraint(...)`.
- [ ] Replace static `cfg = "exec"` patterns with `Rules.makeExecTransition({os, cpu}).apply(cfg)` — construct the transition once per workspace with your host labels (there's no global singleton).
- [ ] Update `LabelResolver` consumers — `resolver.resolve(label)` now returns `SourceArtifact`, not `File`.
- [ ] Update rule `resolve` types — `srcs: File[]` → `srcs: SourceArtifact[]`.
- [ ] Replace `ctx.actions.declareFile(name)` with `ctx.actions.declareOutput(name)` (returns `Artifact`, not `DerivedFile`).
- [ ] Pass declared `Artifact`s directly to `Actions.run.outputs` (no `asOutput` wrapping — that type has been dropped).
- [ ] Destructure the new `Artifact[]` return of `Actions.run` (was `DerivedFile[]`) and use the bound result downstream; the original declared handle is stale after binding.
- [ ] Replace `Cmd.argument(Artifact.input(file))` with `Cmd.argument(Rules.cmdInput(art))`.
- [ ] Replace `Cmd.option("/out:", Artifact.output(declared.path))` with `Cmd.option("/out:", Rules.cmdOutput(declaredArt))`.
- [ ] Use `Rules.getFile(art)` (or `art.file` for sources) when a BuildXL primitive needs a raw `File`.

---

## 1. Configuration / qualifier

**Before** — reading the qualifier directly:

```typescript
if (qualifier.targetRuntime === "linux-x64") { ... }
const isDebug = qualifier.configuration === "debug";
```

**After** — go through `Configuration`:

```typescript
const cfg = Rules.fromQualifier(qualifier);
const platform = cfg.platform;                                    // "linux-x64"
const mode     = Rules.getConstraint(cfg, Rules.ConstraintSettings.mode);  // "debug"
if (platform === Rules.Platforms.linuxX64) { ... }
```

Why: `Configuration` is the single source of truth for build settings. The qualifier remains the underlying carrier (accessible via `cfg.underlyingQualifier`), but rules should not read fields off it directly — there's no contract that field names are stable.

## 2. Transitions

**Before** — passing a magic string for execution-side dependencies:

```typescript
const codegenDep = { label: "//tools:codegen", cfg: "exec" };
```

**After** — construct an exec transition with your workspace's host labels, then apply it and use its `underlyingQualifier` at the dep-import site:

```typescript
// Once per workspace (e.g. in a shared module):
export const ExecTransition = Rules.makeExecTransition({
    os:  Rules.hostOs(),   // or remap to your vocabulary if it isn't "unix"/"macos"/"windows"
    cpu: Rules.hostCpu(),
});

// At each call site:
const targetCfg = Rules.fromQualifier(qualifier);
const execCfg   = ExecTransition.apply(targetCfg);
import * as Codegen from "Codegen" withQualifier(execCfg.underlyingQualifier);
```

`Rules.IdentityTransition` / `Rules.TargetTransition` are the predefined no-op transitions. `Rules.makeExecTransition({os, cpu})` is a factory for the exec case; the SDK does **not** ship a singleton because it can't know your qualifier vocabulary (BuildXL's `Context.getCurrentHost()` reports `unix` for Linux/FreeBSD/Haiku and `x64`/`x86` only — so a global singleton would silently mismatch any workspace declaring `os: "linux"` in its qualifier matrix). Custom transitions can be defined as `<Transition>{ name, apply: cfg => ... }` and must be idempotent.

**Scope:** BuildXL's `withQualifier` is syntactic, so the dep-import side stays manual:

```typescript
import * as Tool from "Tool" withQualifier(execCfg.underlyingQualifier);
```

A Transition computes the new Configuration as a value; the rule writes the `withQualifier` import at the call site. Buck2's `attrs.dep(target, transition)` would automate this, but it presupposes a value-level analog of BuildXL's syntactic `withQualifier` operator. Treat the manual import as the supported shape.

## 3. Label resolution

**Before** — `LabelResolver` returned raw `File`s:

```typescript
resolve: (attrs, resolver) => ({
    name: attrs.name,
    srcs: resolver.resolveAll(attrs.srcs),  // was File[]
})

// Inside impl:
ctx.args.srcs.forEach(s => use(s));  // s was a File
```

**After** — `LabelResolver` returns `SourceArtifact`s:

```typescript
resolve: (attrs, resolver) => ({
    name: attrs.name,
    srcs: resolver.resolveAll(attrs.srcs),  // now SourceArtifact[]
})

// Inside impl:
ctx.args.srcs.forEach(s => use(Rules.getFile(s)));  // unwrap to File when needed
// or: s.file (typed File, no Contract guard)
```

The framework wraps every resolved label in a `SourceArtifact` so that rule code uniformly speaks in `Artifact`s. To bridge to a BuildXL primitive that wants a raw `File`, call `Rules.getFile(art)` (asserts `art.kind !== "unbound"`) or — for sources only — read `srcArt.file` directly.

## 4. Declaring outputs

**Before** — `ctx.actions.declareFile(name)` returned a `DerivedFile`:

```typescript
const out = ctx.actions.declareFile("foo.dll");           // DerivedFile
ctx.actions.run({
    outputs: [out],                                       // raw DerivedFile
    arguments: [Cmd.option("/out:", Artifact.output(out.path))]
});
const outFile: File = out;                                // already a File
```

**After** — `declareOutput` returns an unbound `Artifact`; pass it directly to `outputs`; consume the bound `Artifact` returned by `run`:

```typescript
const out     = ctx.actions.declareOutput("foo.dll");    // Artifact, kind: "unbound"
const [bound] = ctx.actions.run({                        // returns Artifact[] (bound)
    outputs: [out],
    arguments: [Cmd.option("/out:", Rules.cmdOutput(out))]
});
const outFile: File = Rules.getFile(bound);              // the produced DerivedFile
// From here on, reference `bound`. `out` is a stale unbound handle.
```

Three things changed:
- The return of `declareOutput` is unbound. It becomes bound only after `run` returns. Don't carry the unbound value forward — use the value `run` returns.
- `outputs: [...]` takes `Artifact[]` (with `kind === "unbound"`), not `Path[]` and not `OutputArtifact[]` (that type has been removed — see *Why no `OutputArtifact`?* below).
- `run` returns the bound `Artifact[]` in the same order as `outputs`. Destructure and use the bound values.

**Why no `OutputArtifact`?** Buck2 needs a separate output-handle type because Starlark's `Artifact` carries mutable binding state. Our `Artifact` is value-shaped — `bindArtifact` returns a new value rather than mutating in place — so a separate output-handle type carried no state that `Artifact` didn't. The useful property (each declared output is produced by exactly one action) is now enforced at runtime by the Actions adapter via a path-keyed `MutableSet`. Within a single target, double-binding the same declared path through `run`/`writeFile`/`copyFile` throws at analysis time. Cross-target double-binding still falls to BuildXL's pip-graph layer.

**Stale-handle footgun.** `Actions.run` returns the bound Artifact; the original unbound handle stays stale. To keep the two from being confused, prefer the destructure pattern:

```typescript
const outArt = ctx.actions.declareOutput("foo.dll");
const [foo]  = ctx.actions.run({
    outputs: [outArt],
    arguments: [..., Rules.cmdOutput(outArt)],
    ...
});
// Use `foo` from here on; `outArt` is the stale unbound handle.
```

**Cmdline-vs-outputs gap.** The SDK does *not* pre-check that every cmdline-referenced output (via `Rules.cmdOutput`) also appears in the action's `outputs:` array. If you `cmdOutput(art)` without listing `art` in `outputs:`, BuildXL catches it later as a pip-graph error — not at SDK-evaluation time. In normal use this is the obvious "/out: flag without putting the file in outputs" mistake; flagged here only so the asymmetry isn't surprising when it fires.

## 5. Command-line construction

**Before** — direct calls to `Sdk.Transformers.Artifact`:

```typescript
import {Artifact, Cmd} from "Sdk.Transformers";

arguments: [
    Cmd.option("/out:", Artifact.output(declared.path)),
    Cmd.argument(Artifact.input(srcFile))
]
```

**After** — go through `Rules.cmdInput` / `Rules.cmdOutput`:

```typescript
import {Cmd} from "Sdk.Transformers";

arguments: [
    Cmd.option("/out:", Rules.cmdOutput(declaredArt)),
    Cmd.argument(Rules.cmdInput(srcArtifact))
]
```

Why: `Artifact.path` is now `@internal`. The `Rules.cmd*` helpers are the only sanctioned readers outside the SDK adapters. They also carry through Contract preconditions: `cmdInput` asserts `kind !== "unbound"`, and `cmdOutput` asserts `kind === "unbound"` (so source files and already-bound Artifacts can't be smuggled into the output position).

You can still import `{Cmd}` from `Sdk.Transformers` directly — `Cmd.argument`, `Cmd.option`, etc. are unchanged.

## 6. `dependencies` on `Actions.run`

**Before**:

```typescript
ctx.actions.run({ ..., dependencies: [someFile, anotherFile] });  // File[]
```

**After**:

```typescript
ctx.actions.run({ ..., dependencies: [someArt, anotherArt] });    // Artifact[]
```

`dependencies` accepts `Artifact[]` now. The adapter calls `Rules.getFile(...)` on each to feed BuildXL — which means **every dependency must already be bound** (sources are bound at construction; declared outputs become bound after the producing `run` returns). If you pass an unbound declared output, `getFile`'s Contract check fires.

## 7. `genrule`, `copy_file`, `filegroup`

If you call these from BUILD.dsc files, the call sites are unchanged. If you reach into their return types, these changed:

- `genrule(...)` — `result.outs` is now `Artifact[]` (was `DerivedFile[]`).
- `copy_file(...)` — return is `Artifact` (was `DerivedFile`).
- `copy_files(...)` — return is `Artifact[]` (was `DerivedFile[]`).
- `filegroup(...)` — `srcs` parameter type is `SourceArtifact[]` (label resolution still happens automatically when called via labels in BUILD files, but if you build a manual list, wrap each `f\`...\`` with `Rules.sourceArtifact(f\`...\`)`).

To unwrap to `File`, use `Rules.getFile(art)`.

## 8. `Provider` shapes

There's no enforced change — providers can carry whatever fields they like. Two soft conventions to consider:

- For outputs that downstream rules will inject into `cmdInput`, prefer carrying `Artifact` (so the consumer can pass straight to `cmdInput` without unwrapping). For outputs consumed only by code that then writes them to disk (logs, manifests), `File` is fine.
- `defaultInfo({ files: [...] })` now takes `Artifact[]`, so pass bound Artifacts directly.

## What did **not** change

- BUILD.dsc call sites (the user-facing Part 1 of the README): `csharp_library({ name, srcs, refs })` etc. all still take label-string arrays. The artifact split is invisible above the rule boundary.
- `Toolchain` — a field on the rule definition, accessed as `ctx.toolchain`. Per-target toolchain transitions (Buck2's "toolchains as configured deps") would require a value-level analog of BuildXL's syntactic `withQualifier` operator, which DScript does not offer; toolchains stay scoped to the rule definition.
- `select()`, `depset()`, `Provider`, `DefaultInfo`, `rule()` factory shape — same signatures.
- `Rules.Label` type and label string syntax — same.
- `Cmd.*`, `Tool.*` — unchanged BuildXL surface.

---

## Reference: minimal compiling rule, before vs. after

**Before:**

```typescript
import {Artifact, Cmd, Transformer} from "Sdk.Transformers";

interface MyResolved { name: string; srcs: File[]; }

export const my_compiler = Rules.rule({
    resolve: (attrs, r) => ({ name: attrs.name, srcs: r.resolveAll(attrs.srcs) }),
    impl: (ctx) => {
        const out = ctx.actions.declareFile(ctx.args.name + ".out");
        ctx.actions.run({
            tool: ctx.toolchain.compiler,
            outputs: [out],
            arguments: [
                Cmd.option("/out:", Artifact.output(out.path)),
                ...ctx.args.srcs.map(s => Cmd.argument(Artifact.input(s)))
            ]
        });
        return { kind: "MyResult", file: out, defaultInfo: Rules.defaultInfo({ files: [out] }) };
    }
});
```

**After:**

```typescript
import {Cmd} from "Sdk.Transformers";

interface MyResolved { name: string; srcs: Rules.SourceArtifact[]; }

export const my_compiler = Rules.rule({
    resolve: (attrs, r) => ({ name: attrs.name, srcs: r.resolveAll(attrs.srcs) }),
    impl: (ctx) => {
        const out     = ctx.actions.declareOutput(ctx.args.name + ".out");
        const [bound] = ctx.actions.run({
            tool: ctx.toolchain.compiler,
            outputs: [out],
            arguments: [
                Cmd.option("/out:", Rules.cmdOutput(out)),
                ...ctx.args.srcs.map(s => Cmd.argument(Rules.cmdInput(s)))
            ]
        });
        return {
            kind: "MyResult",
            artifact: bound,
            defaultInfo: Rules.defaultInfo({ files: [bound] })
        };
    }
});
```

The mechanical edits: `declareFile` → `declareOutput`; `Artifact.output(out.path)` → `Rules.cmdOutput(out)`; `Artifact.input(s)` → `Rules.cmdInput(s)`; destructure `Actions.run`'s return and use the bound result downstream; `srcs: File[]` → `srcs: SourceArtifact[]`; `defaultInfo` now carries the bound `Artifact` directly.
