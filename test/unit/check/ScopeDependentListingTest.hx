package unit.check;

import anyparse.check.RuleIndex;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import devkit.RawJson;

/**
 * The rule listing a tool reads to learn which rules answer differently on a narrower report scope: the rules that
 * do are marked, and the ones a scoped land must carry from the base are named by it.
 */
class ScopeDependentListingTest extends Test {

	@:pin('control')
	@:killer('M-RULE-INDEX-JSON-DROPS-SCOPE-DEPENDENT')
	public function testTheListingNamesTheScopeDependentRules(): Void {
		final marked: Array<String> = scopeDependentIds();
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

	private static function scopeDependentIds(): Array<String> {
		final records: Array<JValue> = switch JValueParser.parse(RuleIndex.json(Linter.builtins())) {
			case JArray(items): items;
			case _: [];
		}
		return [
			for (record in records) if (RawJson.isTrue(JValueTools.field(record, 'scopeDependent'))) RawJson.stringAt(record, 'id') ?? ''
		];
	}

}
