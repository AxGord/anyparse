package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BracePlacement;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-objectlit-leftCurly-cascade — `objectLiteralLeftCurly = Next`
 * is wrap-engine-aware. Short literals chosen NoWrap by the wrap cascade
 * stay cuddled even under `Next`; only literals the wrap engine breaks
 * to multi-line get the Allman `{` placement.
 *
 * leftCurly emission for `HxObjectLit.fields` is owned by
 * `triviaSepStarExpr` (per-slice macro change): the trivia branch
 * prepends `_dhl()` (Next) before `_dt('{')`, the no-trivia branch
 * threads `(leadFlat, leadBreak) = (_de(), _dhl())` into
 * `WrapList.emit` so `Group(IfBreak(brk, flat))` picks cuddled vs
 * Allman per the wrap cascade's own flat/break decision.
 *
 * Test is trivia-pipeline-only — knob-form leftCurly is invisible
 * from `HxModuleWriter` per `feedback_unit_test_trivia_writer.md`.
 */
@:nullSafety(Strict)
final class HxObjectLitLeftCurlyOptionsTest extends Test {

	private static final _forceParser:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final _forceWriter:Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function new():Void {
		super();
	}

	public function testShortLiteralStaysCuddledUnderNext():Void {
		final src:String = 'class Foo { static var x = {a: 1, b: 2}; }';
		final out:String = writeWith(src, BracePlacement.Next);
		Assert.isTrue(out.indexOf('= {a: 1, b: 2};') != -1, 'expected cuddled `= {a: 1, b: 2};` in: <$out>');
		Assert.isTrue(out.indexOf('=\n') == -1, 'did not expect Allman before `{` for short literal: <$out>');
	}

	public function testEmptyLiteralStaysCuddledUnderNext():Void {
		final src:String = 'class Foo { static var x = {}; }';
		final out:String = writeWith(src, BracePlacement.Next);
		Assert.isTrue(out.indexOf('= {};') != -1, 'expected cuddled `= {};` in: <$out>');
	}

	public function testMultilineSourceLiteralGoesAllmanUnderNext():Void {
		final src:String = 'class Foo {\n\tstatic var x = {\n\t\tone: 1,\n\t\ttwo: 2\n\t};\n}';
		final out:String = writeWith(src, BracePlacement.Next);
		// `{` lands at the same indent as `static var x =` (one tab inside
		// `class Foo`); inner fields get +1. Continuation-indent of var-rhs
		// is a separate concern (not in this slice).
		Assert.isTrue(out.indexOf('=\n\t{\n\t\tone:') != -1, 'expected Allman + indented brace in: <$out>');
	}

	public function testFourFieldLiteralWrapsAndGoesAllmanUnderNext():Void {
		final src:String = 'class Foo { static var x = {one: 1, two: 2, three: 3, four: 4}; }';
		final out:String = writeWith(src, BracePlacement.Next);
		Assert.isTrue(out.indexOf('=\n\t{') != -1, 'expected Allman before wrapped brace: <$out>');
	}

	public function testShortLiteralStillCuddledUnderSame():Void {
		final src:String = 'class Foo { static var x = {a: 1, b: 2}; }';
		final out:String = writeWith(src, BracePlacement.Same);
		Assert.isTrue(out.indexOf('= {a: 1, b: 2};') != -1, 'expected cuddled `= {a: 1, b: 2};` in: <$out>');
	}

	public function testTwoMultilineArgsHaveNoBlankLineBetween():Void {
		// Slice ω-opthardline regression: when two multi-line object
		// literals appear as call args under a wrap-engine break, the
		// outer wrap engine emits `,\n` between args; without
		// OptHardline the inner literal's leftCurly Next would also
		// emit `\n`, producing `,\n\n{`. With OptHardline the inner `\n`
		// is dropped — result is `,\n\t\t\t{`.
		final src:String = 'class Main {\n\tpublic static function main() {\n\t\tvar result = formatter.formatFile({\n\t\t\tname: doc.uri.toFsPath().toString(),\n\t\t\tcontent: doc.tokens.bytes\n\t\t}, {\n\t\t\ttokens: doc.tokens.list,\n\t\t\ttokenTree: doc.tokens.tree\n\t\t});\n\t}\n}\n';
		final out:String = writeWith(src, BracePlacement.Next);
		Assert.isTrue(out.indexOf(',\n\n') == -1, 'no spurious blank line between args expected in: <$out>');
	}

	public function testCascadeSetsBothKnobsViaJson():Void {
		final src:String = 'class Foo { static var x = {a: 1}; }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"leftCurly": "before"}}'
		);
		Assert.equals(BracePlacement.Next, opts.objectLiteralLeftCurly);
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		// Short literal still cuddled despite cascade
		Assert.isTrue(out.indexOf('= {a: 1};') != -1, 'expected cuddled short literal under cascaded Next: <$out>');
	}

	private inline function writeWith(src:String, placement:BracePlacement):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.objectLiteralLeftCurly = placement;
		// Disable indentObjectLiteral so this suite stays focused on the
		// leftCurly axis — slice ω-indent-objectliteral default-true would
		// otherwise add one extra indent step in front of `{` (turning
		// `=\n\t{` into `=\n\t\t{`), which is a different concern tested
		// separately in `HxIndentObjectLiteralOptionsTest`.
		opts.indentObjectLiteral = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
