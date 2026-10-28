package unit.check;

import anyparse.check.RuleCategory;
import anyparse.check.RuleIndex;

/**
 * Every builtin rule names a category of the closed set, every category holds a rule, and the generated
 * `docs/lint-rules.md` is the index the registry renders today — so neither a rule nor its category can change without
 * the index being regenerated beside it.
 */
class RuleCategoryTest extends Test {

	public function testTheSetIsTheTwelveSubjects(): Void {
		Assert.same([
			'imports',
			'docs',
			'naming',
			'nullsafety',
			'types',
			'members',
			'unused',
			'control',
			'loops',
			'literals',
			'expressions',
			'design'
		], [for (c in RuleCategory.ALL) (c: String)]);
		for (c in RuleCategory.ALL) Assert.equals(c, RuleCategory.fromId(c), 'fromId reads back $c');
		Assert.isNull(RuleCategory.fromId('style'), 'an id outside the set is no category');
	}

	public function testEveryBuiltinNamesACategoryAndEveryCategoryHoldsOne(): Void {
		final used: Array<RuleCategory> = [];
		for (check in Linter.builtins()) {
			Assert.isTrue(RuleCategory.ALL.contains(check.category()), '${check.id()} names a category of the set');
			if (!used.contains(check.category())) used.push(check.category());
		}
		Assert.equals(RuleCategory.ALL.length, used.length, 'every category holds a rule');
	}

	public function testTheCheckedInIndexIsTheRegistryRendered(): Void {
		#if (sys || nodejs)
		final expected: String = RuleIndex.markdown(Linter.builtins());
		final actual: String = sys.io.File.getContent('docs/lint-rules.md');
		Assert.isTrue(
			expected == actual,
			'docs/lint-rules.md is stale — regenerate: node bin/apq.js lint --lang haxe --list-rules --format markdown > docs/lint-rules.md'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
