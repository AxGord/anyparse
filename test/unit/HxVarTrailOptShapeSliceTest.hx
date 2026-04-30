package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-var-trailOpt-rhs-shape — `@:trailOpt(';')` on `VarStmt` / `FinalStmt`
 * gates the trailing `;` on the rhs shape via
 * `@:fmt(trailOptShapeGate('endsWithCloseBrace', 'init'))`. The gate
 * follows haxe-formatter's empirical corpus rule: only control-flow
 * expressions that visually look like statements drop the trailing `;`.
 *
 * **Drops `;`** — `var x = switch (y) { … }` (issue_119, issue_254),
 * `var f = function() { … }` block-body anon-fn (inline_calls),
 * `var x = try … catch (…) { … }` block-catch.
 *
 * **Keeps `;`** — `var x = { … };` (BlockExpr value),
 * `var o = {a: 1};` (ObjectLit value, issue_101 / space_in_anon),
 * `var x = if (a) { … } else { … };` (IfExpr value, issue_42),
 * `var f = function(x) trace(x);` (FnExpr bare-body),
 * `var x = 5;` (any non-block shape).
 *
 * Each "drops" test asserts the absence of `};` byte sequence; "keeps"
 * tests assert the explicit positive form is present.
 */
@:nullSafety(Strict)
final class HxVarTrailOptShapeSliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testVarSwitchRhsDropsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = switch (true) { case _: 1; }\n\t}\n}';
		final out:String = format(src);
		Assert.equals(-1, out.indexOf('};'), 'unexpected stray `;` after `}` in: <$out>');
	}

	public function testVarBlockRhsKeepsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = { 1; };\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('};') != -1,
			'expected `;` retained after var-rhs block expression, got: <$out>');
	}

	public function testVarIntRhsKeepsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = 5;\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('var x = 5;') != -1,
			'expected `var x = 5;` with trailing `;`, got: <$out>');
	}

	public function testVarNoInitKeepsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x:Int;\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('var x:Int;') != -1,
			'expected `var x:Int;` with trailing `;`, got: <$out>');
	}

	public function testFinalSwitchRhsDropsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tfinal x = switch (true) { case _: 1; }\n\t}\n}';
		final out:String = format(src);
		Assert.equals(-1, out.indexOf('};'), 'unexpected stray `;` after `}` in: <$out>');
	}

	public function testVarIfElseBlockRhsKeepsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = if (a) { 1; } else { 2; };\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('};') != -1,
			'expected `;` retained after var-rhs if-else-block (issue_42 contract), got: <$out>');
	}

	public function testVarObjectLitRhsKeepsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = {a: 1};\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('};') != -1,
			'expected `;` retained after var-rhs object literal (issue_101 contract), got: <$out>');
	}

	public function testVarFnExprBlockBodyRhsDropsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar g = function() { return 1; }\n\t}\n}';
		final out:String = format(src);
		Assert.equals(-1, out.indexOf('};'), 'unexpected stray `;` after `}` in: <$out>');
	}

	public function testVarFnExprBareBodyKeepsSemicolon():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar g = function(x) trace(x);\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('trace(x);') != -1,
			'expected `;` retained after bare-expr fn body, got: <$out>');
	}

	private inline function format(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
