package anyparse.grammar.haxe;

/**
 * /**
 * One additional binding inside a multi-variable declaration
 * (`var a = 1, b = 2;` — `b = 2` is an `HxVarMore`). Mirror of
 * `HxElseifStmt` / `HxElseifDecl` at the var-list scope: the `,`
 * separator sits on the first field's metadata so the parent's
 * `@:tryparse` Star loop in `HxVarDecl.more` can dispatch + terminate
 * uniformly — the loop calls the element parser, which fails fast when
 * the next token is not `,`, ending the list with no closing delimiter
 * required (the enclosing `VarStmt`/`FinalStmt` ctor's `@:trailOpt(';')`
 * or a `}` block-end terminates the statement).
 *
 * `decl` is a full `HxVarDecl`, so every binding after the first
 * carries the same optional `:Type` / `= init` shape as the head
 * binding. The grammar is mutually recursive with `HxVarDecl`
 * (`HxVarDecl.more : Array<HxVarMore>`), the same shape the
 * `HxConditionalStmt` / `HxElseifStmt` pair already relies on.
 *
 * Because `decl` is the recursive `HxVarDecl` (which itself carries
 * `more`), the binding list is right-recursive, not flat: `var a, b,
 * c;` parses as `a{more:[{decl: b{more:[{decl: c{more:[]}}]}}]}` —
 * each level's `more` holds exactly one `HxVarMore` whose `decl`
 * nests the remainder. This is the same right-recursion the Pratt
 * expression grammar produces; it round-trips byte-consistently (the
 * writer walks the nesting and re-emits `, b, c`) and is accepted
 * under the permissive-parser stance. A flat list would require
 * hoisting `more` onto the non-recursive `VarStmt`/`FinalStmt` ctor
 * via a ctor-wraps-typedef reshape — out of scope for this
 * parse-completeness slice. Consumers that need every binding walk `decl.more[0].decl` recursively until `more` is empty.
 *
 * `@:spanned('VarMore')` makes each continuation an ADDRESSABLE `QueryNode` carrying its own name, so `apq refs` resolves the binding and every declaration-walking check sees it. Without it the projection surfaced only the continuation's INITIALIZER, as a bare extra child of the head declaration: `var a = 0, _b = 0;` read as `(VarStmt a (IntLit 0) (IntLit 0))`, `_b` existed nowhere, and the naming rules were silently blind to it. The kind is published as `RefShape.localDeclContinuationKinds` for consumers enumerating a statement's bound names (`TailMerge.localDeclNames`); the name is lifted off the `decl` field through `QueryWalkerLowering.NAME_UNWRAP_SLOTS`.
 */
@:peg
@:spanned('VarMore')
typedef HxVarMore = {
	@:lead(',') @:fmt(spaceAfterLead) var decl: HxVarDecl;
};
