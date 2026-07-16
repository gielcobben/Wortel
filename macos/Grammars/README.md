# Vendored tree-sitter scanners

These are **not** grammars we maintain — they're a narrow workaround for a build
bug in a few upstream tree-sitter grammar SPM packages.

## Why this exists

Diff syntax highlighting (`Wortel/Git/DiffHighlighter.swift`) pulls tree-sitter
grammars as SPM packages (see `project.yml`). Most grammars list their C sources
unconditionally and build fine. But a few — currently **css**, **javascript**,
**python** — guard the external scanner like this in their `Package.swift` (yaml has the same
bug, plus a scanner that `#include`s `schema.core.c`):

```swift
var sources = ["src/parser.c"]
if FileManager.default.fileExists(atPath: "src/scanner.c") {   // <- relative path
    sources.append("src/scanner.c")
}
```

That `fileExists` uses a path relative to the process working directory. Under
`swift build` the CWD is the package root and it works; under **Xcode's** manifest
evaluation the CWD is elsewhere, so the check returns false, `scanner.c` is never
compiled, and the app fails to link with:

```
"_tree_sitter_python_external_scanner_scan", referenced from:
    _tree_sitter_python.language in TreeSitterPython.o
ld: symbol(s) not found for architecture arm64
```

Only `scanner.c` is dropped — SPM still builds the (large) `parser.c` and ships
the `queries/`. So the fix is to compile just the missing scanner ourselves.

## What's here

- `scanners/<lang>_scanner.c` — a verbatim copy of that grammar's `src/scanner.c`.
- `include/tree_sitter/{parser.h,array.h,alloc.h}` — the runtime headers those
  scanners `#include` (identical across grammars for a given tree-sitter release).
- `include/schema.core.c` — yaml's scanner `#include`s this; it lives in the
  header search path (not `scanners/`) so it is pulled in by the scanner rather
  than compiled as its own translation unit.

`project.yml` compiles `scanners/` into the app target with
`HEADER_SEARCH_PATHS` pointing at `include/`. The scanner symbols are
language-prefixed (`tree_sitter_css_external_scanner_*`), so there's no collision
with each other or with SPM-built parsers, and each definition is referenced by
its SPM `parser.c` — nothing here is dead-stripped.

## Keeping this correct

The scanner and its `parser.c` must come from the **same grammar version**, or
the ABI between them can drift. So the three affected packages are pinned with
`exactVersion` in `project.yml`. **If you bump one of those versions, re-copy its
`src/scanner.c` here** (and the `tree_sitter` headers if the tree-sitter runtime
version changed). If a newly-added grammar link-fails on a missing
`*_external_scanner_*` symbol, it has the same bug — vendor its scanner the same
way and exact-pin it.
