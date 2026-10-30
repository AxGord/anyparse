# anyparse

**Structural tooling for source code: query, refactor, format and lint through typed ASTs, not text.**

[User guide](docs/guide/README.md) · [Lint rules](docs/lint-rules.md) · [Roadmap](docs/roadmap.md)

anyparse parses source into a typed AST and builds tools on top of it:

- **`hxq`** — a command-line tool that finds code by its *shape* and edits it with
  scope-correct, re-parse-validated operations. Everything outside the edited span
  stays byte-for-byte intact.
- **A formatter and a linter** — one writer formats the tree it parsed; lint rules
  report findings and fix the mechanical ones in place.
- **A grammar platform** — describe a format or a language as Haxe types with metadata,
  and a macro generates a specialized parser, writer and tree transform for it.

The tools are safe to drive from scripts and coding agents: every command takes stable
addresses (`--select 'FnMember:area'`, `--match 'a * $b'`, or `line:col`), prints JSON
on request, and refuses a rewrite that does not re-parse rather than writing it.

## What it can do

The examples below use one file, `Sample.hx`:

```haxe
class Sample {
	public function area(width:Int, height:Int):Int {
		var total = width * height;
		if (total == 0) {
			return 0;
		} else {
			return total;
		}
	}
}
```

### Find code by structure

```sh
$ hxq search '$a * $b' Sample.hx          # every multiplication, operands captured
Sample.hx:
  3:15: match (a=width, b=height)

$ hxq refs total Sample.hx                # declarations, reads and writes, scope-resolved
Sample.hx:
  3:3: [decl] total
  4:7: [read] total -> 3:3
  7:11: [read] total -> 3:3
```

Also: type uses (`uses`), change impact of a type (`blast`), every mention of a name
(`mentions`), string and comment text (`lit`), `#if` branches under a define (`cond`),
an approximate call graph (`callers`, `callees`, `reach`). → [Querying](docs/guide/query.md)

### Refactor with scope awareness

```sh
$ hxq rename Sample.hx --select 'FnMember:area >> VarStmt:total' prod --write
$ hxq change-sig Sample.hx --select 'FnMember:area' 1,0 --write   # reorder params + in-file call sites
```

Rename (in a file or across a project), inline, extract variable / method / constant /
interface / superclass, move a type or a member, pull up / push down, safe delete,
encapsulate a field, introduce a parameter object. → [Refactoring](docs/guide/refactoring.md)

### Edit at an AST address

```sh
$ hxq patch Sample.hx --select 'FnMember:area' --write - <<'EOF'
return total;
====
return total * 2;
EOF
```

Insert, replace and remove members, statements, imports, metadata and doc comments; each
edit is re-emitted through the writer and checked before it is written. The same ops edit
JSON files in place, keeping their layout. → [Editing](docs/guide/editing.md)

### Format

```sh
$ hxq fmt src/ --list        # files that drift from canonical form
$ hxq fmt src/ --write       # rewrite them
```

Reads the project's `hxformat.json`. A file whose comment would be lost is left untouched
and reported. → [Formatting](docs/guide/formatting.md) · [hxformat.json values](docs/haxe-format-config.md)

### Lint and fix

```sh
$ hxq lint Sample.hx --all
Sample.hx:
  1:1: [info] public type 'Sample' has no doc comment (doc-coverage)
  3:3: [info] local 'total' is never reassigned; use final (prefer-final)
  6:10: [info] this else is redundant — the if branch always exits (redundant-else-after-return)

$ hxq lint Sample.hx --fix
```

```haxe
class Sample {
	public function area(width:Int, height:Int):Int {
		final total = width * height;
		return total == 0 ? 0 : total;
	}
}
```

Close to two hundred rules: unused code, imports, null flow, redundant casts and
conditions, loop and branch simplifications, naming, member order, documentation,
thread-context analysis. Configured per directory with `apqlint.json`; can use the Haxe
compiler as an oracle that checks every risky fix before keeping it.
→ [Lint](docs/guide/lint.md) · [Rules](docs/lint-rules.md) · [Configuration](docs/guide/lint-config.md)

### Describe a grammar, get a parser and a writer

```haxe
@:peg @:schema(anyparse.grammar.json.JsonFormat) @:ws
enum JValue {
	@:lit('null') JNull;
	@:lit('true', 'false') JBool(v:Bool);
	JNumber(v:JNumberLit);
	JString(v:JStringLit);
	@:lead('[') @:trail(']') @:sep(',', tailRelax) JArray(items:Array<JValue>);
	@:lead('{') @:trail('}') @:sep(',', tailRelax) JObject(entries:Array<JEntry>);
}

@:build(anyparse.macro.Build.buildParser(anyparse.grammar.json.JValue))
class JValueParser {}

@:build(anyparse.macro.Build.buildWriter(anyparse.grammar.json.JValue, anyparse.grammar.json.JValueWriteOptions))
class JValueWriter {}
```

`JValueParser.parse(text)` returns a `JValue`; `JValueWriter` prints one back through a
Wadler-style document IR. Each grammar can be built in two modes from one source: **Fast**
(plain types, throws on error) and **Tolerant** (spans, error collection, for tools).
Grammars shipped: Haxe (the one behind `hxq`), JSON, S-expressions, Mermaid and the `ar`
binary archive. → [The grammar platform](docs/guide/grammar.md) · [Architecture](docs/architecture.md)

## Install

Requires [Haxe](https://haxe.org) 4.3, Node.js and the `hxnodejs` haxelib.

```sh
git clone https://github.com/AxGord/anyparse
cd anyparse
haxelib install hxnodejs
haxe bin/apq-js.hxml                  # builds bin/apq.js
ln -s "$PWD/bin/hxq" ~/.local/bin/hxq # put hxq on PATH
```

`hxq` is `apq` with the Haxe grammar preselected; inside this repository it rebuilds the
engine when `src/` changes. → [Getting started](docs/guide/getting-started.md)

## Quickstart

```sh
hxq ast Sample.hx --select 'FnMember:area'   # look at the tree
hxq search 'trace($x)' src/                  # find by shape
hxq lint src/ --rule unused-import --fix     # fix one rule across a tree
hxq --help                                   # every command
hxq <command> --help                         # the flags of one
```

## Status

Phase 3 of the [roadmap](docs/roadmap.md): the Haxe grammar, writer and tooling are in daily
use on this repository's own source. Query and refactoring commands work on Haxe (and the
edit ops on JSON); other languages arrive as grammar plugins. The Haxe writer is gated
against the haxe-formatter test corpus with a no-regression rule.

Not goals: an automatic cross-language translator, a native code backend, a
background-incremental parser. → [Design principles](docs/design-principles.md)

## Contributing

Build and run the suite with `haxe test-js.hxml && node bin/test.js` (js/node is the only
runner); the test layers, gates and tooling are in [docs/testing.md](docs/testing.md).
Where each document lives and what may go into it: [docs/README.md](docs/README.md). A new
feature is documented in [docs/guide/](docs/guide/README.md), never in this file.

## License

MIT. See [LICENSE](LICENSE).
