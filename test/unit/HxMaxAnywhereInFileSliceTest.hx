package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-max-anywhere-in-file — final-pass cap on consecutive `lineEnd` runs.
 * Drives haxe-formatter's `emptyLines.maxAnywhereInFile: @:default(1)`
 * knob. Lives on the generic base `WriteOptions` as
 * `maxConsecutiveBlanks:Int` so every grammar can opt in; the Haxe
 * loader maps the JSON key onto the runtime field.
 *
 * Semantics: any run of `N+1` or more consecutive `lineEnd` sequences
 * in the rendered output collapses to exactly `N+1` line-ends — i.e.
 * at most `N` blank lines between any two non-empty lines. Default
 * `1` matches the fork; `0` strips every blank line; `-1` disables
 * the cap entirely.
 */
@:nullSafety(Strict)
class HxMaxAnywhereInFileSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testDefaultMatchesUpstream(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(1, defaults.maxConsecutiveBlanks);
	}

	public function testZeroStripsAllBlanks(): Void {
		final src: String = 'package;\n\n\nclass Main {\n\tpublic function new() {}\n}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"maxAnywhereInFile": 0}}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\nclass Main {\n\tpublic function new() {}\n}\n', out);
	}

	public function testOneCapsToOneBlank(): Void {
		final src: String = 'package;\n\n\n\nclass Main {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\n\nclass Main {}\n', out);
	}

	public function testTwoAllowsTwoBlanks(): Void {
		// `afterPackage:3` requests 3 blanks; cap:2 trims to 2.
		final src: String = 'package;\nclass Main {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterPackage": 3, "maxAnywhereInFile": 2}}'
		);
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\n\n\nclass Main {}\n', out);
	}

	public function testNegativeOneDisablesCap(): Void {
		// `afterPackage:4` requests 4 blanks; cap:-1 (off) lets them through.
		final src: String = 'package;\nclass Main {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"afterPackage": 4}}');
		opts.maxConsecutiveBlanks = -1;
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\n\n\n\n\nclass Main {}\n', out);
	}

	public function testCapsAcrossClassClassPair(): Void {
		// Source carries 4 blanks between two single-line classes; the
		// default cap:1 trims the inter-class gap down to 1 blank.
		final src: String = 'class A {}\n\n\n\n\nclass B {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('class A {}\n\nclass B {}\n', out);
	}

	public function testConfigLoaderMapsZero(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"maxAnywhereInFile": 0}}');
		Assert.equals(0, opts.maxConsecutiveBlanks);
	}

	public function testConfigLoaderMissingKeyKeepsDefault(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(1, opts.maxConsecutiveBlanks);
	}

	public function testCapOverridesAfterPackage(): Void {
		// `afterPackage:2` would emit 2 blanks; default `maxConsecutiveBlanks:1`
		// caps that back to 1 blank — fork's mark-then-cap ordering.
		final src: String = 'package;\nclass Main {}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines": {"afterPackage": 2}}');
		final out: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('package;\n\nclass Main {}\n', out);
	}

}
