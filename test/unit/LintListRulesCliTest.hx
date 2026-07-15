package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.query.Cli;

/**
 * `apq lint --list-rules` — the machine-consumable check listing review
 * tooling subtracts manual-checklist rules by. Exit-code e2e via `Cli.run`
 * plus content invariants pinned on `Linter.builtins()` directly (the CLI
 * prints exactly that set, so the invariants hold for the listing too).
 */
class LintListRulesCliTest extends Test {

	public function testListRulesExitsZeroWithoutScope(): Void {
		#if (sys || nodejs)
		Assert.equals(0, Cli.run(['lint', '--list-rules']), '--list-rules needs no scope and exits 0');
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testBuiltinIdsUniqueKebabAndDescribed(): Void {
		final checks: Array<Check> = Linter.builtins();
		Assert.isTrue(checks.length >= 60, 'builtin set is the full registry, not a stub');
		final seen: Array<String> = [];
		for (c in checks) {
			final id: String = c.id();
			Assert.isFalse(seen.contains(id), 'duplicate check id "$id"');
			seen.push(id);
			Assert.isTrue(~/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/.match(id), 'id "$id" is kebab-case');
			Assert.isTrue(c.description().length > 0, 'check "$id" has a description');
		}
	}

}
