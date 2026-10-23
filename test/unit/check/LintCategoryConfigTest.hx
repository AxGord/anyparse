package unit.check;

import anyparse.check.CommentWidth;
import anyparse.check.DocLength;
import anyparse.check.EffectiveRules;
import anyparse.check.EmptyComment;
import anyparse.check.EnglishComments;
import anyparse.check.LintConfig;
import anyparse.check.LintDocuments;
import anyparse.check.MagicNumber;
import anyparse.check.PreferFind;
import unit.cli.CliFixture;

/**
 * The `apqlint.json` rule switches: a `rules` entry as `true` / `false` or as an object of options, and the
 * `categories` section that switches a whole `RuleCategory`. A rule entry outranks its category's entry, which
 * outranks the rule's own default, and both sections fold over a nested chain key by key.
 */
@:nullSafety(Strict)
class LintCategoryConfigTest extends Test {

	@:pin('control') @:killer('M-CATEGORY-OUTRANKS-RULE')
	public function testARuleEntryOutranksItsCategory(): Void {
		final config: LintConfig = LintConfig.parse(
			'{"categories": {"docs": false}, "rules": {"empty-comment": true, "doc-length": true}}'
		);
		Assert.isTrue(Linter.enabledBy(config, new EmptyComment()), 'a rule entry true switches a member of a disabled category on');
		Assert.isTrue(Linter.enabledBy(config, new DocLength()), 'so does one on a default-off member');
		Assert.isFalse(Linter.enabledBy(config, new EnglishComments()), 'an unnamed member follows its category');
		final off: LintConfig = LintConfig.parse('{"categories": {"docs": true}, "rules": {"doc-length": false}}');
		Assert.isFalse(Linter.enabledBy(off, new DocLength()), 'a rule entry false wins over its category true');
	}

	@:pin('control') @:killer('M-CATEGORY-IGNORED')
	public function testACategorySwitchesEveryMemberDefaultOffOnesIncluded(): Void {
		Assert.isFalse(Linter.enabledBy(LintConfig.parse('{}'), new DocLength()), 'doc-length is default-off');
		final on: LintConfig = LintConfig.parse('{"categories": {"docs": true}}');
		Assert.isTrue(Linter.enabledBy(on, new DocLength()), 'enabling the category enables a default-off member');
		Assert.isTrue(Linter.enabledBy(on, new CommentWidth()), 'every default-off member');
		final off: LintConfig = LintConfig.parse('{"categories": {"docs": false}}');
		Assert.isFalse(Linter.enabledBy(off, new EmptyComment()), 'disabling the category disables a default-on member');
		Assert.isTrue(Linter.enabledBy(off, new MagicNumber()), 'a rule of another category keeps its default');
	}

	@:pin('control') @:killer('M-RULE-SHORTHAND-DROPPED')
	public function testABooleanRuleEntryIsTheEnabledShorthand(): Void {
		final config: LintConfig = LintConfig.parse('{"rules": {"doc-length": true, "magic-number": false}}');
		Assert.isTrue(Linter.enabledBy(config, new DocLength()), 'true enables a default-off rule');
		Assert.isFalse(Linter.enabledBy(config, new MagicNumber()), 'false disables a default-on rule');
	}

	@:pin('control') @:killer('M-OPTIONS-OBJECT-INERT')
	public function testAnObjectOfOptionsEnablesItsRule(): Void {
		final config: LintConfig = LintConfig.parse('{"rules": {"doc-length": {"max": 5}}}');
		Assert.isTrue(Linter.enabledBy(config, new DocLength()), 'an object of options enables a default-off rule');
		Assert.equals(5, config.intOption('doc-length', 'max'), 'and still carries its options');
		final stated: LintConfig = LintConfig.parse('{"rules": {"doc-length": {"enabled": false, "max": 5}}}');
		Assert.isFalse(Linter.enabledBy(stated, new DocLength()), 'a stated enabled false still wins');
	}

	@:pin('control') @:killer('M-UNKNOWN-CATEGORY-SILENT')
	public function testAnUnknownCategoryOrAValueOfTheWrongShapeIsNamedAndIgnored(): Void {
		final doc: Null<LintDocument> =
			LintDocuments.parseDocument('{"categories": {"style": true, "docs": "on", "loops": false}, "rules": {"naming": "error"}}');
		if (doc == null) {
			Assert.fail('the document itself is valid');
			return;
		}
		final drops: String = doc.drops.join('\n');
		Assert.stringContains('unknown category "style" (known: imports, docs,', drops);
		Assert.stringContains('categories "docs" is neither true nor false', drops);
		Assert.stringContains('rules "naming" is neither true, false nor an object of options', drops);
		final config: LintConfig = LintDocuments.fromDocument(doc);
		Assert.isFalse(Linter.enabledBy(config, new PreferFind()), 'the valid entry beside them still applies');
		Assert.isTrue(Linter.enabledBy(config, new EmptyComment()), 'the ignored docs value switches nothing');
	}

	@:pin('control') @:killer('M-CATEGORIES-NOT-INHERITED')
	public function testANestedDocumentInheritsBothSectionsKeyByKey(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('lintcategory', [
			{ name: 'apqlint.json', source: '{"categories": {"docs": true, "literals": false}, "rules": {"empty-comment": false}}' },
			{ name: 'nested/apqlint.json', source: '{"categories": {"literals": true}}' },
			{ name: 'nested/Probe.hx', source: 'class Probe {}\n' }
		]);
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.isTrue(Linter.enabledBy(config, new DocLength()), 'the ancestor category falls through');
		Assert.isTrue(Linter.enabledBy(config, new MagicNumber()), 'the nearer category entry wins');
		Assert.isFalse(Linter.enabledBy(config, new EmptyComment()), 'the ancestor rule entry still outranks the category');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTheListingNamesTheCategoryThatDecided(): Void {
		final config: LintConfig = LintConfig.parse('{"categories": {"docs": true}, "rules": {"comment-width": false}}');
		final byCategory: RuleState = EffectiveRules.stateOf(new DocLength(), 'P.hx', config);
		Assert.isTrue(byCategory.on);
		Assert.equals('category', byCategory.reason);
		Assert.equals('config', EffectiveRules.stateOf(new CommentWidth(), 'P.hx', config).reason, 'a rule entry is the config\'s word');
	}

}
