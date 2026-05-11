# bxl_rules — A Build Rules Framework for BuildXL

bxl_rules is a DScript SDK that provides a structured way to define build rules in [BuildXL](https://github.com/microsoft/BuildXL). It's modeled after [Bazel's](https://bazel.build) rules system, bringing concepts like providers, labels, toolchains, and hermetic actions to BuildXL.

If you've used Bazel before, you'll recognize the patterns. If you haven't, this README introduces each concept from scratch.

> **Status — Buck2-shaped redesign.** Most of the SDK has been rewritten this cycle to apply Buck2's lessons-learned. **Configurations and Transitions**, **Artifacts**, **Actions**, **Anatomy of a Rule**, **select()**, and the **Bazel mapping table** all describe shipped behavior. The **Toolchains** section still describes the older "field on the rule definition" shape — toolchain-as-configured-dep is blocked on a BuildXL language gap (`importFrom` requires a string-literal module name; runtime resolution would need a value-level `importByName`). See [MIGRATION.md](MIGRATION.md) for the consumer-facing changes.

## Setup

Add bxl_rules to your `config.dsc`:

```typescript
config({
    resolvers: [
        {
            kind: "DScript",
            root: d`/path/to/bxl_rules`
        }
    ]
});
```

The `root` directive auto-discovers all modules in the directory.

---

## Part 1: Using Rules in BUILD.dsc Files

This section is for people writing BUILD.dsc files that call existing rules (e.g., `csharp_library`). You don't need to understand how rules are built — just how to call them.

### BUILD.dsc Files

A BUILD.dsc file declares build targets. Each target calls a rule with a set of attributes:

```typescript
import * as CSharp from "Sdk.Rules.CSharp";

@@public
export const myLib = CSharp.csharp_library({
    name: "MyLib",
    srcs: ["Foo.cs", "Bar.cs"],
    refs: ["//libs/System.Runtime:System.Runtime.dll"]
});
```

No file path construction, no compiler flags, no output directory management. The rule handles all of that.

### Labels

A **label** is a string that identifies a file in your workspace. You'll use labels everywhere in BUILD.dsc files — for source files, references, and dependencies.

```typescript
// File in the current directory (most common)
"Foo.cs"

// Explicit local reference (equivalent to above)
":Foo.cs"

// File in another directory (workspace-relative)
"//src/libs/MyLib:MyLib.dll"

// Convention: //path/to/directory:filename
```

Labels are just strings, but DScript's type system ensures you can't accidentally pass a label where a file object is expected, or vice versa. This prevents hardcoded absolute paths like `/home/user/code/...` from leaking into BUILD files.

**Resolution is mechanical:** `"//path/to/dir:file"` always maps to `{workspace_root}/path/to/dir/file`. There's no registry or configuration — the label *is* the path.

### Dependencies Between Targets

Use `deps` to depend on other targets. The rule automatically picks up the dependency's outputs:

```typescript
const lib = CSharp.csharp_library({ name: "Lib", srcs: ["Lib.cs"], ... });
const app = CSharp.csharp_binary({ name: "App", srcs: ["Main.cs"], deps: [lib] });
// App automatically gets Lib.dll as a reference
```

### Visibility

- `@@public export` — visible to other modules (like Bazel's `visibility = ["//visibility:public"]`)
- `export` without `@@public` — visible only within the same module

---

## Part 2: Writing New Rules

This section is for people creating new build rules — for a new language, a code generator, a test runner, etc. You'll use the `Sdk.Rules` module directly.

```typescript
import * as Rules from "Sdk.Rules";
```

### Anatomy of a Rule

A rule has three parts:

1. **Attributes** — the interface callers use (with `Label[]` for file references)
2. **Resolve** — a function that maps labels to files (tells the framework which fields are labels)
3. **Implementation** — the build logic (receives only resolved files, never labels)

```typescript
// 1. What callers pass
interface MyAttrs {
    name: string;
    srcs: Rules.Label[];     // labels — resolved by the framework
    optimize?: boolean;       // plain values — passed through as-is
}

// 2. What impl receives (labels resolved to source artifacts)
interface MyResolved {
    name: string;
    srcs: Rules.SourceArtifact[];
    optimize: boolean;
}

// 3. Define the rule
export const my_compiler = Rules.rule<MyAttrs, MyResolved, MyToolchain, MyResult>({
    doc: "Compile my language",
    toolchain: defaultToolchain,

    // Resolve: declare which fields are labels
    resolve: (attrs, resolver) => ({
        name: attrs.name,
        srcs: resolver.resolveAll(attrs.srcs),  // Label[] → SourceArtifact[]
        optimize: attrs.optimize || false
    }),

    // Impl: build logic — only sees resolved artifacts
    impl: (ctx) => {
        const out = ctx.actions.declareOutput(ctx.args.name + ".out");
        const outHandle = Rules.asOutput(out);
        const [boundOut] = ctx.actions.run({
            tool: ctx.toolchain.compiler,
            arguments: [
                Cmd.option("/out:", Rules.cmdOutput(outHandle)),
                ...ctx.args.srcs.map(s => Cmd.argument(Rules.cmdInput(s)))
            ],
            outputs: [outHandle]
        });
        return {
            kind: "MyResult",
            artifact: boundOut,
            defaultInfo: Rules.defaultInfo({ files: [Rules.getFile(boundOut)] })
        };
    }
});
```

**The key contracts:**
- The `resolve` function is the only place labels are turned into files. The `LabelResolver` is passed in by the framework — it's not importable or callable from anywhere else. This ensures all file references go through controlled resolution.
- Rule code never reaches through `art.path` or `Sdk.Transformers.Artifact.input/output` directly; `Rules.cmdInput` and `Rules.cmdOutput` are the sanctioned bridges to the BuildXL command-line layer. The underlying `path` field is `@internal` and only used by the SDK adapters in `providers.dsc` and `genrule.dsc`.

### Providers

A **provider** is a typed data structure that a rule returns. It carries outputs and metadata so downstream rules can consume them.

```typescript
// Define your provider
interface MyInfo extends Rules.Provider {
    kind: "MyInfo";      // discriminator tag (required)
    binary: File;        // your outputs
    deps: MyInfo[];      // for transitive dependency walking
}
```

Every rule should include a `DefaultInfo` — the universal provider that carries default outputs and runtime dependencies:

```typescript
return {
    kind: "MyInfo",
    binary: outputFile,
    deps: [],
    defaultInfo: Rules.defaultInfo({
        files: [outputFile],                    // default outputs
        runfiles: [outputFile, ...runtimeDeps]  // files needed at runtime
    })
};
```

### Actions

The `ctx.actions` API is how rule implementations declare outputs and run processes. It speaks in **Artifacts** end-to-end — see the *Artifacts* section below for the type details.

```typescript
// Declare an output (the framework decides where it goes)
const out = ctx.actions.declareOutput("output.dll");
const outHandle = Rules.asOutput(out);

// Run a process — returns the BOUND artifacts in the same order as outputs
const [outArt] = ctx.actions.run({
    tool: ctx.toolchain.compiler,
    arguments: [
        Cmd.option("/out:", Rules.cmdOutput(outHandle)),
        ...sources.map(s => Cmd.argument(Rules.cmdInput(s)))
    ],
    outputs: [outHandle],               // OutputArtifact, not raw path
    description: "compile: MyLib"
});

// outArt.kind === "bound"; Rules.getFile(outArt) is the produced DerivedFile
```

You can't pass raw paths as outputs — only `OutputArtifact` instances obtained from `Rules.asOutput(declaredArtifact)`. This ensures the framework controls output placement, prevents collisions between targets, and tracks bind/unbound state. Likewise, command-line construction goes through `Rules.cmdInput` / `Rules.cmdOutput` so rule code never touches the `@internal` `Artifact.path` field.

Other action helpers:
- `ctx.actions.writeFile(output, lines)` — write a text file (returns bound Artifact)
- `ctx.actions.copyFile(source, dest)` — copy an Artifact (returns bound Artifact)

### Artifacts

An **Artifact** is the unit rule code passes around when wiring inputs and outputs. It replaces the older `DeclaredOutput` and the bare `File` shape borrowed from BuildXL — both of which let rule code accidentally smuggle raw filesystem paths into the build graph.

There are three types, all branded so a bare object literal can't accidentally satisfy them:

```typescript
type ArtifactKind = "unbound" | "bound" | "source";

interface Artifact {                       // referenceable handle; may be unbound
    shortPath: string;                     // user-visible logical name
    extension: string;                     // ".dll", "" if none
    kind: ArtifactKind;                    // "unbound" | "bound" | "source"
    path: Path;                            // @internal — SDK adapters only; use Rules.cmdInput / cmdOutput
    boundFile?: DerivedFile;               // populated after Actions.run binds it
}

interface SourceArtifact extends Artifact { // wraps a workspace File; always bound
    kind: "source";                        // narrowed discriminator
    file: File;
}

interface OutputArtifact {                  // single-use binding handle
    artifact: Artifact;                     // @internal — SDK adapters only
}
```

`kind` is a string-literal discriminator (not paired booleans) so the day DScript narrows discriminated unions reliably, redefining `type Artifact = UnboundArtifact | BoundArtifact | SourceArtifact` — each variant pinning `kind` to a single literal — is a near-trivial change. Today the checker doesn't narrow on field values, so the bound/unbound precondition on `getFile`, `bindArtifact`, and `asOutput` is still enforced by `Contract.requires(...)` rather than statically.

**The lifecycle:** declare → bind → reference.

```typescript
const art = ctx.actions.declareOutput("foo.dll");   // Artifact, kind: "unbound"
const [bound] = ctx.actions.run({                    // bind via Actions.run
    outputs: [Rules.asOutput(art)],                  // single-use OutputArtifact
    ...
});
// bound.kind === "bound", bound.boundFile is the produced DerivedFile
```

**Source files** entering through label resolution are wrapped in `SourceArtifact` automatically by the framework (the `LabelResolver` returns `SourceArtifact`, not raw `File`):

```typescript
resolve: (attrs, resolver) => ({
    name: attrs.name,
    srcs: resolver.resolveAll(attrs.srcs),  // SourceArtifact[]
})
// ctx.args.srcs[i].file gives you the underlying File when a BuildXL
// primitive needs it; or use Rules.getFile(art) which works uniformly
// for source and bound artifacts.
```

**Cheat sheet:**
- `Rules.declareArtifact(targetDir, name, opts?)` — low-level factory (rule code uses `ctx.actions.declareOutput` instead).
- `Rules.sourceArtifact(file)` — wrap a workspace `File`.
- `Rules.asOutput(art)` — project an Artifact to its single-use binding handle. Rejects `SourceArtifact`s.
- `Rules.getFile(art)` — extract the underlying `File`/`DerivedFile`. Asserts `kind !== "unbound"`.
- `Rules.cmdInput(art)` — build a command-line input value. Wraps `Sdk.Transformers.Artifact.input(getFile(art))`.
- `Rules.cmdOutput(out)` — build a command-line output value. Wraps `Sdk.Transformers.Artifact.output(out.artifact.path)`; this is the *only* sanctioned reader of `Artifact.path` outside the SDK adapters.
- `Rules.bindArtifact(unbound, derivedFile)` — internal; the Actions adapter calls this. Most rule code does not.
- `Rules.artifactsEqual(a, b)`, `Rules.outputArtifactsEqual(a, b)` — undefined-safe equality.

### Toolchains

A **toolchain** bundles the tools a rule needs so they're not hardcoded in the build logic:

```typescript
// Define a toolchain type
interface CSharpToolchain extends Rules.Toolchain {
    compiler: File;
    hostExe: File;
}

// Create a concrete instance
const defaultToolchain: CSharpToolchain = {
    kind: "CSharpToolchain",
    name: "default",
    compiler: f`${sdkDir}/roslyn/csc.dll`,
    hostExe: f`${sdkDir}/dotnet`
};
```

The toolchain is declared in the rule definition and passed to `impl` via `ctx.toolchain`. Callers never see or configure it.

> **Future direction (currently blocked).** In Buck2, toolchains are top-level targets resolved via `attrs.exec_dep(...)`, which lets call-sites pick a toolchain instance per target and the framework apply the appropriate `ExecTransition`. The bxl_rules plan reserves the same shape, but BuildXL's `importFrom` requires a string-literal module name, which precludes value-level toolchain resolution. The current "field on the rule definition" shape stays in place until BuildXL exposes a value-level `importByName`.

### Depset (Transitive Dependencies)

`depset` walks a provider graph and collects a deduplicated transitive closure:

```typescript
const allDeps = Rules.depset(myLib, lib => lib.deps);
// Returns all transitive dependencies, post-order (deps before root)
```

Useful for collecting all transitive assemblies, include paths, or other dependency data.

### Macros

Not everything needs to be a `rule()`. A **macro** is a plain function that calls rules and adds repo-specific defaults — like a test macro that bakes in common dependencies:

```typescript
export function my_test(args: { name: string, srcs: Rules.Label[] }) {
    return CSharp.csharp_binary({
        name: args.name,
        srcs: args.srcs,
        refs: [...COMMON_TEST_DEPS],       // baked-in labels
        fileRefs: [...NUGET_XUNIT_REFS],   // baked-in NuGet files
        analyzers: [testGeneratorDll]
    });
}
```

Macros pass labels through to rules — they never resolve labels themselves.

### Configurations and Transitions

A **Configuration** describes how a target should be built — its platform (e.g., `linux-x64`), build mode (`debug`/`release`), and any other typed constraints. It's a value-shaped wrapper over BuildXL's qualifier:

```typescript
import * as Rules from "Sdk.Rules";

const cfg = Rules.fromQualifier(qualifier);
// cfg.platform        === "linux-x64"
// cfg.constraints     === [{setting: "mode", value: "debug"}]
// cfg.hash            === stable identity string
```

`Configuration` is the **only** sanctioned way to read what platform/constraints apply — there's no second mechanism that can disagree with it. Two Configurations are equivalent iff `configurationsEqual(a, b)` (which compares hashes).

**Reading constraint values:**

```typescript
const os = Rules.getConstraint(cfg, Rules.ConstraintSettings.os);
if (os === "linux") { ... }
```

Predefined platform labels live under `Rules.Platforms.*` (e.g., `Rules.Platforms.linuxX64`); predefined constraint setting names live under `Rules.ConstraintSettings.*` (`os`, `cpu`, `mode`).

**Transitions** describe how a dependency's Configuration relates to its consumer's. They're values, not magic strings:

```typescript
const targetCfg = Rules.fromQualifier(qualifier);
const execCfg   = Rules.ExecTransition.apply(targetCfg);
// execCfg.platform    === Rules.hostExecPlatform()  (where build tools run)
// execCfg preserves the mode constraint, drops target-specific ones
```

Predefined transitions:
- `Rules.IdentityTransition` — no-op; same Configuration as the consumer.
- `Rules.TargetTransition` — alias of identity. Use for readability when documenting "this dep stays in the target config."
- `Rules.ExecTransition` — switch to the host's exec platform. For build tools that must run on the build machine.

Transitions are **idempotent**: applying twice equals applying once. This matches Buck2's enforced contract.

**ConfiguredLabel** pairs a target string with the Configuration it should be evaluated under:

```typescript
const dep = Rules.withConfiguration("//tools:codegen", execCfg);
// dep.label         === "//tools:codegen"
// dep.configuration === execCfg
```

Two configured labels with the same string but different Configurations are distinct nodes in the dependency graph.

**Bazel-platforms-style multi-axis qualifiers (recommended for new workspaces).** Bazel's platform system lets you `select()` on individual constraints (`@platforms//os:linux`, `@platforms//cpu:arm64`) rather than on combined platform names. You can get the same ergonomics here by declaring your workspace qualifier as independent axes — `os`, `cpu`, and `configuration` — instead of a single `platform: "linux-arm64"` field. `Rules.fromQualifier` understands both shapes; the multi-axis form additionally projects each axis as its own constraint, so `Rules.getConstraint(cfg, Rules.ConstraintSettings.cpu) === "arm64"` Just Works without substring-matching the combined platform string.

Drop this into your top-level `config.dsc` (and adjust the union members to the OSes/CPUs your build actually supports):

```typescript
config({
    resolvers: [ /* ... */ ],
    qualifiers: {
        defaultQualifier: { os: "linux", cpu: "x64", configuration: "debug" },
        namedQualifiers: {
            "linux-x64-debug":     { os: "linux",   cpu: "x64",   configuration: "debug"   },
            "linux-x64-release":   { os: "linux",   cpu: "x64",   configuration: "release" },
            "linux-arm64-release": { os: "linux",   cpu: "arm64", configuration: "release" },
            "macos-arm64-debug":   { os: "macos",   cpu: "arm64", configuration: "debug"   },
            "windows-x64-debug":   { os: "windows", cpu: "x64",   configuration: "debug"   },
        },
    },
});
```

And in any module spec that needs to read the qualifier:

```typescript
export declare const qualifier: {
    os:            "linux" | "macos" | "windows" | "freebsd";
    cpu:           "x64"   | "x86"   | "arm64"   | "arm";
    configuration: "debug" | "release";
};

const cfg = Rules.fromQualifier(qualifier);
const isArm64 = Rules.getConstraint(cfg, Rules.ConstraintSettings.cpu) === "arm64";
```

`bxl /q:linux-arm64-release` (named) or `bxl /q:os=linux;cpu=arm64;configuration=release` (explicit) on the command line; `bxl` with no `/q:` uses the `defaultQualifier`.

**One key difference from Bazel.** Bazel's `@platforms` workspace ships the canonical OS/CPU constraint values (`@platforms//os:linux`, etc.), and any platform target your project defines just references those labels. We can't ship the equivalent: BuildXL requires the qualifier *type* to be declared per-workspace as a union of string literals (so the engine can enumerate the build matrix), and there's no DScript syntax for an SDK to inject a type into your namespace. Hence the paste-once snippet above. The OS/CPU label vocabulary inside it is a soft convention — pick whatever values you like, just stay consistent across your modules.

**Custom host labels for `ExecTransition`.** `Rules.ExecTransition` (the singleton) reports the host using BuildXL's three-bucket OS (`win` / `macOS` / `unix`), which is all `Context.getCurrentHost()` exposes — so on Linux, FreeBSD, or Haiku it reports `unix`. If your workspace's qualifier vocabulary uses finer labels (e.g., `os: "linux" | "freebsd"`), the singleton's emitted qualifier won't match the workspace type. Use `Rules.makeExecTransition({os, cpu})` to pin the host labels in code:

```typescript
const myExec = Rules.makeExecTransition({ os: "linux", cpu: "x64" });
const execCfg = myExec.apply(targetCfg);
```

**Caveat — language gap.** BuildXL's `withQualifier` is a syntactic construct on namespace imports, not a value-level call. So a Transition produces the new Configuration but cannot itself invoke `withQualifier`. The call-site contract today is:

```typescript
const newCfg = Rules.ExecTransition.apply(currentCfg);
import * as Tool from "Tool" withQualifier(newCfg.underlyingQualifier);
```

A later phase will hide this behind `attrs.dep(target, transition)` so users never write the import directly.

### select()

Configuration-based dispatch, like Bazel's `select()`. Use `Configuration` to look up the constraint you're switching on:

```typescript
const cfg = Rules.fromQualifier(qualifier);
const os  = Rules.getConstraint(cfg, Rules.ConstraintSettings.os);

const platformDeps = Rules.select(
    [["windows", winDeps], ["linux", linuxDeps]],
    (key) => key === os,
    defaultDeps
);
```

---

## Bazel Mapping

If you know Bazel, here's the quick correspondence:

| Bazel | bxl_rules |
|-------|-----------|
| `provider()` | `interface X extends Provider` |
| `DefaultInfo` | `DefaultInfo` |
| `depset()` | `depset()` |
| `rule(impl, attrs)` | `rule({ impl, resolve, toolchain })` |
| `attr.label_list()` | Fields in the `resolve` function |
| `ctx.actions.declare_file()` | `ctx.actions.declareOutput()` |
| `ctx.actions.run()` | `ctx.actions.run()` |
| `File` (input) | `Artifact` / `SourceArtifact` |
| `File` (output of action) | `Artifact` (with `boundFile`) |
| Buck2 `OutputArtifact` (`.as_output()`) | `OutputArtifact` (`Rules.asOutput(art)`) |
| `ctx.actions.args().add(file)` | `Cmd.argument(Rules.cmdInput(art))` |
| Bazel implicit output declaration via `args().add()` | `Cmd.argument(Rules.cmdOutput(out))` |
| `ctx.files.srcs` | `ctx.args.srcs` (pre-resolved `SourceArtifact[]`) |
| `toolchain_type` | `interface X extends Toolchain` |
| `"//pkg:target"` labels | `"//pkg:target"` labels (same syntax) |
| `select()` | `select()` |
| `Configuration` (Bazel/Buck2 platform info) | `Configuration` |
| `transition()` | `Transition` (value, not a string) |
| `cfg = "exec"` (Bazel) / `cfg.exec` (Buck2) | `Rules.ExecTransition` |
| Configured target label | `ConfiguredLabel` |
| `visibility = ["//visibility:public"]` | `@@public export` |
| Starlark (Python-like) | DScript (TypeScript-like) |

## Repo Structure

```
bxl_rules/
├── README.md
├── Rules/
│   ├── module.config.dsc       — Module declaration ("Sdk.Rules")
│   ├── configuration.dsc       — Configuration, fromQualifier, hostExecPlatform,
│   │                             Platforms.*, ConstraintSettings.*
│   ├── transition.dsc          — Transition, IdentityTransition,
│   │                             TargetTransition, ExecTransition
│   ├── configured_label.dsc    — ConfiguredLabel, withConfiguration,
│   │                             configuredLabelsEqual
│   ├── artifact.dsc            — Artifact, SourceArtifact, OutputArtifact,
│   │                             declareArtifact, sourceArtifact, asOutput,
│   │                             bindArtifact, getFile, cmdInput, cmdOutput
│   ├── providers.dsc           — Provider, DefaultInfo, depset, rule(),
│   │                             Actions, Label, LabelResolver, select
│   └── genrule.dsc             — genrule, filegroup, copy_file, copy_files
└── Tests/                      — DScript test specs (run via run-tests.sh)
```

## Related

- **[bxl_rules_csharp](../bxl_rules_csharp/)** — C# rules built on this framework
- **[BuildXL](https://github.com/microsoft/BuildXL)** — The underlying build engine
- **[Bazel](https://bazel.build)** — The build system this framework is modeled after
