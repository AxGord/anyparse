package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * ψ₇ — runtime-switchable `objectFieldColon` whitespace policy for the
 * `:` inside anonymous object literals. `WhitespacePolicy.After`
 * (default) emits `{a: 0}`, matching haxe-formatter's
 * `whitespace.objectFieldColonPolicy: @:default(After)`. The other
 * three policies (`None` / `Before` / `Both`) expose the remaining
 * single-character-separator spacings.
 *
 * The knob is wired via `@:fmt(objectFieldColon)` on `HxObjectField.value`
 * only — regression tests below assert that type-annotation `:` on
 * `HxVarDecl.type`, `HxParam.type`, and `HxFnDecl.returnType` stay
 * tight (`x:Int`, `f():Void`) regardless of the configured object-field
 * policy. One emission site in `WriterLowering.lowerStruct` covers the
 * mandatory-lead path, and the four type-annotation sites fall through
 * the same path unchanged.
 *
 * Tests assert the substring pattern that distinguishes each policy,
 * tolerant of unrelated layout so the assertions stay robust against
 * future layout tweaks.
 */
@:nullSafety(Strict)
class HxObjectFieldColonOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testObjectFieldColonDefaultIsAfter():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.After, defaults.objectFieldColon);
	}

	public function testObjectFieldColonAfterEmitsSpaceAfter():Void {
		final out:String = writeWith('class C { var x:Dynamic = {a: 0, b: 1}; }', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('{a: 0, b: 1}') != -1, 'expected `{a: 0, b: 1}` in: <$out>');
	}

	public function testObjectFieldColonNoneKeepsTightLayout():Void {
		final out:String = writeWith('class C { var x:Dynamic = {a: 0, b: 1}; }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('{a:0, b:1}') != -1, 'expected `{a:0, b:1}` in: <$out>');
		Assert.isTrue(out.indexOf('{a: 0') == -1, 'did not expect space after colon in: <$out>');
	}

	public function testObjectFieldColonBeforeEmitsSpaceBefore():Void {
		final out:String = writeWith('class C { var x:Dynamic = {a: 0}; }', WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('{a :0}') != -1, 'expected `{a :0}` in: <$out>');
	}

	public function testObjectFieldColonBothEmitsSpaceOnBothSides():Void {
		final out:String = writeWith('class C { var x:Dynamic = {a: 0}; }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('{a : 0}') != -1, 'expected `{a : 0}` in: <$out>');
	}

	public function testVarTypeAnnotationStaysTightRegardlessOfPolicy():Void {
		final src:String = 'class C { var x:Int = 0; }';
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith(src, policy);
			Assert.isTrue(out.indexOf('var x:Int') != -1,
				'var type annotation should stay tight under policy $policy in: <$out>');
		}
	}

	public function testFunctionReturnTypeStaysTightRegardlessOfPolicy():Void {
		final src:String = 'class C { function f():Void {} }';
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith(src, policy);
			Assert.isTrue(out.indexOf('function f():Void') != -1,
				'return type annotation should stay tight under policy $policy in: <$out>');
		}
	}

	public function testFunctionParamTypeStaysTightRegardlessOfPolicy():Void {
		final src:String = 'class C { function f(p:Int):Void {} }';
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith(src, policy);
			Assert.isTrue(out.indexOf('p:Int') != -1,
				'param type annotation should stay tight under policy $policy in: <$out>');
		}
	}

	public function testNestedObjectLiteralsFollowPolicy():Void {
		final out:String = writeWith('class C { var x:Dynamic = {a: {b: 1}}; }', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('{a: {b: 1}}') != -1, 'expected nested `{a: {b: 1}}` in: <$out>');
	}

	private inline function writeWith(src:String, objectFieldColon:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(objectFieldColon));
	}

	private inline function makeOpts(objectFieldColon:WhitespacePolicy):HxModuleWriteOptions {
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		return {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: objectFieldColon,
			typeHintColon: base.typeHintColon,
			funcParamParens: base.funcParamParens,
			elseIf: base.elseIf,
			fitLineIfWithElse: base.fitLineIfWithElse,
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
		};
	}
}
