package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice ω-typedef-assign — runtime-switchable `typedefAssign`
 * whitespace policy for the `=` joining a typedef name and its
 * right-hand-side type. `WhitespacePolicy.Both` (default) emits
 * `typedef Foo = Bar;`, matching haxe-formatter's
 * `whitespace.binopPolicy: @:default(Around)`. The other three
 * policies expose the remaining single-character-separator spacings.
 *
 * The knob is wired via `@:fmt(typedefAssign)` on `HxTypedefDecl.type`
 * only — regression tests below assert that the optional `=` leads on
 * `HxVarDecl.init` and `HxParam.defaultValue` keep their pre-slice
 * ` = ` layout regardless of the configured typedef policy. They flow
 * through the bare-optional fallback path in `lowerStruct` rather than
 * through `whitespacePolicyLead`.
 */
@:nullSafety(Strict)
final class HxTypedefAssignOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testTypedefAssignDefaultIsBoth():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.Both, defaults.typedefAssign);
	}

	public function testTypedefAssignBothEmitsSpacedEquals():Void {
		final out:String = writeWith('typedef Foo = Bar;', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('typedef Foo = Bar;') != -1, 'expected `typedef Foo = Bar;` in: <$out>');
	}

	public function testTypedefAssignNoneEmitsTightEquals():Void {
		final out:String = writeWith('typedef Foo = Bar;', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('typedef Foo=Bar;') != -1, 'expected `typedef Foo=Bar;` in: <$out>');
		Assert.isTrue(out.indexOf('Foo = Bar') == -1, 'did not expect spaced `=` in: <$out>');
	}

	public function testTypedefAssignBeforeEmitsSpaceBefore():Void {
		final out:String = writeWith('typedef Foo = Bar;', WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('typedef Foo =Bar;') != -1, 'expected `typedef Foo =Bar;` in: <$out>');
	}

	public function testTypedefAssignAfterEmitsSpaceAfter():Void {
		final out:String = writeWith('typedef Foo = Bar;', WhitespacePolicy.After);
		Assert.isTrue(out.indexOf('typedef Foo= Bar;') != -1, 'expected `typedef Foo= Bar;` in: <$out>');
	}

	public function testFunctionTypedefRoundtripWithBoth():Void {
		final out:String = writeWith('typedef Cb = Int->Void;', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('typedef Cb = Int->Void;') != -1, 'expected `typedef Cb = Int->Void;` in: <$out>');
	}

	public function testStructTypedefRoundtripWithBoth():Void {
		final out:String = writeWith('typedef P = {x:Int, y:Int};', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('typedef P = {x:Int, y:Int};') != -1, 'expected `typedef P = {x:Int, y:Int};` in: <$out>');
	}

	public function testVarInitAssignStaysSpacedRegardlessOfTypedefPolicy():Void {
		final src:String = 'class C { var x:Int = 0; }';
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith(src, policy);
			Assert.isTrue(out.indexOf('var x:Int = 0;') != -1,
				'var init `=` should stay spaced under typedefAssign $policy in: <$out>');
		}
	}

	public function testFunctionParamDefaultStaysSpacedRegardlessOfTypedefPolicy():Void {
		final src:String = 'class C { function f(x:Int = 0):Void {} }';
		for (policy in [WhitespacePolicy.None, WhitespacePolicy.Before, WhitespacePolicy.After, WhitespacePolicy.Both]) {
			final out:String = writeWith(src, policy);
			Assert.isTrue(out.indexOf('x:Int = 0') != -1,
				'param default `=` should stay spaced under typedefAssign $policy in: <$out>');
		}
	}

	private inline function writeWith(src:String, typedefAssign:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(typedefAssign));
	}

	private inline function makeOpts(typedefAssign:WhitespacePolicy):HxModuleWriteOptions {
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		return {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			commentStyle: base.commentStyle,
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
			objectFieldColon: base.objectFieldColon,
			typeHintColon: base.typeHintColon,
			funcParamParens: base.funcParamParens,
			callParens: base.callParens,
			elseIf: base.elseIf,
			fitLineIfWithElse: base.fitLineIfWithElse,
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
			existingBetweenFields: base.existingBetweenFields,
			beforeDocCommentEmptyLines: base.beforeDocCommentEmptyLines,
			betweenVars: base.betweenVars,
			betweenFunctions: base.betweenFunctions,
			afterVars: base.afterVars,
			interfaceBetweenVars: base.interfaceBetweenVars,
			interfaceBetweenFunctions: base.interfaceBetweenFunctions,
			interfaceAfterVars: base.interfaceAfterVars,
			typedefAssign: typedefAssign,
			typeParamOpen: base.typeParamOpen,
			typeParamClose: base.typeParamClose,
			anonTypeBracesOpen: base.anonTypeBracesOpen,
			anonTypeBracesClose: base.anonTypeBracesClose,
			objectLiteralBracesOpen: base.objectLiteralBracesOpen,
			objectLiteralBracesClose: base.objectLiteralBracesClose,
		};
	}
}
