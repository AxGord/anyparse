package anyparse.grammar.haxe;

/**
 * Statement-position catch clause grammar with bare-expression body.
 *
 * Shape: `catch (name[:Type]) body` where `body` is a bare `HxExpr`
 * with no inherent terminator. The trailing `;` for the entire
 * `try ... catch (...) BARE` chain lives on the `HxStatement.
 * TryCatchStmtBare` ctor at the parent level. Block-body siblings
 * (`HxCatchClause`) carry an `HxStatement` body instead.
 *
 * Field shape mirrors `HxCatchClauseExpr` / `HxCatchClause`:
 * `@:kw('catch') @:lead('(') @:trail(')')` on `param:HxCatchParam`
 * — the kw/lead/trail consolidate on the wrapper so the inner
 * `:Type` annotation can be omitted (e.g. `catch (_)`). The body
 * field carries `@:fmt(bareBodyBreaks)` —
 * the runtime ctor switch forces hardline + Nest for non-block
 * bodies (`catch (e:E)\n\tbody`) and keeps the inline `' '`
 * separator for block bodies (`catch (e:E) { … }`). The flag now takes an optional `BodyPolicy` knob name
 * (`@:fmt(bareBodyBreaks('catchBody'))`) — bare with no argument keeps the unconditional hardline,
 * while a named knob set to `FitLine` lets a fitting body stay on the `catch` line, which is what a
 * de-braced try/catch needs to survive its own re-parse unchanged. `@:fmt(constructFitBody)` alongside
 * it makes that escape a SOFT line owned by the enclosing construct group instead of a per-line
 * width probe, so the body breaks together with the `catch` seam.
 */
@:peg
@:spanned('CatchClause')
typedef HxCatchClauseStmtBare = {
	@:kw('catch') @:lead('(') @:trail(')') var param: HxCatchParam;
	@:fmt(bareBodyBreaks('catchBody'), constructFitBody) var body: HxExpr;
};
