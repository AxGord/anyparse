package unit;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * ω-fill-after-collection — a collection argument is a structural boundary:
 * the arguments after it either ALL share its line or ALL move to the next
 * one. Greedy fill instead broke at whatever column ran out, leaving
 * `[…], 155,` / `null` — a split at no boundary a reader can name.
 *
 * An EMPTY collection is excluded: `{}` is not something to navigate around.
 */
@:nullSafety(Strict)
class HxFillAfterCollectionTest extends Test {

	/** The array must reach the width cascade, else it keeps its source shape and the call never fills. */
	private static final CONFIG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, '
		+ '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, '
		+ '"arrayWrap": {"defaultWrap": "ignore", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "packedOrOnePerLine"}]}}}';

	public function new(): Void {
		super();
	}

	public function testFollowersMoveTogetherPastACollection(): Void {
		// `[…], 155,` fits (138 columns) so greedy fill packed `155` and
		// stranded `null`. One assertion over both lines — either half alone
		// is satisfied by a shape the other rejects.
		final src: String = 'class C {\n\tfunction f(message:String):Void {\n\t\tfinal form:Row = new Row('
			+ "[new Image('notifications:notice_check.svg', true, 17, 17), new Label(message, Typography.getNotification(), 110, null)], "
			+ '155, null);\n\t}\n}';
		final out: String = write(src);
		Assert.isTrue(out.indexOf('null)],\n\t\t\t155, null\n\t\t);') != -1, 'expected the followers to move together in:\n<$out>');
	}

	public function testEmptyCollectionIsNotABoundary(): Void {
		// `{}` carries nothing to navigate around; breaking after it would
		// strand two characters on their own line.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tapi.post('
			+ "'/some/reasonably/long/endpoint/path/for/the/test', {}, success -> {\n\t\t\ttrace(success);\n\t\t}, failure);\n\t}\n}";
		final out: String = write(src);
		Assert.isTrue(out.indexOf('{},\n') == -1, 'expected `{}` not to force a break in:\n<$out>');
	}

	/**
	 * ω-item-close-trail — the glue must decline when the LAST argument ends in
	 * a line comment. It renders `… lastArg <close>`, so the `)` would sit on
	 * the comment's own line; the writer's guard breaks that seam and the `)`
	 * is left ALONE under an otherwise packed call — one editor join away from
	 * commenting out the call's terminator.
	 *
	 * Declining restores the shape the cascade had ALREADY chosen (this config
	 * resolves to `fillLineWithLeadingBreak` once the line overflows), which is
	 * also what the source wrote.
	 */
	public function testCollectionGlueDeclinesATrailingLineComment(): Void {
		// Full bytes rather than a pair of `indexOf` probes: the closer half of
		// such a pair (`// last\n\t\t);`) occurs VERBATIM in the input AND in the
		// glued shape this test exists to reject, so it discriminates nothing.
		final src: String = 'class C {\n\tfunction f(message:String):Void {\n\t\tfinal form:Row = new Row(155, '
			+ "[new Image('notifications:notice_check.svg', true, 17, 17), new Label(message)] // last\n\t\t);\n\t}\n}";
		Assert.equals(
			'class C {\n\tfunction f(message:String):Void {\n\t\tfinal form:Row = new Row(\n\t\t\t155,\n\t\t\t'
			+ "[new Image('notifications:notice_check.svg', true, 17, 17), new Label(message)] // last\n\t\t);\n\t}\n}\n",
			write(src)
		);
	}

	/**
	 * ω-item-close-trail: the sibling intercept `shapeMultiArgBlockLambda` shares
	 * `multiArgBlockLambdaGlueShape`, so it shares the seam and the refusal.
	 * Pinned separately because neither gate is reachable through the other —
	 * the arrow here makes `soleMultilineCollectionArg` answer -1, so the
	 * collection intercept cannot fire, and the fixture above carries no block
	 * lambda, so this one cannot.
	 */
	public function testBlockLambdaGlueDeclinesATrailingLineComment(): Void {
		final src: String = 'class C {\n\tfunction g(message:String):Void {\n\t\tapi.post('
			+ "'/some/reasonably/long/endpoint/path', message, success -> {\n\t\t\ttrace(success);\n\t\t} // last\n\t\t);\n\t}\n}";
		Assert.equals(
			'class C {\n\tfunction g(message:String):Void {\n\t\tapi.post(\n\t\t\t'
			+ "'/some/reasonably/long/endpoint/path', message, success -> {\n\t\t\t\ttrace(success);\n\t\t\t} // last\n\t\t);\n\t}\n}\n",
			write(src)
		);
	}

	private static inline function write(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
