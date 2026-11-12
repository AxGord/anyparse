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

	public function testEmptyDocumentIsTheLoaderBaselineItself(): Void {
		final text: String = ok(rewritten("loadHxFormatJson('{}')"));
		Assert.isFalse(text.contains('forkWith'), text);
		Assert.isTrue(text.contains("loadHxFormatJson('{}')"), text);
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

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-STRICTJSON-SITE')
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
		Assert.isTrue(text.contains("HxWriteConfig.ofOptions(HaxeFormatConfigLoader.loadHxFormatJson('{}'))"), text);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-FIXTURE-SITE')
	public function testAFixtureCallsJsonArgumentBecomesTheTypedEdit(): Void {
		final json: String = '{"sameLine": {"tryBody": "same"}}';
		final text: String = ok(rewritten('HxWriteFixture.triviaWrite(SRC, \'$json\')'));
		Assert.isTrue(
			text.contains('HxWriteFixture.triviaWrite(SRC, HxWriteOptionsKit.forkWith(edited -> edited.tryBody = BodyPolicy.Same))'), text
		);
		final plain: String = ok(rewritten('HxWriteFixture.plainWrite(SRC, \'$json\')'));
		Assert.isTrue(
			plain.contains('HxWriteFixture.plainWrite(SRC, HxWriteOptionsKit.forkWith(edited -> edited.tryBody = BodyPolicy.Same))'), plain
		);
		Assert.isFalse(text.contains('{"sameLine"'), text);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-ARGUMENT-ONLY')
	public function testAFixtureCallKeepsTheSourceItWasGiven(): Void {
		final text: String = ok(rewritten("HxWriteFixture.triviaWrite('class A {}' + tail, '{}')"));
		Assert.isTrue(
			text.contains("HxWriteFixture.triviaWrite('class A {}' + tail, HaxeFormatConfigLoader.loadHxFormatJson('{}'))"), text
		);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-ALREADY-TYPED')
	public function testAFixtureCallWithATypedConfigurationIsLeftAlone(): Void {
		final once: String = ok(rewritten("HxWriteFixture.triviaWrite(SRC, '{}')"));
		switch HxTypedOptionsRewrite.rewrite(once, KIT, true, new HaxeQueryPlugin()) {
			case Ok(text, rewrites):
				Assert.equals(once, text);
				Assert.equals(0, rewrites);
			case Err(message):
				Assert.fail(message);
		}
		final wrapped: String = 'HxWriteFixture.plainWrite(SRC, HxWriteConfig.ofOptions(HxWriteOptionsKit.forkWith(edited -> {})))';
		Assert.isTrue(ok(rewritten(wrapped)).contains(wrapped));
		final raw: String = 'HxWriteFixture.triviaWrite(SRC, HxWriteOptionsKit.rawWith(_ -> {}))';
		Assert.isTrue(ok(rewritten(raw)).contains(raw));
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-NESTED-FIXTURE')
	public function testAFixtureCallInAFixtureCallsSourceIsRewrittenInTheSameRun(): Void {
		final json: String = '{"sameLine": {"tryBody": "same"}}';
		final typed: String = 'HxWriteOptionsKit.forkWith(edited -> edited.tryBody = BodyPolicy.Same)';
		final once: String = ok(rewritten('HxWriteFixture.triviaWrite(HxWriteFixture.triviaWrite(SRC, \'$json\'), \'$json\')'));
		Assert.isTrue(flat(once).contains(flat('HxWriteFixture.triviaWrite(HxWriteFixture.triviaWrite(SRC, $typed), $typed)')), once);
		Assert.isFalse(once.contains('{"sameLine"'), once);
		switch HxTypedOptionsRewrite.rewrite(once, KIT, true, new HaxeQueryPlugin()) {
			case Ok(text, rewrites):
				Assert.equals(once, text);
				Assert.equals(0, rewrites);
			case Err(message):
				Assert.fail(message);
		}
		final typedOuter: String = ok(
			rewritten("HxWriteFixture.triviaWrite(HxWriteFixture.triviaWrite(SRC, '{}'), HxWriteOptionsKit.rawWith(_ -> {}))")
		);
		Assert.isTrue(
			flat(typedOuter)
				.contains(flat(
					"HxWriteFixture.triviaWrite(HxWriteFixture.triviaWrite(SRC, HaxeFormatConfigLoader.loadHxFormatJson('{}')), "
					+ 'HxWriteOptionsKit.rawWith(_ -> {}))'
				)),
			typedOuter
		);
		final refused: String = err(rewritten("HxWriteFixture.triviaWrite(HxWriteFixture.triviaWrite(SRC, cfg), '{}')"));
		Assert.isTrue(refused.contains('triviaWrite(SRC, cfg'), refused);
	}

	public function testAFixtureCallIsRefusedLikeALoaderCall(): Void {
		final variable: String = err(rewritten('HxWriteFixture.triviaWrite(SRC, cfg)'));
		Assert.isTrue(variable.contains('not a constant string'), variable);
		Assert.isTrue(variable.contains('triviaWrite'), variable);
		final ignored: String = err(rewritten("HxWriteFixture.plainWrite(SRC, '{\"sameLine\": {\"throwBody\": \"next\"}}')"));
		Assert.isTrue(ignored.contains('throwBody'), ignored);
	}

	public function testACallOfAnotherTypeNamedLikeAFixtureMethodIsLeftAlone(): Void {
		final src: String = 'class S {\n\n\tfunction f() {\n\t\ttriviaWrite(SRC, \'{}\');\n\t\tOther.plainWrite(SRC, \'{}\');\n\t}\n\n}\n';
		switch HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()) {
			case Ok(text, rewrites):
				Assert.equals(src, text);
				Assert.equals(0, rewrites);
			case Err(message):
				Assert.fail(message);
		}
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
			Assert.isTrue(message.contains('not a constant string'), message);
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
		Assert.isTrue(err(HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin())).contains('not a constant string'));
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-NAMED-FINAL')
	public function testAFinalReadOnlyByConfigurationCallsIsRetypedOnce(): Void {
		final typed: String = 'HxWriteOptionsKit.forkWith(edited -> edited.tryBody = BodyPolicy.Same)';
		final src: String = module(
			"\tprivate static final CONFIG: String = '{\"sameLine\": {\"tryBody\": \"same\"}}';",
			'\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);\n\t\tfinal b = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);\n'
			+ "\t\tfinal c = HxWriteConfig.ofJson(CONFIG);\n\t\tfinal local = '{}';\n\t\tHxWriteFixture.plainWrite(SRC, local);"
		);
		final once: String = ok(HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()));
		Assert.isTrue(flat(once).contains(flat('private static final CONFIG: HxModuleWriteOptions = $typed;')), once);
		Assert.isTrue(flat(once).contains(flat('HxWriteFixture.triviaWrite(SRC, CONFIG);')), once);
		Assert.isTrue(flat(once).contains(flat('final b = CONFIG;')), once);
		Assert.isTrue(flat(once).contains(flat('final c = HxWriteConfig.ofOptions(CONFIG);')), once);
		Assert.isTrue(
			flat(once).contains(flat("final local: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');")), once
		);
		Assert.isTrue(flat(once).contains(flat('HxWriteFixture.plainWrite(SRC, local);')), once);
		Assert.isTrue(once.contains('import anyparse.grammar.haxe.HxModuleWriteOptions;'), once);
		switch HxTypedOptionsRewrite.rewrite(once, KIT, true, new HaxeQueryPlugin()) {
			case Ok(text, rewrites):
				Assert.equals(once, text);
				Assert.equals(0, rewrites);
			case Err(message):
				Assert.fail(message);
		}
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-CONCATENATION')
	public function testAConcatenationOfLiteralsIsOneDocument(): Void {
		final text: String = ok(rewritten("loadHxFormatJson('{\"sameLine\": ' + '{\"tryBody\": \"same\"}}')"));
		Assert.isTrue(text.contains('forkWith(edited -> edited.tryBody = BodyPolicy.Same)'), text);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-INLINE-CUT')
	public function testAnInlineFinalLosesItsInlineModifier(): Void {
		final text: String = ok(
			named("\tprivate static inline final CONFIG: String = '{}';", '\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);')
		);
		Assert.isTrue(
			flat(text).contains(flat('private static final CONFIG: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson')), text
		);
		Assert.isFalse(text.contains('inline'), text);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-PUBLIC-FINAL')
	public function testAPublicFinalIsNotRetyped(): Void {
		final message: String = err(named("\tpublic static final CONFIG: String = '{}';", '\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);'));
		Assert.isTrue(message.contains('`CONFIG` cannot hold the typed options: it is public'), message);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-NAMED-READERS')
	public function testAFinalReadElsewhereRefusesTheSource(): Void {
		final message: String = err(named('', "\t\tfinal cfg = '{}';\n\t\tHxWriteFixture.triviaWrite(SRC, cfg);\n\t\ttrace(cfg);"));
		Assert.isTrue(message.contains('`cfg` is read where no configuration call reads it'), message);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-FIELD-READ')
	public function testAFinalReadAsAFieldRefusesTheSource(): Void {
		final message: String = err(
			named("\tprivate static final CONFIG: String = '{}';", '\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);\n\t\ttrace(S.CONFIG);')
		);
		Assert.isTrue(message.contains('`CONFIG` is read as a field'), message);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-TYPED-VALUE')
	public function testAValueTypedAsTheOptionsIsLeftAlone(): Void {
		final src: String = module(
			'\tfunction g(given: Null<HxModuleWriteOptions>) {\n\t\tHxWriteFixture.plainWrite(SRC, given);\n\t}',
			'\t\tfinal opts: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {});\n\t\tHxWriteFixture.triviaWrite(SRC, opts);'
		);
		switch HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()) {
			case Ok(text, rewrites):
				Assert.equals(src, text);
				Assert.equals(0, rewrites);
			case Err(message):
				Assert.fail(message);
		}
		final text: String = err(named('', '\t\tfinal s: String = make();\n\t\tHxWriteFixture.triviaWrite(SRC, s);'));
		Assert.isTrue(text.contains('not a constant string'), text);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-FINAL-CLASS')
	public function testAMemberOfAClassASubclassMayExtendIsNotRetyped(): Void {
		final src: String = "package unit.grammar.haxe;\n\nclass S {\n\n\tprivate static final CONFIG: String = '{}';\n\n"
			+ '\tfunction f() {\n\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);\n\t}\n\n}\n';
		final message: String = err(HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()));
		Assert.isTrue(
			message.contains('`CONFIG` cannot hold the typed options: it is a member of a type that is not a `final class`'), message
		);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-ACCESS-GRANT')
	public function testAMemberAnAccessGrantOpensIsNotRetyped(): Void {
		final onMember: String = err(
			named("\t@:allow(other.X) private static final CONFIG: String = '{}';", '\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);')
		);
		Assert.isTrue(onMember.contains('opened to another module by `@:allow`'), onMember);
		final src: String = 'package unit.grammar.haxe;\n\n@:allow(other.X)\nfinal class S {\n\n\tprivate static final CONFIG: String = '
			+ '\'{}\';\n\n\tfunction f() {\n\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);\n\t}\n\n}\n';
		final onType: String = err(HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()));
		Assert.isTrue(onType.contains('opened to another module by `@:allow`'), onType);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-GUARDED-PUBLIC')
	public function testAPublicUnderAConditionalRegionIsNotRetyped(): Void {
		final message: String = err(
			named("\t#if foo public #end static final CONFIG: String = '{}';", '\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);')
		);
		Assert.isTrue(message.contains('`CONFIG` cannot hold the typed options: it is public'), message);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-GUARDED-INLINE')
	public function testAnInlineUnderAConditionalRegionIsNotRetyped(): Void {
		final message: String = err(
			named("\t#if foo inline #end static final CONFIG: String = '{}';", '\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);')
		);
		Assert.isTrue(message.contains('`inline` under a conditional region'), message);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-LISTS-KEEP-SOURCE')
	public function testAListsKeepSourceWrapperIsReadAsItsTypedCounterpart(): Void {
		final json: String = '\'{"sameLine": {"tryBody": "same"}}\'';
		final loader: String = ok(rewritten('HxWriteOptionsKit.strictJson(HxWriteFixture.listsKeepSource($json))'));
		Assert.isTrue(loader.contains('HxWriteOptionsKit.forkWith(edited -> {'), loader);
		Assert.isTrue(flat(loader).contains(flat('HxListsKeepSource.keep(edited); edited.tryBody = BodyPolicy.Same;')), loader);
		Assert.isFalse(loader.contains('Wrap = {'), loader);
		Assert.isTrue(loader.contains('import anyparse.grammar.haxe.HxListsKeepSource;'), loader);
		Assert.isFalse(loader.contains('listsKeepSource'), loader);
		final fixture: String = ok(rewritten('HxWriteFixture.triviaWrite(SRC, HxWriteFixture.listsKeepSource(\'{}\'))'));
		Assert.isTrue(
			flat(fixture)
				.contains(flat('HxWriteFixture.triviaWrite(SRC, HxWriteOptionsKit.forkWith(edited -> HxListsKeepSource.keep(edited)))')),
			fixture
		);
		Assert.isFalse(fixture.contains('listsKeepSource'), fixture);
		final own: String = ok(rewritten(
			'HxWriteOptionsKit.strictJson(HxWriteFixture.listsKeepSource(\'{"wrapping": {"objectLiteral": {"defaultWrap": "noWrap"}}}\'))'
		));
		Assert.isTrue(own.indexOf('HxListsKeepSource.keep(edited)') < own.indexOf('edited.objectLiteralWrap = {'), own);
		Assert.isFalse(own.contains('edited.arrayLiteralWrap'), own);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-LISTS-KEEP-SOURCE-NAMED')
	public function testAFinalReadUnderTheWrapperHoldsTheWrappedDocument(): Void {
		final src: String = module(
			"\tprivate static final CONFIG: String = '{\"sameLine\": {\"tryBody\": \"same\"}}';",
			'\t\tHxWriteFixture.triviaWrite(SRC, HxWriteFixture.listsKeepSource(CONFIG));\n'
			+ '\t\tfinal b = HxWriteOptionsKit.strictJson(HxWriteFixture.listsKeepSource(CONFIG));'
		);
		final once: String = ok(HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()));
		Assert.isTrue(
			flat(once).contains(flat('private static final CONFIG: HxModuleWriteOptions = HxWriteOptionsKit.forkWith(edited -> {')), once
		);
		Assert.isTrue(once.contains('HxListsKeepSource.keep(edited);'), once);
		Assert.isTrue(flat(once).contains(flat('HxWriteFixture.triviaWrite(SRC, CONFIG);')), once);
		Assert.isTrue(flat(once).contains(flat('final b = CONFIG;')), once);
		Assert.isFalse(once.contains('listsKeepSource'), once);
		switch HxTypedOptionsRewrite.rewrite(once, KIT, true, new HaxeQueryPlugin()) {
			case Ok(text, rewrites):
				Assert.equals(once, text);
				Assert.equals(0, rewrites);
			case Err(message):
				Assert.fail(message);
		}
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-LISTS-KEEP-SOURCE-MIXED')
	public function testAFinalReadUnderAndOutsideTheWrapperRefusesTheSource(): Void {
		final message: String = err(named(
			"\tprivate static final CONFIG: String = '{}';",
			'\t\tHxWriteFixture.triviaWrite(SRC, HxWriteFixture.listsKeepSource(CONFIG));\n\t\tHxWriteFixture.triviaWrite(SRC, CONFIG);'
		));
		Assert.isTrue(message.contains('`CONFIG` is read both under `listsKeepSource` and outside it'), message);
	}

	@:pin('control')
	@:killer('M-TYPED-OPTIONS-LISTS-KEEP-SOURCE-OWN')
	public function testATestsOwnListsKeepSourceHelperIsNotTheFixturesWrapper(): Void {
		final src: String = module(
			'\tprivate static function listsKeepSource(json: String): String {\n\t\treturn json;\n\t}',
			"\t\tfinal opts = HxWriteOptionsKit.strictJson(listsKeepSource('{}'));"
		);
		final message: String = err(HxTypedOptionsRewrite.rewrite(src, KIT, true, new HaxeQueryPlugin()));
		Assert.isTrue(message.contains('the argument is not a constant string'), message);
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

	/** `text` without whitespace: the writer lays a long call out over lines, and a case asks for the call, not for its layout. */
	private static function flat(text: String): String {
		return ~/\s+/g.replace(text, '');
	}

	/** `module(members, body)` rewritten. */
	private static function named(members: String, body: String): EditResult {
		return HxTypedOptionsRewrite.rewrite(module(members, body), KIT, true, new HaxeQueryPlugin());
	}

	/** A module of the kit's package whose final class `S` declares `members` and runs `body` in `f`. */
	private static function module(members: String, body: String): String {
		return 'package unit.grammar.haxe;\n\nfinal class S {\n\n$members\n\n\tfunction f() {\n$body\n\t}\n\n}\n';
	}

}
