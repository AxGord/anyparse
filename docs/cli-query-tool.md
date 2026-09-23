# CLI query tool (`apq` / `hxq`)

This document is the CONTRACT of the CLI built on top of anyparse: the exit-code convention, every registered command with its synopsis and the refusals its `--help` does not state, and the syntaxes shared across commands (pattern, selector, addressing, JSON). The phased work plan lives in [cli-query-roadmap.md](cli-query-roadmap.md). Per-command flags are NOT retold here — `apq <command> --help` is the flag reference, generated from the same code that parses them, and it is authoritative. Every measurement taken while these contracts were built lives in [`journal/cli-query-log.md`](journal/cli-query-log.md).

## What this is

A command-line tool over source files in any language anyparse has a grammar for: structural search, navigation, metadata indexing, lint, and scope-correct source rewriting. The engine is parameterised over `(GrammarPlugin, ParseResult, Query)` — nothing in the engine references concrete AST node types of any single language (§ "Universalization invariant"). Day-1 scope is Haxe-only, but adding the next language is a config-only change (a preset alias + the grammar plugin itself), not a code change in the query engine. Three of v1's five "NOT" decisions have since been lifted — the rewriting ops, the call graph (`callees` / `callers` / `reach`) and project resolution (`resolutionRoots`, the compiler oracle's hxml) shipped; type resolution is confined to the lint layer's `TypeResolver` (`refs` / `rename` stay lexical), and it is still not an LSP — a one-shot CLI per invocation. The journal records the v1 scope as it stood.

## Naming convention

- `apq` is the engine and the canonical binary name. It always takes a `--lang <name>` argument selecting the grammar plugin.
- `hxq` is a thin alias that pre-selects the Haxe grammar: `hxq <args>` is `apq --lang haxe <args>`.

Future language presets follow the same pattern: `as3q`, `pyq`, etc. Each preset is a one-line alias; the engine binary is always `apq`.

## Exit codes

`anyparse.query.ExitCode`: **0** success, **2** usage error (`EXIT_USAGE`), **1** runtime error or refusal (`EXIT_RUNTIME`). The conventions every command follows:

- An ARGV fault — a flag given no value, a `--limit` that is not a non-negative integer, a `--lang` naming no registered plugin, a `--kind` / `--select` segment naming a kind the grammar does not project — raises `UsageFailure`, which `Cli.run` catches: one sentence on stderr, named with the subcommand, and exit 2. A plain `throw` from a command module still reaches `main` as a raw stack, which is what an internal bug wants; a new flag read through `CliArgs.expectValue` inherits the usage path, a hand-rolled `throw` does not.
- An unknown subcommand prints two lines — the miss with the nearest real names (`apq: unknown subcommand "members" — did you mean: add-member, move-member, remove-member?`) and where the full list is — never the whole help page. The ranking is `CliWalk.findFuzzy` (contiguous substring, then Levenshtein within 3), the same matcher the walkers' own did-you-mean uses, plus one plural probe in `CliRegistry.nearest`; nothing close enough means no clause at all rather than a fabricated one.
- A read-only walker exits 0 on zero hits — an absence is an answer — unless `--exit-on-empty` (alias `--require-match`) is passed. A mutation op exits 1 on every refusal, and every refusal is ONE stderr line; a mutation op without `--write` is PRINT-ONLY and exits 0.
- `lint` exits 1 when `--fail-on <sev>` selects a severity present in the findings, when the scope matches no `.hx`, when the compiler oracle REJECTS the tree in report mode (`apq lint: compiler oracle REJECTED — build does not typecheck`), and under `--fix` when the safe pass had to revert (`docs/testing.md` § "The safe pass reverts the file the compiler blames, not the wave"); `lint-diff` exits 1 when the snapshots disagree and 2 when it could not compare at all; `mutation-verdict` exits 0 for every verdict (its exit answers "could this be classified"); `fmt` exits non-zero if any file failed to parse, could not be written, or (under `--one-pass`) did not settle in one rewrite; `self-status --strict` exits non-zero on any skip-parse; `test-summary` exits 1 when it finds no report at all, and 1 on an `--exit-status` disagreement.

## Command surface

The registry is `anyparse.query.cli.CliRegistry`; `apq --help` prints it. The tables below list every registered command with its synopsis as `--help` prints it; the contract paragraphs that follow cover what `--help` does not say. `show` is an alias of `source` for a sandbox that vetoes that word.

### Read-only walkers

Multi-file by construction: every scope argument is a file, a directory (walked recursively for `.hx`) or a glob resolved in-process (§ "Input path forms"). Output is grouped by file (`<file>:` then indented `<line>:<col>: <hit>`); `--flat` gives one `<file>:<line>:<col>: <hit>` per line. Every walker caps at 500 hits without `--limit N` and says so. An unparseable file is skipped, and `self-status` is the command that lists the skipped set.

| command | synopsis | contract beyond `--help` |
|---|---|---|
| `ast` | `apq ast [options] <file> \| --code <s> \| --stdin` | § "`apq ast`" — `--depth` counts from the DISPLAYED root; `--spans` are CODEPOINTS; `--type-refs` is a second projection; `--select` on an unprojected kind exits 2 with empty stdout |
| `probe` | `apq probe <code> [ast-options]` | `ast` over inline source; stages the bytes to a per-process slot and prints the path (§ "`apq probe`: the staged scratch slot") |
| `search` | `apq search [options] <pattern> <file-or-dir-or-glob>` | § "Pattern syntax for `search`"; a degenerate single-leaf pattern gets a stderr nudge and runs anyway |
| `refs` | `apq refs [options] <name> <file-or-dir-or-glob>...` | § "`apq refs`" — VALUE bindings, lexical scope, no member access; `--json` takes ONE name |
| `uses` | `apq uses [options] <type-name> <file-or-dir-or-glob>...` | § "`apq uses`" — TYPE positions; a simple name also answers a qualified spelling's last segment; text output only |
| `meta` | `apq meta [<annotation>[(<arg>)]] [options] <file-or-dir-or-glob>...` | § "`apq meta`" — the target language's own annotation syntax; `--on <kind>` lists every annotation on a kind |
| `blast` | `apq blast [options] <type-name> <file-or-dir-or-glob>...` | `uses` + `refs` + heuristic `.field` access; the heuristic section is capped at 20 hits unless `--all` |
| `lit` | `apq lit [options] <text> <file-or-dir-or-glob>...` | § "`apq lit`" — string-content leaves in every quote spelling by default; `--include-comments` / `--include-directives` / `--any-kind`; mints `Comment` and `Directive` |
| `mentions` | `apq mentions [options] <name> <file-or-dir-or-glob>...` | `uses` + `refs` + `lit --any-kind --exact` in three sections; a dotted path is ONE leaf, so an import is found only by its full spelling |
| `cases` | `apq cases <Ctor> <file-or-dir-or-glob>... [--flat] [--limit N]` | case-pattern lookup only (`case Ctor:` / `case Ctor(_):` / `case A \| Ctor:`); no `--kind` |
| `cond` | `apq cond <DEFINE> <file-or-dir-or-glob>... [options]` | § "`apq cond`" — branch bodies by DIRECTIVE, parse-free, three-valued liveness tags |
| `symbols` | `apq symbols <scope...> [options]` | top-level type declarations across a scope; `--kind` is vocabulary-checked |
| `importers` | `apq importers <module> <scope...> [options]` | files importing a module |
| `declares` | `apq declares <type> <scope...> [options]` | declaration site(s) of ONE type by simple name or qualified path; more than one row = ambiguous, none = not declared |
| `callees` / `callers` | `apq callees <Type.method\|method> <file-or-dir-or-glob>... [options]` / `apq callers <Type.method\|method> <file-or-dir-or-glob>... [options]` | approximate call graph (name + declared-type resolution, virtual edges, `Ref` edges for lambdas / `.bind`); a `callers` result with no edge and unresolved sites in scope SAYS it is not proof of absence |
| `reach` | `apq reach --from <Type.method> --to <Type.method\|Type.*> <file-or-dir-or-glob>... [options]` | shortest call path per pair; `--to` repeatable |
| `clusters` | `apq clusters <TypeName> <file-or-dir-or-glob>... [options]` | connected components over intra-type call edges after top-fan-in hubs go to a utils bucket (`--hubs N`, `0` = off); scope the type's OWN package, never the whole tree |
| `gates` | `apq gates [<file-or-dir-or-glob>...] [--flat] [--limit N] [--mechanism <name>]` | `@:fmt(trailOptParseGate/trailOptShapeGate)` annotations + predicate names (parser-dev) |
| `self-status` | `apq self-status [<file/dir/glob>...] [--strict] [--source]` | every `.hx` the plugin cannot parse, `SKIP <path> :: LINE:COL expected="<X>"`; `--strict` is the CI guard |

### Reading one file

| command | synopsis | contract beyond `--help` |
|---|---|---|
| `source` / `show` | `apq source [options] <file>   (alias: apq show)` | raw lines, no parse, DEDENTED by the printed window's minimum indentation; `--select` is repeatable and prints in document order; a file over the line budget with no `--range` / `--select` / `--at` is REFUSED with a selector menu, exit 2 (§ "Several queries in one walk, the progress gate, and the whole-file read guard"); a `--select` miss exits 1 |
| `diff` | `apq diff [options] <a> <b>` | structural AST diff between two files (`--flat`, `--limit N`) |
| `writer-equals` | `apq writer-equals [options] <input> <expected>` | byte-equality of the writer's output against a file (`--plain` for the plain writer); reads a `.hxtest` section |
| `writer-probe` | `apq writer-probe [options] <file>` | trivia and plain writer outputs side by side |
| `strip` | `apq strip [options] <file> [<file2> ...] --replace <pat> --with <repl> [...]` | sed-strip + parse-check; explicitly multi-file, takes no directory or glob; `--dry-run` is the typo guard |
| `recon` | `apq recon [<dir>] [--top N \| --all] [--cluster <substr> [--source]]` | skip-parse drill over a corpus (default `$ANYPARSE_HXFORMAT_FORK/test/testcases`), `--probe <file> [--writer-equals]` for one file; caches the fork path per USER under `$HOME/.config/anyparse/fork_path` |
| `sweep` | `apq sweep [--file <path>] [--prev <path>] [--diff <path>] [--save <path>]` | READS the corpus snapshot the suite wrote; `--run` re-derives it (`docs/testing.md` § "Reproducing the corpus census: `apq sweep --run`"); a pathless `--diff` defaults to `bin/.prev-sweep.json`, which the corpus harness rotates before every write, and the run says so (`… this compared the last two runs of this tree, not a change against its base`) — a slice gate names the base snapshot it saved with `--save` |

### Lint and the analysis layer

| command | synopsis | contract beyond `--help` |
|---|---|---|
| `lint` | `apq lint <scope...> [options]` | § "`apq lint`"; `--list-rules` prints every REGISTERED check, not what runs here; `--fix` writes in place with no `--write` and reports EDIT SPANS; `--baseline` is refused with `--fix` (`apq lint: --baseline narrows the REPORT and cannot be combined with --fix (--range narrows both)`) |
| `lint-diff` | `apq lint-diff --old <a.json> --new <b.json> [--root <prefix>] [--label <name>]` | multiset diff over `(file, rule, severity, message)`; exit 1 = disagree, 2 = could not compare (`docs/testing.md` § "`apq lint-diff` — the blast-radius gate") |
| `oracle` | `apq oracle <scope>` | one COLD typecheck, verdict recorded under the content fingerprint; cannot lie (`docs/testing.md` § "`apq oracle` — the battery's hand-off") |
| `stdlib-dup` | `apq stdlib-dup <scope...> [options]` | pure functions a differential run proves equal to a stdlib call; stages its probe under `<temp root>/apq-stdlib-dup.<pid>` and announces it (`--work <dir>` names it outright) |

