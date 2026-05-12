# Migration guide — bxl_rules consumers

This guide lists the breaking changes shipped by the Buck2-shaped redesign of `bxl_rules` and shows the call-site updates needed to keep a consuming repo (e.g. `bxl_rules_csharp`) working.

If a section says "no change required", it's listed only so you can verify your assumptions.

---

## Quick checklist

- [ ] Replace `qualifier.<field>` reads with `Rules.fromQualifier(qualifier)` + `Rules.getConstraint(...)`.
- [ ] Replace static `cfg = "exec"` patterns with `Rules.ExecTransition.apply(cfg)`.
- [ ] Update `LabelResolver` consumers — `resolver.resolve(label)` now returns `SourceArtifact`, not `File`.
- [ ] Update rule `resolve` types — `srcs: File[]` → `srcs: SourceArtifact[]`.
- [ ] Replace `ctx.actions.declareFile(name)` with `ctx.actions.declareOutput(name)` (returns `Artifact`, not `DerivedFile`).
- [ ] Wrap each declared output with `Rules.asOutput(art)` before passing to `Actions.run.outputs`.
- [ ] Destructure the new `Artifact[]` return of `Actions.run` (was `DerivedFile[]`).
- [ ] Replace `Cmd.argument(Artifact.input(file))` with `Cmd.argument(Rules.cmdInput(art))`.
- [ ] Replace `Cmd.option("/out:", Artifact.output(declared.path))` with `Cmd.option("/out:", Rules.cmdOutput(outHandle))`.
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

**After** — apply a Transition value:

```typescript
const targetCfg  = Rules.fromQualifier(qualifier);
const execCfg    = Rules.ExecTransition.apply(targetCfg);
const codegenDep = Rules.withConfiguration("//tools:codegen", execCfg);
```

`Rules.IdentityTransition` / `Rules.TargetTransition` / `Rules.ExecTransition` are the predefined transitions. Custom ones can be defined as `<Transition>{ name, apply: cfg => ... }` and must be idempotent.

**Caveat (unchanged):** BuildXL's `withQualifier` is syntactic, so the rule code still has to do:

```typescript
import * as Tool from "Tool" withQualifier(execCfg.underlyingQualifier);
```

This will eventually be hidden behind `attrs.dep(target, transition)`, but that requires a BuildXL language change (no value-level analog of the syntactic `withQualifier` operator exists today). Until that gap is closed, rule code must emit the `withQualifier` import explicitly at the call site.

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

**After** — `declareOutput` returns an unbound `Artifact`; wrap with `asOutput` for the action; consume the bound `Artifact` returned by `run`:

```typescript
const out      = ctx.actions.declareOutput("foo.dll");    // Artifact, kind: "unbound"
const outHdl   = Rules.asOutput(out);                     // OutputArtifact (single-use)
const [bound]  = ctx.actions.run({                        // returns Artifact[] (bound)
    outputs: [outHdl],
    arguments: [Cmd.option("/out:", Rules.cmdOutput(outHdl))]
});
const outFile: File = Rules.getFile(bound);               // the produced DerivedFile
```

Three things changed:
- The return of `declareOutput` is unbound. It becomes bound only after `run` returns. Don't carry the unbound value forward — use the value `run` returns.
- `outputs: [...]` takes `OutputArtifact[]`, not `Artifact[]` and not `Path[]`. Wrap with `Rules.asOutput`.
- `run` returns the bound `Artifact[]` in the same order as `outputs`. Destructure to wire downstream.

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
    Cmd.option("/out:", Rules.cmdOutput(outHandle)),
    Cmd.argument(Rules.cmdInput(srcArtifact))
]
```

Why: `Artifact.path` is now `@internal`. The `Rules.cmd*` helpers are the only sanctioned readers outside the SDK adapters. They also carry through the `getFile`-style `kind !== "unbound"` Contract check on inputs.

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
- `defaultInfo({ files: [...] })` still takes `File[]`, so use `Rules.getFile(art)` when populating it from bound Artifacts.

## What did **not** change

- BUILD.dsc call sites (the user-facing Part 1 of the README): `csharp_library({ name, srcs, refs })` etc. all still take label-string arrays. The artifact split is invisible above the rule boundary.
- `Toolchain` — still a field on the rule definition, accessed as `ctx.toolchain`. Wiring toolchains in as configured deps (Buck2-style) would require value-level transitions at the import boundary, which is the same BuildXL language gap that blocks `attrs.dep(target, transition)`.
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
        const out      = ctx.actions.declareOutput(ctx.args.name + ".out");
        const outHdl   = Rules.asOutput(out);
        const [bound]  = ctx.actions.run({
            tool: ctx.toolchain.compiler,
            outputs: [outHdl],
            arguments: [
                Cmd.option("/out:", Rules.cmdOutput(outHdl)),
                ...ctx.args.srcs.map(s => Cmd.argument(Rules.cmdInput(s)))
            ]
        });
        return {
            kind: "MyResult",
            artifact: bound,
            defaultInfo: Rules.defaultInfo({ files: [Rules.getFile(bound)] })
        };
    }
});
```

The mechanical edits: `declareFile` → `declareOutput`; introduce `outHdl = asOutput(out)`; `outputs: [out]` → `outputs: [outHdl]`; `Artifact.output(out.path)` → `Rules.cmdOutput(outHdl)`; `Artifact.input(s)` → `Rules.cmdInput(s)`; destructure `Actions.run`'s return; `srcs: File[]` → `srcs: SourceArtifact[]`; `defaultInfo` files via `Rules.getFile(bound)`.
