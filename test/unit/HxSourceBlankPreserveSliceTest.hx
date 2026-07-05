package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-blank2 — >1-blank source gaps round-trip up to `maxConsecutiveBlanks`.
 * The trivia model carries the extra blank count (`blankBefore2:Int`)
 * beyond the single `blankBefore` bool, so the writer reproduces a two-
 * or-more blank authored gap instead of collapsing it to one. The final
 * `maxConsecutiveBlanks` cap still governs the ceiling: default `1`
 * collapses the over-emit back (fork-inert), a higher cap keeps it.
 */
@:nullSafety(Strict)
class HxSourceBlankPreserveSliceTest extends Test {

	public function new(): Void {
		super();
	}

	function write(src: String, json: String, ?capOverride: Null<Int>): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		if (capOverride != null) opts.maxConsecutiveBlanks = capOverride;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	public function testTwoSourceBlanksPreservedWhenCapTwo(): Void {
		// Two authored blank lines between two decls survive when the cap
		// permits two — the pre-fix writer collapsed them to one.
		final src: String = 'class A {}\n\n\nclass B {}';
		final out: String = write(src, '{"emptyLines": {"maxAnywhereInFile": 2}}');
		Assert.equals('class A {}\n\n\nclass B {}\n', out);
	}

	public function testThreeSourceBlanksCapTwoTrimsToTwo(): Void {
		// Three authored blanks widen the emit to three; the cap trims to two.
		final src: String = 'class A {}\n\n\n\nclass B {}';
		final out: String = write(src, '{"emptyLines": {"maxAnywhereInFile": 2}}');
		Assert.equals('class A {}\n\n\nclass B {}\n', out);
	}

	public function testTwoSourceBlanksDefaultCapOneCollapses(): Void {
		// Default cap `1` collapses the two-blank over-emit back to one —
		// the extra hardlines are inert for a fork-default config.
		final src: String = 'class A {}\n\n\nclass B {}';
		final out: String = write(src, '{}');
		Assert.equals('class A {}\n\nclass B {}\n', out);
	}

	public function testTwoSourceBlanksCapDisabledKeepsTwo(): Void {
		// Cap off (`-1`) keeps the source-faithful two-blank gap verbatim.
		final src: String = 'class A {}\n\n\nclass B {}';
		final out: String = write(src, '{}', -1);
		Assert.equals('class A {}\n\n\nclass B {}\n', out);
	}

	public function testSingleSourceBlankUnaffectedByCapTwo(): Void {
		// One authored blank carries `blankBefore2 == 0`, so a cap of two
		// leaves it at one blank — no phantom widening.
		final src: String = 'class A {}\n\nclass B {}';
		final out: String = write(src, '{"emptyLines": {"maxAnywhereInFile": 2}}');
		Assert.equals('class A {}\n\nclass B {}\n', out);
	}

	public function testInterMemberTwoBlanksPreservedWhenCapTwo(): Void {
		// The block-member Star reproduces a two-blank gap between fields.
		final src: String = 'class C {\n\tfunction a() {}\n\n\n\tfunction b() {}\n}';
		final out: String = write(src, '{"emptyLines": {"maxAnywhereInFile": 2}}');
		Assert.equals('class C {\n\tfunction a() {}\n\n\n\tfunction b() {}\n}\n', out);
	}

	public function testInterMemberTwoBlanksCollapseWhenCapOne(): Void {
		// Same member gap collapses to one blank under the default cap.
		final src: String = 'class C {\n\tfunction a() {}\n\n\n\tfunction b() {}\n}';
		final out: String = write(src, '{}');
		Assert.equals('class C {\n\tfunction a() {}\n\n\tfunction b() {}\n}\n', out);
	}

}
