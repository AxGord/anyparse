package anyparse.grammar.haxe;

/**
 * Payload of `HxDecl.ImportAliasInDecl` — single-symbol `import` with
 * the legacy pre-Haxe-4 `in Name` alias clause (slice ω-import-in-
 * alias). Spelling twin of `HxImportAlias` (the modern `as Name`
 * form): `import python.Exceptions.Exception in PyException;` instead
 * of `import python.Exceptions.Exception as PyException;`. Both
 * spellings are valid Haxe today and are semantically identical — the
 * ONLY reason this is a separate struct + ctor rather than a second
 * keyword choice on `HxImportAlias.name` is round-trip fidelity: the
 * writer must re-emit whichever keyword the source used, never
 * rewrite one spelling to the other, and the PEG engine captures a
 * literal keyword's presence, not its exact matched text, so two
 * struct shapes (each with its own hard-coded `@:kw`) is the only way
 * to keep the two spellings from collapsing into one output form.
 *
 * Shape mirrors `HxImportAlias` exactly: a dotted-ident `HxTypeName`
 * followed by the mandatory `in <ident>` suffix. The leading `import`
 * keyword and the trailing `;` live on the `HxDecl.ImportAliasInDecl`
 * ctor, mirroring the kw/trail split on `ImportDecl` / `ImportAliasDecl`.
 * Same multi-positional-ctor restriction as `HxImportAlias` applies —
 * `ImportAliasInDecl(path, alias)` would hit "unsupported enum branch
 * shape" — so both fields live in this wrapper struct.
 *
 * `@:kw('in')` on `name` is hard, not `@:optional`, for the same
 * tryBranch-rollback reason as `HxImportAlias.name`'s `@:kw('as')`:
 * a missing `in` rolls back to the plain `ImportDecl` branch. `in`
 * fires word-boundary matching so `input` is not eaten as the keyword.
 *
 * Ordering at the `HxDecl` dispatch site does not matter between this
 * ctor and `ImportAliasDecl` — `as` and `in` are mutually exclusive
 * keywords, so at most one of the two alias branches can ever match a
 * given import; both are tried before the plain `ImportDecl` fallback
 * (longer-match-first, same rollback pattern as `ImportWildDecl` →
 * `ImportDecl`).
 *
 * Real-world motivation: `python.net.SslSocket` (Python std lib
 * bindings) mixes both spellings in adjacent import lines, and
 * `cs`/`js` std-lib modules (`cs._std.sys.net.Socket`, `js.lib.Date`)
 * use the legacy `in` form exclusively — pre-Haxe-4 code that has
 * never been migrated to `as`.
 */
@:peg
typedef HxImportAliasIn = {
	var path: HxTypeName;
	@:kw('in') var name: HxIdentLit;
}
