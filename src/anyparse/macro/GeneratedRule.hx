package anyparse.macro;

#if macro
import haxe.macro.Expr;

/**
 * Output of a Lowering pass for one rule. Carries everything Codegen
 * needs to turn the rule into a Haxe `Field`:
 *
 *  - `fnName`    — the generated function name (e.g. `parseJValue`)
 *  - `returnCT`  — the `ComplexType` the function returns
 *  - `body`      — the function body expression, already rewritten
 *                  against the runtime helpers (`skipWs`, `matchLit`,
 *                  `expectLit`, `matchRe`, sibling `parseXxx` calls)
 *  - `eregs`     — static regex fields the rule needs Codegen to emit
 *                  alongside the function (matched to the `ereg.varName`
 *                  references used inside `body`)
 *  - `hasMinPrec`— true for the top-level Pratt-loop rule generated
 *                  from an enum with `@:infix` branches. The function
 *                  takes an extra `?minPrec:Int = 0` parameter that
 *                  the precedence-climbing loop reads to decide when
 *                  to stop consuming operators and return. Everywhere
 *                  else in the grammar the parameter stays defaulted,
 *                  so external call sites like `parseHxExpr(ctx)` do
 *                  not need to pass it explicitly.
 */
class GeneratedRule {

	public final fnName:String;
	public final returnCT:ComplexType;
	public final body:Expr;
	public final eregs:Array<EregSpec>;
	public final hasMinPrec:Bool;

	public function new(fnName:String, returnCT:ComplexType, body:Expr, eregs:Array<EregSpec>, hasMinPrec:Bool = false) {
		this.fnName = fnName;
		this.returnCT = returnCT;
		this.body = body;
		this.eregs = eregs;
		this.hasMinPrec = hasMinPrec;
	}
}

/**
 * Specification of one static `EReg` field that Codegen must lift out
 * of a generated rule body.
 */
typedef EregSpec = {
	/** Private static field name, e.g. `_re_JStringLit`. */
	varName:String,
	/** Regex source without surrounding slashes or `^` anchor. */
	pattern:String,
};
#end
