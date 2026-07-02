package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Source trailing-comma preservation for anon-type field lists
 * (`HxType.Anon`), wired via `@:fmt(trailingComma('trailingCommaAnonTypes'))`
 * — the same `<field>TrailPresent` slot mechanism as `HxObjectLit.fields`
 * and `HxExpr.ArrayExpr`.
 *
 * The correctness-critical case is the extension-only typedef: Haxe
 * REQUIRES a comma after every `> Type` structure-extension entry,
 * including the last one (`typedef R = { > A, > B, }` — dropping the
 * final `,` is a compile error `Expected ,`). Before this slice the
 * trivia writer normalised the trailing separator away, so a format
 * round-trip produced invalid Haxe (caught live on the dogfood corpus: extension-only typedefs broke under `apq fmt`). PLAIN mode (`HaxeModuleParser` / `HxModuleWriter`) is knowingly out of scope: the `<field>TrailPresent` slot exists only on the trivia pair, so the plain writer still emits `{> A, > B}` without the mandatory comma; `apq fmt` and every writer-emit op run the trivia pipeline, which is what this slice fixes.
 */
@:nullSafety(Strict)
final class HxAnonTypeSourceTrailCommaSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testExtensionOnlyTypedefKeepsMandatoryTrailingComma(): Void {
		final src: String = 'typedef R = {\n\t> A,\n\t> B,\n}';
		Assert.equals(src, roundTrip(src));
	}

	public function testSingleExtensionKeepsMandatoryTrailingComma(): Void {
		final src: String = 'typedef R = {\n\t> A,\n}';
		Assert.equals(src, roundTrip(src));
	}

	public function testExtensionThenFieldsKeepsSourceTrailingComma(): Void {
		final src: String = 'typedef R = {\n\t> A,\n\tx:Int,\n}';
		Assert.equals(src, roundTrip(src));
	}

	public function testPlainFieldsKeepSourceTrailingComma(): Void {
		final src: String = 'typedef R = {\n\tx:Int,\n\ty:Int,\n}';
		Assert.equals(src, roundTrip(src));
	}

	public function testPlainFieldsWithoutTrailingCommaStayCommaFree(): Void {
		final src: String = 'typedef R = {\n\tx:Int,\n\ty:Int\n}';
		Assert.equals(src, roundTrip(src));
	}

	public function testSemicolonSeparatedFieldsUnaffected(): Void {
		final src: String = 'typedef R = {\n\tvar x:Int;\n\tvar y:Int;\n}';
		Assert.equals(src, roundTrip(src));
	}

	public function testInlineAnonWithoutTrailingCommaUnaffected(): Void {
		final src: String = 'class M {\n\tvar p:{x:Int, y:Int};\n}';
		Assert.equals(src, roundTrip(src));
	}

	private inline function roundTrip(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
