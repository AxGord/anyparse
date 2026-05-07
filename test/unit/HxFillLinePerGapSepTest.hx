package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-fillline-pergap-sep — `WrapList.shapeFillLine` per-gap sep
 * awareness. Items split into chunks at every leading-hardline
 * boundary; within each chunk items pack via `Fill(chunk, softSep)`
 * (Wadler fillSep, soft `Line(' ')`); between chunks a forced
 * `Text(sep) + Line('\n')` enforces the break in front of the next
 * chunk's leading-hardline first item.
 *
 * Replaces the previous `forceBreak`-when-anyLeadingHardline mechanism
 * which over-fired: with one hardline-led item in a list of N, ALL
 * N-1 seps were turned into forced hardlines, breaking even between
 * items that would otherwise pack inline.
 *
 * Coverage:
 *  - Mixed soft + leading-hardline arg list (the regression case
 *    surfaced by `call_wrapping_indent.hxtest`'s inner Call): the
 *    objLit-with-`leftCurly=Next` arg's leading hardline must NOT
 *    smear onto the soft seps before non-hardline args. Pre-fix the
 *    `forceBreak` arm forced every gap to break, putting `id, false,
 *    {…}` each on its own line; post-fix only the gap before the
 *    objLit chunk breaks.
 *  - All-hardline-led arg list (the `issue_138` regression base): all
 *    gaps break via the chunk boundaries — same observable layout the
 *    pre-fix `forceBreak` produced. Confirms the chunked structure
 *    preserves the multi-objLit-arg fix.
 */
@:nullSafety(Strict)
final class HxFillLinePerGapSepTest extends Test {

	private static final _forceBuildParser:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final _forceBuildWriter:Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function new():Void {
		super();
	}

	public function testSoftArgsStayInlineBeforeHardlineLedArg():Void {
		// `f(id, false, {…})` with `leftCurly=Next` (objLit gets a leading
		// hardline). Soft args `id`, `false` pack inline; only the gap
		// before the objLit breaks.
		final src:String = 'class Foo { static function go() { f(id, false, {longFieldA: 1, longFieldB: 2, longFieldC: 3, longFieldD: 4, longFieldE: 5}); } }';
		final out:String = writeWith(src, '{"lineEnds": {"leftCurly": "both"}}');
		Assert.isTrue(out.indexOf('f(id, false,\n') != -1,
			'expected `id, false,` to stay inline before the objLit break in: <$out>');
		Assert.isTrue(out.indexOf('id,\n') == -1,
			'pre-fix `forceBreak` smeared `id,\\n` between args — must NOT appear: <$out>');
	}

	public function testMultipleHardlineLedArgsAllBreak():Void {
		// `f({…}, {…})` with both args hardline-led: every chunk
		// boundary forces the `Text(sep) + Line('\n')` break, so both
		// objLits land on their own indented lines — same observable
		// shape as the pre-slice `forceBreak` mechanism for the
		// `issue_138` regression base.
		final src:String = 'class Foo { static function go() { f({longFieldA: 1, longFieldB: 2, longFieldC: 3, longFieldD: 4}, {anotherFieldA: 1, anotherFieldB: 2, anotherFieldC: 3, anotherFieldD: 4}); } }';
		final out:String = writeWith(src, '{"lineEnds": {"leftCurly": "both"}}');
		// Both objLits should be on their own lines, with the comma
		// after the first one's `}` followed by a hardline before the
		// second `{`.
		Assert.isTrue(out.indexOf('},\n') != -1,
			'expected `},\\n` between the two hardline-led args in: <$out>');
		// And neither objLit should be glued inline to the call's open
		// paren (both should land at the call's continuation indent
		// after their leading hardline).
		Assert.isTrue(out.indexOf('f({') == -1,
			'expected break before first objLit (hardline-led) — must not glue inline in: <$out>');
	}

	private inline function writeWith(src:String, configJson:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(configJson);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
