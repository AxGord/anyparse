package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Writer Slice 2: wrap before `extends`/`implements` keyword when the
 * whole class/interface header line exceeds `maxLineLength`. Structural
 * twin of `HxAbstractDecl.clauses` (`from`/`to`), which already wraps
 * via `@:fmt(padLeading, lineLengthAwareSeps)` — heritage carries only
 * `padLeading`, so its line currently stays flat regardless of width.
 *
 * Fixtures (haxe-formatter fork):
 *  - `wrapping/extends_break_before_keyword_not_type_params.hxtest`
 *  - `wrapping/extends_meta_priority_brace_boundary.hxtest`
 */
@:nullSafety(Strict)
final class HxHeritageLineWrapSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testExtendsBreaksBeforeKeywordWhenLineExceedsMax(): Void {
		final cfg: String = '{"wrapping":{"maxLineLength":140},'
			+ '"whitespace":{"bracesConfig":{"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"}}}}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		final input: String = '@:nullSafety final class GenericContainerXYZ extends FetchHelper<GenericContainerEntityXYZ, pkg.inner.bundles.GenericContainerXYZ, { enableExtraOptionXY:Bool }> {}';
		final expected: String = '@:nullSafety final class GenericContainerXYZ\n'
			+ '\textends FetchHelper<GenericContainerEntityXYZ, pkg.inner.bundles.GenericContainerXYZ, { enableExtraOptionXY:Bool }> {}';
		final actualRaw: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(input), opts);
		final actual: String = actualRaw.length > 0 && StringTools.fastCodeAt(actualRaw, actualRaw.length - 1) == '\n'.code
			? actualRaw.substr(0, actualRaw.length - 1)
			: actualRaw;
		Assert.equals(expected, actual);
	}

	public function testExtendsBreaksBeforeKeywordBraceBoundary(): Void {
		final cfg: String = '{"wrapping":{"maxLineLength":140},'
			+ '"whitespace":{"bracesConfig":{"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"}}}}';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		final input: String = '@:nullSafety final class Languages extends APISmartEntity<Array<Language>, Array<Language>, Array<Language>, { includeTranslations:Bool }, ErrorResponse> {}';
		final expected: String = '@:nullSafety final class Languages\n'
			+ '\textends APISmartEntity<Array<Language>, Array<Language>, Array<Language>, { includeTranslations:Bool }, ErrorResponse> {}';
		final actualRaw: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(input), opts);
		final actual: String = actualRaw.length > 0 && StringTools.fastCodeAt(actualRaw, actualRaw.length - 1) == '\n'.code
			? actualRaw.substr(0, actualRaw.length - 1)
			: actualRaw;
		Assert.equals(expected, actual);
	}

	public function testShortHeritageStaysFlat(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final input: String = 'class Foo extends Bar {}';
		final actualRaw: String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(input), opts);
		final actual: String = actualRaw.length > 0 && StringTools.fastCodeAt(actualRaw, actualRaw.length - 1) == '\n'.code
			? actualRaw.substr(0, actualRaw.length - 1)
			: actualRaw;
		Assert.equals('class Foo extends Bar {}', actual);
	}

}
