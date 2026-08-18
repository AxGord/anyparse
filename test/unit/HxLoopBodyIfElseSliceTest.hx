package unit;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * omega-loop-body-if-else-next: `sameLine.loopBodyIfElseNext` breaks a `for` / `while` header away from a body that is
 * an `if` WITH an `else`, so the two halves of that `if` sit one indent step under the loop head instead of leaving the
 * `else` at the loop's own indent, where it reads as a branch of the loop.
 *
 * The gate is the CHILD's shape, not a sibling field: `if` without `else` keeps gluing, because
 * `for (xs) if (c) f(x);` is a deliberate project idiom. That is the whole difference from `fitLineIfWithElse`, which
 * one storey down asks whether the `if` BEING placed has an `else` of its own.
 *
 * Every fixture is asserted on BOTH knob states off one config pair that differs in nothing but the knob, so a diff is
 * attributable to the knob rather than to a second config key. The config itself is a real project `hxformat.json`
 * (`forBody`/`whileBody: fitLine`, `singleStatementBraces: remove`, `fitLineBodyGlue: true`), because the glue this
 * slice changes only exists under that combination.
 */
@:nullSafety(Strict)
final class HxLoopBodyIfElseSliceTest extends Test {

	/** A real project `hxformat.json`, minified. */
	private static final PROJECT_CONFIG: String =
		'{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAn'
		+ 'ywhereInFile":1,"afterBlocks":"remove","afterLeftCurly":"remove","beforeRightCurly":"remove","classEmptyLines":{"beginType":1,"e'
		+ 'ndType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1},"uniformStatementB'
		+ 'lanks":"collapse","aroundMultilineFields":1},"wrapping":{"comprehensionCuddledOpen":true,"methodChainCuddledLinks":true,"trailin'
		+ 'gComma":"remove","arrayMatrixWrap":"matrixWrapNoAlign","functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"'
		+ 'conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"condition'
		+ 's":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"anonType":{"defaultWrap":"ignore","rules":[{"co'
		+ 'nditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}]'
		+ ',"type":"packedOrOnePerLine"}]},"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"excee'
		+ 'dsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n",'
		+ '"value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":'
		+ '3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond'
		+ '":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine'
		+ '","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exc'
		+ 'eedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"excee'
		+ 'dsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","locat'
		+ 'ion":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLi'
		+ 'neLength","value":0}],"type":"noWrap"}]},"objectLiteral":{"defaultWrap":"ignore","rules":[{"conditions":[{"cond":"exceedsMaxLine'
		+ 'Length","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]},"a'
		+ 'rrayWrap":{"defaultWrap":"ignore","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditio'
		+ 'ns":[{"cond":"exceedsMaxLineLength","value":1}],"type":"packedOrOnePerLine"}]}},"whitespace":{"addLineCommentSpace":false,"norma'
		+ 'lizeLineCommentIndent":true,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy"'
		+ ':"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"non'
		+ 'e","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{'
		+ '"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before","arrowBodyOpenPad":true,"arrowBodyReflow":true},"anonTyp'
		+ 'eBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"'
		+ 'blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"befor'
		+ 'e"},"singleStatementBraces":"remove"},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamPare'
		+ 'ns":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFu'
		+ 'ncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"'
		+ '},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"},"switchSubjectParens":"remove"}},"lineEnds":{"emptyCurly":"'
		+ 'noBreak"},"comments":{"blockCommentStyle":"javadoc"},"sameLine":{"caseBody":"fitLine","expressionCase":"fitLine","ifBody":"fitLi'
		+ 'ne","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","expressionIfFit":true,"expressionI'
		+ 'fArrowBodyReflow":true,"elseIfCommentReflow":true,"fitLineBodyGlue":true,"conditionalExprFit":true,"comprehensionFor":"fitLine"}'
		+ '}'
	;

	/** The project config with the knob ON. */
	private static final NEXT_ON: String = config(true);

	/** The same config with the knob OFF - the pre-slice layout. */
	private static final NEXT_OFF: String = config(false);

	/** A `for` whose body is a bare `if`/`else` pair, glued: the `else` sits at the `for`'s own indent. */
	private static final FOR_IF_ELSE_GLUED: String = 'class C {\n\n\tfunction apply(values:Dynamic):Void {\n'
		+ '\t\tfor (field in values.fields()) if (_groups.exists(field))\n\t\t\t_groups[field].value = values.field(field);\n'
		+ '\t\telse\n\t\t\ttrace(field);\n\t}\n\n}';

	/** The same `for` with the whole `if`/`else` one step under the header - the `else` now lines up with its `if`. */
	private static final FOR_IF_ELSE_NEXT: String = 'class C {\n\n\tfunction apply(values:Dynamic):Void {\n'
		+ '\t\tfor (field in values.fields())\n\t\t\tif (_groups.exists(field))\n'
		+ '\t\t\t\t_groups[field].value = values.field(field);\n\t\t\telse\n\t\t\t\ttrace(field);\n\t}\n\n}';

	/** A `while` whose body is a BLOCK-bodied `if`/`else`, glued to the header. */
	private static final WHILE_IF_ELSE_GLUED: String = 'class C {\n\n\tfunction fit():Void {\n'
		+ '\t\twhile (true) if (Math.abs(upper - lower) > 2) {\n\t\t\tmid = Std.int((lower + upper) / 2);\n'
		+ '\t\t\tlowerCount = numLines;\n\t\t} else {\n\t\t\tremoved = upper;\n\t\t\tbreak;\n\t\t}\n\t}\n\n}';

