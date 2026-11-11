package unit.format;

import anyparse.format.BodyPolicy;
import anyparse.format.OptionsSource;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.macro.OptionKnobs;
import haxe.Exception;

/**
 * `OptionsSource` — the value of an options knob read back as Haxe source, and the knobs an edit changed. The shapes are written by hand
 * here and read from the real record through `OptionKnobs.of`.
 */
@:nullSafety(Strict)
final class OptionsSourceTest extends Test {

	public function testAScalarIsItsOwnSourceAndATextIsQuotedForASingleQuotedString(): Void {
		Assert.equals('true', OptionsSource.spell(Scalar, true, []));
		Assert.equals('3', OptionsSource.spell(Scalar, 3, []));
		Assert.equals("'it\\'s $$x\\n'", OptionsSource.spell(Text, "it's $x\n", []));
	}

	public function testAnEnumAbstractKnobIsItsConstantAndNamesItsImport(): Void {
		final imports: Array<String> = [];
		Assert.equals('BodyPolicy.Next', OptionsSource.spell(shapeOf('ifBody'), BodyPolicy.Next, imports));
		Assert.equals('BodyPolicy.FitLine', OptionsSource.spell(shapeOf('ifBody'), BodyPolicy.FitLine, imports));
		Assert.same(['anyparse.format.BodyPolicy'], imports);
	}

	public function testANullableAListAndARecursiveRecord(): Void {
		Assert.equals('null', OptionsSource.spell(Nullable(Scalar), cast null, []));
		Assert.equals('[1, 2]', OptionsSource.spell(List(Scalar), [1, 2], []));
		final node: OptionShape = Record('node', [
			{ name: 'n', optional: false, shape: Scalar },
			{ name: 'next', optional: true, shape: Again('node') }
		]);
		Assert.equals('{ n: 1, next: { n: 2 } }', OptionsSource.spell(node, { n: 1, next: { n: 2 } }, []));
		Assert.equals('{ n: 1 }', OptionsSource.spell(node, { n: 1 }, []));
	}

	public function testATypeWithNoSpellingIsRefused(): Void {
		Assert.raises(() -> OptionsSource.spell(Opaque('Void -> Void'), () -> {}, []), Exception);
	}

	public function testTheKnobTableNamesTheRecordsFieldsAndKeepsAnOptionalFieldOptional(): Void {
		final names: Array<String> = [for (k in OptionKnobs.of(HxModuleWriteOptions)) k.name];
		Assert.contains('ifBody', names);
		Assert.contains('lineWidth', names);
		final wrap: String = OptionsSource.spell(
			shapeOf('arrayLiteralWrap'), { rules: [], defaultMode: 1, defaultAdditionalIndent: 0 }, []
		);
		Assert.equals('{ defaultAdditionalIndent: 0, defaultMode: WrapMode.OnePerLine, rules: [] }', wrap);
	}

	@:pin('control')
	@:killer('M-OPTIONS-SOURCE-CHANGED-ONLY')
	public function testOnlyTheKnobsAnEditChangedAreAssigned(): Void {
		final knobs: Array<OptionKnob> = OptionKnobs.of(HxModuleWriteOptions);
		final base: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(0, OptionsSource.changes(knobs, base, HaxeFormatConfigLoader.loadHxFormatJson('{}'), []).length);
		final edited: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		edited.tryBody = BodyPolicy.Same;
		final imports: Array<String> = [];
		final changed: Array<{ name: String, source: String }> = OptionsSource.changes(knobs, base, edited, imports);
		Assert.equals(1, changed.length);
		Assert.equals('tryBody', changed[0].name);
		Assert.equals('BodyPolicy.Same', changed[0].source);
		Assert.same(['anyparse.format.BodyPolicy'], imports);
	}

	public function testAFunctionKnobThatDiffersIsRefusedByName(): Void {
		final knobs: Array<OptionKnob> = OptionKnobs.of(HxModuleWriteOptions);
		final base: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		final edited: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		edited.blockCommentAdapter = null;
		try {
			final changed: Array<{ name: String, source: String }> = OptionsSource.changes(knobs, base, edited, []);
			Assert.fail('a changed function has no source: $changed');
		} catch (exception: Exception) {
			Assert.stringContains('blockCommentAdapter', exception.message);
		}
	}

	private static function shapeOf(knob: String): OptionShape {
		for (k in OptionKnobs.of(HxModuleWriteOptions)) if (k.name == knob) return k.shape;
		throw new Exception('no knob $knob');
	}

}
