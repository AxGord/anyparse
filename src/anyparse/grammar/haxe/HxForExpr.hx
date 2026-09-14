package anyparse.grammar.haxe;

/**
 * Expression-position `for` loop — the head of a Haxe array comprehension (`[for (x in xs)
 * bodyExpr]`) or any value-position for-loop where the body produces a value.
 *
 * Structurally parallel to `HxForStmt` but `body` is `HxExpr`, not `HxStatement` —
 * comprehension bodies must be value-producing expressions. Nested comprehensions like
 * `[for (a in xs) for (b in ys) a * b]` work naturally because the inner `for` is itself an
 * `HxExpr` (`ForExpr`). The statement-level form still dispatches through
 * `HxStatement.ForStmt(HxForStmt)` because enum-branch source order puts `ForStmt` ahead of
 * `ExprStmt` in `HxStatement`; the dual-typedef split mirrors `HxIfStmt`/`HxIfExpr`: same
 * source shape, different body type.
 *
 * Map key-value iteration `for (k => v in m)` goes through the optional `valueName` field —
 * `@:optional @:lead('=>')`, mirroring `HxForStmt`, whose doc carries the rationale for the
 * `@:spanned('KeyValueBinder')` wrapper.
 *
 * `@:fmt(bodyPolicy('expressionForBody'))` on `body` — distinct from `HxForStmt`'s `forBody`
 * knob because expression-position `for` needs a different default: `Keep` preserves source
 * layout via the `<field>BeforeNewline:Bool` synth slot, matching haxe-formatter's
 * `sameLine.expressionIf` default, and the JSON key `sameLine.expressionIf` overrides all
 * three expression-knob defaults uniformly. Single-line bodies under any policy stay flat.
 *
 * `@:fmt(bodyAllmanIndentForCtor('ObjectLit', 'indentObjectLiteral'))` on `body` — a
 * structural runtime override that fires when the body's runtime ctor is `ObjectLit`, the
 * body's writeCall has internal hardlines (`flatLength == -1`) and `opt.indentObjectLiteral`
 * is true: the layout becomes `_dn(_cols, [_dhl(), _dn(_cols, body)])` — `{` on its own line
 * at +cols, fields at +2cols, `}` at +cols — regardless of the policy axis AND of
 * `opt.objectLiteralLeftCurly` (which governs RHS-value contexts like `var x = {...}`). The
 * comprehension body breaks the object literal out structurally per the fork's rule for
 * `[for (x in xs) {<multi>}]`; the asymmetry vs `HxIfExpr.thenBranch` (which stays cuddled
 * for `if (cond) {<obj>}`) is the fork's per-construct rule.
 */
@:peg
typedef HxForExpr = {
	@:lead('(') var varName: HxIdentLit;
	@:optional @:lead('=>') var valueName: Null<HxKeyValueBinder>;
	@:kw('in') @:trail(')') var iterable: HxExpr;
	@:trailOpt(';') @:fmt(bodyPolicy('expressionForBody'), bodyAllmanIndentForCtor('ObjectLit', 'indentObjectLiteral'),
		strictFitLineBody('IfExpr', 'ForExpr', 'ForReifExpr', 'WhileExpr')) var body: HxExpr;
};
