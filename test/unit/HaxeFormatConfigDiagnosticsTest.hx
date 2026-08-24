package unit;

import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.grammar.haxe.HaxeFormatConfigIssues;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.format.HxFormatConfigParser;
import anyparse.grammar.haxe.format.HxFormatWrappingSection;
import anyparse.runtime.Parser;
import anyparse.runtime.StringInput;
import anyparse.runtime.UnknownField;
import utest.Assert;
import utest.Test;

/**
 * A setting hxq does not act on must SAY so.
 *
 * `hxformat.json` is haxe-formatter's file and hxq models a subset of
 * it, so both drop paths — an unknown key, and a wrap rule naming an
 * unmodelled predicate — are correct at runtime and must stay silent in
 * their EFFECT. What these tests pin is the other half: that the drop is
 * observable. Measured on the three real configs this project touches,
 * the silent surface was 12 / 19 / 19 keys plus three of the fork's own
 * shipped condition strings.
 *
 * The collection itself is grammar-agnostic — it lives on
 * `anyparse.runtime.Parser` and is emitted by the ByName struct
 * lowering, so every `@:schema` whose format declares
 * `onUnknown = Skip` gets it. `testContextCollectsUnknownFields` is the
 * test of that seam; the rest exercise the `hxformat.json` consumer.
 */
@:nullSafety(Strict)
class HaxeFormatConfigDiagnosticsTest extends Test {

	public function new(): Void {
		super();
	}