### Suite and battery tooling

| command | synopsis | contract beyond `--help` |
|---|---|---|
| `mutation-verdict` | `apq mutation-verdict <transcript> [--expect <csv>]` | KILLED / SURVIVED / MISMATCH / … from a utest transcript; `--build <log>` names a BUILD-FAIL cause; every verdict exits 0 (`docs/testing.md` § "Verdicts") |
| `shard-plan` | `apq shard-plan (--runner <RunTests.hx> \| --classes <list>) --shards <N>` | refuses a plan whose union is not the registration list, a substring-collision pair, an empty shard, an unregistered sticky class (`docs/testing.md` § "Parallel shards: one suite, N processes") |
| `test-summary` | `apq test-summary [<file> \| -] [--exit-status <N>]` | parses a utest transcript into counts; no path default (`$APQ_TEST_OUT` or a usage error); `apq test-summary: no report found in "…"` exits 1; `-` truncates a large pipe, so write the log to a file first |

### Refactoring ops — span-splice, format-preserving

Scope-correct edits driven by the `refs` / `Scope` binding resolver: everything outside the edit is byte-verbatim (these move EXISTING tokens, so no new code is formatted), and the result is re-parse-validated. Every op is print-only without `--write`. Cursor positions are 1-based `line:col`, and every op that addresses a node accepts the address forms of § "Op addressing" (`--select` / `--match` / `--nth` / position).

| command | synopsis |
|---|---|
| `rename` | `apq rename <file> (<line>:<col> \| --select '<sel>' \| --match '<pattern>') <newName> [--write] [--scope <dir>]` — refuses a rename that re-binds an occurrence (a de-prefixing rename whose new name a parameter holds; `--qualify-shadowed` writes `this.x = x` for the parameter idiom), a `$name` interpolation read, and a same-block redeclaration; a bare `$name` macro reification splice is neither renamed nor refused |
| `inline` | `apq inline <file> (<line>:<col> \| --select '<sel>' \| --match '<pattern>') [--write]` |
| `inline-method` | `apq inline-method <file> (<line>[:<col>] \| --select 'FnMember:<name>' \| --match '<pattern>') [options]` |
| `extract-var` | `apq extract-var <file> (<line>:<col> \| --match '<expr-pattern>') <name> [--write]` |
| `add-param` | `apq add-param <file> (<line>[:<col>] \| --select 'FnMember:<name>' \| --match '<pattern>') <paramText> [--write]` |
| `change-sig` | `apq change-sig <file> (<line>:<col> \| --select 'FnMember:<name>' \| --match '<pattern>') <perm>  (perm = comma-separated 0-based new order, e.g. 2,0,1)` |
| `remove-param` | `apq remove-param <file> (<line>:<col> \| --select 'FnMember:<name>' \| --match '<pattern>') <index> [--write]  (index = 0-based parameter to remove)` |
| `move` | `apq move <file> (<line>:<col> \| --select 'ClassDecl:<Name>' \| --match '<pattern>') <dest-file> --scope <dir> [--write]` — a type to another file; importers repointed, a `using` carried |
| `move-member` | `apq move-member <srcFile> <member[,member...]> --to <DestType> --scope <dir> [options]` — any package if all static; `--closure` / `--scaffold` |
| `extract-interface` | `apq extract-interface <srcFile> <IfaceName> [options]` |
| `pull-up` / `push-down` | `apq pull-up <srcFile> <member> --to <superclass> --scope <dir> [options]` / `apq push-down <srcFile> <member> --to <subclass> --scope <dir> [options]` |
| `extract-superclass` | `apq extract-superclass <srcFile> <SuperName> --members m1,m2 [options]` |
| `make-final` | `apq make-final <file> <field> [--scope <dir>] [options]` — a never-reassigned `var` field to `final` |
| `introduce-parameter-object` | `apq introduce-parameter-object <file> (<l>:<c> \| --select \| --match) --params a,b --as <TypeName> [options]` |

The move family (`move`, `move-member`, `pull-up`, `push-down`) is the one op family no lint or fmt gate exercises; `test/unit/query/MoveFamilyCaptureTest.hx` pins its bytes (`docs/testing.md` § "The move family: the one op family with its own byte capture").

### Writer-emit ops — canonical-gated

These introduce NEW code, so the raw text is placed and the WHOLE file is re-emitted through the writer, which formats the inserted code by the grammar's own rules (`hxformat.json` discovered from the file's directory) and re-parse-validates in one step; an unparseable result is rejected. Because a whole-file rewrite would reflow unrelated hand-wrapping, the file must already be writer-canonical (`write(parse(f)) == f`): a non-canonical file is refused with `file is not in canonical form` unless `--reformat` is passed. The whole result goes through `CanonicalEdit.canonicalize`, never a bare splice, so the shared refusals apply to every op here: a doc-splitting edit (`RefactorSupport.docSplittingEdit` — an insertion that would land between a declaration and its doc), a `;`-terminated element into a comma container, a bare-modifier `newSource`, and a region that was the whole body slot of a brace-less `if` (`BodySlotGuard`). Write the FLAT form and every type annotation: the writer supplies layout and infers no type.

| command | synopsis | contract beyond `--help` |
|---|---|---|
| `add-member` | `apq add-member <file> --type <TypeName> (<memberText> \| --from-file <path> \| -) [--reformat] [--write]` | append-only to a TYPE BODY; no address form; a module-level sibling is `add-element` |
| `add-import` | `apq add-import <file> <module.path> [--using] [--reformat] [--write]` | after the last import / using, else after `package`, else at file top; a same-kind duplicate is refused |
| `add-meta` | `apq add-meta <file> (--select '<sel>' \| --match '<pattern>' \| --at <line>[:<col>]) '<@:meta>' [--reformat] [--write]` | one `@:metadata` entry on a type or member; `--kind` lifts |
| `add-element` | `apq add-element <file> (--after \| --before \| --append) (<l>[:<c>] \| --select '<sel>' \| --match '<pattern>') (<code> \| --from-file <path> \| -) [options]` | a sibling statement / case / list element / module-level declaration; clears a neighbour's doc block on either side (`RefactorSupport.docExtendedSpan`) |
| `replace-node` | `apq replace-node <file> (--select '<sel>' \| --match '<pattern>' \| --at <line>[:<col>]) (<newSource> \| --from-file <path> \| -) [--reformat] [--write]` | replaces the node's WHOLE span INCLUDING its leading modifiers — spell them verbatim; `--kind` narrows with `--at`, LIFTS with `--select` / `--match` |
| `patch` | `apq patch <file> (--select '<sel>' \| --match '<pattern>' \| --at <line>[:<col>]) (- \| --from-file <path>) [--sep <marker>] [--all] [--reformat] [--write]` | `old ==== new` pairs, byte-exact then dedent-tolerant, each unique in the addressed node (`the old fragment does not occur in the resolved <Kind> node`), located against the ORIGINAL text, all-or-nothing; `--all` rewrites every occurrence; refuses an edit that re-parents a doc block (§ "Choosing between `patch` and `replace-node`") |
| `remove-element` | `apq remove-element <file> (<line>[:<col>] \| --select '<sel>' \| --match '<pattern>') [options]` | removes the element with its modifier / `@:meta` group and leading doc, and NAMES what it cut (§ "What a removal reports") |
| `remove-import` | `apq remove-import <file> <module.path> [options]` | by module path; the backend of `lint --fix` for `unused-import` / `redundant-import` |
| `remove-member` | `apq remove-member <file> (--select '<sel>' \| --match '<pattern>' \| --type <T> <memberName>) [options]` | removal is BY NAME — every conditional-compilation twin of the name goes; two declarations of one name in ONE branch are refused with a pointer at `remove-element … --nth <k>` |
| `set-doc` | `apq set-doc <file> (<line>[:<col>] \| --select '<sel>' \| --match '<pattern>') (<text> \| --from-file <path> \| -) [--reformat] [--write]` | PLAIN newline-separated text, prefix derived; replaces EVERY doc block above the target, so an orphaned doc of an earlier type is collapsed with it |
| `set-comment` | `apq set-comment <file> <line>:<col> (<text> \| --from-file <path> \| -) [--reformat] [--write]` | the comment at a cursor (line run or block) |
| `comment-rewrite` | `apq comment-rewrite <find> <replace> <file/dir/glob>... [--regex] [--write] [--list]` | the write-twin of `lit`: a LITERAL find is matched against the NORMALIZED body (line breaks and ` * ` continuations folded to one space), a `--regex` find against the RAW body; a multi-line replacement is re-prefixed and reflowed to the configured width (`--allow-wide` to skip); a find that matches nothing SAYS so; a deletion may not swallow a paragraph separator |
| `rewrite` | `apq rewrite <file> <pattern> <replacement> [--reformat] [--write]` | structural search-and-replace; § "`apq rewrite`: a template is a TREE" — refuses a pattern containing `...` |
| `resolve-define` | `apq resolve-define <DEFINE> <file/dir/glob>... [--undefined] [--write] [--list]` | § "`apq resolve-define`" — the write-twin of `cond` |
| `set-modifier` | `apq set-modifier <file> (<line>[:<col>] \| --select '<sel>' \| --match '<pattern>') <change>... [--reformat] [--write]` | flips visibility / modifiers without retyping the member |
| `safe-delete` | `apq safe-delete <srcFile> <member> --scope <dir> [options]` | removes a member only if unreferenced across the scope; refuses two declarations of one name in the same `#if` branch |
| `encapsulate-field` | `apq encapsulate-field <file> <field> [options]` | a `var` field to a get/set property (`@:isVar`) |
| `extract-constant` | `apq extract-constant <file> --type <Type> --name <NAME> --literal '<text>' [--reformat] [--write]` | a repeated single-quoted literal to a named constant |
| `extract-method` | `apq extract-method <file> <startLine>:<col> <endLine>:<col> <name> [options]` | a statement run to a local function (closure); takes `--fix` |

Eleven ops take `--fix` beside `--write` — `patch`, `replace-node`, `add-member`, `add-element`, `remove-element`, `remove-member`, `remove-import`, `add-meta`, `set-doc`, `set-comment`, `extract-method` (§ "`--fix` on a write op").

### File-level ops

| command | synopsis | contract beyond `--help` |
|---|---|---|
| `new` | `apq new <path> (--class \| --implements <iface> \| --kind <k> \| --raw -) [--extends <T>]... [--open] [--underlying <T>] [--from <T>]... [--to <T>]... [--field <m>]... [--bodies -] [--write]` | CREATE-ONLY — an existing path is refused (`… already exists (create-only; use the ops / fmt to modify)`); parses-or-rejects, byte-canonical, atomic; `--implements` slices each interface signature and carries the imports it needs; `--raw -` is the validated equivalent of a raw write for any shape no `--kind` covers |
| `fmt` | `apq fmt <file/dir/glob>... [--write] [--list] [--verify] [--one-pass]` | § "`apq fmt`: canonicalise source through the writer" |

## Contracts the per-command help does not state

### Input path forms

