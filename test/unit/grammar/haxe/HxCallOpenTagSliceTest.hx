package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Every writer that emits the `(` of a call's argument run names it as opening the call's arguments — the call's own,
 * a method chain segment's and a `new` argument list's — so the opBool re-evaluation, which asks whether an operand is a
 * call, sees each kind of call operand.
 */
@:nullSafety(Strict)
class HxCallOpenTagSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"tabWidth": 4}, "wrapping": {"maxLineLength": 100, "callParameter": {'
		+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], '
		+ '"type": "noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "afterLast"}]}}}';

	/** A plain call operand is a call: the chain re-evaluates after it and breaks before its operator. */
	@:pin('control')
	@:killer('M-CALLARGS-POSTFIX-CALL')
	public function testACallOperandReevaluatesTheChain(): Void {
		final out: String = HxWriteFixture.triviaWrite(source('functionWithManyParams'), CONFIG);
		Assert.isTrue(out.contains('\n\t\t\t&& functionWithManyParams('), out);
	}

	/** A method chain's call operand is a call too, its segments' argument runs named by the chain writer. */
	@:pin('control')
	@:killer('M-CALLARGS-CHAIN-SEGMENT')
	public function testAChainedCallOperandReevaluatesTheChain(): Void {
		final out: String = HxWriteFixture.triviaWrite(source('builder.make().functionWithManyParams'), CONFIG);
		Assert.isTrue(out.contains('\n\t\t\t&& builder.make()'), out);
	}

	/** A constructor call operand is a call too, its argument field marked a call's arguments by the grammar. */
	@:pin('control')
	@:killer('M-CALLARGS-NEW-ARGS')
	public function testANewOperandReevaluatesTheChain(): Void {
		final out: String = HxWriteFixture.triviaWrite(source('new FunctionWithManyParams'), CONFIG);
		Assert.isTrue(out.contains('\n\t\t\t&& new FunctionWithManyParams('), out);
	}

	private static function source(callee: String): String {
		return 'class Main {\n\tstatic function main() {\n\t\tif (conditionAlpha && $callee(longParameterA, longParameterB, '
			+ 'longParameterC, longParameterD) && conditionBravo) {\n\t\t\tdoWork();\n\t\t}\n\t}\n}';
	}

}
