package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-callparam-function-block-lambda: a `function`-keyword anonymous function
 * with a BLOCK body, as a multi-arg call argument, keeps its head glued to the
 * open paren (like the arrow-body block lambda) instead of opening the call —
 * the pervasive OpenFL callback idiom (`addEventListener(evt, function(e) {…})`,
 * `Timer.delay(function() {…}, ms)`). Hugs at last / first / middle position;
 * trailing args ride the block-close line. A bare block-expr argument (first
 * token `{`, not `function`) is NOT lambda-hugged by this path.
 */
@:nullSafety(Strict)
final class HxCallParamFunctionLambdaSliceTest extends Test {

	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';

	public function new(): Void {
		super();
	}

	public function testFunctionLambdaTrailingGluesHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\twidget.bindEnterFrameHandlerHere(EventType.ENTER_FRAME_EVENT, function(eventValue:EventType):Void {\n\t\t\tadvanceFrameStep();\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testFunctionLambdaFirstThenArgGluesHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\ttimerHelper.delayInvokeCallbackHere(function():Void {\n\t\t\tdoTheThing();\n\t\t}, delayMillisValue);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testFunctionLambdaMiddleGluesHead(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\tregistry.bindHandlerAtSlotHere(slotIndexValue, function(payloadValue:PayloadType):Void {\n\t\t\thandlePayloadHere(payloadValue);\n\t\t}, priorityLevelValue);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testBareBlockExprArgNotLambdaHugged(): Void {
		final src: String = 'class C {\n\tfunction test() {\n\t\trunInScopeHere(scopeArgumentValue, {\n\t\t\tfirstStatementHere();\n\t\t\tsecondStatementHere();\n\t\t});\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
