package anyparse.grammar.haxe;

/**
 * Catch clause grammar (block-body form).
 *
 * Shape: `catch (name:Type) body`.
 *
 * The `catch` keyword and opening `(` are both on the `name` field —
 * `@:kw('catch')` emits `expectKw` and `@:lead('(')` emits
 * `expectLit`, both sequentially (D50). The closing `)` is
 * `@:trail(')')` on the `type` field. The `body` is a bare
 * `HxStatement` Ref — any statement branch (including `BlockStmt`)
 * is accepted. The bare-expression sibling `HxCatchClauseStmtBare`
 * carries the same name/type fields with `body:HxExpr`.
 *
 * `@:fmt(bodyPolicy('catchBody'))` on `body` (slice ω-catch-body)
 * routes the `)`→body separator through the runtime `BodyPolicy`
 * switch, mirroring `HxIfStmt.thenBody` / `HxForStmt.body` /
 * `HxWhileStmt.body`. `Same` keeps `} catch (e:T) body;` flat;
 * `Next` always pushes the body to the next line at one indent
 * level deeper; `FitLine` keeps it flat when it fits within
 * `lineWidth`, otherwise breaks. Block bodies (`{ … }`) are
 * shape-aware — `bodyPolicyWrap`'s block-ctor detection routes
 * them through `sameLayoutExpr` regardless of the policy, so
 * the typical `} catch (e:T) { … }` stays inline. Default is
 * `Next` mirroring haxe-formatter's `sameLine.catchBody:
 * @:default(Next)` and the sibling `forBody` / `whileBody`
 * defaults; only non-block bodies see the difference.
 */
@:peg
typedef HxCatchClause = {
	@:kw('catch') @:lead('(') var name:HxIdentLit;
	@:lead(':') @:trail(')') var type:HxType;
	@:fmt(bodyPolicy('catchBody')) var body:HxStatement;
};
