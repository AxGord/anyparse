package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-imports-using-blank — exact number of blank lines emitted by the
 * trivia-mode writer at the `import → using` transition. Drives
 * haxe-formatter's `emptyLines.importAndUsing.beforeUsing: @:default(1)`
 * knob; the runtime field is `opt.beforeUsing:Int` and the per-Star
 * wiring is
 * `@:fmt(blankLinesBeforeCtor('decl', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'))`
 * on `HxModule.decls`.
 *
 * Override semantics, not floor: when the current decl is a `using`
 * directive AND the previous decl is NOT a `using` directive, the
 * source-captured `blankBefore` flag is ignored and the writer emits
 * exactly `opt.beforeUsing` blank lines. `0` strips any blank line
 * even when the source carried one; positive counts insert that many
 * blanks even when the source had none. Consecutive `using` decls
 * fall through to source-driven `blankBefore` (no override applied) so
 * a tightly-grouped `using A;\nusing B;` block stays tight.
 */
@:nullSafety(Strict)
class HxBeforeUsingSliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultMatchesUpstream():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(1, defaults.beforeUsing);
	}

	public function testDefaultInsertsBlankBetweenImportAndUsing():Void {
		final out:String = writeWith('import haxe.*;\nusing haxe.*;', 1);
		Assert.equals('import haxe.*;\n\nusing haxe.*;\n', out);
	}

	public function testDefaultInsertsBlankBeforeUsingWild():Void {
		final out:String = writeWith('import haxe.*;\nusing haxe.macro.Tools.*;', 1);
		Assert.equals('import haxe.*;\n\nusing haxe.macro.Tools.*;\n', out);
	}

	public function testZeroStripsBlankBeforeUsing():Void {
		final out:String = writeWith('import haxe.*;\n\nusing haxe.*;', 0);
		Assert.equals('import haxe.*;\nusing haxe.*;\n', out);
	}

	public function testTwoEmitsTwoBlanks():Void {
		final out:String = writeWith('import haxe.*;\nusing haxe.*;', 2);
		Assert.equals('import haxe.*;\n\n\nusing haxe.*;\n', out);
	}

	public function testOverridesSourceBlankCount():Void {
		final out:String = writeWith('import haxe.*;\n\n\nusing haxe.*;', 1);
		Assert.equals(
			'import haxe.*;\n\nusing haxe.*;\n', out,
			'opt.beforeUsing=1 overrides source blank-line count to exactly 1'
		);
	}

	public function testConsecutiveUsingsStaySourceDriven():Void {
		final out:String = writeWith('using A;\nusing B;', 1);
		Assert.equals(
			'using A;\nusing B;\n', out,
			'using → using transition is not a "before-ctor" event; source `blankBefore=false` flows through'
		);
	}

	public function testConsecutiveUsingsRespectSourceBlank():Void {
		final out:String = writeWith('using A;\n\nusing B;', 1);
		Assert.equals(
			'using A;\n\nusing B;\n', out,
			'consecutive `using` decls fall through to source-driven blankBefore'
		);
	}

	public function testNoUsingNoChange():Void {
		final out:String = writeWith('import foo.Bar;\nclass Main {}', 1);
		Assert.equals('import foo.Bar;\nclass Main {}\n', out);
	}

	public function testPackageThenUsingTriggersOverride():Void {
		final out:String = writeWith('package;\nusing haxe.*;', 1);
		// package → using: prev is PackageDecl (not Using*), curr matches
		// → beforeUsing override fires. afterPackage also matches at the
		// same slot (prev is package); the cascade picks afterPackage
		// first, but both knobs default to 1 so the visible output is the
		// same single blank line.
		Assert.equals('package;\n\nusing haxe.*;\n', out);
	}

	public function testConfigLoaderMapsBeforeUsing():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"importAndUsing": {"beforeUsing": 2}}}'
		);
		Assert.equals(2, opts.beforeUsing);
	}

	public function testConfigLoaderMapsBeforeUsingZero():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"importAndUsing": {"beforeUsing": 0}}}'
		);
		Assert.equals(0, opts.beforeUsing);
	}

	public function testConfigLoaderMissingKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(1, opts.beforeUsing);
	}

	public function testConfigLoaderMissingNestedKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterPackage": 2}}'
		);
		Assert.equals(1, opts.beforeUsing);
	}

	private inline function writeWith(src:String, beforeUsing:Int):String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(beforeUsing));
	}

	private inline function makeOpts(beforeUsing:Int):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.beforeUsing = beforeUsing;
		return opts;
	}
}
