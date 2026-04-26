package anyparse.grammar.haxe;

/**
 * Statement-position catch clause grammar with bare-expression body.
 *
 * Shape: `catch (name:Type) body` where `body` is a bare `HxExpr`
 * with no inherent terminator. The trailing `;` for the entire
 * `try ... catch (...) BARE` chain lives on the `HxStatement.
 * TryCatchStmtBare` ctor at the parent level. Block-body siblings
 * (`HxCatchClause`) carry an `HxStatement` body instead.
 *
 * Field shape mirrors `HxCatchClauseExpr` / `HxCatchClause`:
 * `@:kw('catch') @:lead('(')` on `name`, `@:lead(':') @:trail(')')`
 * on `type`. The body field carries `@:fmt(bareBodyBreaks)` —
 * the runtime ctor switch forces hardline + Nest for non-block
 * bodies (`catch (e:E)\n\tbody`) and keeps the inline `' '`
 * separator for block bodies (`catch (e:E) { … }`). No policy
 * involvement: the layout is decided purely by the body's enum
 * ctor.
 */
@:peg
typedef HxCatchClauseStmtBare = {
	@:kw('catch') @:lead('(') var name:HxIdentLit;
	@:lead(':') @:trail(')') var type:HxType;
	@:fmt(bareBodyBreaks) var body:HxExpr;
};
