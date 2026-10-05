package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * ω-restprobe-self-break — a `GroupWithRestProbe` measures the rest of its line
 * only up to where a later construct breaks BY ITSELF.
 *
 * An inline anon type hint (`wrapping.anonType` fit cascade) used to be weighed
 * against the whole flat width of what followed it on the line, so an object
 * literal initializer that breaks anyway — its `{` is the last token of the line
 * in either layout — pushed a hint that fits onto three lines:
 * `final obj:{` / `cropRect:…, name:String` / `} = {`. The rest walk now cuts at
 * the head of a construct whose content does not fit flat even from the column
 * it reaches once the group breaks, and charges a construct that would fit then
 * in full, so a group still breaks when its break is what keeps a later list
 * on one line (`[…].contains(type)`, `t(…).chain(…)`).
 */
@:nullSafety(Strict)
class HxRestProbeSelfBreakSliceTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, '
		+ '"anonType": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}, '
		+ '"objectLiteral": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}, '
		+ '"arrayWrap": {"defaultWrap": "ignore", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, '
		+ '"whitespace": {"bracesConfig": {"anonTypeBraces": {"openingPolicy": "after", "closingPolicy": "before"}, '
		+ '"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}}}';

	private static final LITERAL: String = '{\n\t\t\t"name": itemName(i),\n'
		+ '\t\t\t"cropRect": { x: croppedRect.x, y: croppedRect.y, width: croppedRect.width, height: croppedRect.height, more: 1 }\n\t\t}';

	private static final HINT: String = '{ cropRect:{ height:Float, width:Float, x:Float, y:Float }, name:String }';

	private static final HINT_BROKEN: String = '{\n\t\t\tcropRect:{ height:Float, width:Float, x:Float, y:Float }, name:String\n\t\t}';

	private static final ARGS: String = 'firstArgumentOfHolder, secondArgumentOfHolder, thirdArgumentOfHolder, fourthArgumentOfHolder, '
		+ 'fifthArgumentOfHolder, sixthArgumentOfHolder';

	private static final ARGS_BROKEN: String = '(\n\t\t\tfirstArgumentOfHolder, secondArgumentOfHolder, thirdArgumentOfHolder, '
		+ 'fourthArgumentOfHolder, fifthArgumentOfHolder,\n\t\t\tsixthArgumentOfHolder\n\t\t)';

	public function new(): Void {
		super();
	}

	/**
	 * The reported shape: the literal breaks whatever the hint does, so the hint's line ends at
	 * `= {` and the hint, nested anon included, stays on it. The nested anon reaches the literal
	 * through the outer hint's force-flat tail, so this also pins that such a tail keeps the column.
	 */
	@:pin('control')
	@:killer('M-RESTPROBE-COLUMN-GUESS')
	@:killer('M-REST-FORCEFLAT-FRAME-INEXACT')
	public function testHintStaysFlatBeforeALiteralThatBreaksByItself(): Void {
		Assert.equals(fn('final obj:$HINT = $LITERAL;'), write(fn('final obj:$HINT = $LITERAL;')));
	}

	/**
	 * Two nested anons: the first one's tail holds the second, a rest-aware group behind a
	 * `WrapBoundary`, which renders flat or ends the line and so keeps the column.
	 */
	@:pin('control')
	@:killer('M-REST-GROUP-FRAME-INEXACT')
	@:killer('M-REST-GROUP-NODE-INEXACT')
	public function testHintWithTwoNestedAnonsStaysFlat(): Void {
		final hint: String = '{ a:{ x:Int, y:Int }, b:{ z:Int, w:Int }, name:String }';
		Assert.equals(fn('final two:$hint = $LITERAL;'), write(fn('final two:$hint = $LITERAL;')));
	}

	/** A `new` whose argument list breaks after `(` at any column is the same shape as the literal. */
	@:pin('control')
	@:killer('M-RESTPROBE-COLUMN-GUESS')
	public function testHintStaysFlatBeforeArgumentsThatBreakByThemselves(): Void {
		Assert.equals(fn('final made:$HINT = new Holder$ARGS_BROKEN;'), write(fn('final made:$HINT = new Holder($ARGS);')));
	}

	/** A short initializer never needed the cut: the hint fits with it, as it always did. */
	@:pin('guard')
	public function testHintStaysFlatBeforeAShortInitializer(): Void {
		final src: String = fn('final short:$HINT = { "name": n };\n\t\tfinal call:$HINT = make();');
		Assert.equals(src, write(src));
	}

	/**
	 * A hint that does not fit up to its own `= {` still breaks: the cut shortens the rest, never
	 * the hint, and the literal behind it then fits on its own continuation.
	 */
	@:pin('guard')
	public function testHintThatDoesNotFitStillBreaks(): Void {
		final hint: String = '{ cropRectangle:{ height:Float, width:Float, x:Float, y:Float }, nameOfTheThing:String, '
			+ 'anotherFieldHere:Int, more:Int }';
		final broken: String = '{\n\t\t\tcropRectangle:{ height:Float, width:Float, x:Float, y:Float }, nameOfTheThing:String, '
			+ 'anotherFieldHere:Int, more:Int\n\t\t}';
		Assert.equals(fn('final wide:$broken = { "name": n };'), write(fn('final wide:$hint = { "name": n };')));
	}

	/**
	 * `.contains(type)` would fit once the array breaks, so it is no break of its own: the array
	 * still opens rather than handing the overflow to a one-argument list.
	 */
	@:pin('control')
	@:killer('M-RESTPROBE-COLUMN-FLAT')
	public function testArrayStillBreaksForAShortTrailingCall(): Void {
		final items: String = 'ToolData.TYPE_STRIGHT_LINE_DASHED, ToolData.TYPE_ARC_LINE_DASHED, ToolData.TYPE_WAVE_LINE_DASHED';
		Assert.equals(
			fn('toolData.isDashed = [\n\t\t\t$items\n\t\t].contains(type);'), write(fn('toolData.isDashed = [$items].contains(type);'))
		);
	}

	/**
	 * A method-chain link opens on the width of its whole line, the group's flat content
	 * included, so it is no break point for the group: the call before it still opens.
	 */
	@:pin('control')
	@:killer('M-RESTPROBE-FULL-LINE')
	public function testCallStillBreaksBeforeAChainLink(): Void {
		final args: String = "'If this item is deleted, sessions will not work. Are you sure you want to delete the item {value}?', 10227";
		Assert.equals(
			fn('message = t(\n\t\t\t$args\n\t\t).findAndReplaceValue(\'<b>file</b>\');'),
			write(fn('message = t($args).findAndReplaceValue(\'<b>file</b>\');'))
		);
	}

	/** A function parameter's anon type followed by the body: the body's `{` was already the cut. */
	@:pin('guard')
	public function testParameterHintBeforeABodyIsUnchanged(): Void {
		final src: String = 'class C {\n\tfunction g(a:$HINT, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:Int):Void {\n\t\ttrace(a);\n\t}\n}';
		Assert.equals(src, write(src));
	}

	/** The shape the old measure produced re-writes to the flat hint, which is a fixed point. */
	@:pin('control')
	@:killer('M-RESTPROBE-COLUMN-GUESS')
	public function testTheFlatHintIsAFixedPoint(): Void {
		final once: String = write(fn('final obj:$HINT_BROKEN = $LITERAL;'));
		Assert.equals(fn('final obj:$HINT = $LITERAL;'), once);
		Assert.equals(once, write(once));
	}

	private static function fn(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private static function write(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
