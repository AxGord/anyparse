package unit.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.OptionsSource;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxTypedOptionsRewrite;
import anyparse.macro.OptionKnobs;
import anyparse.query.CanonicalEdit.EditResult;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `HxTypedOptionsRewrite` — a test's hxformat.json call becomes the typed edit of `HxWriteOptionsKit` over the baseline the call
 * started from. Each case drives the rewrite on an in-memory source; the equivalence cases compare the rewritten edit, written out
 * by hand, with the options the document loads.
 */
@:nullSafety(Strict)
final class HxTypedOptionsRewriteTest extends Test {

	private static final KIT: String = 'unit.grammar.haxe.HxWriteOptionsKit';

	public function testEmptyDocumentIsAnEmptyEditOverTheLoaderBaseline(): Void {
		final text: String = ok(rewritten("loadHxFormatJson('{}')"));
		Assert.isTrue(text.contains('HxWriteOptionsKit.forkWith(edited -> {})'), text);
		Assert.isFalse(text.contains('loadHxFormatJson'), text);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-BASELINE')
	public function testABaselineKnobTheDocumentLeavesAloneIsNotAssigned(): Void {
		final text: String = ok(rewritten("loadHxFormatJson('{\"sameLine\": {\"tryBody\": \"same\"}}')"));
		Assert.isTrue(text.contains('forkWith(edited -> edited.tryBody = BodyPolicy.Same)'), text);
		Assert.equals(1, text.split('edited.').length - 1, 'only the knob the document changed is assigned: <$text>');
	}

	public function testAKeyThatSetsSeveralKnobsIsEachOfThem(): Void {
		final text: String = ok(rewritten("loadHxFormatJson('{\"lineEnds\": {\"leftCurly\": \"both\"}}')"));
		Assert.isTrue(text.contains('edited.leftCurly = BracePlacement.Next;'), text);
		Assert.isTrue(text.contains('edited.blockLeftCurly = BracePlacement.Next;'), text);
	}

	public function testTheTypedEditLoadsTheSameOptionsAsTheDocument(): Void {
		final cascaded: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {
			edited.leftCurly = BracePlacement.Next;
			edited.objectLiteralLeftCurly = BracePlacement.Next;
			edited.anonTypeLeftCurly = BracePlacement.Next;
			edited.anonFunctionLeftCurly = BracePlacement.Next;
			edited.blockLeftCurly = BracePlacement.Next;
		});
		final loaded: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"leftCurly": "both"}}');
		Assert.isTrue(same(cascaded, loaded));
		final single: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> edited.tryBody = BodyPolicy.Same);
		Assert.isTrue(same(single, HaxeFormatConfigLoader.loadHxFormatJson('{"sameLine": {"tryBody": "same"}}')));
		Assert.isFalse(same(single, cascaded));
	}

	public function testAWrapCascadeIsWrittenOutAsItsTypedValue(): Void {
		final json: String = '{"wrapping": {"arrayWrap": {"defaultWrap": "onePerLine", "rules": '
			+ '[{"type": "fillLine", "additionalIndent": 1, "conditions": [{"cond": "itemCount >= n", "value": 3}]}]}}}';
		final text: String = ok(rewritten('loadHxFormatJson(\'$json\')'));
		Assert.isTrue(text.contains('edited.arrayLiteralWrap = {'), text);
		Assert.isTrue(text.contains('defaultMode: WrapMode.OnePerLine'), text);
		Assert.isTrue(text.contains('cond: WrapConditionType.ItemCountLargerThan'), text);
		Assert.isTrue(text.contains('import anyparse.format.wrap.WrapMode;'), text);
		final written: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> edited.arrayLiteralWrap = {
			defaultAdditionalIndent: 0,
			defaultMode: WrapMode.OnePerLine,
			rules: [
				{ additionalIndent: 1, conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 3 }], mode: WrapMode.FillLine }
			]
		});
		Assert.isTrue(same(written, HaxeFormatConfigLoader.loadHxFormatJson(json)));
		Assert.isFalse(same(written, HaxeFormatConfigLoader.loadHxFormatJson('{}')));
	}

	public function testAStrictJsonCallOfTheKitIsRewrittenLikeALoaderCall(): Void {
		final text: String = ok(rewritten('HxWriteOptionsKit.strictJson(\'{"sameLine": {"tryBody": "same"}}\')'));
		Assert.isTrue(text.contains('HxWriteOptionsKit.forkWith(edited -> edited.tryBody = BodyPolicy.Same)'), text);
		Assert.isFalse(text.contains('strictJson'), text);
		final refused: String = err(rewritten('HxWriteOptionsKit.strictJson(\'{"noSuchKey": 1}\')'));
		Assert.isTrue(refused.contains('strictJson'), refused);
	}

	public function testAQualifiedLoaderCallAndADoubleQuotedLiteralAreRewritten(): Void {
		final text: String = ok(rewritten('HaxeFormatConfigLoader.loadHxFormatJson("{\\"sameLine\\": {\\"tryBody\\": \\"same\\"}}")'));
		Assert.isTrue(text.contains('forkWith(edited -> edited.tryBody = BodyPolicy.Same)'), text);
		Assert.isFalse(text.contains('loadHxFormatJson'), text);
	}

	public function testOfJsonKeepsItsConfigWrapper(): Void {
		final text: String = ok(rewritten("HxWriteConfig.ofJson('{}')"));
		Assert.isTrue(text.contains('HxWriteConfig.ofOptions(HxWriteOptionsKit.forkWith(edited -> {}))'), text);
	}

	public function testTheKitAndTheValueTypesAreImportedOnceWhereThePackageDiffers(): Void {
		final src: String = 'package other;\n\nimport anyparse.format.BodyPolicy;\n\nclass S {\n\n\tfunction f() {\n'
			+ "\t\tfinal a = loadHxFormatJson('{\"sameLine\": {\"tryBody\": \"same\"}}');\n"
			+ "\t\tfinal b = loadHxFormatJson('{\"sameLine\": {\"tryBody\": \"fitLine\"}}');\n\t}\n\n}\n";
		final text: String = ok(HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()));
		Assert.equals(1, text.split('import unit.grammar.haxe.HxWriteOptionsKit;').length - 1, text);
		Assert.equals(1, text.split('import anyparse.format.BodyPolicy;').length - 1, text);
		final samePackage: String = ok(rewritten("loadHxFormatJson('{\"sameLine\": {\"tryBody\": \"same\"}}')"));
		Assert.isFalse(samePackage.contains('import unit.grammar.haxe.HxWriteOptionsKit;'), samePackage);
	}

	public function testASourceWithoutACallIsHandedBackAsItIs(): Void {
		final src: String = 'class S {\n\n\tfunction f() {}\n\n}\n';
		switch HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()) {
			case Ok(text, rewrites):
				Assert.equals(src, text);
				Assert.equals(0, rewrites);
			case Err(message):
				Assert.fail(message);
		}
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-LITERAL-ONLY')
	public function testAnArgumentThatIsNotOnePlainLiteralIsRefused(): Void {
		for (argument in ['cfg', "'{' + cfg + '}'", "'{$cfg}'"]) {
			final message: String = err(rewritten('loadHxFormatJson($argument)'));
			Assert.isTrue(message.contains('one plain string literal'), message);
			Assert.isTrue(message.contains('loadHxFormatJson'), 'the message quotes the call: <$message>');
		}
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-IGNORED-KEY')
	public function testAKeyTheLoaderDoesNotActOnIsRefusedByName(): Void {
		final message: String = err(rewritten("loadHxFormatJson('{\"sameLine\": {\"throwBody\": \"next\"}}')"));
		Assert.isTrue(message.contains('throwBody'), message);
	}

	public function testADocumentThatDoesNotLoadIsRefused(): Void {
		final message: String = err(rewritten("loadHxFormatJson('{\"sameLine\": ')"));
		Assert.isTrue(message.contains('loadHxFormatJson'), message);
	}

	public function testOneRefusedCallRefusesTheWholeSource(): Void {
		final src: String =
			'class S {\n\n\tfunction f() {\n\t\tfinal a = loadHxFormatJson(\'{}\');\n\t\tfinal b = loadHxFormatJson(cfg);\n\t}\n\n}\n';
		Assert.isTrue(err(HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin())).contains('one plain string literal'));
	}

	private static function rewritten(call: String): EditResult {
		final src: String = 'package unit.grammar.haxe;\n\nclass S {\n\n\tfunction f() {\n\t\tfinal opts = $call;\n\t}\n\n}\n';
		return HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin());
	}

	private static function same(a: HxModuleWriteOptions, b: HxModuleWriteOptions): Bool {
		return OptionsSource.changes(OptionKnobs.of(HxModuleWriteOptions), a, b, []).length == 0;
	}

	private static function ok(result: EditResult): String {
		return switch result {
			case Ok(text, _): text;
			case Err(message):
				Assert.fail(message);
				'';
		};
	}

	private static function err(result: EditResult): String {
		return switch result {
			case Ok(text, _):
				Assert.fail('expected a refusal, got: <$text>');
				'';
			case Err(message): message;
		};
	}

}
