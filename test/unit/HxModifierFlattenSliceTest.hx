package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice 45 — `@:fmt(forceInlineSep)` on modifier Stars.
 *
 * Closes the trivia-pipeline layout gap on `lineends/issue_626_overload_modifier`:
 * source `static\n\toverload extern inline function foo() {}` rendered through
 * the corpus harness's trivia path now flattens to `static overload extern
 * inline function foo() {}`, matching the haxe-formatter fork's expected
 * output. Plain pipeline (`HxModuleWriter`) was already inline (regression
 * guard below).
 *
 * The flag is gated to SimpleCtor-only inter-element slots so the existing
 * `HxConditionalMod` ParamCtor layout (issue_332 V1 / V4 — source newline
 * between `#end` and the next modifier keyword preserved) stays byte-
 * identical. `CondModProbe` is the cross-check.
 *
 * Trivia-mode `parse → write` is byte-identity on legal source — the inputs
 * here are the canonical flattened shape, so expected == input + `'\n'` on
 * the top-level fixture path (mirrors `CondModProbe.roundTrip`).
 */
class HxModifierFlattenSliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	// -- Trivia pipeline: multi-line modifier list FLATTENS to single line --

	public function testTriviaMemberStaticOverloadFlatten(): Void {
		flattenTrivia(
			'abstract class Foo {\n\tstatic\n\toverload extern inline function foo() {}\n}',
			'abstract class Foo {\n\tstatic overload extern inline function foo() {}\n}\n'
		);
	}

	public function testTriviaMemberOverloadStaticFlatten(): Void {
		flattenTrivia(
			'abstract class Foo {\n\toverload\n\tstatic extern inline function foo(i:Int) {}\n}',
			'abstract class Foo {\n\toverload static extern inline function foo(i:Int) {}\n}\n'
		);
	}

	public function testTriviaTopLevelOverloadStaticFlatten(): Void {
		flattenTrivia('overload\n\tstatic inline function foo(i:Int) {}', 'overload static inline function foo(i:Int) {}\n');
	}

	// -- Trivia pipeline: single modifier untouched (smoke-test empty-Star and
	// -- single-element paths — the new branch only fires at _si > 0). --

	public function testTriviaSingleModifierUntouched(): Void {
		roundTripTrivia('class C {\n\tstatic function foo() {}\n}');
	}

	public function testTriviaInlineModifierListUntouched(): Void {
		roundTripTrivia('class C {\n\tstatic overload extern inline function foo() {}\n}');
	}

	// -- Trivia pipeline: ConditionalMod boundary newline PRESERVED. --
	// -- Mirrors CondModProbe.testIssue332V1 — the `forceInlineSep` flag must
	// -- NOT collapse the `#end\n\tpublic` boundary (ParamCtor gate). --

	public function testTriviaConditionalBoundaryNewlinePreserved(): Void {
		roundTripTrivia('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end\n\tpublic static function main() {}\n}');
	}

	// -- Plain pipeline: already flattens, byte-identity guard. --

	public function testPlainMemberFlattenStillByteIdentical(): Void {
		final source: String = 'abstract class Foo {\n\tstatic\n\toverload extern inline function foo() {}\n}';
		final expected: String = 'abstract class Foo {\n\tstatic overload extern inline function foo() {}\n}\n';
		Assert.equals(expected, HxModuleWriter.write(HaxeModuleParser.parse(source)));
	}

	private static function flattenTrivia(source: String, expected: String): Void {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(expected, out, 'trivia flatten failed for <$source>');
	}

	private static function roundTripTrivia(source: String): Void {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out, 'trivia byte-identity failed for <$source>');
	}

}