	/** The same `while` with the `if`/`else` under the header. */
	private static final WHILE_IF_ELSE_NEXT: String = 'class C {\n\n\tfunction fit():Void {\n'
		+ '\t\twhile (true)\n\t\t\tif (Math.abs(upper - lower) > 2) {\n\t\t\t\tmid = Std.int((lower + upper) / 2);\n'
		+ '\t\t\t\tlowerCount = numLines;\n\t\t\t} else {\n\t\t\t\tremoved = upper;\n\t\t\t\tbreak;\n\t\t\t}\n\t}\n\n}';

	/** The project idiom: a guard `if` with NO `else`, statement body. Must keep gluing under both knob states. */
	private static final FOR_GUARD_STMT: String = 'class C {\n\n\tfunction apply(xs:Array<Int>):Void {\n'
		+ '\t\tfor (x in xs) if (isWanted(x)) collect(x);\n\t}\n\n}';

	/** The same idiom with a braced body. Must keep gluing too. */
	private static final FOR_GUARD_BLOCK: String = 'class C {\n\n\tfunction apply(xs:Array<Int>):Void {\n'
		+ '\t\tfor (x in xs) if (isWanted(x)) {\n\t\t\tcollect(x);\n\t\t\tnotify(x);\n\t\t}\n\t}\n\n}';

	/** A `while` whose body is a guard `if` with no `else` - the idiom again, on the other loop. */
	private static final WHILE_GUARD_STMT: String = 'class C {\n\n\tfunction drain():Void {\n'
		+ '\t\twhile (hasNext()) if (isWanted(peek())) collect(take());\n\t}\n\n}';

	/** A loop body that is not an `if` at all - nothing about it changes. */
	private static final FOR_PLAIN_BODY: String = 'class C {\n\n\tfunction total(xs:Array<Int>):Void {\n'
		+ '\t\tfor (x in xs) sum += x;\n\t}\n\n}';

	/** An `if`/`else` that is NOT a loop body - the knob is scoped to `forBody` / `whileBody` and must not reach it. */
	private static final PLAIN_IF_ELSE: String = 'class C {\n\n\tfunction pick(flag:Bool):Void {\n\t\tif (flag)\n\t\t\ttakeFirst();\n'
		+ '\t\telse\n\t\t\ttakeSecond();\n\t}\n\n}';

	/** The reported `for` site: with the knob on, the `else` moves under its own `if`. */
	public function testForIfElseBreaksUnderHeader(): Void {
		Assert.equals(FOR_IF_ELSE_NEXT, triviaWrite(FOR_IF_ELSE_GLUED, NEXT_ON));
		Assert.equals(FOR_IF_ELSE_GLUED, triviaWrite(FOR_IF_ELSE_GLUED, NEXT_OFF));
	}

	/** The reported `while` site: a block-bodied `if`/`else` takes the same break. */
	public function testWhileIfElseBreaksUnderHeader(): Void {
		Assert.equals(WHILE_IF_ELSE_NEXT, triviaWrite(WHILE_IF_ELSE_GLUED, NEXT_ON));
		Assert.equals(WHILE_IF_ELSE_GLUED, triviaWrite(WHILE_IF_ELSE_GLUED, NEXT_OFF));
	}

	/** Already broken: writing the target shape again reproduces it, so one `fmt` pass is a fixed point. */
	public function testBrokenShapeIsIdempotent(): Void {
		Assert.equals(FOR_IF_ELSE_NEXT, triviaWrite(FOR_IF_ELSE_NEXT, NEXT_ON));
		Assert.equals(WHILE_IF_ELSE_NEXT, triviaWrite(WHILE_IF_ELSE_NEXT, NEXT_ON));
	}

	/** The project idiom is the population the gate exists to spare: no `else`, so the body stays on the header line. */
	public function testGuardIfWithoutElseStaysGlued(): Void {
		Assert.equals(FOR_GUARD_STMT, triviaWrite(FOR_GUARD_STMT, NEXT_ON));
		Assert.equals(FOR_GUARD_STMT, triviaWrite(FOR_GUARD_STMT, NEXT_OFF));
		Assert.equals(FOR_GUARD_BLOCK, triviaWrite(FOR_GUARD_BLOCK, NEXT_ON));
		Assert.equals(FOR_GUARD_BLOCK, triviaWrite(FOR_GUARD_BLOCK, NEXT_OFF));
		Assert.equals(WHILE_GUARD_STMT, triviaWrite(WHILE_GUARD_STMT, NEXT_ON));
		Assert.equals(WHILE_GUARD_STMT, triviaWrite(WHILE_GUARD_STMT, NEXT_OFF));
	}

	/** A non-`if` loop body and an `if`/`else` outside a loop are both outside the gate. */
	public function testNonLoopAndNonIfBodiesUnchanged(): Void {
		Assert.equals(FOR_PLAIN_BODY, triviaWrite(FOR_PLAIN_BODY, NEXT_ON));
		Assert.equals(FOR_PLAIN_BODY, triviaWrite(FOR_PLAIN_BODY, NEXT_OFF));
		Assert.equals(PLAIN_IF_ELSE, triviaWrite(PLAIN_IF_ELSE, NEXT_ON));
		Assert.equals(PLAIN_IF_ELSE, triviaWrite(PLAIN_IF_ELSE, NEXT_OFF));
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/**
	 * The project `hxformat.json` verbatim, with the one key under test spliced into its `sameLine` section.
	 */
	private static function config(next: Bool): String {
		return PROJECT_CONFIG.replace('"sameLine":{', '"sameLine":{"loopBodyIfElseNext":' + (next ? 'true' : 'false') + ',');
	}


}
