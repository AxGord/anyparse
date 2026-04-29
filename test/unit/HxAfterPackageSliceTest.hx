package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-after-package — minimum number of blank lines emitted by the
 * trivia-mode writer between the top-level `package …;` directive and
 * the following decl. Drives haxe-formatter's
 * `emptyLines.afterPackage: @:default(1)` knob; the runtime field is
 * `opt.afterPackage:Int` and the per-Star wiring is
 * `@:fmt(blankLinesAfterCtor('decl', 'PackageDecl', 'PackageEmpty', 'afterPackage'))`
 * on `HxModule.decls`.
 *
 * Override semantics, not floor: when the previous element is a
 * package decl, the source-captured `blankBefore` flag is ignored and
 * the writer emits exactly `opt.afterPackage` blank lines. `0` strips
 * any blank line even when the source carried them; positive counts
 * insert that many blanks even when the source had none. Matches
 * haxe-formatter's count-driven `emptyLines.afterPackage` semantics
 * (Int, not Bool).
 *
 * Only `PackageDecl` (`package foo.bar;`) and `PackageEmpty` (`package;`)
 * trigger the gate. Other top-level decls (`class`, `import`, `using`,
 * metadata, …) leave the captured-source separator unchanged — verified
 * via the no-package fixtures below.
 */
@:nullSafety(Strict)
class HxAfterPackageSliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultMatchesUpstream():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(1, defaults.afterPackage);
	}

	public function testDefaultInsertsBlankAfterPackage():Void {
		final out:String = writeWith('package;\nclass Main {}', 1);
		Assert.equals('package;\n\nclass Main {}\n', out);
	}

	public function testDefaultInsertsBlankAfterDottedPackage():Void {
		final out:String = writeWith('package foo.bar;\nclass Main {}', 1);
		Assert.equals('package foo.bar;\n\nclass Main {}\n', out);
	}

	public function testZeroStripsBlankAfterPackage():Void {
		final out:String = writeWith('package;\n\nclass Main {}', 0);
		Assert.equals('package;\nclass Main {}\n', out);
	}

	public function testZeroStripsBlankAfterDottedPackage():Void {
		final out:String = writeWith('package foo;\n\n\nclass Main {}', 0);
		Assert.equals('package foo;\nclass Main {}\n', out);
	}

	public function testTwoEmitsTwoBlanks():Void {
		final out:String = writeWith('package;\nclass Main {}', 2);
		Assert.equals('package;\n\n\nclass Main {}\n', out);
	}

	public function testOverridesSourceBlankCount():Void {
		final out:String = writeWith('package;\n\n\nclass Main {}', 1);
		Assert.equals('package;\n\nclass Main {}\n', out, 'opt.afterPackage=1 overrides source blank-line count to exactly 1');
	}

	public function testNoPackageNoChange():Void {
		final out:String = writeWith('import foo.Bar;\nclass Main {}', 1);
		Assert.equals('import foo.Bar;\nclass Main {}\n', out);
	}

	public function testPackageEmptyAtEOFNoTrailingBlank():Void {
		final out:String = writeWith('package;', 1);
		Assert.equals('package;\n', out);
	}

	public function testPackageDoesNotAffectClassClassSeparator():Void {
		final out:String = writeWith('package;\nclass A {}\nclass B {}', 1);
		Assert.equals('package;\n\nclass A {}\nclass B {}\n', out, 'only package→next pair gains blank, class→class stays source-driven');
	}

	public function testConfigLoaderMapsAfterPackage():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterPackage": 2}}'
		);
		Assert.equals(2, opts.afterPackage);
	}

	public function testConfigLoaderMapsAfterPackageZero():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"emptyLines": {"afterPackage": 0}}'
		);
		Assert.equals(0, opts.afterPackage);
	}

	public function testConfigLoaderMissingKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(1, opts.afterPackage);
	}

	private inline function writeWith(src:String, afterPackage:Int):String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), makeOpts(afterPackage));
	}

	private inline function makeOpts(afterPackage:Int):HxModuleWriteOptions {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.afterPackage = afterPackage;
		return opts;
	}
}