The scope positionals of every walker accept a **file** (parsed directly), a **directory** (walked recursively, every `.hx` parsed) or a **glob** — `*` (within a path segment), `**` (across segments; `**/` also matches zero directories), `?`, `[...]` (leading `!` negates) — resolved in-process, so quote it to keep the shell from pre-expanding it. The literal prefix before the first metacharacter is the walk root: `src/grammar/haxe/*.hx` scans only that directory, `src/**/Hx*.hx` the whole subtree. A scope argument that matches no `.hx` is reported and skipped, with the hint that a QUERY belongs before a bare `--`.

### Several queries in one walk, the progress gate, and the whole-file read guard

**A bare `--` separates SEVERAL queries from the scope.** `refs`, `mentions`, `lit` and `declares` take a list (`apq refs alphaOne betaTwo -- src --decls`), each query printing under its own `=== <query> ===` banner in the order given, with its own `--limit` budget, its own 0-hit nudge and (for `lit`) its own smart `--kind` default; `source --select` is repeatable the same way and orders by document position. ONE query prints exactly what it printed before the separator existed — no banner, byte for byte — which is what the skill, the hooks and every fixture depend on. `refs --json` takes ONE name (two JSON documents are not JSON). A second positional IS a scope spec and several are legal, so without the separator the extra names are dropped — and the run now names the dropped positionals on stderr instead of silently walking one. What a batch buys is ROUNDS, not CPU.

**Progress is printed only to a TERMINAL.** `CliIo.streamProgress` writes `apq <cmd>: scanned N/M files…` every 25 files plus once at completion; a pipe gets nothing, `HXQ_PROGRESS=1` asks for it back, `HXQ_PROGRESS=0` (or the older `HXQ_NO_PROGRESS`) forces it off. `2>/dev/null` is not an available answer, because the same stream carries the `--limit` cap line, the `refs` member-access warning and, for every mutation op, the ONLY channel a refusal has.

**A long whole-file read is refused, with the selector menu instead.** `apq source <file>` with no `--range` / `--select` / `--at` past the line budget (`HXQ_SOURCE_MAX_LINES`, default 120; `0` disables) answers the NAMES instead of the bytes, exit 2: each menu entry is `Address.describe`'s canonical, edit-stable selector with the line window `--select` will actually print (`CliEdit.sourceWindows`), and "top-level" is counted in NAMED ANCESTORS with one-line nodes dropped, never in grammar kind names, so the menu works on a grammar this code has never seen. `--all` prints the file whole. The budget counts LINES, not Haxe: a long `.md` / `.json` / log is refused the same way with the no-menu form; a file that does not parse has no menu and names `--range` and `--all`.

```
apq source: <file> is 3101 lines and nothing narrowed the read (budget 120 lines, HXQ_SOURCE_MAX_LINES; 0 disables).
Narrow it — `apq source <file> --select '<sel>'` (repeatable):
  InterfaceDecl:GrammarPlugin   lines 19-306
  …
Or read a line window with `--range L:L2`. `--all` prints the whole file.
```

### `apq ast`

```
apq ast <file>                     # S-expr default, full tree
apq ast <file> --json              # JSON output
apq ast <file> --at <line>:<col>   # smallest node enclosing cursor
apq ast <file> --select <path>     # subtree(s) matching a selector
apq ast <file> --depth <n>         # truncate beyond depth n, counted from the DISPLAYED root
                                   # (module by default; the matched node with --select / --at)
apq ast <file> --select <path> --doc --source   # + doc-comment / verbatim slice
apq ast <file> --type-refs         # the type-position projection instead of the default tree
```

Output is deterministic so the tool is usable in CI and diff-based workflows. `--depth N` SILENTLY truncates below N — never conclude a node LACKS a child from a depth-limited dump. `--spans` annotates every node with `@from-to` in CODEPOINTS, not bytes (`docs/testing.md` § "A span is a CODEPOINT offset — a census that slices bytes measures a different file").

**The `type` slot.** What a binding is DECLARED as is answered in the default tree, on the binding itself: `QueryNode.type` is a slot beside `name`, not a child, filled for every BINDING (local `var` / `final`, class and static members, anon-struct fields, comma-continuations, function and lambda parameters, a `catch` binding). Its subtree is the type's own shape — kind = the grammar's type constructor, name = the nominal head, children = the type ARGUMENTS — rendered `(: …)` between the name and the children in S-expr and as the node's own `type` key in `--json`. A KIND could not have carried this: in Haxe `Arrow` is both `HxType.Arrow` and `HxExpr.Arrow`, so "which child is the type" has no kind-level answer, the same reason `name` is a slot.

**`--type-refs` dumps the `parseFileTypeRefs` projection** — the tree `uses` / `blast` / `mentions` and the rewriting ops read — through the same S-expr / JSON path, so `--select`, `--at`, `--depth`, `--children-limit`, `--count`, `--spans` and `--json` compose with it (`--writer-output` does not: the projection is not a writable tree, and the combination exits `EXIT_USAGE`). A parameterized type flattens into **sibling** `TypeRef` nodes (`Map`, `String`, `Foo`). The dump is deliberately RAW — a missing node here means `uses` and `blast` are blind to that position too. Anonymous structures are covered wherever the structure itself can appear; field NAMES never project as type references (`apq uses node` over `var v:{node:Doc}` is 0 hits), because a name that did would be rewritten by `CrossRename` at every site. Residual gap: the HEAD of a structural extension (`typedef Ext = { > Base, … }`) does not project `Base`; its type arguments and every field type still do.

### `--doc` / `--source` (opt-in, on `refs` / `uses` / `ast`)

For each declaration hit, also emit prose alongside the `file:line:col`, so a locate step does not force a follow-up full-file read. `--doc` walks back from the hit's `span.from` over blank and single-line `@…` annotation lines to the immediately-preceding block-style or line-style comment and emits it verbatim (multi-line paren-continued metadata between the comment and the decl is a known v1 limitation). `--source` is the verbatim `source[span.from .. span.to]` cut — for a declaration the whole decl including its body. Both are opt-in and purely additive: default output (text and JSON) is byte-identical, the reconstruction is from source offsets only, and the JSON `doc` / `source` keys are `@:optional`. `refs --json` and `ast --json` carry them; `uses` has no JSON form.

### `apq search`

```
apq search <pattern> <file-or-dir-or-glob>
apq search <pattern> <files> --json
apq search --kind <Kind> <pattern> <files>   # only match nodes of that AST kind
```

The pattern is a fragment of the target language, parsed by the same grammar plugin, with the metavariable extension of § "Pattern syntax for `search`". `--kind <Kind>` restricts matches to nodes of that kind (the same vocabulary `ast --select` uses); a kind this grammar projects no node for is a USAGE error, not an empty result (§ "The kind vocabulary is checked"). `search` is a **structural** query: a degenerate pattern that resolves to a single leaf carries no shape and only ever matches that name in expression position, so the CLI emits a non-fatal stderr nudge pointing at `refs <name> --decls` / `uses <Type>` / `ast --select` and runs the search anyway. Bool literals in a pattern match by KIND, not value.

### `apq refs`

```
apq refs <name> <file-or-dir-or-glob>
apq refs --writes <name> <files>     # only assignment positions
apq refs --reads <name> <files>      # only read positions
apq refs --decls <name> <files>      # only declaration positions
apq refs <name>... -- <files> --decls            # SEVERAL names, one walk
```

Scope awareness is lexical only: a local declaration shadows an outer name; a name RE-declared in the SAME block shadows its own predecessor from that point on; a loop iterator, a catch-clause exception name and a lambda parameter are declarations scoped to their body. No type-based resolution, no cross-file resolution. Write classification is by parent context: an identifier is a `write` when it is the direct first operand of an assignment-shaped node the plugin declares (bare, compound and null-coalescing assignments); identifiers nested deeper on the LHS remain reads; a compound assignment is one `write` hit. `refs` is blind to EVERY member access, a qualified static included — by design, because it feeds `rename`, which must not drag `obj.f` along when renaming a local `f` — and it warns on stderr with a count when it resolved no read/write but the scope holds accesses. Never turn a bare `refs` result into "unused" for a member; confirm with `mentions`.

### `apq uses`

```
apq uses <type-name> <file-or-dir-or-glob>
```

TYPE-position references — field / var annotations, enum-constructor and function parameter types, return types, type-parameter constraints, `extends` / `implements`, `new T(...)`. A parameterized type reports every nominal name it contains. No scope resolution, no cross-file resolution. A QUALIFIED spelling answers a simple `<type-name>` too: `pkg.Mod.T` reaches the tree as ONE node whose name is the whole dotted string, so the match is on the LAST SEGMENT and each hit prints the spelling it found; a dotted query stays an exact compare. The widening is opt-in at the API (`Uses.find(..., includeQualified)`) and off for the rewriters — renaming `T` has to splice the last segment of `Mod.T` and must first prove the path resolves to THIS `T` (`CrossRename`). The default parse tree drops type-position nodes from its CHILDREN to stay lean; `uses` runs on the separate `GrammarPlugin.parseFileTypeRefs` projection.

### `apq meta`

```
apq meta <annotation> <file-or-dir-or-glob>
apq meta <annotation> --arg-contains <substring> <files>
apq meta --on <decl-kind> <files>    # list every annotation on a kind
```

`<annotation>` is the target language's user-source annotation syntax, not anyparse grammar metadata — `@:foo` or `@bar` for Haxe, `[Foo]` for AS3, `@foo` for Python. `meta '@:tag(arg)'` matches the exact arg, not a substring. An annotation attributes to the declaration it precedes; expression-level metadata with no following declaration attributes to the nearest enclosing declaration.

### `apq lit`

`apq lit <text> <file-or-dir-or-glob>...` — every captured leaf whose `name` slot matches `<text>` (substring by default, `--exact` for full equality).

**The default `--kind` is the grammar's string-content vocabulary, in EVERY quote spelling it has.** One string value can be spelled several ways and the spellings do not project alike (Haxe's single-quoted literal is a composite whose text lives in `stringInterpTextKind` child segments; the double-quoted one is a single raw terminal whose `name` slot is the source slice WITH its quotes), so the default set is `stringInterpTextKind` plus every `stringLiteralKinds` entry that is not itself an `interpolatingStringKinds` one, and the declared quotes (`stringLiteralDelimiters`) come off before the compare — a WIDENING, so a query that spells the quotes itself still matches. `apq mentions`' third section reads the same delimiters. An explicit `--kind` naming part of that vocabulary still narrows, and a stderr note names the spelling no longer searched (`apq lit: NOTE --kind Literal covers 1 of this grammar's 2 string-literal content kind(s) — content written as DoubleStringExpr is NOT searched …`). An explicit `--kind` naming a kind no rule projects is REFUSED; `lit` mints `Comment` and `Directive` itself (both come from a separate scan over the raw source) and declares them where it mints them, so the shared gate admits exactly those two on top of the grammar's vocabulary.

**Smart default:** a camelCase / snake_case `<text>` is unambiguously an identifier query, so the default also takes `identKind`; a pure-lowercase or all-uppercase single word stays content-only. `--any-kind` matches every named leaf and also scans comments; `--include-comments` / `--include-directives` add those scans beside the AST walk. Escapes are decoded on NEITHER side. A 0-hit run auto-widens once and says so.

### `apq cond`

`apq cond <DEFINE> <file-or-dir-or-glob>...` — for every conditional-compilation region whose own `#if` / `#elseif` conditions mention `<DEFINE>` as a standalone identifier, one head line per branch (position, verbatim directive, tags) with that branch's own source indented under it.

```
apq cond FEATURE_X src                      # bodies of every branch of every matching region
apq cond FEATURE_X src --active --names     # only what can run with the flag, as symbol names
apq cond FEATURE_X src --inactive           # only the branches that cannot run with it
```

