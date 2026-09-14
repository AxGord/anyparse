package anyparse.grammar.haxe;

/**
 * Catch clause grammar (block-body form): `catch (name[:Type]) body`.
 *
 * The `catch` keyword, opening `(` and closing `)` all sit on the `param` wrapper field —
 * `@:kw('catch')` emits `expectKw`, `@:lead('(')` emits `expectLit`, both sequentially (D50),
 * and `@:trail(')')` emits the matching closer after the inner shape parses. The inner shape
 * (name + optional `:Type`) lives in `HxCatchParam` so the type annotation can be omitted
 * (`catch (_)`); a single field cannot combine `@:optional` with a mandatory `@:trail`, so
 * the closer is hoisted onto the always-present wrapper. `body` is a bare `HxStatement` Ref
 * — any statement branch is accepted; the bare-expression sibling `HxCatchClauseStmtBare`
 * carries the same param field with `body:HxExpr`.
 *
 * `body` is `@:optional` with `@:absentOn('}')` peek-ahead — a body-less `catch (e:Type)`
 * directly followed by the enclosing block close (`} catch (e:Any)\n}`) treats the body as
 * absent instead of failing the `HxStatement` parse. There is no lead / keyword / trailing
 * token before a catch body, so `@:absentOn` (not the `@:lead`-commit-point form) is the
 * correct optional mechanism — the mirror of `HxFnExpr.body`'s `@:optional @:absentOn(',',
 * ')', ';', '}', ']')`. The terminator set is just `}`; a statement never starts with `}`,
 * so a real catch body is never mis-classified as absent. The body-less form is invalid Haxe,
 * but the haxe-formatter reference round-trips it verbatim — round-trip outranks semantic
 * validation. Byte-perfect re-emit of the body-less form (the writer must emit no body
 * token; `@:fmt(bodyPolicy('catchBody'))` operates on a present body) is a deferred
 * follow-up; a present body's codegen path is unchanged (optional-but-present == required).
 *
 * `@:fmt(bodyPolicy('catchBody'))` on `body` (ω-catch-body) routes the `)`→body separator
 * through the runtime `BodyPolicy` switch, mirroring `HxIfStmt.thenBody` / `HxForStmt.body`
 * / `HxWhileStmt.body`: `Same` keeps `} catch (e:T) body;` flat, `Next` always pushes the
 * body to the next line one indent deeper, `FitLine` keeps it flat when it fits within
 * `lineWidth`. Block bodies are shape-aware — `bodyPolicyWrap`'s block-ctor detection routes
 * them through `sameLayoutExpr` regardless of the policy, so `} catch (e:T) { … }` stays
 * inline. `@:fmt(constructFitBody)` alongside it makes the `FitLine` layout a SOFT line owned
 * by the enclosing `constructFitGroup` (see `HxTryCatchStmt`), so this body and the try body
 * break together instead of each answering for its own line. The default is `Next`,
 * haxe-formatter's `sameLine.catchBody` default; only non-block bodies see the difference.
 */
@:peg
@:spanned('CatchClause')
typedef HxCatchClause = {
	@:kw('catch') @:lead('(') @:trail(')')
	@:fmt(catchParensGap, catchParensInsideOpen, catchParensInsideClose)
	var param: HxCatchParam;
	@:optional @:absentOn('}') @:trailOpt(';') @:fmt(bodyPolicy('catchBody'), constructFitBody) var body: Null<HxStatement>;
};