	public function testFullyModelledConfigIsSilent(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"wrapping": {"maxLineLength": 100, "arrayWrap": {"defaultWrap": "onePerLine"}}}'
		);
		Assert.equals(0, issues.keys.length);
		Assert.equals(0, issues.wrapValues.length);
	}

	public function testUnknownTopLevelSectionIsReported(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose('{"bogusSection": {"a": 1}}');
		Assert.equals(1, issues.keys.length);
		Assert.stringContains('bogusSection', issues.keys[0]);
	}

	public function testUnknownNestedKeyIsReportedWithItsOwnLine(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{\n\t"wrapping": {\n\t\t"totallyBogusKnob": 1\n\t}\n}'
		);
		Assert.equals(1, issues.keys.length);
		Assert.equals('totallyBogusKnob (l.3)', issues.keys[0]);
	}

	/**
	 * `additionalIndent` is a real per-rule haxe-formatter key hxq has
	 * not wired, and `HxFormatWrapRule` knows only `type` / `location` /
	 * `conditions` — none within two edits. Asserting the WHOLE phrase
	 * pins the absence of a suggestion, which `stringContains` would not.
	 */
	public function testUnknownKeyInsideAWrapRuleIsReported(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"wrapping": {"arrayWrap": {"rules": [{"type": "onePerLine", "additionalIndent": 1}]}}}'
		);
		Assert.equals(1, issues.keys.length);
		Assert.equals('additionalIndent (l.1)', issues.keys[0]);
	}

	/** A near-miss is a typo, so name the field it almost spells. */
	public function testTypoNamesTheNearestSchemaKey(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose('{"wrapping": {"arrayWarp": {"defaultWrap": "keep"}}}');
		Assert.equals(1, issues.keys.length);
		Assert.stringContains('did you mean "arrayWrap"?', issues.keys[0]);
	}

	/**
	 * `mapWrap` is a REAL haxe-formatter knob hxq has not wired, not a
	 * misspelling of `arrayWrap` — measured 2026-08-25, map literals are
	 * governed entirely by `arrayWrap`. Suggesting a neighbour here would
	 * tell the author to break their haxe-formatter config; the honest
	 * answer is that hxq does not implement the key.
	 */
	public function testUnimplementedForkKeyDrawsNoSuggestion(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose('{"wrapping": {"mapWrap": {"defaultWrap": "noWrap"}}}');
		Assert.equals(1, issues.keys.length);
		Assert.equals('mapWrap (l.1)', issues.keys[0]);
	}

	public function testUnknownWrapConditionIsReported(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"wrapping": {"arrayWrap": {"rules": [{"type": "onePerLine", "conditions": [{"cond": "equalItemLengths", "value": 1}]}]}}}'
		);
		Assert.equals(0, issues.keys.length);
		Assert.equals(1, issues.wrapValues.length);
		Assert.equals('cond "equalItemLengths" (the rule is dropped)', issues.wrapValues[0]);
	}

	public function testUnknownWrapTypeAndDefaultWrapAreReported(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"wrapping": {"anonType": {"defaultWrap": "bogusMode", "rules": [{"type": "bogusType"}]}}}'
		);
		Assert.equals(2, issues.wrapValues.length);
		Assert.stringContains('defaultWrap "bogusMode"', issues.wrapValues.join(' '));
		Assert.stringContains('type "bogusType"', issues.wrapValues.join(' '));
	}

	/** The same predicate appears in several cascades; the author needs the string once, not once per site. */
	public function testRepeatedWrapConditionIsReportedOnce(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"wrapping": {"arrayWrap": {"rules": [{"type": "onePerLine", "conditions": [{"cond": "anyItemLength <= n", "value": 5}]}]},'
			+ ' "anonType": {"rules": [{"type": "onePerLine", "conditions": [{"cond": "anyItemLength <= n", "value": 5}]}]}}}'
		);
		Assert.equals(1, issues.wrapValues.length);
	}

	/**
	 * A config that does not parse is the load path's error to report,
	 * not this one's — and the keys recorded before the input broke are
	 * discarded with it rather than half-reported. The unknown key sits
	 * BEFORE the truncation, so an implementation that kept the partial
	 * record would answer 1 here.
	 */
	public function testMalformedConfigDiscardsThePartialRecord(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose('{"bogusSection": 1, "wrapping": ');
		Assert.equals(0, issues.keys.length);
		Assert.equals(0, issues.wrapValues.length);
	}

	/** Diagnosing changes nothing: an unknown key is still skipped and every modelled key beside it still lands. */
	public function testUnknownKeyStillLoadsTheRestOfTheSection(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"wrapping": {"totallyBogusKnob": 1, "maxLineLength": 77}}'
		);
		Assert.equals(77, opts.lineWidth);
	}

	/**
	 * The grammar-agnostic seam: the ByName parser records the key on the
	 * caller's own context, together with the schema field list a
	 * suggestion is drawn from. Nothing Haxe-specific is involved.
	 */
	public function testContextCollectsUnknownFields(): Void {
		final ctx: Parser = new Parser(new StringInput('{"bogusSection": 1}'));
		HxFormatConfigParser.parseWith(ctx);
		Assert.equals(1, ctx.unknownFields.length);
		final field: UnknownField = ctx.unknownFields[0];
		Assert.equals('bogusSection', field.key);
		// The opening quote of the key token, not its first character.
		Assert.equals(1, field.pos);
		Assert.isTrue(field.known.contains('wrapping'));
		Assert.isNull(field.suggestion());
	}

	/** Owning the context changes nothing about the VALUE the parse returns. */
	public function testParseAndParseWithAgreeOnTheValue(): Void {
		final json: String = '{"wrapping": {"maxLineLength": 55}}';
		final viaParse: Null<HxFormatWrappingSection> = HxFormatConfigParser.parse(json).wrapping;
		final viaParseWith: Null<HxFormatWrappingSection> = HxFormatConfigParser.parseWith(new Parser(new StringInput(json))).wrapping;
		Assert.equals(55, viaParse == null ? -1 : viaParse.maxLineLength);
		Assert.equals(viaParse == null ? -1 : viaParse.maxLineLength, viaParseWith == null ? -2 : viaParseWith.maxLineLength);
	}

	/** A rule the loader drops for SHAPE, not for an unreadable string, is just as silent — and just as reported. */
	public function testRuleShapeDropsAreReported(): Void {
		final noType: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"wrapping": {"arrayWrap": {"rules": [{"conditions": [{"cond": "itemCount >= n", "value": 3}]}]}}}'
		);
		Assert.equals('a rule with no "type" (the rule is dropped)', noType.wrapValues.join(', '));
		final noCond: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"wrapping": {"arrayWrap": {"rules": [{"type": "onePerLine", "conditions": [{"value": 3}]}]}}}'
		);
		Assert.equals('a condition with no "cond" (the rule is dropped)', noCond.wrapValues.join(', '));
	}

	/** `arrayMatrixWrap` is the one `String`-with-a-vocabulary in `wrapping` that is not part of a cascade. */
	public function testUnknownArrayMatrixWrapIsReported(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose('{"wrapping": {"arrayMatrixWrap": "bogusMatrix"}}');
		Assert.equals(0, issues.keys.length);
		Assert.equals('arrayMatrixWrap "bogusMatrix" (the format default is kept)', issues.wrapValues.join(', '));
	}

	/**
	 * `cascades()` is a hand-maintained mirror of the list
	 * `HaxeFormatConfigLoader.applyWrappingRulesA` / `…RulesB` walk, and
	 * nothing in the language keeps the three in step. This table is what
	 * fails when they drift: `keys == 0` proves the name is a real schema
	 * field (so a typo in the table fails loudly rather than silently
	 * passing), and `wrapValues == 1` proves the cascade is enumerated.
	 */
	public function testEveryWrapCascadeIsSurveyed(): Void {
		final cascadeKeys: Array<String> = [
			'arrayWrap',
			'multiVar',
			'casePattern',
			'anonType',
			'methodChain',
			'opBoolChain',
			'opAddSubChain',
			'callParameter',
			'objectLiteral',
			'conditionWrapping',
			'ternaryExpression',
			'functionSignature',
			'anonFunctionSignature',
			'metadataCallParameter',
			'typeParameter',
			'expressionWrapping',
			'implementsExtends'
		];
		for (name in cascadeKeys) {
			final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
				'{"wrapping": {"$name": {"defaultWrap": "bogusMode"}}}'
			);
			Assert.equals(0, issues.keys.length, '$name is not a schema field');
			Assert.equals(1, issues.wrapValues.length, '$name is not surveyed by cascades()');
		}
	}

	/** The stderr wording is the whole user-facing product; pin it here rather than by reading a terminal. */
	public function testMessageNamesTheFileTheClassesAndTheEscapeHatch(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"wrapping": {"mapWrap": {"defaultWrap": "noWrap"}, "arrayWrap": {"defaultWrap": "bogusMode"}}}'
		);
		final line: Null<String> = HaxeFormatConfigDiagnostics.message('/p/hxformat.json', issues);
		Assert.equals(
			'apq: /p/hxformat.json: 1 key(s) hxq does not implement, so they have no effect: mapWrap (l.1); 1 wrap setting(s) hxq does '
			+ 'not implement: defaultWrap "bogusMode" (the cascade keeps its built-in default) [silence with APQ_NO_CONFIG_WARN=1]\n',
			line
		);
	}

	/** Nothing to say means nothing is said — the clean-config path must not print an empty header. */
	public function testMessageIsNullWhenThereIsNothingToSay(): Void {
		Assert.isNull(HaxeFormatConfigDiagnostics.message('/p/hxformat.json', { keys: [], wrapValues: [] }));
	}

}
