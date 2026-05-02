package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BracePlacement;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-indent-objectliteral — runtime knob `indentObjectLiteral:Bool`
 * driving the `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral'))`
 * wrap on `HxVarDecl.init` and `HxObjectField.value`. When `true`
 * (default) the value Doc is wrapped in `Nest(_cols, …)` so every
 * hardline inside the literal indents one extra level relative to the
 * surrounding line; combined with `objectLiteralLeftCurly=Next`/`Both`
 * (which puts `{` on its own line) the visible effect is `var x =\n\t{`
 * instead of `var x =\n{`. When `false` the value emits unwrapped, so
 * the literal's hardlines align with the surrounding line.
 *
 * Mirrors haxe-formatter's `indentation.indentObjectLiteral: @:default(true)`.
 *
 * Multi-line emission is driven by source newlines flowing through the
 * trivia parser/writer — the trivia mode preserves per-element
 * `newlineBefore` flags, so a multi-line input produces a multi-line
 * output regardless of the `WrapRules` count threshold.
 */
@:nullSafety(Strict)
class HxIndentObjectLiteralOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultMatchesUpstream():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(true, defaults.indentObjectLiteral);
	}

	public function testJsonLoaderRoutesIndentObjectLiteralFalse():Void {
		final json:String = '{"indentation":{"indentObjectLiteral":false}}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(false, opts.indentObjectLiteral);
	}

	public function testJsonLoaderRoutesIndentObjectLiteralTrue():Void {
		final json:String = '{"indentation":{"indentObjectLiteral":true}}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(true, opts.indentObjectLiteral);
	}

	public function testJsonLoaderMissingKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(true, opts.indentObjectLiteral);
	}

	public function testTrueIndentsBraceUnderAllmanLeftCurly():Void {
		// objectLiteralLeftCurly=Next puts `{` on its own line. With
		// indentObjectLiteral=true the Nest wrap on HxVarDecl.init lifts
		// the `{` line one indent step above the `static var` line.
		final src:String = 'class C {\n\tstatic var x:T = {\n\t\ta: 1\n\t};\n}';
		final out:String = writeWith(src, true, BracePlacement.Next);
		Assert.isTrue(out.indexOf('static var x:T =\n\t\t{\n') != -1, 'expected `static var x:T =\\n\\t\\t{` in: <$out>');
	}

	public function testFalseLeavesBraceFlushUnderAllmanLeftCurly():Void {
		// Same input under indentObjectLiteral=false — `{` lands at the
		// same indent as `static var`, mirroring the pre-slice layout.
		final src:String = 'class C {\n\tstatic var x:T = {\n\t\ta: 1\n\t};\n}';
		final out:String = writeWith(src, false, BracePlacement.Next);
		Assert.isTrue(out.indexOf('static var x:T =\n\t{\n') != -1, 'expected `static var x:T =\\n\\t{` (no extra indent) in: <$out>');
	}

	public function testTrueIsInertUnderCuddledLeftCurly():Void {
		// The wrap is gated on `objectLiteralLeftCurly == Next`. Under
		// `Same` the wrap is inert even with `indentObjectLiteral=true`
		// — `{` lands on the parent line so the inner content's existing
		// nest is enough (one extra indent step would over-indent
		// relative to fork's behavior, which only fires the rule when
		// `{` is on its own line).
		final src:String = 'class C {\n\tstatic var x:T = {\n\t\ta: 1\n\t};\n}';
		final out:String = writeWith(src, true, BracePlacement.Same);
		Assert.isTrue(out.indexOf('static var x:T = {\n\t\ta:') != -1, 'expected inert wrap (`\\t\\ta:` baseline) under leftCurly=Same in: <$out>');
	}

	public function testFalseLeavesContentDefaultUnderCuddledLeftCurly():Void {
		final src:String = 'class C {\n\tstatic var x:T = {\n\t\ta: 1\n\t};\n}';
		final out:String = writeWith(src, false, BracePlacement.Same);
		Assert.isTrue(out.indexOf('static var x:T = {\n\t\ta:') != -1, 'expected baseline inner `\\t\\ta:` in: <$out>');
	}

	public function testTrueIndentsNestedObjectFieldValueUnderAllman():Void {
		// Nested ObjectLit on a `:` RHS — outer Nest wrap (HxVarDecl.init)
		// pushes outer content one step deeper, inner Nest wrap
		// (HxObjectField.value) pushes the inner `{` and its content
		// another step deeper. Inside `class C {…}` the base is one tab,
		// so the inner `{` lands at four tabs (base + outer-wrap +
		// content + inner-wrap). The fork issue_490 fixture sits at zero
		// base (no class wrapper), where the same calculation produces
		// the three-tab `\n\t\t\t{` shape recorded in fork's expected.
		final src:String = 'class C {\n\tstatic var u:U = {\n\t\tAddress: {\n\t\t\tStreet: ""\n\t\t}\n\t};\n}';
		final out:String = writeWith(src, true, BracePlacement.Next);
		Assert.isTrue(out.indexOf('Address:\n\t\t\t\t{\n') != -1, 'expected `Address:\\n\\t\\t\\t\\t{` in: <$out>');
	}

	public function testFalseLeavesNestedObjectFieldValueAtBaseUnderAllman():Void {
		final src:String = 'class C {\n\tstatic var u:U = {\n\t\tAddress: {\n\t\t\tStreet: ""\n\t\t}\n\t};\n}';
		final out:String = writeWith(src, false, BracePlacement.Next);
		Assert.isTrue(out.indexOf('Address:\n\t\t{\n') != -1, 'expected `Address:\\n\\t\\t{` (no extra indent) in: <$out>');
	}

	public function testTrueLeavesShortInlineLiteralCuddled():Void {
		// Single-field flat-fit literal stays cuddled under `true` — the
		// Nest wrap is inert when the value emits inline (no internal
		// hardlines for Nest to apply to).
		final src:String = 'class C {\n\tstatic var x:T = {a: 1};\n}';
		final out:String = writeWith(src, true, BracePlacement.Same);
		Assert.isTrue(out.indexOf('static var x:T = {a: 1}') != -1, 'expected `static var x:T = {a: 1}` (cuddled flat) in: <$out>');
	}

	public function testTrueDoesNotIndentNonObjectLitValue():Void {
		// A non-ObjectLit RHS (call expression here) is unaffected by the
		// gate — the `Type.enumConstructor(value) == 'ObjectLit'` runtime
		// check fails and the wrap degrades to plain `writeCall`.
		final src:String = 'class C {\n\tstatic var x:T = compute(1);\n}';
		final out:String = writeWith(src, true, BracePlacement.Same);
		Assert.isTrue(out.indexOf('static var x:T = compute(1)') != -1, 'expected `static var x:T = compute(1)` in: <$out>');
	}

	private inline function writeWith(src:String, indentObjectLiteral:Bool, leftCurly:BracePlacement):String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(indentObjectLiteral, leftCurly));
	}

	private inline function makeOpts(indentObjectLiteral:Bool, leftCurly:BracePlacement):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.indentObjectLiteral = indentObjectLiteral;
		opts.objectLiteralLeftCurly = leftCurly;
		return opts;
	}
}
