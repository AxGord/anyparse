package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ternary-rest-aware, DECLARATION-INITIALIZER position: a ternary initializing a
 * `var` / `final` wraps `cond ? then : else` when its physical line -- INCLUDING
 * the un-flushed `= ` separator space AND the trailing `;` -- exceeds
 * maxLineLength, matching the fork. The rest-of-stack probe already counted the
 * `;`, but the space after `=` is still PENDING at the ternary's Group decision,
 * so a declaration at exactly maxLineLength + 1 stayed flat. Sister of
 * `HxTernaryCallArgRestAwareTest` (call-argument position, trailing `,`).
 *
 * `CFG` is the Tactics Manager project's real `hxformat.json` verbatim (the
 * config the reported site formats under); identifiers are fully synthetic.
 */
@:nullSafety(Strict)
final class HxTernaryDeclInitRestAwareTest extends Test {

	private static final CFG: String =
		'{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":1,"afterBlocks":"remove","afterLeftCurly":"remove","beforeRightCurly":"remove","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1},"uniformStatementBlanks":"collapse"},"wrapping":{"comprehensionCuddledOpen":true,"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"normalizeLineCommentIndent":true,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before","arrowBodyOpenPad":true,"arrowBodyReflow":true},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"},"singleStatementBraces":"remove"},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"},"switchSubjectParens":"remove"}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	public function new(): Void {
		super();
	}

	/**
	 * The declaration's physical line is 141 -- 139 measured columns plus the
	 * un-flushed `= ` space and the trailing `;`: the ternary WRAPS.
	 */
	public function testTernaryDeclInitWrapsWhenPendingSpaceOverflows(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal resolvedStamp:Int = syncResult.Success && syncResult.Payload != null\n\t\t\t? syncResult.Payload.LastModifiedStamp\n\t\t\t: fallbackStampXXX;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal resolvedStamp:Int = syncResult.Success && syncResult.Payload != null ? syncResult.Payload.LastModifiedStamp : fallbackStampXXX;\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * BOUNDARY: the declaration's physical line is EXACTLY 140 -- it stays FLAT (a
	 * line at the limit does not exceed it). Guards the off-by-one in the other
	 * direction.
	 */
	public function testTernaryDeclInitFlatAtExactLimit(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tfinal resolvedStamp:Int = syncResult.Success && syncResult.Payload != null ? syncResult.Payload.LastModifiedStamp : fallbackStampXX;\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tfinal resolvedStamp:Int = syncResult.Success && syncResult.Payload != null ? syncResult.Payload.LastModifiedStamp : fallbackStampXX;\n\t}\n}',
				CFG
			)
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
