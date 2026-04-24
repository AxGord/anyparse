package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.IndentChar;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * τ₃ — first consumer of the `WriteOptions` infrastructure: parses a
 * real `hxformat.json` document through the project's own
 * `JValueParser`, maps the recognised fields into
 * `HxModuleWriteOptions`, and feeds those options into the macro-
 * generated `HxModuleWriter`. Closes the loop: own parser → own writer
 * → driven by the user-facing formatter config shape.
 *
 * Each test targets one key path in isolation and asserts that the
 * corresponding field flips while the rest stay on
 * `HaxeFormat.instance.defaultWriteOptions`. The end-to-end test
 * round-trips a source through parser + configured writer and checks
 * the output reflects the config.
 */
@:nullSafety(Strict)
class HaxeFormatConfigLoaderTest extends Test {

	public function new():Void {
		super();
	}

	public function testEmptyObjectMatchesDefaults():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(defaults.indentChar, opts.indentChar);
		Assert.equals(defaults.indentSize, opts.indentSize);
		Assert.equals(defaults.tabWidth, opts.tabWidth);
		Assert.equals(defaults.lineWidth, opts.lineWidth);
		Assert.equals(defaults.lineEnd, opts.lineEnd);
		Assert.equals(defaults.finalNewline, opts.finalNewline);
		Assert.equals(defaults.sameLineElse, opts.sameLineElse);
		Assert.equals(defaults.sameLineCatch, opts.sameLineCatch);
		Assert.equals(defaults.sameLineDoWhile, opts.sameLineDoWhile);
		Assert.equals(defaults.trailingCommaArrays, opts.trailingCommaArrays);
		Assert.equals(defaults.trailingCommaArgs, opts.trailingCommaArgs);
		Assert.equals(defaults.trailingCommaParams, opts.trailingCommaParams);
	}

	public function testSameLineIfElseNextFlipsElse():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"ifElse": "next"}}');
		Assert.equals(SameLinePolicy.Next, opts.sameLineElse);
		Assert.equals(SameLinePolicy.Same, opts.sameLineCatch);
		Assert.equals(SameLinePolicy.Same, opts.sameLineDoWhile);
	}

	public function testSameLineTryCatchNextFlipsCatch():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"tryCatch": "next"}}');
		Assert.equals(SameLinePolicy.Same, opts.sameLineElse);
		Assert.equals(SameLinePolicy.Next, opts.sameLineCatch);
		Assert.equals(SameLinePolicy.Same, opts.sameLineDoWhile);
	}

	public function testSameLineDoWhileNextFlipsDoWhile():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"doWhile": "next"}}');
		Assert.equals(SameLinePolicy.Same, opts.sameLineElse);
		Assert.equals(SameLinePolicy.Same, opts.sameLineCatch);
		Assert.equals(SameLinePolicy.Next, opts.sameLineDoWhile);
	}

	public function testSameLineKeepMapsToKeepAndFitLineMapsToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"ifElse": "keep", "tryCatch": "fitLine", "doWhile": "keep"}}'
		);
		Assert.equals(SameLinePolicy.Keep, opts.sameLineElse);
		Assert.equals(SameLinePolicy.Same, opts.sameLineCatch);
		Assert.equals(SameLinePolicy.Keep, opts.sameLineDoWhile);
	}

	public function testTrailingCommasYesFlipsFlag():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"trailingCommas": {"arrayLiteralDefault": "yes"}}'
		);
		Assert.isTrue(opts.trailingCommaArrays);
		Assert.isFalse(opts.trailingCommaArgs);
		Assert.isFalse(opts.trailingCommaParams);
	}

	public function testTrailingCommasAllYesFlipsAll():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"trailingCommas": {'
			+ '"arrayLiteralDefault": "yes",'
			+ '"callArgumentDefault": "yes",'
			+ '"functionParameterDefault": "yes"'
			+ '}}'
		);
		Assert.isTrue(opts.trailingCommaArrays);
		Assert.isTrue(opts.trailingCommaArgs);
		Assert.isTrue(opts.trailingCommaParams);
	}

	public function testTrailingCommasKeepAndIgnoreMapToFalse():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"trailingCommas": {'
			+ '"arrayLiteralDefault": "keep",'
			+ '"callArgumentDefault": "ignore",'
			+ '"functionParameterDefault": "no"'
			+ '}}'
		);
		Assert.isFalse(opts.trailingCommaArrays);
		Assert.isFalse(opts.trailingCommaArgs);
		Assert.isFalse(opts.trailingCommaParams);
	}

	public function testIndentationTwoSpaces():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"indentation": {"character": "  ", "tabWidth": 2}}'
		);
		Assert.equals(IndentChar.Space, opts.indentChar);
		Assert.equals(2, opts.indentSize);
		Assert.equals(2, opts.tabWidth);
	}

	public function testIndentationTabKeepsTabWidth():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"indentation": {"character": "tab", "tabWidth": 8}}'
		);
		Assert.equals(IndentChar.Tab, opts.indentChar);
		Assert.equals(1, opts.indentSize);
		Assert.equals(8, opts.tabWidth);
	}

	public function testWrappingMaxLineLength():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping": {"maxLineLength": 200}}'
		);
		Assert.equals(200, opts.lineWidth);
	}

	public function testUnknownFieldsAreIgnored():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"baseTypeHints": [], "excludes": [".git"], "sameLine": {"elseBody": "same"}}'
		);
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(defaults.sameLineElse, opts.sameLineElse);
		Assert.equals(defaults.sameLineCatch, opts.sameLineCatch);
		Assert.equals(defaults.sameLineDoWhile, opts.sameLineDoWhile);
	}

	public function testLineEndsLeftCurlyBeforeFlipsToNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"leftCurly": "before"}}');
		Assert.equals(BracePlacement.Next, opts.leftCurly);
	}

	public function testLineEndsLeftCurlyBothFlipsToNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"leftCurly": "both"}}');
		Assert.equals(BracePlacement.Next, opts.leftCurly);
	}

	public function testLineEndsLeftCurlyAfterKeepsSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"leftCurly": "after"}}');
		Assert.equals(BracePlacement.Same, opts.leftCurly);
	}

	public function testLineEndsLeftCurlyNoneDegradesToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"leftCurly": "none"}}');
		Assert.equals(BracePlacement.Same, opts.leftCurly);
	}

	public function testLineEndsLeftCurlyEndToEnd():Void {
		final src:String = 'class Main { public static function main() {} }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"leftCurly": "both"}}');
		final ast:HxModule = HaxeModuleParser.parse(src);
		final out:String = HxModuleWriter.write(ast, opts);
		Assert.isTrue(out.indexOf('class Main\n{') != -1, 'expected `class Main\\n{` in: <$out>');
		Assert.isTrue(out.indexOf('function main()\n\t{') != -1, 'expected `function main()\\n\\t{` in: <$out>');
	}

	public function testWhitespaceObjectFieldColonDefaultsToAfter():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(WhitespacePolicy.After, opts.objectFieldColon);
	}

	public function testWhitespaceObjectFieldColonNoneFlipsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"objectFieldColonPolicy": "none"}}');
		Assert.equals(WhitespacePolicy.None, opts.objectFieldColon);
	}

	public function testWhitespaceObjectFieldColonBeforeFlipsToBefore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"objectFieldColonPolicy": "before"}}');
		Assert.equals(WhitespacePolicy.Before, opts.objectFieldColon);
	}

	public function testWhitespaceObjectFieldColonAroundFlipsToBoth():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"objectFieldColonPolicy": "around"}}');
		Assert.equals(WhitespacePolicy.Both, opts.objectFieldColon);
	}

	public function testWhitespaceObjectFieldColonNoneBeforeMapsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"objectFieldColonPolicy": "noneBefore"}}');
		Assert.equals(WhitespacePolicy.None, opts.objectFieldColon);
	}

	public function testWhitespaceObjectFieldColonOnlyAfterMapsToAfter():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"objectFieldColonPolicy": "onlyAfter"}}');
		Assert.equals(WhitespacePolicy.After, opts.objectFieldColon);
	}

	public function testWhitespaceObjectFieldColonEndToEnd():Void {
		final src:String = 'class C { var x:Dynamic = {a: 0, b: 1}; }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"objectFieldColonPolicy": "none"}}');
		final ast:HxModule = HaxeModuleParser.parse(src);
		final out:String = HxModuleWriter.write(ast, opts);
		Assert.isTrue(out.indexOf('{a:0, b:1}') != -1, 'expected tight `{a:0, b:1}` in: <$out>');
		Assert.isTrue(out.indexOf('var x:Dynamic') != -1, 'var type annotation should stay tight in: <$out>');
	}

	public function testWhitespaceTypeHintColonDefaultsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(WhitespacePolicy.None, opts.typeHintColon);
	}

	public function testWhitespaceTypeHintColonAroundMapsToBoth():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"typeHintColonPolicy": "around"}}');
		Assert.equals(WhitespacePolicy.Both, opts.typeHintColon);
	}

	public function testWhitespaceTypeHintColonEndToEnd():Void {
		final src:String = 'class C { var x:Int; function f(p:String):Void {} }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"typeHintColonPolicy": "around"}}');
		final ast:HxModule = HaxeModuleParser.parse(src);
		final out:String = HxModuleWriter.write(ast, opts);
		Assert.isTrue(out.indexOf('var x : Int') != -1, 'expected `var x : Int` in: <$out>');
		Assert.isTrue(out.indexOf('p : String') != -1, 'expected `p : String` in: <$out>');
		Assert.isTrue(out.indexOf(') : Void') != -1, 'expected `) : Void` in: <$out>');
	}

	public function testWhitespaceFuncParamParensDefaultsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(WhitespacePolicy.None, opts.funcParamParens);
	}

	public function testWhitespaceFuncParamParensBeforeMapsToBefore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"parenConfig": {"funcParamParens": {"openingPolicy": "before"}}}}');
		Assert.equals(WhitespacePolicy.Before, opts.funcParamParens);
	}

	public function testWhitespaceFuncParamParensEndToEnd():Void {
		final src:String = 'class C { function f(p:Int):Void {} }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"parenConfig": {"funcParamParens": {"openingPolicy": "before"}}}}');
		final ast:HxModule = HaxeModuleParser.parse(src);
		final out:String = HxModuleWriter.write(ast, opts);
		Assert.isTrue(out.indexOf('function f (p:Int)') != -1, 'expected `function f (p:Int)` in: <$out>');
	}

	public function testWhitespaceParenConfigClosingPolicyIsIgnored():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace": {"parenConfig": {"funcParamParens": {"closingPolicy": "before"}}}}');
		Assert.equals(WhitespacePolicy.None, opts.funcParamParens);
	}

	public function testSameLineElseIfDefaultsToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(KeywordPlacement.Same, opts.elseIf);
	}

	public function testSameLineElseIfNextMapsToNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"elseIf": "next"}}');
		Assert.equals(KeywordPlacement.Next, opts.elseIf);
	}

	public function testSameLineElseIfSameMapsToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"elseIf": "same"}}');
		Assert.equals(KeywordPlacement.Same, opts.elseIf);
	}

	public function testSameLineElseIfKeepDegradesToSame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"elseIf": "keep"}}');
		Assert.equals(KeywordPlacement.Same, opts.elseIf);
	}

	public function testSameLineElseIfEndToEnd():Void {
		final src:String = 'class F { function f():Void { if (a) {} else if (b) {} } }';
		final configured:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"elseIf": "next"}}');
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), configured);
		Assert.isTrue(out.indexOf('else\n\t\t\tif (b)') != -1, 'expected nested if on next line in: <$out>');
		Assert.isTrue(out.indexOf('} else if (b)') == -1, 'did not expect inline nested if in: <$out>');
	}

	public function testSameLineFitLineIfWithElseDefaultsToFalse():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.isFalse(opts.fitLineIfWithElse);
	}

	public function testSameLineFitLineIfWithElseTrueMapsToTrue():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"fitLineIfWithElse": true}}');
		Assert.isTrue(opts.fitLineIfWithElse);
	}

	public function testSameLineFitLineIfWithElseFalseMapsToFalse():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"fitLineIfWithElse": false}}');
		Assert.isFalse(opts.fitLineIfWithElse);
	}

	public function testBodyPolicyDefaultsMatchUpstream():Void {
		// ψ₁₀a: stock haxe-formatter defaults every non-block body knob
		// to Next. Verify our defaults align with the empty-config path.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Next, opts.ifBody);
		Assert.equals(BodyPolicy.Next, opts.elseBody);
		Assert.equals(BodyPolicy.Next, opts.forBody);
		Assert.equals(BodyPolicy.Next, opts.whileBody);
		Assert.equals(BodyPolicy.Next, opts.doBody);
	}

	public function testEndToEndConfigDrivesWriter():Void {
		final src:String = 'class F { function f():Void { if (x) {} else {} try {} catch (e:E) {} } }';
		final configuredOpts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"ifElse": "next", "tryCatch": "next"}}'
		);
		final defaultOpts:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final ast:HxModule = HaxeModuleParser.parse(src);
		final configured:String = HxModuleWriter.write(ast, configuredOpts);
		final withDefaults:String = HxModuleWriter.write(ast, defaultOpts);
		Assert.isTrue(withDefaults.indexOf('} else ') != -1, 'default should keep `} else ` in: <$withDefaults>');
		Assert.isTrue(withDefaults.indexOf('} catch ') != -1, 'default should keep `} catch ` in: <$withDefaults>');
		Assert.isTrue(configured.indexOf('} else ') == -1, 'ifElse=next should break else in: <$configured>');
		Assert.isTrue(configured.indexOf('} catch ') == -1, 'tryCatch=next should break catch in: <$configured>');
	}

	public function testEmptyLinesAfterFieldsWithDocCommentsDefaultsToOne():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(CommentEmptyLinesPolicy.One, opts.afterFieldsWithDocComments);
	}

	public function testEmptyLinesAfterFieldsWithDocCommentsIgnoreMapsToIgnore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterFieldsWithDocComments": "ignore"}}'
		);
		Assert.equals(CommentEmptyLinesPolicy.Ignore, opts.afterFieldsWithDocComments);
	}

	public function testEmptyLinesAfterFieldsWithDocCommentsNoneMapsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterFieldsWithDocComments": "none"}}'
		);
		Assert.equals(CommentEmptyLinesPolicy.None, opts.afterFieldsWithDocComments);
	}

	public function testEmptyLinesAfterFieldsWithDocCommentsOneInsertsBlankLine():Void {
		// Source has no blank line between the doc-commented function and
		// the second function — default `One` policy forces a blank line.
		final src:String = 'class M {\n\t/** */\n\tpublic function a():Void {}\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\n\tpublic function b') != -1,
			'expected blank line between doc-commented a() and b() in: <$out>');
	}

	public function testEmptyLinesAfterFieldsWithDocCommentsIgnorePreservesSource():Void {
		// Source has no blank line — `Ignore` policy honours the source
		// (no blank line in output either).
		final src:String = 'class M {\n\t/** */\n\tpublic function a():Void {}\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterFieldsWithDocComments": "ignore"}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\tpublic function b') != -1,
			'expected tight layout (no blank line) with `ignore` in: <$out>');
	}

	public function testEmptyLinesAfterFieldsWithDocCommentsNoneStripsBlankLine():Void {
		// Source HAS a blank line — `None` policy strips it.
		final src:String = 'class M {\n\t/** */\n\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterFieldsWithDocComments": "none"}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\tpublic function b') != -1,
			'expected blank line stripped with `none` in: <$out>');
	}

	public function testEmptyLinesAfterFieldsWithDocCommentsDoesNotFireForNonDocComment():Void {
		// Leading `/* */` (non-doc block comment) on first fn should NOT
		// trigger the policy — only `/**`-prefixed comments count.
		final src:String = 'class M {\n\t/* not doc */\n\tpublic function a():Void {}\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\tpublic function b') != -1,
			'expected no blank line when leading is plain block comment in: <$out>');
	}

	public function testEmptyLinesExistingBetweenFieldsDefaultsToKeep():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(KeepEmptyLinesPolicy.Keep, opts.existingBetweenFields);
	}

	public function testEmptyLinesExistingBetweenFieldsKeepMapsToKeep():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"existingBetweenFields": "keep"}}}'
		);
		Assert.equals(KeepEmptyLinesPolicy.Keep, opts.existingBetweenFields);
	}

	public function testEmptyLinesExistingBetweenFieldsRemoveMapsToRemove():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"existingBetweenFields": "remove"}}}'
		);
		Assert.equals(KeepEmptyLinesPolicy.Remove, opts.existingBetweenFields);
	}

	public function testEmptyLinesExistingBetweenFieldsKeepPreservesSourceBlank():Void {
		// Source has a blank line between the two plain fields — `Keep`
		// (default) honours it.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\n\tpublic function b') != -1,
			'expected source blank line preserved with `keep` in: <$out>');
	}

	public function testEmptyLinesExistingBetweenFieldsRemoveStripsSourceBlank():Void {
		// Source has a blank line — `Remove` policy strips it regardless.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"existingBetweenFields": "remove"}}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\tpublic function b') != -1,
			'expected source blank line stripped with `remove` in: <$out>');
	}

	public function testEmptyLinesExistingBetweenFieldsRemoveDoesNotBlockAddByDoc():Void {
		// Compose with `afterFieldsWithDocComments=One`: the source blank
		// is stripped by `Remove`, but `One` then re-inserts exactly one
		// blank after the doc-commented field. Net effect on a source
		// that already had a blank: idempotent — blank survives.
		final src:String = 'class M {\n\t/** */\n\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"existingBetweenFields": "remove"}}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\n\tpublic function b') != -1,
			'expected `One`-inserted blank to survive `Remove` strip in: <$out>');
	}

	public function testEmptyLinesExistingBetweenFieldsRemoveWithIgnoreStripsAll():Void {
		// `existingBetweenFields=remove` with
		// `afterFieldsWithDocComments=ignore`: no add-policy fires, so
		// every source blank gets stripped.
		final src:String = 'class M {\n\t/** */\n\tpublic function a():Void {}\n\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterFieldsWithDocComments": "ignore", "classEmptyLines": {"existingBetweenFields": "remove"}}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\tpublic function b') != -1,
			'expected all source blanks stripped with ignore+remove in: <$out>');
	}

	public function testEmptyLinesBeforeDocCommentEmptyLinesDefaultsToOne():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(CommentEmptyLinesPolicy.One, opts.beforeDocCommentEmptyLines);
	}

	public function testEmptyLinesBeforeDocCommentEmptyLinesIgnoreMapsToIgnore():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"beforeDocCommentEmptyLines": "ignore"}}'
		);
		Assert.equals(CommentEmptyLinesPolicy.Ignore, opts.beforeDocCommentEmptyLines);
	}

	public function testEmptyLinesBeforeDocCommentEmptyLinesNoneMapsToNone():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"beforeDocCommentEmptyLines": "none"}}'
		);
		Assert.equals(CommentEmptyLinesPolicy.None, opts.beforeDocCommentEmptyLines);
	}

	public function testEmptyLinesBeforeDocCommentEmptyLinesOneInsertsBlankLine():Void {
		// Source has no blank line between plain-commented first function
		// and the doc-commented second function — default `One` policy
		// forces a blank line before the doc-commented field.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\t/** */\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\n\t/** */\n\tpublic function b') != -1,
			'expected blank line before doc-commented b() in: <$out>');
	}

	public function testEmptyLinesBeforeDocCommentEmptyLinesIgnorePreservesSource():Void {
		// Source has no blank line — `Ignore` policy honours the source
		// (no blank line in output either). Requires also turning off
		// `afterFieldsWithDocComments` default to isolate this axis — the
		// first field has no doc comment so it doesn't fire anyway.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\t/** */\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"beforeDocCommentEmptyLines": "ignore"}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\t/** */\n\tpublic function b') != -1,
			'expected tight layout (no blank line) with `ignore` in: <$out>');
	}

	public function testEmptyLinesBeforeDocCommentEmptyLinesNoneStripsBlankLine():Void {
		// Source HAS a blank line — `None` policy strips it.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\n\t/** */\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"beforeDocCommentEmptyLines": "none"}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\t/** */\n\tpublic function b') != -1,
			'expected blank line stripped with `none` in: <$out>');
	}

	public function testEmptyLinesBeforeDocCommentEmptyLinesDoesNotFireForNonDocComment():Void {
		// Leading `/* */` (non-doc block comment) on second fn should NOT
		// trigger the policy — only `/**`-prefixed comments count.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\t/* not doc */\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\t/* not doc */\n\tpublic function b') != -1,
			'expected no blank line when leading is plain block comment in: <$out>');
	}

	public function testEmptyLinesBetweenVarsDefaultsToZero():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(0, opts.betweenVars);
	}

	public function testEmptyLinesBetweenFunctionsDefaultsToZero():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(0, opts.betweenFunctions);
	}

	public function testEmptyLinesAfterVarsDefaultsToZero():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(0, opts.afterVars);
	}

	public function testEmptyLinesBetweenVarsMapsToInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"betweenVars": 2}}}'
		);
		Assert.equals(2, opts.betweenVars);
	}

	public function testEmptyLinesBetweenFunctionsMapsToInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"betweenFunctions": 1}}}'
		);
		Assert.equals(1, opts.betweenFunctions);
	}

	public function testEmptyLinesAfterVarsMapsToInt():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"afterVars": 3}}}'
		);
		Assert.equals(3, opts.afterVars);
	}

	public function testEmptyLinesBetweenFunctionsOneInsertsBlankBetweenFns():Void {
		// Source has no blank line between two functions — `betweenFunctions: 1`
		// forces one blank line regardless of source.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"classEmptyLines": {"betweenFunctions": 1}}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\n\tpublic function b') != -1,
			'expected blank line with betweenFunctions=1 in: <$out>');
	}

	public function testEmptyLinesBetweenFunctionsZeroKeepsTightBetweenFns():Void {
		// Default `betweenFunctions: 0` — no blank line is inserted
		// between plain sibling functions.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\tpublic function b') != -1,
			'expected tight layout (no blank line) with betweenFunctions=0 in: <$out>');
	}

	public function testEmptyLinesBeforeDocCommentComposesWithRemove():Void {
		// issue_208 shape: `existingBetweenFields=remove` +
		// `afterFieldsWithDocComments=ignore` + default
		// `beforeDocCommentEmptyLines=One`. Between plain-commented a()
		// and doc-commented b() the source has no blank — `One` still
		// inserts one. Between a() and c() (both plain) `remove` strips
		// the source blank.
		final src:String = 'class M {\n\tpublic function a():Void {}\n\n\tpublic function c():Void {}\n\t/** */\n\tpublic function b():Void {}\n}';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterFieldsWithDocComments": "ignore", "classEmptyLines": {"existingBetweenFields": "remove"}}}'
		);
		opts.finalNewline = false;
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.isTrue(out.indexOf('a():Void {}\n\tpublic function c') != -1,
			'expected blank between a() and c() stripped by `remove` in: <$out>');
		Assert.isTrue(out.indexOf('c():Void {}\n\n\t/** */\n\tpublic function b') != -1,
			'expected `One`-inserted blank before doc-commented b() in: <$out>');
	}
}
