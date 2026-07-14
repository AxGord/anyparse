package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice D6 (dogfood) — `caseBody` defaults to `Keep` so the no-config
 * (dogfood) writer-equals path preserves user's same-line `case Ctor(v): body;`
 * shape instead of always exploding to `case Ctor(v):\n\tbody;`.
 *
 * Engine wiring (`bodyPolicy('caseBody', 'expressionCase')` on
 * `HxCaseBranch.body` — see `WriterLowering.bodyPolicyWrap`) already
 * honours `Keep` + `Trivial<T>.newlineBefore=false` → flat. The fix
 * flips `HaxeFormat.defaultWriteOptions.caseBody` from `Next` to `Keep`,
 * matching the existing `expressionCase: Keep` default. The corpus
 * (fork-canonical `caseBody: Next`) is preserved by re-baselining in
 * `HaxeFormatConfigLoader.loadHxFormatJson` BEFORE `applySameLine`,
 * mirroring the D5 `afterLeftCurly` / `beforeRightCurly` template.
 *
 * Sister to D5: dogfood track on `test/unit/*.hx` writes case arms
 * inline; fork-canonical breaks them. D6 closes the largest remaining
 * dogfood writer-equals fail class (67 of 188 post-D5).
 */
@:nullSafety(Strict)
class HxCaseBodySameLineSliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testDefaultOptionsKeepCaseBody(): Void {
		Assert.equals(BodyPolicy.Keep, HaxeFormat.instance.defaultWriteOptions.caseBody);
	}

	public function testDefaultOptionsKeepExpressionCase(): Void {
		Assert.equals(BodyPolicy.Keep, HaxeFormat.instance.defaultWriteOptions.expressionCase);
	}

	public function testSingleStmtCaseBodyStaysInline(): Void {
		roundTrip('class F {\n\tfunction f() {\n\t\tswitch x {\n\t\t\tcase A: doA();\n\t\t\tcase B: doB();\n\t\t}\n\t}\n}');
	}

	public function testCtorPatternCaseBodyStaysInline(): Void {
		roundTrip('class F {\n\tfunction f() {\n\t\tswitch x {\n\t\t\tcase Foo(v): use(v);\n\t\t\tcase _: fail();\n\t\t}\n\t}\n}');
	}

	public function testEmptyArmStaysEmpty(): Void {
		roundTrip('class F {\n\tfunction f() {\n\t\tswitch x {\n\t\t\tcase A:\n\t\t\tcase _: fail();\n\t\t}\n\t}\n}');
	}

	public function testMultiStmtCaseBodyStillBreaks(): Void {
		roundTrip('class F {\n\tfunction f() {\n\t\tswitch x {\n\t\t\tcase A:\n\t\t\t\tfirst();\n\t\t\t\tsecond();\n\t\t}\n\t}\n}');
	}

	public function testSourceBrokenStaysBroken(): Void {
		// Keep policy preserves source shape: if the source has the body
		// on the next line, the writer keeps it there.
		roundTrip('class F {\n\tfunction f() {\n\t\tswitch x {\n\t\t\tcase A:\n\t\t\t\tdoA();\n\t\t}\n\t}\n}');
	}

	public function testJsonOmittedAppliesForkNextDefault(): Void {
		// Fork's SameLineConfig declares `caseBody: Next`. A fixture that
		// omits `sameLine` (or the `caseBody` key inside it) must still
		// receive `Next` so corpus parity holds at Δ 0/0/0.
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Next, opts.caseBody);
	}

	public function testJsonSameLinePresentButCaseBodyOmittedAppliesForkNextDefault(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{ "sameLine": { "ifBody": "next" } }');
		Assert.equals(BodyPolicy.Next, opts.caseBody);
	}

	public function testJsonExplicitKeepStillKeeps(): Void {
		final source: String = 'class F {\n\tfunction f() {\n\t\tswitch x {\n\t\t\tcase A: doA();\n\t\t}\n\t}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{ "sameLine": { "caseBody": "keep" } }');
		Assert.equals(BodyPolicy.Keep, opts.caseBody);
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast, opts);
		Assert.equals(source + '\n', out);
	}

	private static function roundTrip(source: String): Void {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

}
