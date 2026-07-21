package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Expression-statement terminator elision for two wrapper shapes whose
 * `;` is consumed INSIDE the expression, leaving the enclosing
 * `HxStatement.ExprStmt` with nothing to claim.
 *
 *  - `untyped <expr>` -- a transparent keyword wrapper with no
 *    terminator slot of its own. `untyped if (...) e = e.msg;` hands the
 *    `;` to `HxIfExpr.thenBranch`'s `@:trailOpt(';')`, so the statement
 *    ends at the then-branch (std `neko/_std/sys/db/Mysql.hx:131`).
 *  - `<operand> #if ... #end` -- the `HxExpr.CondSpliceTail` postfix,
 *    but ONLY when the fragment is `else`-led, i.e. an if-chain
 *    continuation (openfl `text/_internal/TextEngine.hx:1183`). Every
 *    other fragment is an independent guarded statement and must keep
 *    demanding the `;`, otherwise the postfix reading wins and glues
 *    two unrelated statements together -- the third test is that guard,
 *    taken verbatim from Tactics Manager
 *    `video/GpuDirectPipeline.hx:48`.
 */
@:nullSafety(Strict)
final class HxExprStmtTerminatorSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testUntypedIfExprStatementNeedsNoTrailingSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f(e:Dynamic) {\n\t\tuntyped if (t(e) == o)\n\t\t\te = e.msg;\n\t\tuntyped rethrow(e);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testElseLedSpliceTailStatementNeedsNoTrailingSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tg._d = if (!a.invalid) a.dir; #if !(js && html5) else if (p.length > 0)\n'
			+ '\t\t\tp[0].dir; #end\n\t\telse mainDirection();\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testNonElseLedRegionStaysItsOwnStatement(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t@:privateAccess {\n\t\t\tfinal s:Int = 1;\n\t\t}\n\n'
			+ '\t\t#if debug final t1:Float = Sys.time(); #end\n\n\t\tfoo();\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
