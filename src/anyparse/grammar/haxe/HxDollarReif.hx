package anyparse.grammar.haxe;

/**
 * Body of a named macro-reification escape: `$name{ expr }`
 * (`$i{}` / `$e{}` / `$a{}` / `$b{}` / `$v{}` / `$p{}`).
 *
 * The leading `$` and the closing `}` are consumed at the enum-branch
 * level (`@:lead("$") @:trail("}")` on `HxExpr.DollarReifExpr`). This
 * typedef describes the remainder: a single reification-name ident
 * followed by a brace-delimited recursive expression.
 *
 * Same ctor-wraps-typedef shape as `NewExpr` / `HxNewExpr`. The brace
 * lead lives on the `expr` field (not the enum-ctor param, which Haxe
 * does not allow inline metadata on); the matching `}` is the ctor's
 * `@:trail`, so no single-Ref field `@:trail` is needed.
 *
 * Intentionally permissive on the name: any identifier is accepted
 * rather than enforcing Haxe's fixed `i/e/a/b/v/p` set — semantic
 * policing belongs to a later pass, consistent with the
 * `HxAccessClause` / `HxHeritageClause` philosophy. Purely syntactic:
 * no reification semantics are applied.
 */
@:peg
typedef HxDollarReif = {
	var name: HxIdentLit;
	@:lead("{") var expr: HxExpr;
};