**A branch is not a node — it is delimited by its DIRECTIVES.** A whole region projects as ONE node whose span covers every branch with the constructs flattened into one sibling list, so no selector addresses a branch. `cond` takes a branch's body to be the byte run `[end of its own directive, start of the next directive at the same nesting depth)`, replayed from `CondDirectives.scan` through a depth stack. Three things follow: it is **nest-safe by construction** (an outer branch runs across the whole inner region; a region that itself mentions the define is reported as its own entry too, tagged `nested`); it is **parse-free** (an unparseable file is walked, and so is an expression-position `#if` the grammar projects as a childless `CondSplice*` node — tagged `raw span` and printed verbatim); and **a body never carries a directive**. **Matching is by CONDITION, not by directive text**: `#if (sys || nodejs)` is a site of both flags.

| Tag | Meaning |
|---|---|
| `[live]` | taken whenever `<DEFINE>` is set |
| `[dead]` | never taken when `<DEFINE>` is set |
| `[maybe]` | a flag outside the query decides |
| `[raw span]` | the body holds text no node covers — printed verbatim; `--names` keeps the source |
| `[no parse]` | the FILE has no tree, so every non-blank branch of it is unmodelled for THAT reason — printed verbatim |
| `[nested]` | the region sits inside another one |

Liveness is `CondRegionLiveness.branchStep` folded over the region's directives under the hypothesis that `<DEFINE>` is set and every other flag is unknown — the same step the oracle-coverage question uses, so the two cannot disagree. It is three-valued because a positive-only define set cannot prove a flag absent: an `#elseif <DEFINE>` after an `#if other` is `maybe`.

**Options.** `--active` keeps every branch that is not `[dead]`, `--inactive` exactly the `[dead]` ones (neither flag, or both, keeps everything). `--names` prints the distinct `<Kind> <name>` rows of the branch instead of its source: every node whose `name` slot is symbol-shaped — an identifier, a dotted path, or a metadata name written with one of the grammar's own sigils (`MetaCall @:build`, printed WITH the sigil) — while a literal's CONTENT is never a row in either quote spelling (asked by KIND, off the same two fields `lit` reads with the opposite polarity), though its `$name` / `${ … }` children still are. `--max-body N` bounds each body (default 20, `0` = no cap) and names what it dropped; `--limit` counts REGIONS (a region is never half-printed); `--flat` prefixes each head line with the file.

### `apq resolve-define`

`apq resolve-define <DEFINE> <file-or-dir-or-glob>...` — the WRITE-TWIN of `cond`. Every region whose conditions mention `<DEFINE>` and whose branches are ALL decided is replaced, from its `#if` marker to the end of its `#end`, by the body of its one live branch — or deleted when no branch is live.

```
apq resolve-define FEATURE_X src --list          # which files would change
apq resolve-define FEATURE_X src/A.hx            # the rewritten file on stdout (preview)
apq resolve-define FEATURE_X src --write         # apply
apq resolve-define FEATURE_Y src --undefined -w  # retire a flag that is never SET
```

Retiring a define is a one-time procedure, not a standing policy — an op, not a lint rule (the `if-false` check matches only a literal `#if true` / `#if false`). **DECIDED vs UNDECIDED**: a region carrying a `[maybe]` branch is left as is and reported on stderr by position (`src/popups/Foo.hx:91:3: #if (mobile && X) - left as is: a flag outside the query decides`). **Conditions are never SIMPLIFIED** — `(mobile && X)` does not become `mobile`; that is a rewrite of the condition TEXT with separate failure modes. **`--undefined` is the negative hypothesis**, an assertion the operator signs for: no compile output can prove a flag undefined, so `CondRegionLiveness.evaluate` stays positive-only and only the explicit `evaluateFacts` entry point reads a name as false. A decided region inside a decided one is folded into its parent's replacement and counted separately; inside an undecided one it is folded on its own and the parent stays. A region whose `#if` starts its line and whose `#end` ends one takes those lines with it when nothing is live; a region sharing its lines with code keeps the narrow span and is re-indented by the writer.

What is refused is the shared write gate's list: a region that was the whole body slot of a brace-less `if` (`BodySlotGuard`), `file is not in canonical form` (run `apq fmt --write` or pass `--reformat`), and a source the grammar cannot parse — the deliberate difference from `cond`, since writing needs a re-parse. Each is a per-file failure: the walk continues, the file is left byte-identical, and the run exits non-zero. Multi-file UX is `comment-rewrite`'s: one file with no flag previews on stdout, a directory or glob lists the paths that would change, `--write` rewrites in place; a walk that matched nothing says so.

### Parse-failure locus

When the parser cannot parse a file it reports the **farthest input position any terminal reached** (PEG max-position heuristic), not the position where the outermost rule bailed — without it recursive-descent backtracking collapses every failure to the file head.

### `apq probe`: the staged scratch slot

`apq probe '<code>'` persists the bytes it was handed so the next command can target the same source without re-heredoc-ing it, and prints the path on stderr (`apq probe: staged source -> /var/folders/…/T/anyparse-last-probe.19905.hx (use it with …)`). **Read that path out of the nudge — never spell one yourself.** It resolves to `$APQ_PROBE_PATH` when set and non-empty, otherwise `<temp root>/anyparse-last-probe.<pid>.hx`, where the temp root is the OS one (`os.tmpdir()` on node, so `$TMPDIR` when the caller set one). Both halves are load-bearing: the temp root answers the caller's own isolation (the suite's private root reaches it), and the pid separates two CONCURRENT probes on one machine — a shared fixed slot handed a worker a foreign source with exit 0 and no exception. `$APQ_PROBE_PATH` is an escape hatch, not an isolation mechanism: two workers exporting the SAME value re-create that defect. Nothing reaps the slot (it is a bare file, and `tools/tmp-lifecycle.sh` sweeps claimed DIRECTORIES); within one process a chained `recon --probe` targets the LAST probe. Staging never fails a probe: a write error skips the nudge, and a target that exists and is not a regular file is refused (`apq probe: not staged — "…" exists and is not a regular file (symlink, directory or device); set APQ_PROBE_PATH to stage somewhere else.`), because `File.saveContent` FOLLOWS a symlink. That refusal is the NODE runner's (`lstat`); the `sys` fallback catches a directory only, and a HARD link is outside either check.

**Where the temp root comes from.** `anyparse.core.TempScratch` is the single answer to "where may this process write scratch, and what keeps it apart from another process's": `TempScratch.root()` stays a FUNCTION (`TMPDIR` is mutated at runtime, which is how the suite's private root reaches every producer), while the process token is resolved once. Every producer reads it — `OracleCache`, `CompilerServer`, `ProbeCommand`, `StdlibDupCommand`, the suite's `CliFixture`.

### `apq lint`

`apq lint <scope...>` runs the analysis checks and reports violations grouped by file (`<line>:<col>: [severity] message (rule)`). Info advisories are hidden from the TEXT report unless `--all`; `json` and `checkstyle` always carry every finding. `--list-rules` prints every REGISTERED check, not what runs here — it never reads `apqlint.json`, so a config-disabled rule still prints, and `--rule <id>` on an actual run force-enables a rule the config disables. Inline suppression: a trailing `// noqa` or `// noqa: rule1, rule2` (those two spellings only), or a `CHECKSTYLE:OFF` / `ON` region. Project config is an `apqlint.json` discovered by walking up from a linted file and folded as a CHAIN nearest-first (`docs/testing.md` § "The project declares its own sources as `resolutionRoots`"). Its `compilerOracle` key is EITHER one hxml path or a list of `{hxml, defines?, dir?}` configurations — the string is the one-element case, and a project with conditional compilation needs more than one, because a `#if` has two or more arms and each is a different build (`docs/testing.md` § "The oracle answers for what it COMPILED, not for what you linted"). A malformed list element is dropped with a diagnostic and the configurations beside it still apply.

**`--fix` writes in place** (no `--write`, no print-only mode) and reports `N edit(s) in M file(s) over P pass(es)` — EDIT SPANS, not findings (`docs/testing.md` § "The `--fix` summary counts EDITS, and is not a verdict about a rule"). The write set is the lint scope, and canonicalization can touch any file it writes. An edit is not a promise the finding is gone: a check may fix part of what a finding reports and decline the rest (`member-order` sorts what its pins allow and leaves the pinned pair), and a finding that survives its own check's edit carries the reason in `Violation.declineReason`, which the unfixed ledger prints. `--no-oracle` skips the project-wide typecheck; in report mode findings are unchanged, with `--fix` it also turns off every oracle-backed net — never in a gate (`docs/testing.md` § "`--no-oracle` for the edit loop").

**`--range <a>:<b>`** takes a 1-based inclusive line window over a scope of exactly one file and narrows the report AND `--fix` alike. It selects FINDINGS, never EDITS — an atomic fix (`unused-parameter` rewrites the signature and every call-site argument) still writes wherever its own fix says, off a finding inside the window; under `--fix` the window is re-applied on every fixed-point pass against the file's current bytes.

**`--baseline <path>`** reports only the findings a previous `--format json` snapshot at `<path>` does not already carry, then rewrites `<path>` with every finding of this run — unless `<path>` exists and could not be read as a report, in which case the run leaves it alone (a path that is there and is not a snapshot is a file the caller named by mistake; `--baseline` carries no `--write` and must not be able to destroy source). The comparison is `lint-diff`'s multiset over `(file, rule, severity, message)`, so an edit that inserts a line above a finding manufactures no delta. It narrows the report, the severity summary and `--fail-on` alike; a missing, empty or unreadable snapshot reports everything and says which it was. Refused with `--fix`.

**`--verbose`** brings back two blocks a quiet `--fix` run withholds — the per-rule unfixed ledger + never-asked list + rule census (printed only when the run produced an edit), and `compiler oracle SKIPPED (--no-oracle) …` (it narrates back a flag the reader passed). The OTHER netless arm, `no compilerOracle configured …`, always speaks: it names a remedy the reader has not taken.

### `--fix` on a write op: the lint pass, scoped to the lines the write changed

After the write lands and reports, the op lints the file it just wrote and applies the safe fixes. The op's own exit status is unaffected: the write already happened, so a lint that finds nothing, or refuses, must not turn a successful edit into a failure. **The scope is the lines the write CHANGED**, computed by trimming the common leading and trailing LINES between the file as it was and the text the op emitted, and printed (`apq: --fix over lines 9-10 of <file>`); byte-level trimming is wrong because the minimal EDIT of an insertion is not line-aligned. Several changed regions give their HULL, wider than the truth. A scope at all because a whole-file `--fix` on a codebase with standing fixable debt would rewrite code nobody asked about. **`--no-oracle` is hardcoded** — the oracle is a project-wide build no per-edit step can pay — so every `RiskyFix` and `OracleAssisted` rule stays report-only and only the SAFE half of the fixer can land behind an edit; `runLint` prints that it had no net. The window is a `lint` feature (`--range`), not an op feature.

### Choosing between `patch` and `replace-node`, and what NOT to type

`patch` matches its `old` fragment **verbatim** inside the resolved node — byte-exact first, then dedent-tolerant — and refuses with `the old fragment does not occur in the resolved <Kind> node` when it does not; that refusal is the tool being correct, so the cost of `patch` is retyping the fragment exactly, and it grows with the fragment. **When the replacement covers more than about half the node, address the node and pass only the new text** — `replace-node --select '<Kind>:<name>'`. Two boundary cases stay with `replace-node` whatever the size: a macro-time local (`rename` cannot see a bare `$name` reification splice), and any change to a leading modifier group — and there `replace-node`'s span **includes** the modifiers, so spell them verbatim. A leading `/** */` on a TYPE is trivia BEFORE that type's node, so no `patch` address reaches it; use `comment-rewrite` for a sentence inside it or `set-doc` for the whole block. A MEMBER's doc is inside the enclosing type's node, so `patch --select 'ClassDecl:T'` does reach it. What you do not have to type: layout. What you do: types — every writer-emit op canonicalises the text it is handed by the project's own `hxformat.json`, and infers no annotation (`explicit-type` / `explicit-local-type` are `OracleAssisted`, inert under a write op's `--fix`).

