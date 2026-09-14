package anyparse.grammar.haxe;

/**
 * Payload of `HxDecl.ImportAliasInDecl` — single-symbol `import` with the legacy pre-Haxe-4
 * `in Name` alias clause (ω-import-in-alias); spelling twin of `HxImportAlias` (the modern
 * `as Name` form, which std-lib bindings such as `python`/`cs`/`js` still mix with this one).
 * The two spellings are semantically identical; the ONLY reason this is a separate struct +
 * ctor rather than a second keyword choice on `HxImportAlias.name` is round-trip fidelity: the
 * writer must re-emit whichever keyword the source used, and the PEG engine captures a literal
 * keyword's presence, not its matched text, so two struct shapes (each with its own hard-coded
 * `@:kw`) is the only way to keep the spellings apart.
 *
 * Shape mirrors `HxImportAlias`: a dotted-ident `HxTypeName` followed by the mandatory
 * `in <ident>` suffix; the leading `import` keyword and the trailing `;` live on the
 * `HxDecl.ImportAliasInDecl` ctor. Both fields live in this wrapper struct because a
 * multi-positional ctor is an unsupported enum branch shape.
 *
 * `@:kw('in')` on `name` is hard, not `@:optional`: a missing `in` rolls back to the plain
 * `ImportDecl` branch (the same tryBranch-rollback reason as `HxImportAlias.name`'s
 * `@:kw('as')`); `in` matches on a word boundary so `input` is not eaten as the keyword.
 * Ordering against `ImportAliasDecl` at the `HxDecl` dispatch site does not matter — `as` and
 * `in` are mutually exclusive — and both are tried before the plain `ImportDecl` fallback.
 */
@:peg
typedef HxImportAliasIn = {
	var path: HxTypeName;
	@:kw('in') var name: HxIdentLit;
}
