package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Slice D3: `;` glue inside `#if … #end` body Star.
 *
 * Pre-slice, `HxConditionalStmt.body` was `@:tryparse` Star without `@:sep`.
 * A `final/var <name> = call();` was decomposed into TWO Star elements —
 * `FinalStmt` (no trailing `;`) plus `EmptyStmt(';')` — and the writer's
 * sep-less inter-element pad inserted `' '` between them, producing
 * `call() ;`. Outside the `#if` block the same statement wrote correctly
 * because `BlockStmt.stmts` uses `@:sep(';', tailRelax, blockEnded(...))`
 * and consumes the `;` as a sep.
 *
 * Fix: align `HxConditionalStmt.body` / `elseBody` and `HxElseifStmt.body`
 * with the `BlockStmt` sep meta. The trivia pipeline (`apq ast --writer-
 * output`, dogfooded test files) now round-trips byte-identically.
 *
 * Slice D4: `elseBody` was wired LAST because the kw-led optional Star
 * path (`Lowering.emitOptionalKwStarFieldSteps`) silently ignored
 * `@:sep`. Adding the meta on its own would not have closed the bug —
 * the engine had to learn the same sep-consumption shape its
 * non-optional sibling (`emitTriviaStarFieldSteps`) already had.
 */
class HxCondCompStmtTrailOptSliceTest extends Test {

	private static final forceBuildParser: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final forceBuildWriter: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	public function testVarStmtCallRhsInsideIfEndKeepsSemiTight(): Void {
		roundTrip(
			'class T {\n\tstatic function f():Void {\n\t\t#if sys\n\t\tfinal fixture:String = writeFixture(\'class X\');\n\t\t#end\n\t}\n}'
		);
	}

	public function testTwoVarStmtsInsideIfEndKeepSemiTight(): Void {
		roundTrip('class T {\n\tstatic function f():Void {\n\t\t#if sys\n\t\tfinal a = 1;\n\t\tfinal b = 2;\n\t\t#end\n\t}\n}');
	}

	public function testElseifBodyKeepsSemiTight(): Void {
		roundTrip(
			'class T {\n\tstatic function f():Void {\n\t\t#if sys\n\t\tfinal a = 1;\n\t\t#elseif js\n\t\tfinal b = 2;\n\t\t#end\n\t}\n}'
		);
	}

	// Slice D4 — single-stmt elseBody.
	public function testElseBodyKeepsSemiTight(): Void {
		roundTrip('class T {\n\tstatic function f():Void {\n\t\t#if sys\n\t\tfinal a = 1;\n\t\t#else\n\t\tfinal b = 2;\n\t\t#end\n\t}\n}');
	}

	// Slice D4 — multi-stmt elseBody, both inter-element and trailing sep.
	public function testElseBodyMultiStmtKeepsSemiTight(): Void {
		roundTrip(
			'class T {\n\tstatic function f():Void {\n\t\t#if sys\n\t\tfinal a = 1;\n\t\t#else\n\t\tfinal b = 2;\n\t\tfinal c = 3;\n\t\t#end\n\t}\n}'
		);
	}

	private static function roundTrip(source: String): Void {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		final out: String = HaxeModuleTriviaWriter.write(ast);
		Assert.equals(source + '\n', out);
	}

}
