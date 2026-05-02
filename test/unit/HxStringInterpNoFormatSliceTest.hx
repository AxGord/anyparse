package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-string-interp-noformat — runtime-switchable verbatim emission of
 * `${expr}` interpolation segments in single-quoted Haxe strings via
 * the `formatStringInterpolation:Bool` knob on `HxModuleWriteOptions`.
 *
 * Mechanism: `HxStringSegment.Block` carries
 * `@:fmt(captureSource('formatStringInterpolation'))`. In trivia mode
 * the synth pair `HxStringSegmentT.Block` grows a positional
 * `sourceText:String` arg filled by the parser with the byte slice
 * between `${` and `}`; the writer emits the captured slice verbatim
 * when `opt.formatStringInterpolation == false`, otherwise it recurses
 * into the parsed `HxExpr` for canonical spacing.
 *
 * Targets corpus fixtures
 * `whitespace/issue_135_string_interpolation_with_escaped_dollar_noformat`
 * and `whitespace/issue_72_whitespace_in_string_interpolation_noiformat`.
 *
 * Plain-mode pipelines (`HaxeModuleParser` / `HxModuleWriter`) are NOT
 * exercised — the synth-pair carrier is trivia-only and the knob is
 * silently inert there. Plain mode would need a second mechanism if
 * verbatim emission is ever required outside the trivia pipeline.
 *
 * Note on string escapes in this test file: Haxe single-quoted
 * strings interpolate `$ident` and `${expr}`, and a literal `$` is
 * written as `$$`. Haxe does not recognise `\$` as an escape in
 * either quote style. To represent the SOURCE-UNDER-TEST verbatim,
 * input strings use double quotes (no interpolation) and assertion-
 * message strings either use double quotes or escape `$` as `$$`
 * inside single quotes.
 */
@:nullSafety(Strict)
final class HxStringInterpNoFormatSliceTest extends Test {

	private static final _forceBuildParser:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final _forceBuildWriter:Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function new():Void {
		super();
	}

	// ---- Default (formatStringInterpolation = true) ----

	public function testDefaultIsTrue():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.isTrue(defaults.formatStringInterpolation,
			'expected formatStringInterpolation default `true`');
	}

	public function testDefaultReformatsInteriorSpaces():Void {
		// Source `${i+1}` -> expected `${i + 1}` (canonical Pratt spacing).
		final src:String = "class M { function f():Void { var s = '${i+1}'; } }";
		final out:String = formatDefault(src);
		Assert.isTrue(out.indexOf("'${i + 1}'") != -1,
			'expected reformatted single-quoted block under default knob, got: <$out>');
	}

	// ---- Knob = false (verbatim emission) ----

	public function testKnobFalseKeepsTightInterior():Void {
		final src:String = "class M { function f():Void { var s = '${i+1}'; } }";
		final out:String = formatNoFormat(src);
		Assert.isTrue(out.indexOf("'${i+1}'") != -1,
			'expected verbatim tight block under noformat knob, got: <$out>');
		Assert.equals(-1, out.indexOf("'${i + 1}'"),
			'unexpected reformatted block under noformat knob, got: <$out>');
	}

	public function testKnobFalseKeepsAuthoredSpaces():Void {
		// Source `${ i + 1 }` (leading + trailing spaces inside braces).
		// Verbatim must include both interior spaces.
		final src:String = "class M { function f():Void { var s = '${ i + 1 }'; } }";
		final out:String = formatNoFormat(src);
		Assert.isTrue(out.indexOf("'${ i + 1 }'") != -1,
			'expected verbatim spaced block under noformat knob, got: <$out>');
	}

	public function testKnobFalseKeepsBraceLiteralInside():Void {
		// issue_72 motivator: source `${foo ("{") }` with `{` inside string
		// literal AND trailing space before `}`. Verbatim emission preserves
		// both — the parsed HxExpr would render as `foo("{")` (tight call).
		final src:String = "class M { function f():Void { var s = '${foo (\"{\") }'; } }";
		final out:String = formatNoFormat(src);
		Assert.isTrue(out.indexOf("'${foo (\"{\") }'") != -1,
			'expected verbatim block with brace literal inside under noformat knob, got: <$out>');
	}

	public function testKnobFalseEscapedDollarPassesThrough():Void {
		// `$$` is the Dollar segment, not Block — captureSource is inert
		// for Dollar. `$${i+1}` parses as `$$` (escape) followed by literal
		// `{i+1}` (no interp because `$` was already consumed). Output
		// must be byte-identical to source regardless of knob.
		final src:String = "class M { function f():Void { var s = '$${i+1}'; } }";
		final out:String = formatNoFormat(src);
		Assert.isTrue(out.indexOf("'$${i+1}'") != -1,
			'expected escaped-dollar block byte-identical under noformat knob, got: <$out>');
	}

	public function testKnobFalseTripleDollarVerbatim():Void {
		// `$$${i+1}` parses as `$$` (Dollar) + `${i+1}` (Block). The Block
		// segment captures `i+1` verbatim under noformat; the Dollar is
		// untouched. Combined output must be `$${i+1}` (no spaces added).
		final src:String = "class M { function f():Void { var s = '$$${i+1}'; } }";
		final out:String = formatNoFormat(src);
		Assert.isTrue(out.indexOf("'$$${i+1}'") != -1,
			'expected triple-dollar block verbatim under noformat knob, got: <$out>');
	}

	// ---- JSON config ----

	public function testJsonFalseMapsToFalse():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"formatStringInterpolation": false}}');
		Assert.isFalse(opts.formatStringInterpolation,
			'expected `false` from JSON config');
	}

	public function testJsonTrueMapsToTrue():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"formatStringInterpolation": true}}');
		Assert.isTrue(opts.formatStringInterpolation,
			'expected `true` from JSON config');
	}

	public function testJsonAbsentKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.isTrue(opts.formatStringInterpolation,
			'expected default `true` when key absent');
	}

	private inline function formatDefault(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	private inline function formatNoFormat(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"whitespace": {"formatStringInterpolation": false}}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
