package unit.check;

import anyparse.check.Linter;
import anyparse.check.RuleIndex;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;

/**
 * The rule listing a tool reads to learn which rules answer differently on a narrower report scope: the rules that
 * do are marked, and the ones a scoped land must carry from the base are named by it.
 */
class ScopeDependentListingTest extends Test {

	@:pin('control')
	@:killer('M-RULE-INDEX-JSON-DROPS-SCOPE-DEPENDENT')
	public function testTheListingNamesTheScopeDependentRules(): Void {
		final marked: Array<String> = markedIds('scopeDependent');
		for (id in [
			'unused-return-value',
			'hoist-common-import',
			'unused-import',
			'anon-type-dup',
			'duplicate-code',
			'duplicate-code-renamed'
		]) Assert.contains(id, marked, id);
		Assert.notContains('unused-local', marked);
	}

	@:pin('control')
	@:killer('M-RULE-INDEX-JSON-DROPS-AMBIENT-GOVERNED')
	public function testTheListingNamesTheAmbientGovernedRules(): Void {
		final governed: Array<String> = markedIds('ambientGoverned');
		Assert.contains('hoist-common-import', governed);
		for (id in ['unused-return-value', 'unused-import', 'anon-type-dup', 'duplicate-code']) Assert.notContains(id, governed, id);
	}

	/** The ids of the listed rules whose record holds `field` true. */
	private static function markedIds(field: String): Array<String> {
		final records: Array<JValue> = switch JValueParser.parse(RuleIndex.json(Linter.builtins())) {
			case JArray(items): items;
			case _: [];
		}
		return [
			for (record in records) if (JValueTools.isTrue(JValueTools.field(record, field))) JValueTools.stringAt(record, 'id') ?? ''
		];
	}

}
