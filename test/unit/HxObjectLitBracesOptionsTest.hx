package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice ω-objectlit-braces — runtime-switchable
 * `objectLiteralBracesOpen` and `objectLiteralBracesClose` whitespace
 * policies for the `{}` of `HxObjectLit`. Mirrors ω-anontype-braces but
 * targets the regular `emitWriterStarField` sep-Star path used for
 * struct fields (vs. `lowerEnumStar` Alt-branch path used by anon
 * types). Default `None`/`None` keeps `{a: 1}` tight, matching
 * haxe-formatter's `bracesConfig.objectLiteralBraces` defaults whose
 * effective inside spaces are also none.
 *
 * The knob is wired via `@:fmt(objectLiteralBracesOpen,
 * objectLiteralBracesClose)` on `HxObjectLit.fields`'s `@:lead('{')
 * @:trail('}') @:sep(',')` Star, routed through the existing
 * `delimInsidePolicySpace` helper (whose flag-name list is extended to
 * include the two new flags so the same `firstFmtFlag` lookup picks
 * them up alongside `typeParamOpen`/`typeParamClose`).
 */
@:nullSafety(Strict)
final class HxObjectLitBracesOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testObjectLitBracesOpenDefaultIsNone():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.None, defaults.objectLiteralBracesOpen);
	}

	public function testObjectLitBracesCloseDefaultIsNone():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.None, defaults.objectLiteralBracesClose);
	}

	public function testNoneKeepsTight():Void {
		final out:String = writeWith('class Foo { static var x = {a: 1}; }', WhitespacePolicy.None, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('{a: 1}') != -1, 'expected tight `{a: 1}` in: <$out>');
	}

	public function testOpenAfterEmitsSpaceInsideAfterOpen():Void {
		final out:String = writeWith('class Foo { static var x = {a: 1}; }', WhitespacePolicy.After, WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('{ a: 1}') != -1, 'expected `{ a: 1}` in: <$out>');
	}

	public function testCloseBeforeEmitsSpaceInsideBeforeClose():Void {
		final out:String = writeWith('class Foo { static var x = {a: 1}; }', WhitespacePolicy.None, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('{a: 1 }') != -1, 'expected `{a: 1 }` in: <$out>');
	}

	public function testBothEmitsSpaceInsideBothSides():Void {
		final out:String = writeWith('class Foo { static var x = {a: 1}; }', WhitespacePolicy.After, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('{ a: 1 }') != -1, 'expected `{ a: 1 }` in: <$out>');
	}

	public function testMultiFieldObjectLitHonorsBothSides():Void {
		final out:String = writeWith('class Foo { static var y = {a: 1, b: 2}; }', WhitespacePolicy.After, WhitespacePolicy.Before);
		Assert.isTrue(out.indexOf('{ a: 1, b: 2 }') != -1, 'expected `{ a: 1, b: 2 }` in: <$out>');
	}

	public function testJsonLoaderRoutesObjectLitBracesPolicies():Void {
		final json:String = '{ "whitespace": { "bracesConfig": { "objectLiteralBraces": { "openingPolicy": "around", "closingPolicy": "around" } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(WhitespacePolicy.Both, opts.objectLiteralBracesOpen);
		Assert.equals(WhitespacePolicy.Both, opts.objectLiteralBracesClose);
	}

	public function testJsonLoaderIgnoresUnknownBracesKey():Void {
		final json:String = '{ "whitespace": { "bracesConfig": { "objectLiteralBraces": { "openingPolicy": "after", "closingPolicy": "before", "removeInnerWhenEmpty": false } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(WhitespacePolicy.After, opts.objectLiteralBracesOpen);
		Assert.equals(WhitespacePolicy.Before, opts.objectLiteralBracesClose);
	}

	public function testAnonTypeAndObjectLitKnobsAreIndependent():Void {
		// Defaults: both pairs None. Anon type uses anonTypeBraces*, object
		// literal uses objectLiteralBraces*. Setting only one pair should
		// not affect the other — ensures the @:fmt flag dispatch picks the
		// correct field per Star site.
		final json:String = '{ "whitespace": { "bracesConfig": { "objectLiteralBraces": { "openingPolicy": "around", "closingPolicy": "around" } } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		Assert.equals(WhitespacePolicy.Both, opts.objectLiteralBracesOpen);
		Assert.equals(WhitespacePolicy.Both, opts.objectLiteralBracesClose);
		Assert.equals(WhitespacePolicy.None, opts.anonTypeBracesOpen);
		Assert.equals(WhitespacePolicy.None, opts.anonTypeBracesClose);
	}

	private inline function writeWith(src:String, open:WhitespacePolicy, close:WhitespacePolicy):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(open, close));
	}

	private inline function makeOpts(open:WhitespacePolicy, close:WhitespacePolicy):HxModuleWriteOptions {
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
			typedefAssign: base.typedefAssign,
			typeParamOpen: base.typeParamOpen,
			typeParamClose: base.typeParamClose,
			anonTypeBracesOpen: base.anonTypeBracesOpen,
			anonTypeBracesClose: base.anonTypeBracesClose,
			objectLiteralBracesOpen: open,
			objectLiteralBracesClose: close,
		};
	}
}
