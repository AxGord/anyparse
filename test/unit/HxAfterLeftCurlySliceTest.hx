package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice D5 (dogfood) — `afterLeftCurly` / `beforeRightCurly` blank-line
 * policy actually drives the writer when no `hxformat.json` is supplied.
 *
 * Engine wiring (`opt.afterLeftCurly == Keep && _firstSourceBlank`,
 * `opt.beforeRightCurly == Keep && _trailBB`) has been in `WriterLowering`
 * since the ω-class-begin-end-type slice, but `HaxeFormat.defaultWriteOptions`
 * shipped both knobs as `Remove`, so the dogfood writer-equals path on
 * `test/unit/*.hx` always stripped the user's source blanks after `{`
 * and before `}`. This slice flips the no-config defaults to `Keep`, and
 * `HaxeFormatConfigLoader.loadHxFormatJson` re-baselines to `Remove`
 * before merging the JSON so fork-canonical fixtures (corpus sweep) stay
 * Δ 0/0/0.
 *
 * Tests cover all four type-decl bodies (class / interface / abstract /
 * enum) on both sides of the brace, plus the JSON-driven explicit
 * `Remove` override that the corpus path relies on.
 */
class HxAfterLeftCurlySliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testDefaultOptionsKeepAfterLeftCurly(): Void {
		Assert.equals(KeepEmptyLinesPolicy.Keep, HaxeFormat.instance.defaultWriteOptions.afterLeftCurly);
	}

	public function testDefaultOptionsKeepBeforeRightCurly(): Void {
		Assert.equals(KeepEmptyLinesPolicy.Keep, HaxeFormat.instance.defaultWriteOptions.beforeRightCurly);
	}

	public function testClassBlankAfterLeftCurlyPreserved(): Void {
		roundTrip('class C {\n\n\tvar x:Int;\n}');
	}

	public function testClassBlankBeforeRightCurlyPreserved(): Void {
		roundTrip('class C {\n\tvar x:Int;\n\n}');
	}

	public function testInterfaceBlankAfterLeftCurlyPreserved(): Void {
		roundTrip('interface I {\n\n\tfunction f():Void;\n}');
	}

	public function testAbstractBlankAfterLeftCurlyPreserved(): Void {
		roundTrip('abstract A(Int) {\n\n\tpublic var x:Int;\n}');
	}

	public function testEnumBlankAfterLeftCurlyPreserved(): Void {
		roundTrip('enum E {\n\n\tA;\n}');
	}

	public function testNoBlankAfterLeftCurlyStaysTight(): Void {
		roundTrip('class C {\n\tvar x:Int;\n}');
	}

	public function testJsonExplicitRemoveStillRemoves(): Void {
		final source: String = 'class C {\n\n\tvar x:Int;\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{ "emptyLines": { "afterLeftCurly": "remove", "beforeRightCurly": "remove" } }'
		);
		Assert.equals(KeepEmptyLinesPolicy.Remove, opts.afterLeftCurly);
		Assert.equals(KeepEmptyLinesPolicy.Remove, opts.beforeRightCurly);
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast, opts);
		Assert.equals('class C {\n\tvar x:Int;\n}\n', out);
	}

	public function testJsonOmittedAppliesForkRemoveDefault(): Void {
		// Fork's `EmptyLinesConfig` declares both knobs `@:default(Remove)`.
		// A fixture that omits `emptyLines` (or the curly keys inside it)
		// must still receive `Remove` so corpus parity holds at Δ 0/0/0.
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(KeepEmptyLinesPolicy.Remove, opts.afterLeftCurly);
		Assert.equals(KeepEmptyLinesPolicy.Remove, opts.beforeRightCurly);
	}

	public function testJsonEmptyLinesPresentButCurlyOmittedAppliesForkRemoveDefault(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{ "emptyLines": { "afterPackage": 0 } }');
		Assert.equals(KeepEmptyLinesPolicy.Remove, opts.afterLeftCurly);
		Assert.equals(KeepEmptyLinesPolicy.Remove, opts.beforeRightCurly);
	}

	private static function roundTrip(source: String): Void {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals('$source\n', out);
	}

}
