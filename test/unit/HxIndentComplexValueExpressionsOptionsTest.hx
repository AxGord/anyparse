package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-indent-complex-value-expr — runtime knob
 * `indentComplexValueExpressions:Bool` driving the second
 * `@:fmt(indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))`
 * entry on `HxVarDecl.init`. When `true` the `init` value Doc is wrapped
 * in `Nest(_cols, …)` whenever the bound `HxExpr` ctor is `IfExpr`, so
 * every hardline inside the if-expression's block bodies indents one
 * extra level relative to the `var` line. When `false` (default) the
 * wrap is inert.
 *
 * Mirrors haxe-formatter's
 * `indentation.indentComplexValueExpressions: @:default(false)` rule for
 * the `var x = if (cond) { … } else { … };` shape.
 *
 * The 2-arg form drops the leftCurly gate — `if` always cuddles its `{`
 * so a placement check would be inert.
 */
@:nullSafety(Strict)
class HxIndentComplexValueExpressionsOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultMatchesUpstream():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(false, defaults.indentComplexValueExpressions);
	}

	public function testJsonLoaderRoutesIndentComplexValueExpressionsTrue():Void {
		final json:String = '{"indentation":{"indentComplexValueExpressions":true}}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(true, opts.indentComplexValueExpressions);
	}

	public function testJsonLoaderRoutesIndentComplexValueExpressionsFalse():Void {
		final json:String = '{"indentation":{"indentComplexValueExpressions":false}}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(false, opts.indentComplexValueExpressions);
	}

	public function testJsonLoaderMissingKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(false, opts.indentComplexValueExpressions);
	}

	public function testTrueIndentsIfExprBlockBodies():Void {
		// Mirrors fork's `issue_42_if_after_assign_with_blocks_indent_assignment_expr`
		// fixture. Inside `class C {…}` the `var foo` line lands at base+1
		// (one tab). With the knob true, the if-expression's block content
		// shifts one tab deeper: `""` at base+3 instead of base+2; `} else {`
		// at base+2 instead of base+1; `};` at base+2 instead of base+1.
		final src:String = 'class C {\n\tpublic static function main() {\n\t\tvar foo = if (bar) {\n\t\t\t"";\n\t\t} else {\n\t\t\t"";\n\t\t};\n\t}\n}';
		final out:String = writeWith(src, true);
		Assert.isTrue(out.indexOf('var foo = if (bar) {\n\t\t\t\t"";\n\t\t\t} else {\n\t\t\t\t"";\n\t\t\t};') != -1, 'expected if-expr block bodies indented +1 in: <$out>');
	}

	public function testFalseLeavesIfExprBlockBodiesUnchanged():Void {
		// Default `false` keeps the layout source-faithful (no extra Nest).
		final src:String = 'class C {\n\tpublic static function main() {\n\t\tvar foo = if (bar) {\n\t\t\t"";\n\t\t} else {\n\t\t\t"";\n\t\t};\n\t}\n}';
		final out:String = writeWith(src, false);
		Assert.isTrue(out.indexOf('var foo = if (bar) {\n\t\t\t"";\n\t\t} else {\n\t\t\t"";\n\t\t};') != -1, 'expected pre-slice indent (no extra Nest) in: <$out>');
	}

	public function testTrueIsInertOnNonIfExprValue():Void {
		// Non-`IfExpr` RHS (here a plain `Int` literal) is unaffected by the
		// gate — the runtime ctor check fails and the wrap degrades to the
		// raw write call.
		final src:String = 'class C {\n\tstatic var x = 42;\n}';
		final out:String = writeWith(src, true);
		Assert.isTrue(out.indexOf('static var x = 42;') != -1, 'expected `static var x = 42;` (no wrap on non-IfExpr) in: <$out>');
	}

	public function testTrueLeavesShortInlineIfFlat():Void {
		// Single-line if-expression without internal hardlines — Nest is
		// inert when there are no hardlines to apply to. The source has no
		// hardlines around the if-expr, so the value emits flat.
		final src:String = 'class C {\n\tstatic var x = if (cond) 1 else 2;\n}';
		final out:String = writeWith(src, true);
		Assert.isTrue(out.indexOf('static var x = if (cond) 1 else 2;') != -1, 'expected single-line if cuddled flat in: <$out>');
	}

	public function testTrueDoesNotAffectObjectLitValue():Void {
		// The new entry stacks with the existing
		// `indentValueIfCtor('ObjectLit', …)` entry on the same field. They
		// match disjoint ctors, so toggling the IfExpr knob does not change
		// the ObjectLit-wrap behaviour: a multi-line obj-lit RHS still uses
		// only the ObjectLit gate (driven by `indentObjectLiteral` +
		// `objectLiteralLeftCurly`).
		final src:String = 'class C {\n\tstatic var x = {\n\t\ta: 1\n\t};\n}';
		final out:String = writeWith(src, true);
		Assert.isTrue(out.indexOf('static var x = {\n\t\ta: 1\n\t};') != -1, 'expected obj-lit unchanged when IfExpr knob true in: <$out>');
	}

	private inline function writeWith(src:String, indentComplexValueExpressions:Bool):String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(indentComplexValueExpressions));
	}

	private inline function makeOpts(indentComplexValueExpressions:Bool):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.indentComplexValueExpressions = indentComplexValueExpressions;
		return opts;
	}
}