### `apq rewrite`: a template is a TREE, so it is spliced as one

`apq rewrite <file> <pattern> <replacement>` matches with `search` syntax and splices `<replacement>` over each matched span, expanding `$x` / `${x}` to the captured source. The template is written in AST terms — `$A * 2` reads "the capture, times two" — but text has no precedence, so a raw splice can hand back a different program (`$A * 2` over `v + 1` as `v + 1 * 2`), and both re-parse. Every splice — each expanded metavariable, and the replacement as a whole against the context the PATTERN matched inside — keeps the parse it was written to have, with the fewest parentheses that achieves it: a pair appears only where its absence is observable in the tree (`v * 2`, `-1 * 2` stay bare); nested splices share one pair where one is enough; a metavariable in a position that cannot take parentheses (a declaration NAME, a type annotation) is left alone; a raw splice that does not parse at all (`$A < 5` over `a is C`) succeeds parenthesised. The mechanism is a differential parse, not a precedence table: a grammar declares `parenKind` and `parenDelimiters` and gets the whole behaviour, and one that declares neither keeps the raw splice. A pattern containing `...` is refused — its replacement template would silently delete the absorbed children.

### `apq fmt`: canonicalise source through the writer

```
apq fmt <file/dir/glob>... [--write] [--list] [--verify] [--one-pass] [--lang <name>]
```

Re-emits each file through the writer — the whole-file pipeline the writer-emitted ops use — formatted by the project's `hxformat.json` discovered from the file's own directory. The file-level counterpart of those ops and the measuring stick for the canonical gate (`writeRoundTrip(s) == s`). No flags on one concrete file: the formatted source to stdout. No flags on multiple files or a directory: `--list` mode is implied. `--write` / `-w` rewrites in place; `--list` / `-l` forces list mode and is the machine mode a whole-tree gate spells (an EXPLICIT `--list` is also the one mode that turns the `#if` region notes off, because they cost one extra parse per file that has a `#if`). `--verify` is the audit mode — the output must differ from the input by WHITESPACE only, every other divergence reported, never written (`docs/testing.md` § "`fmt --verify` — the invariant the round trip cannot check"). `--one-pass` additionally requires every file to reach its fixed point in ONE writer rewrite: `fmt` writes the writer's FIXED POINT, so a file the writer settles only on its second rewrite is reported canonical by `--list` while the next writer-emit op refuses it as non-canonical; off by default, on for a gate (`docs/testing.md` § "`--list` and `--write` disagreed across runs, and only the tool could see it").

A file that fails to parse is reported and skipped, exit non-zero. A file whose re-emission would DROP a comment (an inline comment in a seam the parser has no capture slot for, e.g. `if (/* c */ x)`) is reported with the comment and left byte-identical rather than rewritten without it (`APQ_ALLOW_COMMENT_LOSS=1` turns the guard off, and the run says so). A `.hxtest` is refused by name (`: a .hxtest fixture is three `---`-separated sections, not a source file`) with both replacements named. Every summary line names BOTH quantities (`rewrote N of M file(s), K failed[, J could not be written]`). **The `#if` region note**: a conditional-compilation region whose bytes are not a balanced subtree in their position is captured raw by the parser, so the writer re-emits it byte-for-byte while reformatting everything around it — a note, not a failure; mechanism in `docs/architecture.md` § "A `#if` region the parser captured raw".

### The report-only rules that read comments

Four `DefaultOff`, `Info`, `NoAutofix` rules exist because the writer owns every CODE line's width and shape and re-emits a comment interior BYTE FOR BYTE, so no other gate reads a comment. A project opts in through `apqlint.json` (`"<rule>": { "enabled": true }`).

