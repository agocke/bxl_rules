# bxl_rules — A Build Rules Framework for BuildXL

bxl_rules is a DScript SDK that provides a structured way to define build rules in [BuildXL](https://github.com/microsoft/BuildXL). It's modeled after [Bazel's](https://bazel.build) rules system, bringing concepts like providers, labels, toolchains, and hermetic actions to BuildXL.

If you've used Bazel before, you'll recognize the patterns. If you haven't, this README introduces each concept from scratch.

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

// 2. What impl receives (labels resolved to files)
interface MyResolved {
    name: string;
    srcs: File[];
    optimize: boolean;
}

// 3. Define the rule
export const my_compiler = Rules.rule<MyAttrs, MyResolved, MyToolchain, MyResult>({
    doc: "Compile my language",
    toolchain: defaultToolchain,

    // Resolve: declare which fields are labels
    resolve: (attrs, resolver) => ({
        name: attrs.name,
        srcs: resolver.resolveAll(attrs.srcs),  // Label[] → File[]
        optimize: attrs.optimize || false
    }),

    // Impl: build logic — only sees resolved files
    impl: (ctx) => {
        const output = ctx.actions.declareFile(ctx.args.name + ".out");
        const [outputFile] = ctx.actions.run({
            tool: ctx.toolchain.compiler,
            arguments: [
                Cmd.option("/out:", Artifact.output(output.path)),
                ...ctx.args.srcs.map(s => Cmd.argument(Artifact.input(s)))
            ],
            outputs: [output]
        });
        return {
            kind: "MyResult",
            file: outputFile,
            defaultInfo: Rules.defaultInfo({ files: [outputFile] })
        };
    }
});
```

**The key contract:** the `resolve` function is the only place labels are turned into files. The `LabelResolver` is passed in by the framework — it's not importable or callable from anywhere else. This ensures all file references go through controlled resolution.

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

The `ctx.actions` API is how rule implementations declare outputs and run processes:

```typescript
// Declare an output (the framework decides where it goes)
const out = ctx.actions.declareFile("output.dll");

// Run a process — returns produced files in the same order as outputs
const [outputFile] = ctx.actions.run({
    tool: ctx.toolchain.compiler,
    arguments: [
        Cmd.option("/out:", Artifact.output(out.path)),
        ...sources.map(s => Cmd.argument(Artifact.input(s)))
    ],
    outputs: [out],
    description: "compile: MyLib"
});
```

You can't pass raw paths as outputs — only `DeclaredOutput` instances from `declareFile`. This ensures the framework controls output placement and prevents collisions between targets.

Other action helpers:
- `ctx.actions.writeFile(output, lines)` — write a text file
- `ctx.actions.copyFile(source, dest)` — copy a file

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

### select()

Configuration-based dispatch, like Bazel's `select()`:

```typescript
const platformDeps = Rules.select(
    [["windows", winDeps], ["linux", linuxDeps]],
    (key) => qualifier.targetRuntime.includes(key),
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
| `ctx.actions.declare_file()` | `ctx.actions.declareFile()` |
| `ctx.actions.run()` | `ctx.actions.run()` |
| `ctx.files.srcs` | `ctx.args.srcs` (pre-resolved `File[]`) |
| `toolchain_type` | `interface X extends Toolchain` |
| `"//pkg:target"` labels | `"//pkg:target"` labels (same syntax) |
| `select()` | `select()` |
| `visibility = ["//visibility:public"]` | `@@public export` |
| Starlark (Python-like) | DScript (TypeScript-like) |

## Repo Structure

```
bxl_rules/
├── README.md
├── Rules/
│   ├── module.config.dsc   — Module declaration ("Sdk.Rules")
│   ├── providers.dsc       — Provider, DefaultInfo, depset, rule(),
│   │                         Actions, Label, LabelResolver, select
│   └── genrule.dsc         — genrule, filegroup, copy_file, copy_files
```

## Related

- **[bxl_rules_csharp](../bxl_rules_csharp/)** — C# rules built on this framework
- **[BuildXL](https://github.com/microsoft/BuildXL)** — The underlying build engine
- **[Bazel](https://bazel.build)** — The build system this framework is modeled after
