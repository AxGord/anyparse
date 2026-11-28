# Commands

Every `apq` / `hxq` command with its one-line summary and the flags it declares beyond the global ones (`--lang`,
`--lang-default`, `-h`, `--help`). `apq <command> --help` prints the full usage; the contract of each command (exit codes,
selector syntax, JSON schemas) is in [`cli-query-tool.md`](../cli-query-tool.md).

The table is generated from the command registry by `node bin/dev.js docs-gen`; a suite test fails when it is stale, so
regenerate it instead of editing it.

<!-- docs-gen:begin commands -->
| command | summary | flags |
|---|---|---|
| `ast` | Dump parsed AST (S-expr or JSON) | `--count` `--diff` `--doc` `--json` `--source` `--spans` `--stdin` `--type-refs` `--writer-output` `--writer-output-plain` `--at` `--children-limit` `--code` `--depth` `--max-children` `--min-children` `--select` |
| `probe` | AST/writer probe with inline source (no file IO) | `--count` `--diff` `--doc` `--json` `--source` `--spans` `--stdin` `--type-refs` `--writer-output` `--writer-output-plain` `--writer-probe` `--at` `--children-limit` `--code` `--depth` `--max-children` `--min-children` `--select` |
| `search` | Structural pattern search | `--explain` `--flat` `--json` `--kind` `--limit` |
| `refs` | Symbol references (value bindings; scope-aware) | `--decls` `--doc` `--flat` `--json` `--reads` `--source` `--writes` `--limit` |
| `rename` | Scope-correct, format-preserving symbol rename | `--qualify-shadowed` `--write` `--match` `--nth` `--scope` `--select` |
| `move` | Move a type declaration to another file (same package) | `--write` `--no-mirror` `--verify` `--match` `--nth` `--scope` `--select` `--to` |
| `move-member` | Move members to another type (any package if all static), rewriting call sites | `--closure` `--keep-bare` `--scaffold` `--write` `--scope` `--to` `--type` `--via` |
| `move-to-helper` | Move class members into a static helper taking the class as first parameter | `--dry-run` `--write` `--arms` `--file` `--param` `--scope` `--to` `--type` |
| `extract-interface` | Generate an interface from a class's public methods + implement it | `--write` `--members` `--out` `--type` |
| `pull-up` | Move an instance member up to its superclass | `--write` `--scope` `--to` `--type` |
| `push-down` | Move an instance member down to a subclass | `--write` `--scope` `--to` `--type` |
| `extract-superclass` | Generate a superclass, pull members up into it + extend it | `--write` `--members` `--out` `--type` |
| `safe-delete` | Remove a member, or a whole type, only if unreferenced across the scope | `--reformat` `--write` `--scope` `--type` |
| `encapsulate-field` | Turn a var field into a get/set property (@:isVar) | `--reformat` `--write` `--type` |
| `make-final` | Turn a never-reassigned var field into final | `--write` `--scope` `--type` |
| `introduce-parameter-object` | Fold contiguous params into one object param | `--write` `--as` `--match` `--name` `--nth` `--params` `--select` |
| `symbols` | List top-level type declarations across a scope (cross-file) | `--kind` |
| `importers` | List files importing a given module (cross-file) |  |
| `declares` | Declaration site(s) of one named type (ambiguity check) |  |
| `owner` | Which component answers a question, ranked by its doc comment and name | `--list` `--limit` |
| `lint` | Run analysis checks and report violations (e.g. unused-import) | `--all` `--dry-run` `--explain-long` `--fix` `--flat` `--full` `--list-rules` `--no-oracle` `--no-stored-builds` `--summary` `--verbose` `-a` `--baseline` `--category` `--changed-since` `--fail-on` `--fix-probes` `--format` `--range` `--review-budget` `--rule` |
| `lint-diff` | Multiset diff of two lint --format json snapshots (blast radius) | `--label` `--limit` `--new` `--old` `--root` |
| `lint-score` | Score a lint --format json report against a ground-truth file (precision, recall) | `--format` `--limit` `--severity` `--truth` |
| `oracle` | Typecheck the project once and record the verdict for lint |  |
| `mutation-verdict` | Classify one utest transcript as KILLED/SURVIVED/… for mutation-check | `--build` `--expect` |
| `mutation-schema` | Compose mutation arms into one build behind a run-time switch, for mutation-arm |  |
| `shard-plan` | Deal a runner's test classes onto N APQ_TEST shards | `--classes` `--format` `--runner` `--shards` `--weights` |
| `inline` | Inline a local variable into its uses | `--write` `--match` `--nth` `--select` |
| `inline-method` | Inline a single-return function into its call sites + delete it | `--write` `--match` `--nth` `--select` |
| `extract-typedef` | Name an anonymous structure as a typedef module, rewriting its equal occurrences | `--write` `--scope` |
| `extract-var` | Hoist an expression into a new local final | `--write` `--single` `--match` `--nth` |
| `extract-constant` | Move a literal, or one addressed constant expression, into a named constant | `--reformat` `--write` `--shared` `--into` `--literal` `--name` `--type` `--annotate` `--match` `--nth` `--select` `--to` |
| `extract-method` | Extract a statement run into a local function (closure) | `--member` `--reformat` `--write` |
| `add-param` | Add a backward-compatible parameter to a function | `--write` `--match` `--nth` `--select` |
| `change-sig` | Reorder a function's parameters + call-site args | `--write` `--match` `--nth` `--select` |
| `remove-param` | Remove a function parameter + call-site args | `--write` `--match` `--nth` `--select` |
| `add-member` | Append a member to a type body (writer-formatted, canonical-gated) | `--reformat` `--write` `--from-file` `--type` |
| `add-import` | Add an import / using to a module (writer-formatted, canonical-gated) | `--reformat` `--using` `--write` |
| `add-meta` | Add one @:metadata entry to a type or member (canonical-gated) | `--reformat` `--write` `--at` `--kind` `--match` `--nth` `--select` |
| `add-element` | Insert a sibling element — statement/case/list elem (--after/--before) | `--reformat` `--write` `--from-file` `--match` `--nth` `--select` `--after` `--before` `--append` `--sorted` |
| `move-elements` | Move a slice of an array literal's elements into another array literal (--append / --sorted) | `--dry-run` `--reformat` `--write` `--append` `--into` `--match` `--nth` `--range` `--select` `--sorted` |
| `replace-node` | Replace a node's source span (--select / --at; writer-formatted) | `--reformat` `--with-doc` `--write` `--at` `--from-file` `--kind` `--match` `--nth` `--select` |
| `patch` | Replace ONE unique fragment inside a node (old ==== new, stdin) | `--all` `--reformat` `--write` `--at` `--batch` `--from-file` `--kind` `--match` `--nth` `--select` `--sep` |
| `remove-element` | Remove a sibling element by cursor (inverse of add-element) | `--keep-doc` `--reformat` `--with-doc` `--write` `--kind` `--match` `--nth` `--select` |
| `remove-import` | Remove an import / using by module path (backend of lint --fix) | `--keep-doc` `--reformat` `--using` `--write` |
| `remove-member` | Remove a member by --type + name (inverse of add-member) | `--keep-doc` `--reformat` `--with-doc` `--write` `--match` `--nth` `--select` `--type` |
| `uses` | Type references (field/param/type-param positions) | `--doc` `--flat` `--source` `--limit` |
| `meta` | Annotation-on-decl shortcut | `--flat` `--json` `--arg-contains` `--limit` `--on` |
| `blast` | Change-impact checklist (uses + refs + member-access) | `--all` `--flat` `--limit` |
| `lit` | Leaf-name probe (string literals, identifiers — prose-in-code) | `--any-kind` `--exact` `--flat` `--include-comments` `--include-directives` `--kind` `--limit` |
| `mentions` | Every named-leaf occurrence (uses + refs + lit --any-kind --exact) | `--flat` `--limit` |
| `cases` | Precise case-pattern lookup (case Ctor: / case Ctor(_): / case A \| Ctor:) | `--flat` `--limit` |
| `cond` | Branch bodies of every #if region mentioning a define | `--active` `--flat` `--inactive` `--names` `--limit` `--max-body` |
| `resolve-define` | Fold every #if region a define decides: keep the live branch (write-twin of cond) | `--list` `--reformat` `--undefined` `--write` `-l` `-w` |
| `typed-options` | Turn a Haxe test's hxformat.json calls into the typed edit of an options kit | `--reformat` `--write` `-w` `--kit` |
| `callees` | Transitive call tree FROM a function (approximate call graph) | `--depth` `--format` `--kinds` `--limit` |
| `callers` | Transitive call tree INTO a function (approximate call graph) | `--depth` `--format` `--kinds` `--limit` |
| `reach` | Shortest call path(s) --from A --to B over the call graph | `--format` `--from` `--kinds` `--max-paths` `--to` |
| `clusters` | Partition a type's members by call-edge connectivity (hub bucket + components) | `--format` `--hubs` `--kinds` |
| `graph` | Dependency graph of a scope by package, type or member (weights, focus, mutual pairs) | `--external` `--mutual` `--edges` `--flow` `--focus` `--format` `--html` `--kinds` `--level` `--min-weight` `--package-depth` `--radius` `--diff` |
| `stdlib-dup` | Report pure functions a differential run proves equal to a stdlib call | `--census` `--limit` `--work` |
| `gates` | List @:fmt(trailOptParseGate/trailOptShapeGate) annotations + predicate names | `--flat` `--limit` `--mechanism` |
| `diff` | Structural AST diff between two files | `--flat` `--limit` |
| `changed` | What each file changed against a git revision: layout, imports, a rename, or declarations by name | `--names` `--diff` |
| `registry-follow` | Re-spell registry find/replace fragments over a mechanical rewrite of the working tree against a git revision | `--write` `--lang` |
| `merge-file` | Three-way merge of one file through its grammar — the git merge driver (merge=anyparse) | `--choices` `--path` |
| `strip` | Sed-strip + parse-check (sole-blocker confirmation) | `--dry-run` `--per-pattern` `--regex` `--show` `--delete` `--from-cluster` `--replace` `--with` |
| `writer-equals` | Byte-equality check on writer output (trivia + --plain) | `--plain` `--config` |
| `writer-probe` | Emit trivia + plain writer outputs side-by-side |  |
| `recon` | Skip-parse drill — corpus sweep + locus-cluster histogram | `--all` `--permissive-construct` `--predict-relax` `--predict-strip` `--regex` `--regression-probe` `--source` `--writer-equals` `--writer-equals-plain` `--candidates` `--cluster` `--delete` `--expected` `--no-target-cluster` `--probe` `--replace` `--top` `--with` |
| `sweep` | Read corpus sweep snapshot totals + Δ vs prior | `--run` `--corpus` `--file` `--prev` `--save` `--diff` |
| `set-modifier` | Flip visibility / add-remove modifiers at a cursor (no retype) | `--reformat` `--write` `--match` `--nth` `--select` |
| `test-summary` | Parse utest stdout transcript into tests/assertions/failures | `--exit-status` |
| `rewrite` | Structural search-and-replace (search-pattern metavars) | `--reformat` `--write` |
| `set-doc` | Add/replace a declaration's doc-comment at a cursor | `--reformat` `--write` `--from-file` `--match` `--nth` `--select` |
| `set-comment` | Replace the comment at a cursor (line run or block) | `--reformat` `--write` `--from-file` |
| `comment-rewrite` | Text find/replace inside comments (write-twin of lit; --regex) | `--allow-wide` `--list` `--reformat` `--regex` `--write` `-l` `-w` |
| `self-status` | List .hx files the grammar plugin cannot parse (dogfood gap) | `--source` `--strict` |
| `new` | Create a new module — final class / implements <iface> (canonical) | `--class` `--open` `--write` `--arm` `--arm-file` `--arms-dir` `--bodies` `--extends` `--field` `--from` `--from-file` `--implements` `--kind` `--to` `--underlying` `--raw` |
| `source` | Emit RAW verbatim file lines (no parse; --range L:L2) | `--all` `--full` `--number` `--outline` `--raw` `-n` `--at` `--range` `--select` |
| `show` | Alias of `source`, for a sandbox that vetoes that word | `--all` `--full` `--number` `--outline` `--raw` `-n` `--at` `--range` `--select` |
| `get` | Print the value at a dotted path of a data document (JSON) | `--nth` `--select` `--where` |
| `fmt` | Canonicalise Haxe source (writer round-trip; --write / --list) | `--list` `--one-pass` `--verify` `--write` `-l` `-w` |
<!-- docs-gen:end commands -->
