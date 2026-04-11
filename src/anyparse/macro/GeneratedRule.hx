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
 */
class GeneratedRule {

	public final fnName:String;
	public final returnCT:ComplexType;
	public final body:Expr;
	public final eregs:Array<EregSpec>;

	public function new(fnName:String, returnCT:ComplexType, body:Expr, eregs:Array<EregSpec>) {
		this.fnName = fnName;
		this.returnCT = returnCT;
		this.body = body;
		this.eregs = eregs;
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
