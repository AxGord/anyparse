# Editing at an AST address

The ops that insert or replace code at an AST-resolved position, structural search-and-replace, and the same ops on JSON. The span-splice refactorings are in [refactoring.md](refactoring.md).

A second family — `add-member`, `add-import`, `add-element`, `replace-node` — *inserts*
new code: the snippet is placed at an AST-resolved position, then the file is re-emitted
through the writer so the new code is formatted by the grammar's own rules and
re-parse-validated in one step. Their inverses `remove-element` / `remove-import` /
`remove-member` delete a node (with its doc-comment) the same way; `remove-element --kind <Kind>`
removes the enclosing node of that kind an address names (`--match 'g($a)' --kind ExprStmt` takes the
statement the call sits in), the lift `replace-node` / `patch` already had. `add-import` /
`remove-import` take a module path or the whole statement (`add-import F.hx 'using Lambda;'`,
`remove-import F.hx 'using a.B;'`; `--using` is the flag spelling), the keyword picking the kind; a
fresh `using` lands ABOVE the file's first `using`, the lowest static-extension priority. `set-doc` adds or
replaces a declaration's doc-comment, and `set-modifier` flips its visibility / adds or
removes modifiers (`public`, `+static`, `-inline`, …) — both at a cursor, without
retyping the declaration (the safe replacement for editing a modifier via `replace-node`).
`set-comment` is the comment counterpart of `set-doc`: it replaces the comment at a
cursor — a block comment whole, a contiguous run of full-line `//` comments as one unit,
or a trailing `//` — reaching inline comments that aren't declaration doc-blocks.
`patch` is the surgical counterpart of `replace-node` for small edits: it replaces ONE
unique fragment inside the addressed node (the payload is the old fragment, a `====`
separator line, and the new fragment), so changing three lines does not resend the whole
declaration — and several pairs can be applied in one call by alternating sections
(`old1 ==== new1 ==== old2 ==== new2`), all matched against the original node text with
non-overlapping ranges. A fragment is matched byte-exact first, then line-wise with
indentation ignored (a multi-line fragment copied from the dedented `source --select`
output works as-is), and must occur exactly once within the node.

`add-element --sorted` inserts STRING entries into a hand-kept sorted list — a list such as
`TestDiscoveryParityTest`'s base classes — each at its sorted position, so nobody works out
where an entry goes or edits the file with a script: `hxq add-element T.hx --sorted --select
'FinalMember:EXPECTED_BASE_CLASSES >> ArrayExpr' "'unit.a.XTestBase', 'unit.b.YTestBase'" --write`. The address is
the ARRAY (as for `--append`); `<code>` is one entry or a comma list of them, split by the parser.
Order is code-unit order (what `TestDiscovery` sorts by). Positive by construction: every element,
existing and new, must be a constant string — a literal, or a `+` concatenation of literals (the
spelling an over-wide entry takes) — with no escape and no `$`; the existing list must already be
strictly ascending; an entry already present is refused. Each refusal names why and points at
`--append`, which stays the explicit unsorted form (a declaration-ordered list).
The file's formatting is the writer's, as for every insert op. JSON is out of reach: the only grammar
plugin is Haxe's (`--lang haxe`). The `anyparse.grammar.json` grammar has a parser and a writer, but
no `GrammarPlugin`: no spanned `QueryNode` projection for `--select` to address, and no canonical
writer configured to the layout `test/testkit/mutation-arms.json` is kept in — both are needed before
an op can insert an arm object there (an arm is an OBJECT appended in declaration order, `--append`'s
job, not `--sorted`'s).

`rewrite '<pattern>' '<replacement>'` is structural search-and-replace — the fusion of
the structural `search` with a span-replace. Every node matching the pattern (with `$x`
metavariables) is rewritten from a template in one pass: `$x` / `${x}` expand to the
captured node's source, and `${x+N}` / `${x-N}` shift an integer-literal metavariable by
N (`gofmt -r` / comby for the grammar's own AST).

`comment-rewrite '<find>' '<replace>' <path>…` is the write-twin of `lit`: a text
find/replace scoped to comment **bodies** — the gap `rewrite` (AST nodes only) and
`set-comment` (one block at a time) leave open. `--regex` makes `<find>` a regex and
`<replace>` a template where `${1}` expands a capture group and `${1+N}` shifts an
integer group by N. A literal `<find>` matches even across a comment's line breaks (a
phrase wrapped over two ` * ` doc lines). Code and the comment delimiters are never
touched; strings are skipped. A mechanical convention change cited across many doc-comments (e.g. bumping a
coordinate) becomes one command instead of a hand-rolled script.

`resolve-define <DEFINE> <path>…` is the write-twin of `cond`: it RETIRES a
conditional-compilation flag. Every `#if` region whose own conditions mention the define and whose
branches are all decided is replaced, from its `#if` marker to the end of its `#end`, by the body
of its one live branch — or deleted with its lines when no branch is live, including the
expression-position shapes (`x = #if X c ? new A() : #end new B();` folds to
`x = c ? new A() : new B();`) that no node-based rewrite can address. `--undefined` states the
opposite hypothesis, for a flag that is never set. A region a flag OUTSIDE the query also decides
is left alone and reported by position; conditions are never simplified, so `(mobile && X)` never
becomes `mobile`. Retiring a define is a one-time procedure rather than a standing policy, which is
why it is an op and not a lint rule.

**JSON files are edited by the same ops** — `add-element` (`--after` / `--before` / `--append`
/ `--sorted`), `remove-element`, `replace-node`, and read by `ast` / `source`. A `.json` path
selects the `json` grammar plugin whatever `--lang` says. The selector vocabulary is the JSON
grammar's: `JObject`, `Member:<key>` (an object entry, named by its key), `JArray`,
`JString:<value>` (named by its decoded value), `JNumber`, `JBool`, `JNull`; a `--match`
pattern is a JSON value whose `"$x"` strings are metavariables. The writer PRESERVES the
file: an edit changes its own lines only, and a new entry or member is laid out like its
siblings (one per line or inline, the document's indent unit and line end, the siblings' `:`
spacing):

```sh
hxq add-element apqlint.json --append --select 'Member:thread-safety > JObject > Member:registers > JArray' \
    '"api.NetRequest2.success"' --write
hxq remove-element apqlint.json --select 'Member:spawns > JArray > JString:api.NetRequest2.success' --write
hxq add-element test/testkit/mutation-arms.json --append --select 'Member:arms > JArray' - --write <<'EOF'
{"name": "M-X", "type": "anyparse.query.Foo", "method": "bar", "force": "null", "note": "…"}
EOF
```
