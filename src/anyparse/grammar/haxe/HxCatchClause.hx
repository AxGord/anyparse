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
 * `body` is `@:optional` with `@:absentOn('}')` peek-ahead — a
 * body-less `catch (e:Type)` directly followed by the enclosing
 * block close (`} catch (e:Any)\n}`) treats the body as absent
 * instead of failing the `HxStatement` parse. There is no lead /
 * keyword / trailing token before a catch body, so `@:absentOn`
 * (not the `@:lead`-commit-point form) is the correct optional
 * mechanism — exact mirror of `HxFnExpr.body`'s
 * `@:optional @:absentOn(',', ')', ';', '}', ']')`. The terminator
 * set is just `}` because that is the only context the
 * recon-confirmed cluster reaches (the do-while/try-catch
 * `whitespace/issue_583_*` fixtures, post-Slice-2 multi-var); a
 * statement never starts with `}`, so a real catch body is never
 * mis-classified as absent. This is invalid Haxe (a catch needs a
 * body) but the haxe-formatter reference round-trips it verbatim —
 * anyparse philosophy is round-trip over Haxe semantic validation.
 * Byte-perfect re-emit of the body-less form (the writer must emit
 * no body token; `@:fmt(bodyPolicy('catchBody'))` operates on a
 * present body) is a deferred follow-up — newly-parsing fixtures
 * land in `fail` until then (the Slice S1 / Slice 2 caveat pattern).
 * The 482 already-passing fixtures all have a body, so their
 * codegen path is byte-identical (optional-but-present == required).
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
@:spanned('CatchClause')
typedef HxCatchClause = {
	@:kw('catch') @:lead('(') var name:HxIdentLit;
	@:lead(':') @:trail(')') var type:HxType;
	@:optional @:absentOn('}') @:fmt(bodyPolicy('catchBody')) var body:Null<HxStatement>;
};
