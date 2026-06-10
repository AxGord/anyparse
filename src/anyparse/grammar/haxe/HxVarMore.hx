package anyparse.grammar.haxe;

/**
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
 * parse-completeness slice. Consumers that need every binding walk
 * `decl.more[0].decl` recursively until `more` is empty.
 */
@:peg
typedef HxVarMore = {
	@:lead(',') @:fmt(spaceAfterLead) var decl: HxVarDecl;
};