- **`comment-width`** reports a COMMENT line rendered wider than `wrapping.maxLineLength`. The comment has to be what puts the line over: a line is measured whole (`CheckScan.displayColumn`), but a comment sharing its line with code already past the width is the formatter's concern, and the code is read on BOTH sides of the comment. Its fix breaks the line back at spaces into the block it lives in (`SourceComments.wrapCommentBody`, the same reflow `comment-rewrite` repairs its own edits with), addressing lines by body-line INDEX (`wrapAt`) so two identical over-width lines cannot protect each other, and taking a block's closer columns off the LAST line's budget. It declines, with the reason in the message and in `Violation.declineReason`: indentation the author wrote (a code sample, a hanging indent); a bullet / table row / heading / numbered item (`SourceComments.reflowRefusal`, per line); a suppression directive (`Suppression.parseNoqa` reads an empty rule list as EVERY rule); inside a fenced code block (tracked per comment unit); trailing after code (its continuation would be a NEW own-line comment the writer relocates); a raw `#if` region or a file that does not parse (fail-closed). A one-line PLAIN `/* … */` that an edit grows past the width wraps with NO gutter (`commentContinuation` reads the continuation off the block's first interior line; a `/**` opener means a guttered block, a plain `/*` none), and a deletion does not own a paragraph separator on either side of its match (`interiorParagraphBreak`).
- **`doc-measurement-claim`** reports a comment carrying a READING rather than a contract — a number with a unit of time, a share written with the percent sign, an abbreviated commit hash, a slice or backlog id, a before-and-after pair of numbers, the recording verb standing beside a number or opening a claim, or a sentence pinning its claim to the state of this repository. A number is never a marker on its own (a doc naming the code's own constant states a contract); a pointer is not a record (a marker inside a path, a URL or a `@see` line, and a string literal is never visited); the percent sign is a unit except where it is an operator (a number on its RIGHT — per LINE, which settles `20 % (12 % 7)`); the recording verb is read by POSITION, not by case (opening a clause it introduces a claim; mid-clause, `is measured by`, it states a contract). One finding per comment, anchored at the first reading, counting how many the comment holds (`(3 readings)`; an arrow chain counts once).
- **`doc-length`** reports a DOC BLOCK longer than the maximum the project declares (`"doc-length": { "max": N }`, default 40). Only a doc block is measured; a `//` run and a plain `/* … */` banner belong to the statements they stand over. The message quotes the block's length, so the rule declares `VolatileMessage` and masks that number out of the finding identity. There is no comment-to-code ratio: a share names no block to rewrite.
- **`duplicate-code-renamed`** reports what `duplicate-code` reports, with every LOCAL binding's name replaced, before comparison, by the position at which the run first binds it (a type-2 detector: members, types, method names and literals still match byte for byte). Its own rule id, because a shared id would merge two populations into one `--baseline` / `lint-diff` history. The binder dictionary is derived from `BinderScan.binderKinds` (the union of the `RefShape` binder-family fields — a grammar declaring none normalizes nothing); names come from the OUTERMOST binding scope containing the block, renumbered per candidate run, one-to-one (a consistent SWAP is a renaming; a copy whose names do not correspond one for one ends the run). A binder writes its own name in the stretch between its node's start and its first child, so a loop variable and a `catch` binder normalize while a default value and a body are out of reach; the bare single-parameter arrow lambda is left alone. Neither reading contains the other — the occurrence filter keeps the EARLIEST-starting run — so take the union of the two rules. Both readings drop a BARE run — one whose every statement is a local declaration or a plain assignment to a name (dotted or not) with no value, a name or a literal on the right — since a row of slot fills has nothing to extract; a statement the grammar seams cannot place is not bare, so an unclassifiable run stays a finding.

## Pattern syntax for `search` (frozen for v1)

The pattern is parsed by the active grammar plugin **with a metavariable extension**: any identifier-shaped token starting with `$` is treated as a metavariable rather than a concrete identifier.

| Form              | Meaning                                                                    |
|-------------------|----------------------------------------------------------------------------|
| `$X`              | Bind one node. Reusing the same name must match the same subtree.          |
| `$_`              | Wildcard. Matches one node. Does not bind. Multiple `$_` in one pattern are independent — each matches any subtree without cross-constraint. |
| `...`             | Ellipsis. Matches a RUN of siblings, zero or more, in one child list. Does not bind. At most one per child list. |

The matcher walks the input AST and tries to unify each subtree with the pattern AST node-for-node, treating metavariables as holes. `apq search '$x = $x + 1' file.hx` matches every self-increment-by-1 and binds `$x` to the actual variable expression at each site.

### The `...` ellipsis

Without it a pattern cannot say "any arity", because the matcher's child loop gates on an exact length; `new $T(...)` is every construction in one pattern.

```
apq search 'new $T(...)'   every construction, any arity
apq search 'f(...)'        every call to f
apq search '[...]'         every array literal
apq search 'g(1, ...)'     calls whose FIRST argument is 1
apq search 'g(..., 1)'     calls whose LAST argument is 1
apq search 'g(1, ..., 1)'  calls with 1 at both ends
```

**Anchored, not greedy.** The pattern children before the `...` anchor left-to-right from the start of the input's child list; those after it anchor right-to-left from the end; the star absorbs the (possibly empty) run between. Both anchors must FIT — `g(1, ..., 1)` does not match `g(1)`. There is no backtracking and no ambiguity, which is what **one star per child list** buys; a second one in the same list is refused. **It does not bind**: nothing can reference what a star took, so `apq rewrite` refuses a pattern containing one, while the `--match` op locator accepts it (it only addresses a node). **A bare `...` is refused**, as is `...` in a name slot (`new ...()`). **Constructor type arguments** project into the same flat child list as value arguments (`NewExpr T (Named K) (Named V) (IdentExpr a)`), so `new $T(...)` counts `new Map<String,Int>()` too; `new $T<$K>(...)` matches only a construction carrying at least one type argument, because a metavar in a type-argument slot projects as `Named` and no value argument ever does. The projection of type arguments is shallow and `NewExpr`-only — `extends Base<Int,String>`, `function f<T,U>()`, a `typedef`'s parameters and every type annotation project their type arguments as no node at all, so a type-parameter census over anything but `new` is not a `search` question.

### Non-features in v1

Type filters (`$X:Int`) — need type resolution, deferred indefinitely. Regex on identifiers, negative patterns, sibling / ancestor combinators — Phase 2+ candidates. The v1 syntax is the smallest set that is still useful, and every deferred feature can be added later without breaking it.

## Selector syntax for `ast --select` (v2)

| Form                | Meaning                                          |
|---------------------|--------------------------------------------------|
| `<kind>`            | Match any node of this kind                      |
| `<kind>:<name>`     | Match a node of this kind with the given name    |
| `<kind> <name>`     | Space is an accepted alias for `:`               |
| `A > B`             | `B` is a direct child of `A`                     |
| `A >> B`            | `B` is an any-depth descendant of `A` (v2)       |

Kind names come from the grammar plugin's public AST vocabulary. `apq ast file.hx --select 'function:bar >> VarStmt:tmp'` reaches a local without knowing the block nesting — the descendant combinator is what makes the `file → class → method → local` path practical.

### The kind vocabulary is checked

A kind name is checked against what the loaded grammar's parser can actually project (`GrammarPlugin.projectedKinds`, generated from the same shape the walker is emitted from — no list is spelled by hand anywhere in `anyparse.query`). One check with one message, shared by every place a kind can be typed:

| Where | On an unprojected kind |
|---|---|
| `ast --select` / `probe --select` | message + **exit 2**; stdout is EMPTY on this branch (no `(no matches)` line, no `--json` document) |
| `source --select` | message + exit 1 (a `source` miss was always an error) |
| `lit --kind` / `search --kind` / `symbols --kind` / `meta --on` | `apq <cmd>: <flag> "K" is not a node kind this grammar projects (did you mean …?)` + **exit 2** — `<flag>` is the one the user typed; an EMPTY segment (`--kind "Literal,"`) is rejected with no did-you-mean |
| `replace-node` / `patch` / `add-meta`, `--kind` narrow or lift | the same clause under the op's own prefix + exit 1 |

The message names the spelling that was rejected and the nearest ones that exist (the did-you-mean demands a substring hit or an edit distance under half the query, so `ClassDeclz` suggests `ClassDecl` and `Fix` suggests nothing). **A kind that IS projected and merely absent stays exit 0** — `ast --select DoWhileStmt` over a file with no `do while` found nothing, and that IS the answer; only a spelling nothing could ever match is the caller's mistake. Two spellings are admitted beyond the grammar's own vocabulary, neither hard-coded in the checking layer: a `selectKindEquivalence` alias the plugin publishes (`--select ClassDecl` reaching a `final class`'s `ClassForm`), and whatever the CALLING command mints itself (the root kind `module`, `apq lit`'s `Comment` and `Directive`); a minted kind is in the did-you-mean pool too.

### Non-features

Attribute filters (`class[name=Foo]`), pseudo-selectors (`:first-child`, `:has(...)`) — Phase 2+ candidates. Ordinals inside the selector (`#n`) — disambiguation is the CLI-level `--nth <k>` flag, shared by every op that accepts `--select` / `--match`.

## Op addressing: `--select` / `--match` / `--nth` / positions

Every mutation op resolves its target through one shared address layer (`anyparse.query.Address`). Exactly one of position / `--select` / `--match` per invocation:

| Form                 | Meaning |
|----------------------|---------|
| `<line>[:<col>]`     | 1-based position; **column omitted = the line's first non-whitespace character**, then past the declaration's modifier / metadata prefix — `public static function f` resolves the `FnMember`, not the `Public` sibling, and `@:keep` on its own line reaches the declaration below it. The walk stops at anything that is not a node START, so a comment between the prefix and the declaration keeps the address on the prefix. Spell the column explicitly to address a modifier or annotation itself |
| `--select '<sel>'`   | Selector v2 path; must resolve to exactly one node |
| `--match '<pattern>'`| An `apq search` structural pattern (`$x` metavars); the matched node is the target |
| `--nth <k>`          | Picks the k-th (1-based, document order) of several `--select` / `--match` matches |

- Named/pattern addresses are **edit-stable**: they survive edits above them, so a chain of ops needs no re-locate step between edits. On a position / `--match` resolution the op echoes the target's **canonical selector** to stderr (`apq <op>: target FnMember:walk`), and `lint --format json` records carry the same thing in an `address` field (record shape: § "Output JSON schemas").
- An ambiguous `--select` / `--match` fails with a candidate listing ready for an `--nth` pick, and each row a NAME can address alone also carries the selector that does it (`AddressIndex.uniqueSelector` — `#2 4:2 Conditional  --select 'ClassDecl:C >> Conditional'`); a row only an ordinal separates stays bare. Every widening step prepends a NAMED ancestor with `>>`, so a node hanging directly off the nameless root is singled out by a final root-anchored `module > X` attempt, tried only for a direct child of the root. The listing asks the index for "names cannot single this out" as an ABSENCE rather than sniffing `describe`'s rendered string, because a node's name is arbitrary text.
- A `--select` that matched nothing says WHY when it can: two clauses after a leading em dash — the unknown KIND (`--select "FnMembr:f" matched no nodes — "FnMembr" is not a node kind this grammar projects (did you mean FnMember?)`) and the known name under another kind (`"f" exists as 12:9 FnDecl:f; try --select "FnDecl:f"`). A kind that IS projected and merely absent here gets no clause. `apq source` carries the same tail; `apq ast --select` answers the unknown-kind clause ALONE (its `Kinds present here: …` listing answers the wrong question for a spelling no file could match) and keeps the cross-project pointer at `refs` / `uses` / `blast`, since a TypeName typed into `--select` is the commonest way to reach a kind no grammar projects.
- `--kind <Kind>` combined with `--select` / `--match` LIFTS the resolved node to its innermost enclosing `<Kind>` — a pattern matches the expression (`addCase(x)` = the `Call`), while a statement edit wants the `ExprStmt`. With `--at` it keeps its original meaning: the innermost node of `<Kind>` at the cursor.
- `remove-member` REDUCES the resolved node to the `(enclosing type, member)` NAME pair its by-name form takes, lifting an address inside a body to the member holding it; the removal itself stays BY NAME, so every conditional-compilation twin goes. Twins are declarations in DIFFERENT branches; two of one name inside ONE branch (the state a `replace-node` leaves when its replacement re-declares its target) are an illegal duplicate no build compiles, and taking both is data loss, so that is a refusal naming the count and pointing at `remove-element --select … --nth <k>` — where "one branch" includes two SIBLING regions spelling the same condition, compared by `CondBranchPath.sameBranch` over the branch's condition CHAIN (`a`, `a|b`, `a|`, normalised so `#if (a)` and `#if a` compare equal). Giving both an address and `--type <T> <memberName>` is a usage error; an address that resolves to something that is not a member is refused with a pointer at `remove-element`. The ops that accept no address form are the ones whose target is not a node: `add-member` appends by `--type`, `add-import` / `remove-import` take a module path, `new` / `fmt` are whole-file.

### A module-level declaration's RAW span reaches the next one — the ops do not

A module-level declaration's node span runs to the first byte of the declaration after it, so it holds the whitespace AND the comments between them, the next declaration's own doc block included; member spans are tight, which is why the asymmetry keeps being rediscovered from a reading command and filed as a greedy-window bug. None of that reaches an op. Every addressed op folds the node through `ElementSpan.declEditSpan`, whose `trailingTrimmedSpan` walks the swallowed whitespace and comments back off before anything reads or writes them — so `source --select` prints the declaration's own bytes, `patch` cannot find a fragment that lives only in the gap, and `replace-node` / `set-doc` / `remove-element` / `add-element` leave the neighbour's doc standing. `unit.query.GreedyDeclSpanEditBoundarySliceTest` pins the trim, and that the raw span really is greedy.

### What a removal reports, and why it is a report rather than a refusal

`apq remove-element --select 'FnMember:<name>'` removes that member together with its modifier / `@:meta` group and its leading doc block — the DELETE verb of the op family, and the fold is what makes the file still parse afterwards. What it could not do was SAY so: a twenty-line annotated test and a one-line statement produced the identical `wrote <file>`. A specificity rule (refuse a member address when the member carries annotations) refuses an address that is already correct (`--select 'Meta:@:keep'` on the same declaration removes the annotation and leaves the doc standing — nothing is ambiguous); a confirmation threshold fires on nearly every correct use in a tree whose lint config enables `prefer-doc-comment`, and a gate that fires by reflex gets bypassed by reflex. So the fix is the **report**: `wrote F.hx (removed FnMember f: 8 lines, with its doc comment and 2 annotations)` on both the write and the preview line, for a position and a `--match` address too, naming the DECLARATION rather than the node the cursor resolved (a position landing on `public` reports `removed FnMember f`). The count is the LINES THE CUT SPANS, which is not always the file's line delta — removing the only statement of a block lets the writer collapse the block, so the file loses two lines where the report says one; `git diff` describes the file.

## Output formats

Every command supports **text** (default; single-line-per-match summaries) and **JSON** (`--json`; a stable schema per command, for `apq … --json | jq …`). Both include source spans so results can be fed into editors. The schemas below are the **v1 stable contract**: subsequent versions may extend them additively (new optional keys) but will not rename, remove, or retype an existing key. Two cross-cutting conventions: multi-result commands wrap their array in one envelope object (`{ "matches": [...] }` for `search`, `{ "hits": [...] }` for `refs` and `meta`), and **optional keys are omitted, not null** — `jq` filters use `// empty` or `?`.

### Output JSON schemas (v1, finalized)

All schemas share one span type, both coordinates 1-based — the single convention every `apq` / `hxq` surface uses:

```
Span = { start: [line, col], end: [line, col] }
```

#### `ast`

```
{ "file": "path/to/input", "tree": Node }

Node = {
  "kind": "class" | "function" | "field" | ...,   // plugin-defined; see Kind vocabulary
  "name": "Foo",                                   // omitted when node has no name
  "type": Node,                                    // omitted when the node is not a binding
  "children": Node[],
  "span": Span                                     // omitted when node has no source coordinates
}
```

`span` is present on source-addressable nodes and omitted on transparent inner structural nodes and the synthetic root. With `--select` the response is `{ "file": "...", "matches": Node[] }`; with `--at`, `tree` is the smallest enclosing node only.

#### `search`

```
{ "matches": [ { "file": "path/to/input", "span": Span,
                 "bindings": [ { "name": "X", "text": "matched source text", "span": Span }, ... ] }, ... ] }
```

`bindings` is a **static array** of `{ name, text, span }` (the dynamic-object form with metavar names as keys was rejected so the schema stays static and macro-generated). `name` drops the leading `$`. The array is empty for patterns that contain only literals or `$_` wildcards.

#### `refs`

```
{ "hits": [ { "file": "path/to/input", "kind": "read" | "write" | "decl", "span": Span,
              "name": "the_symbol", "binding": Span /* optional */ }, ... ] }
```

`binding` carries the span of the declaration this hit resolves to; declarations self-bind. It is omitted when a read or write is unresolved — a cross-file reference or an inherited member. Loop-iterator, catch-clause and lambda-parameter bindings ARE resolved.

#### `meta`

```
{ "hits": [ { "file": "path/to/input", "annotation": "@:foo", "args": ["arg1", "arg2"],
              "decl": { "kind": "class" | ..., "name": "thingItIsAttachedTo", "span": Span } }, ... ] }
```

#### `lint --format json`

```
[ { "file": "path/to/input", "line": 12, "col": 3, "endLine": 14, "endCol": 2,
    "severity": "error" | "warning" | "info", "rule": "unused-import", "message": "…",
    "address": "FnMember:f" /* optional */ }, ... ]
```

The one surface that predates the envelope convention: a BARE top-level array (`LintDiff.parseReport` wraps it before parsing). `line`/`col` is the finding's span START and `endLine`/`endCol` its EXCLUSIVE end — the same convention as `Span.end`, so `[line:col, endLine:endCol)` is the region and two findings' regions can be tested for nesting from the report alone; all four are `null` (not omitted) on a finding with no span. `address` is the canonical selector of § "Op addressing", omitted when no node resolves. `lint-diff` and `--baseline` key on `(file, rule, severity, message)` only and skip every other key on read, so a snapshot written before `endLine`/`endCol` existed compares against one written after with no delta.

### Kind vocabulary

`kind` strings — in `Node.kind`, `meta.decl.kind`, and every `ast --select` segment — are exactly the grammar plugin's AST node-constructor names. There is no separate display mapping and the engine never enumerates kinds: each plugin publishes its own set as part of its public contract. **Discovery is self-documenting**: `apq ast <file>` prints the real `kind` of every node, which is the authoritative way to learn the kind of any construct in any language. **One surface keyword can be several kinds** — kinds track the construct, not the spelling. The Haxe plugin's commonly-navigated declaration kinds (a convenience list, not a second source of truth; every node constructor is a valid `--select` segment):

| Group | Kinds |
|---|---|
| Module type decls | `ClassDecl`, `InterfaceDecl`, `EnumDecl`, `EnumAbstractDecl`, `AbstractDecl`, `TypedefDecl` |
| Module var / fn | `VarDecl`, `FnDecl` |
| Type members | `VarMember`, `FinalMember`, `FnMember` |
| Anonymous-type fields | `VarField`, `FinalField`, `FnField` |
| Local declarations | `VarStmt`, `FinalStmt` |
| Enum constructors | `SimpleCtor`, `ParamCtor` |
| Params & bindings | `Required`, `Optional`, `Rest` |

**Distinct constructs get distinct kinds — `enum` vs `enum abstract`.** `EnumDecl` is an algebraic enum whose children are constructors; `EnumAbstractDecl` is a typed-constant abstract whose children are `VarMember`s plus the underlying `Named` type. `ast --select EnumDecl` does **not** match an `enum abstract`, by design. **`final` is a wrapper shape, and `--select` folds it.** `final class C` parses to `FinalDecl(ClassForm C …)` and `final function f()` to `FinalModifiedMember`; a `final class` *is* a class, so `--select ClassDecl` also matches a `final class`'s `ClassForm` and `--select FnMember` a `final function`'s `FinalModifiedMember` (chains too). The folding is `--select`-only and limited to the `final` wrappers; a `final` FIELD (`FinalMember`) is its own kind, not a wrapper.

## Shell composition

The JSON envelopes are designed for `jq` / `xargs` pipelines. Decl-kind tokens are the Haxe plugin's published vocabulary.

```
$ apq meta @:inject --json src/ | jq -r '.hits[].decl.name'                       # names carrying an annotation
$ apq meta --on FnMember --json Service.hx | jq -r '.hits[] | "\(.annotation) -> \(.decl.name)"'
$ apq meta @:route --json src/ | jq '.hits | length'                               # count an annotation
$ apq refs --writes n --json Repo.hx | jq '.hits | length'                         # sites that write a symbol
$ ls *.hx | xargs -I{} apq meta --on VarMember --json {} | jq -r '.hits[] | "\(.decl.name):\(.annotation)"'
```

These compose because every command emits exactly one JSON value (the envelope), absent values are omitted rather than `null`, and spans are a stable two-element-array shape `jq` can index directly.

## Universalization invariant

This is the load-bearing architectural rule. **The query engine must not contain any code that references a specific language's AST node types.** The engine sees a `GrammarPlugin` (parser, AST type vocabulary, metavariable token marker), a `ParseResult` produced by that plugin, and a `Query` — for `search`, a pattern parsed by the same plugin; for the rest, a structural request. Adding a new language means: the grammar plugin already exists; a preset alias is added; the plugin declares its metavariable token marker (`$` for most languages — configurable where `$` has lexical meaning). Engine code that switches on Haxe-specific types is a bug.

The rule is about TYPES, and the engine names a Haxe type in exactly two places: the CLI registry, which has to construct the plugin it selects (`cli/CliArgs.hx`), and `query/FormatConfigDiscovery.hx`, which reaches for `HaxeFormatConfigDiagnostics` to warn about a config it found. A kind name spelled as a STRING is the same coupling with none of the compiler's help; the census is one command against `HaxeQueryWalker.projectedKinds()` — the generated vocabulary `unit.query.RefShapeKindProjectionTest` compares the declared side against — and its reading is a function of the tree (the journal keeps the readings):

```
hxq lit '' src/anyparse/query src/anyparse/check --kind Literal --flat   # then intersect
```

The repair per site is a `RefShape` field, site by site rather than in one sweep, because each one is a CONTRACT question — what does this consumer actually need to know about the grammar — not a rename. Shapes answered so far, worth reading as precedent: the string-literal vocabulary (`apq lit` / `InertRegions`), the metadata sigils (`apq cond --names`), the operator / precedence tables (`pureOperatorKinds`, `maximalPrecedenceRootKinds`, which took `InlineMethod.hx` to zero spellings), and a whole CHECK — `prefer-inline` reads `identKind`, `callKind`, the field-access kinds, `writeParentKinds`, `memberDeclKinds` minus `fieldDeclKinds` minus `finalModifierMemberKind`, the modifier seams, `valueReturnKinds`, `exprStatementKind`, `typeAnnotationKinds`, and the null / equality / coalesce kinds instead of its own tables; the hand-written assignment family disagreed with `writeParentKinds` by three members, one of them a real mutator (`>>>=`) the table missed. A hardcoded list is invisible to the declared-vs-projected differential, which is its own hazard: a name moved into the shape gains a build-time check that it is a kind the grammar still projects, and a name left in an engine-side array has none. See [strategies.md](strategies.md) and [formats.md](formats.md) for the plugin-interface vocabulary this engine builds on.

### Ambient imports — the `ambientImportSources` seam

Some languages let a module receive imports it does not spell: Haxe's per-directory `import.hx`, C# `global using`, a Kotlin or Scala prelude. The engine models this as one seam, `GrammarPlugin.ambientImportSources(path, pkg)`, and never as a file name — the spelling and the rule that finds the chain belong to the grammar plugin, the engine only honours the answer. Consequently no `'import.hx'` string and no chain rule appears anywhere in `anyparse.query` / `anyparse.check`; a grammar with no such concept returns an empty, bounded chain and every consumer behaves exactly as before.

**What a plugin returns.** `AmbientImports` = `sources` (each an `AmbientImportSource`: the source `file` and its `source` text) plus `bounded`. `sources` is ordered NEAREST FIRST. `source` travels with `file` because the engine parses it with the same plugin, and because a run narrowed to a few files must still read a chain member outside its scope. `pkg` is the package the index read off the module, for a grammar whose directory layout mirrors its package namespace and whose chain therefore stops at a source root it can compute rather than at a marker file. The chain is read from DISK, so a narrow run sees a member its scope does not cover — and a module path that names no file on disk has no chain at all, which is what keeps an analysed source with an invented path from taking the ambient bindings of whatever directory that path happens to spell.

**Precedence, TWO TIERS** (each step checked against `haxe --interp`, not assumed). An EXPLICIT import — a statement naming a type or its module, and the module's own declarations — is a tier ABOVE a WILDCARD import, and the whole explicit tier outranks the whole wildcard one even when the wildcard is nearer or is the reader's own. Within a tier the module's own statements outrank the chain, and a NEARER ambient source outranks a farther one. Both tiers outrank a same-package or root-package type. A nested ambient source EXTENDS its parents rather than replacing them — a name only a parent binds still resolves. The chain reaches the source root and stops there: an ambient file one directory above the root is inert, and one in the same package of a DIFFERENT source root never applies, because the rule is about directories, not packages.

**A `#if`-guarded statement decides a BUILD, so it cannot decide a declaration.** A guarded import — the module's own or an ambient source's — is present in one configuration and absent from another, and the engine sees one tree, not one configuration. So when the file has an ambient chain AND any guarded import statement, name resolution answers the UNION of two readings: one in which every guarded statement is present and one in which none is. Where they agree the union is the single answer they both gave; where they disagree it is the ambiguity that every consumer pinning a reference to one declaration already refuses on, and that is the honest reading — the compiler resolves the name differently per build, and each of the two answers was checked against it. With no ambient group the second reading can only repeat the first, so it is not taken.

**What the engine does NOT resolve.** An ALIAS statement (`import a.T as U;`) binds a name the engine does not follow, in a file's own imports and in its ambient chain alike — the compiler lets such a binding outrank a same-package `U`, and the engine cannot see that. So the consumer that would act on it refuses instead: `SubtypeGraph` leaves a written supertype whose simple name the file aliases UNRESOLVED rather than pinning it to a namesake picked by package proximity.

**Fail-closed.** `bounded == false` means the chain is knowingly SHORT — its stop point could not be established (for the Haxe plugin, a module whose directory contradicts its package), a source that exists could not be read, or one did not parse. An ambient binding outranks a same-package type, so a chain known to be short cannot be resolved against, only withheld from: `SubtypeGraph.buildAdjacency` files such a file's supertypes as unresolved. It is the ONE consumer that refuses today — `resolveTypeRefAll` and the `importMap` readers still answer from the short chain, so a new consumer that pins a reference to one declaration must read `ambientImportsBounded` itself. A module absent from disk is BOUNDED, not short — there is no chain to be short about.

**Where the engine reads it.** `FileInfo.ambientImports` carries the chain as `AmbientImportGroup` records, SEPARATE from the file's own `imports`: a rule judging a file's own import list must not see a statement the file does not carry, and every ambient `span` addresses the group's file rather than this one. Name resolution (`TypeRefIndex.resolveTypeRefAll` and the alias / module-wildcard predicates beside it, `SymbolIndex.fileImportsMemberName`, and through them `resolveTypeRefsFrom` and the subtype graph) reads the union at the precedence above. The type-aware `importMap` path takes an optional file path: given one it also carries the chain's bindings, given none it is the module's own imports, which is what a caller with no file to name should get. Every memo of a chain is RUN-scoped — one decorator instance serves every pass of a `--fix` run, so a pass that rewrote an ambient source would still be answered from the chain the first pass read.

**The INVERSE seam, for the rules that judge an ambient source's own statements.** `GrammarPlugin.ambientImportGovernance(path)` answers, for a file that IS an ambient source, the modules it GOVERNS — each with its text, read from disk for the reason the chain is — and null for an ordinary module. `bounded` false means that set could not be established, and a short set is unusable rather than smaller: a rule asking whether anything under the directory uses a binding would call it dead on the modules it never saw. So the whole file's verdict is withheld on a false. A grammar with no ambient-import concept answers null for every path and every rule behaves exactly as before.

**What each import rule does with a chain.** `unused-import` asks the governance seam who the READERS of a statement are: an ordinary module reads its own, an ambient source's readers are the modules it governs — judged against its own text every ambient statement reads as dead and the fix deletes a load-bearing import. Because the readers are read from disk, a run narrowed to the ambient source alone answers the same as a whole-tree one. Two things make that reader set deliberately imprecise, in opposite directions. A governed module arrives with no extracted import list, so its OWN `import a.T;` counts as a use of the ambient one — generous, which is the direction a deleting verdict must err in, and the duplicate is `redundant-import`'s to remove anyway. But for an `import` — and ONLY an `import` — the module that DECLARES the imported type is dropped from the set: its own `class T` is not a use of an import that names it, a module's own declaration outranks an import of itself so it never needs one, and leaving it in made a stale statement in an ambient source above its target unreportable forever. A `using` is the asymmetric case and keeps the declaring module: a module does NOT `using` itself, so one that calls its own statics extension-style depends on exactly that statement, and dropping its file there deletes a load-bearing `using`. The file's own scan is never dropped either way — a module importing a sub-module type of ITSELF needs no import, but that is a visibility verdict this rule does not make.

`redundant-import` owns the opposite case — a statement the chain already puts in force. The criterion is positive and has three parts. The group that decides the name is the NEAREST ambient group binding it AT ALL: guardedness may decide the verdict but never steer the search, because a search filtered to unguarded binders walks past a nearer group whose only binder is `#if`-guarded and reports a farther identical one, and deleting the module's own statement then retargets the name in the builds that guard is on. At that group, EVERY binder of the name must be the same unguarded statement, since within one file the last binder wins. And for a `using` there is a further gate: a `using` binds a name AND a POSITION in the static-extension order — extensions resolve in reverse declaration order, every own statement outranks every ambient one, a nearer ambient group outranks a farther one, and the last declaration of a file wins — so an identical statement elsewhere does not reproduce what the deleted one held. Only an EMPTY field of rival `using` statements, the file's own and the whole chain's, makes the two positions interchangeable; naming the method that would actually move needs a receiver-aware collision test the rule does not have. It is `RiskyFix` like the rest of the rule, so every deletion needs a `compilerOracle`. The price of that gate is worth stating: a file that carries `using Lambda` beside a `using StringTools` an ambient source also spells keeps both, so an inserted duplicate `using` survives there as a cosmetic one — legal Haxe with identical semantics, and removing it belongs at the insertion site rather than here.

`hoist-common-import` is the inverse op: it MOVES a statement most of a directory's modules spell into that directory's ambient source. DEFAULT OFF — where a project keeps its shared imports is a convention, not a defect — and `ConfigAware`: `threshold` (the percentage share, default 50), `minModules` (how many modules a directory must govern before a share of them means anything, default 3) and `usingAllowList` (the modules a `using` may be hoisted for, default `StringTools` and `Lambda`).

**Where a statement lands.** The positions an ambient source COULD occupy come from a third seam, `GrammarPlugin.ambientImportSites(path, pkg)` — the chain `ambientImportSources` would read if every rung existed, nearest first — so no engine code names a file or walks a directory, and nesting is decided from the ladders alone: one position is an ancestor of another exactly when some module lists both and the ancestor sits later. The modules a position governs are the governance seam's answer, never a second walk, and a position is weighed only when the run holds EVERY module it governs: the share is a property of the directory, and a run holding half of it would decide on half the evidence. The widest position is weighed first, so a statement lands as high as its share reaches and a nested one takes only what its parents did not — which is also what keeps one statement out of two sources of a single chain, the shape that would read as a redundant import of its own parent. A narrow run therefore hoists only out of the modules it holds: the rest keep their own statement, which is legal, which `redundant-import` owns, and which the rule never proposes again since the statement is ambient for the whole directory from then on.

**What a statement brings into scope.** A statement naming a MODULE binds every non-private type that module declares, not only its leaf — checked against the compiler, which resolved a governed module’s own same-package `Oth` to a SIBLING of the imported `Mod` that nobody had named, and did it while still compiling. A path naming one type inside a module binds only that type, an alias only the alias, a `using` of a module every type of it as well, and a module-private sibling nothing at all. `SymbolIndex.namesBoundBy` is the one place that answers it, so `hoist-common-import` and `redundant-import` cannot disagree about which names an addition or a deletion decides; both ask it for EVERY name, and both refuse when it cannot be established — a statement whose module the run never read has an unknown sibling set, and the leaf is not a safe fallback for it.

**What may move.** The criterion is POSITIVE. A plain `import a.b.C;` or `import a.b.Mod.Sub;` with an upper-initial leaf, or a `using` on the allow-list; unguarded, and in a chain that carries no guarded statement anywhere — a guarded statement decides a BUILD, so every resolution under the chain would answer the union of two readings; a simple name whose declaration is reachable by NO band the ambient statement outranks except the one the path names; a chain that is BOUNDED for every governed module; and no second binder of that name, own or ambient, since within one file the last binder wins. An ambient explicit import outranks exactly three bands a module does not spell — its own package, the root package, and its own wildcard imports — so a namesake elsewhere is not a retarget, and a module keeping its own declaration or its own explicit import of the name is simply unaffected. REFUSED: an alias, an `in`, a package wildcard, and a static wildcard, whose member set the rule cannot enumerate and whose only retarget source is a farther ambient wildcard it does not yet test for.

**What a `using` costs.** A `using` binds a name AND a position in the static-extension order, so hoisting one out of a module DEMOTES it below every own `using` that stays — a real behaviour change where two modules declare one method name. It is therefore removed only from a module whose every remaining own `using` is on the allow-list, whose members do not collide; a module carrying one off the list keeps its own statement and is left unaffected, since own outranks ambient. Adding one to a module that had none is safe in the other direction: the new candidates sit below every own `using` and below every field, so they can only be consulted where the program did not compile. And no ambient source in the chain may carry a `using` already, or the new position would insert itself above one.

**A fix that CREATES a file.** `CrossFileEdits` carries an optional `create` — the whole text of a file the slice makes — because the two answers a slice needs are opposite: an edit is refused when its file is missing, a create when its file is present, and a created file owes its revert a DELETE that no list of previous bytes can express. `CanonicalEdit.stageCrossFileCreates` validates one the way `apq new` validates a module (parseable, and at the writer's FIXED POINT, so the next writer-emit op does not call it drifted), and `LintFixDriver` commits it BEFORE the edits of its own slice — a created ambient source without the removals is harmless, the removals without it do not compile. It is written to disk inside the pass rather than with the wave at the end, because an ambient source is read from disk by the very resolution the next pass runs; the oracle baseline is therefore taken before the first such write, and the safe-pass revert deletes what it created rather than restoring bytes the file never had. Every memo whose answer depends on an ambient source's text is dropped at the head of each pass for the same reason: a memo taken before the write is a second answer for one file, since the plugin behind the decorator reads the chain fresh.

`redundant-import`’s ambient arm asks the same question of every name a statement brings: the group that decides a name has to be the SAME nearest group for all of them, and every binder of each name there the identical statement. Two groups deciding two of one statement’s names is a refusal — the surviving chain reproduces neither position whole, and the compiler hands the sibling to whichever group is nearer.

`duplicate-import` sees a file's own statements only, so an own statement equal to an ambient one is never a duplicate — it is `redundant-import`'s finding, and repetition WITHIN an ambient source is `duplicate-import`'s, exactly as in any other module. `import-order` and `fmt` treat an ambient source as the module it is: a `using` opens its own block there too, and the round trip is idempotent.

**What the ops do with one.** An ambient source is an ordinary `.hx` file to every walker, so `importers` lists it, `rename --scope` rewrites the statement's last segment in it, and `move` repoints its path — each verified on a tree whose only importer of the moved type is an ambient source. The type-aware printer needs nothing added: `importMap` takes the file's path, so `shorten-type-ref` shortens through an ambient binding without adding an import, and declines to shorten a type whose simple name the chain binds to another declaration.

## Architecture sketch

```
┌───────────────────────────────────────────────────────────┐
│  CLI dispatch (parse argv, pick command, pick grammar)    │
└─────────────────────────────┬─────────────────────────────┘
                              ▼
┌───────────────────────────────────────────────────────────┐
│  GrammarPlugin (loaded by --lang)                         │
│  - Parser (anyparse-generated)                            │
│  - AST traversal interface                                │
│  - Metavariable token marker                              │
└─────────────────────────────┬─────────────────────────────┘
                              ▼
┌───────────────────────────────────────────────────────────┐
│  Parser pipeline (anyparse runtime)                       │
│  Input file ──► parse ──► AST                             │
│  Pattern string ──► parse-with-metavars ──► Pattern AST   │
└─────────────────────────────┬─────────────────────────────┘
                              ▼
┌───────────────────────────────────────────────────────────┐
│  Engine (language-agnostic)                               │
│  - Tree walker                                            │
│  - Unification (Pattern AST × Input AST → bindings)       │
│  - Scope tracker (for refs)                               │
│  - Selector matcher (for ast --select / meta)             │
└─────────────────────────────┬─────────────────────────────┘
                              ▼
┌───────────────────────────────────────────────────────────┐
│  Output formatter — Text / JSON (--json)                  │
└───────────────────────────────────────────────────────────┘
```

**Pattern parsing reuses the grammar plugin** — a pattern is just source code with a marker for holes, which is what makes the system universal. **Unification is structural** — a metavariable accepts any subtree (with binding consistency across reuses); every other node must match by kind and child structure. **Scope tracking is plugin-supplied** — each plugin exposes which nodes introduce a lexical scope. **No caching across invocations** — the CLI is stateless; within one run parsed inputs may be memoised across queries.

## Project structure

The skeleton this spec projected, as it shipped (`src/anyparse/query/` has grown well past these modules):

```
src/anyparse/query/
  Engine.hx             # tree walker + unification, language-agnostic
  Pattern.hx            # metavariable extension over grammar parse
  Selector.hx           # path-language matcher
  Scope.hx              # lexical scope tracker
  Cli.hx                # argv dispatch, command routing (cli/ holds the registry and the command modules)
  format/
    Text.hx             # text output
    Json.hx             # JSON output
bin/
  apq-js-common.hxml    # shared build flags (no output line)
  apq-js.hxml           # leaf: writes bin/apq.js
  hxq                   # shell alias script
```

The library code lives inside `src/anyparse/` (no separate haxelib package). `bin/apq-js.hxml` produces the single-file `bin/apq.js`; `hxq` is a tiny shell wrapper that prepends `--lang haxe`. The Phase-1 neko target (`bin/apq.hxml`) is gone: the CLI spawns processes through `js.node`, and the neko artifact it built died at module load before it ran a query.

## Resolved decisions (Phase 0)

### Metavariable reuse: structural-identity unification

When the same metavariable name appears twice in a pattern, both occurrences must match **AST-structurally-identical** subtrees: same node kind, same children recursively, same leaf token text — the semgrep convention, and what `$x = $x + 1` means to a user. Rejected: pure textual identity (parenthesised vs bare forms would fail to match); type-driven unification (requires the deferred typed query layer).

### Star-children matching: ordered and adjacent by default

A pattern matching a container of children walks the input's children **left-to-right** and unifies positionally, adjacent matches only. `class { var $X; var $Y; }` matches a class whose body **begins with** two consecutive `var` fields. Rejected: order-insensitive set matching (exponentially expensive and rarely the intended semantics). The "anywhere in this container" form is the `...` ellipsis — anchored, one per child list, non-binding.

### Whitespace and comments in patterns: both ignored

Whitespace between tokens in a pattern is not an AST node and never participates in matching; comments inside the pattern are discarded by the parser; comments in the input are ignored when matching unless a future feature queries a comment slot. Rejected: treating comments as wildcard-matched nodes.

## Open questions deferred to later phases

- **Perf budget for `apq search` on large files.** Target is sub-second on the largest realistic single file (~10k lines); if unification is unacceptably slow, an indexing layer is added in Phase 5+.
- **Error reporting for malformed patterns.** Pattern parse errors must be at least as helpful as the grammar's own parse errors.

## See also

- [cli-query-roadmap.md](cli-query-roadmap.md) — phased delivery plan with exit criteria.
- [cli-query-phase0-queries.md](cli-query-phase0-queries.md) — the 10 hand-written queries that exercise the v1 syntax across all four commands.
- [journal/cli-query-log.md](journal/cli-query-log.md) — every measurement and narrative this reference condensed, verbatim.
- [architecture.md](architecture.md) — anyparse core architecture, parser pipeline, runtime.
- [strategies.md](strategies.md) — plugin contract for grammar strategies.
- [formats.md](formats.md) — plugin contract for formats.
- [haxe-format-config.md](haxe-format-config.md) — the `hxformat.json` values the Haxe writer accepts (`wrapping.*` modes and `cond` spellings), and why an unknown one is silent.
