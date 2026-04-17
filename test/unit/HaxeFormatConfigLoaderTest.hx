package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.IndentChar;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
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
		Assert.isFalse(opts.sameLineElse);
		Assert.isTrue(opts.sameLineCatch);
		Assert.isTrue(opts.sameLineDoWhile);
	}

	public function testSameLineTryCatchNextFlipsCatch():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"tryCatch": "next"}}');
		Assert.isTrue(opts.sameLineElse);
		Assert.isFalse(opts.sameLineCatch);
		Assert.isTrue(opts.sameLineDoWhile);
	}

	public function testSameLineDoWhileNextFlipsDoWhile():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"doWhile": "next"}}');
		Assert.isTrue(opts.sameLineElse);
		Assert.isTrue(opts.sameLineCatch);
		Assert.isFalse(opts.sameLineDoWhile);
	}

	public function testSameLineKeepAndFitLineMapToFalse():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"ifElse": "keep", "tryCatch": "fitLine", "doWhile": "keep"}}'
		);
		Assert.isFalse(opts.sameLineElse);
		Assert.isFalse(opts.sameLineCatch);
		Assert.isFalse(opts.sameLineDoWhile);
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
}
