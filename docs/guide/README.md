# User guide

How to use `hxq` / `apq`: what each command does, how to configure it, what every lint rule reports. The flags of
any command are its `--help`; the CLI contract (exit codes, pattern and selector syntax, JSON schemas) is
[`cli-query-tool.md`](../cli-query-tool.md).

- [Getting started](getting-started.md) — install, the `hxq` launcher, a first query and rewrite
- [Structural query](query.md) — the read-only commands: find by shape, by binding, by type use, the call graph
- [Scope-correct refactoring](refactoring.md) — rename, inline, extract, move, change a signature
- [Editing at an AST address](editing.md) — insert and replace code, structural search-and-replace, JSON files
- [File creation and formatting](formatting.md) — `new`, `fmt`, and the guards every rewrite passes
  ([`hxformat.json` values](../haxe-format-config.md))
- [Lint](lint.md) — running the checks, `--fix`, suppression, report formats
- [Lint configuration](lint-config.md) — every `apqlint.json` key
- Lint rules — the [index by category](../lint-rules.md) (generated from the registry), and each rule's prose:
  [`imports`](lint/imports.md) · [`docs`](lint/docs.md) · [`naming`](lint/naming.md) ·
  [`nullsafety`](lint/nullsafety.md) · [`types`](lint/types.md) · [`members`](lint/members.md) ·
  [`unused`](lint/unused.md) · [`control`](lint/control.md) · [`loops`](lint/loops.md) ·
  [`literals`](lint/literals.md) · [`expressions`](lint/expressions.md) · [`design`](lint/design.md)
- [The grammar platform](grammar.md) — grammars as Haxe types, the generated parser and writer, design goals
