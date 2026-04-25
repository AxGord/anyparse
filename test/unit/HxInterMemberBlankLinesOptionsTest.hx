package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-interblank — runtime-switchable inter-member blank-line counts.
 *
 * Three Int knobs drive the blank-line gate between two consecutive
 * class members based on their (prevKind, currKind) pair:
 *  - `betweenVars` — both are `var` members.
 *  - `betweenFunctions` — both are `function` members.
 *  - `afterVars` — kind switches (`var` → `function` or back).
 *
 * Defaults (post ω-interblank-defaults) match haxe-formatter:
 * `betweenVars: 0`, `betweenFunctions: 1`, `afterVars: 1`. A blank
 * line appears between sibling functions and at var↔function
 * transitions; consecutive vars stay tight. The assertions here
 * verify the defaults plus that a positive override actually injects
 * the blank line between members even when the source had none.
 * Per-element classification happens via
 * `@:fmt(interMemberBlankLines('member', 'VarMember', 'FnMember'))` on
 * `HxClassDecl.members` — the meta names are wired through
 * `WriterLowering.buildInterMemberClassifyInfo`.
 */
@:nullSafety(Strict)
class HxInterMemberBlankLinesOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultsMatchUpstream():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(0, defaults.betweenVars);
		Assert.equals(1, defaults.betweenFunctions);
		Assert.equals(1, defaults.afterVars);
	}

	public function testBetweenFunctionsZeroKeepsTight():Void {
		final out:String = writeWith(
			'class M { public function a():Void {} public function b():Void {} }',
			0, 0, 0
		);
		Assert.isTrue(out.indexOf('a():Void {}\n\tpublic function b') != -1,
			'expected no blank line between two plain functions with defaults in: <$out>');
	}

	public function testBetweenFunctionsOneInsertsBlank():Void {
		final out:String = writeWith(
			'class M { public function a():Void {} public function b():Void {} }',
			0, 1, 0
		);
		Assert.isTrue(out.indexOf('a():Void {}\n\n\tpublic function b') != -1,
			'expected blank line between two functions with betweenFunctions=1 in: <$out>');
	}

	public function testBetweenVarsOneInsertsBlank():Void {
		final out:String = writeWith(
			'class M { public var a:Int; public var b:Int; }',
			1, 0, 0
		);
		Assert.isTrue(out.indexOf('var a:Int;\n\n\tpublic var b') != -1,
			'expected blank line between two vars with betweenVars=1 in: <$out>');
	}

	public function testAfterVarsOneInsertsBlankOnVarToFunction():Void {
		final out:String = writeWith(
			'class M { public var a:Int; public function b():Void {} }',
			0, 0, 1
		);
		Assert.isTrue(out.indexOf('var a:Int;\n\n\tpublic function b') != -1,
			'expected blank line at var→function transition with afterVars=1 in: <$out>');
	}

	public function testAfterVarsOneInsertsBlankOnFunctionToVar():Void {
		final out:String = writeWith(
			'class M { public function a():Void {} public var b:Int; }',
			0, 0, 1
		);
		Assert.isTrue(out.indexOf('a():Void {}\n\n\tpublic var b') != -1,
			'expected blank line at function→var transition with afterVars=1 in: <$out>');
	}

	public function testBetweenVarsZeroKeepsVarsTight():Void {
		final out:String = writeWith(
			'class M { public var a:Int; public var b:Int; }',
			0, 0, 0
		);
		Assert.isTrue(out.indexOf('var a:Int;\n\tpublic var b') != -1,
			'expected no blank line between two vars with betweenVars=0 in: <$out>');
	}

	public function testAbstractBetweenFunctionsOneInsertsBlank():Void {
		final out:String = writeWith(
			'abstract M(Int) { public function a():Void {} public function b():Void {} }',
			0, 1, 0
		);
		Assert.isTrue(out.indexOf('a():Void {}\n\n\tpublic function b') != -1,
			'expected blank line between two abstract functions with betweenFunctions=1 in: <$out>');
	}

	public function testAbstractAfterVarsOneInsertsBlankOnVarToFunction():Void {
		final out:String = writeWith(
			'abstract M(Int) { public var a:Int; public function b():Void {} }',
			0, 0, 1
		);
		Assert.isTrue(out.indexOf('var a:Int;\n\n\tpublic function b') != -1,
			'expected blank line at abstract var→function transition with afterVars=1 in: <$out>');
	}

	public function testConfigLoaderMapsBetweenFunctionsInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"betweenFunctions": 2}}}'
		);
		Assert.equals(2, opts.betweenFunctions);
	}

	public function testConfigLoaderMapsBetweenVarsInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"betweenVars": 3}}}'
		);
		Assert.equals(3, opts.betweenVars);
	}

	public function testConfigLoaderMapsAfterVarsInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"afterVars": 1}}}'
		);
		Assert.equals(1, opts.afterVars);
	}

	public function testConfigLoaderMissingSectionKeepsDefaults():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(0, opts.betweenVars);
		Assert.equals(1, opts.betweenFunctions);
		Assert.equals(1, opts.afterVars);
	}

	private inline function writeWith(src:String, betweenVars:Int, betweenFunctions:Int, afterVars:Int):String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(betweenVars, betweenFunctions, afterVars));
	}

	private inline function makeOpts(betweenVars:Int, betweenFunctions:Int, afterVars:Int):HxModuleWriteOptions {
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
			betweenVars: betweenVars,
			betweenFunctions: betweenFunctions,
			afterVars: afterVars,
			interfaceBetweenVars: base.interfaceBetweenVars,
			interfaceBetweenFunctions: base.interfaceBetweenFunctions,
			interfaceAfterVars: base.interfaceAfterVars,
			typedefAssign: base.typedefAssign,
			typeParamDefaultEquals: base.typeParamDefaultEquals,
			typeParamOpen: base.typeParamOpen,
			typeParamClose: base.typeParamClose,
			anonTypeBracesOpen: base.anonTypeBracesOpen,
			anonTypeBracesClose: base.anonTypeBracesClose,
			objectLiteralBracesOpen: base.objectLiteralBracesOpen,
			objectLiteralBracesClose: base.objectLiteralBracesClose,
		};
	}
}
