package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * A rule whose FIX emits newer syntax is dropped for a project that declares an older
 * `languageVersion`.
 *
 * `??` and `?.` are Haxe 4.3, `haxe.Exception` is 4.1, and the rules that rewrite into them
 * applied unconditionally. On one library that moved `??` from a single module into 27 —
 * core types among them — and raised 15 more modules from 4.0 to 4.1, in a tree that
 * already carried 54 `#if (haxe_ver >= 4.2)` guards. All of it had to be undone by hand.
 *
 * A project states its floor once and the rules follow. No declared floor means no
 * constraint — what every existing config already means.
 */
class LintLanguageVersionGateTest extends Test {

	/** A ternary the 4.3 rule rewrites, and a `catch (e: Dynamic)` the 4.1 rule rewrites. */
	private static final SOURCE: String = 'class V {\n\n\tpublic static function pick(a: Null<Int>, b: Int): Int {\n'
		+ '\t\treturn a != null ? a : b;\n\t}\n\n\tpublic static function boom(): Void {\n\t\ttry {\n\t\t\trun();\n'
		+ '\t\t} catch (e: Dynamic) {\n\t\t\ttrace(e);\n\t\t}\n\t}\n\n\tprivate static function run(): Void {}\n\n}\n';

	public function testNoDeclaredVersionConstrainsNothing(): Void {
		final rules: Array<String> = rulesFor(null);
		Assert.contains('prefer-null-coalescing', rules);
		Assert.contains('catch-dynamic', rules);
	}

	public function testAFourZeroProjectGetsNeither(): Void {
		final rules: Array<String> = rulesFor('4.0');
		Assert.isFalse(rules.contains('prefer-null-coalescing'));
		Assert.isFalse(rules.contains('catch-dynamic'));
	}

	public function testAFourOneProjectGetsTheExceptionRuleOnly(): Void {
		final rules: Array<String> = rulesFor('4.1');
		Assert.isFalse(rules.contains('prefer-null-coalescing'));
		Assert.contains('catch-dynamic', rules);
	}

	public function testAFourThreeProjectGetsBoth(): Void {
		final rules: Array<String> = rulesFor('4.3');
		Assert.contains('prefer-null-coalescing', rules);
		Assert.contains('catch-dynamic', rules);
	}

	public function testATwoComponentVersionComparesNumericallyNotLexically(): Void {
		// `4.10` is newer than `4.9`, which a string comparison gets backwards.
		Assert.isTrue(new LintConfig([], null, null, null, null, null, null, '4.10').allowsLanguageVersion('4.9'));
		Assert.isFalse(new LintConfig([], null, null, null, null, null, null, '4.9').allowsLanguageVersion('4.10'));
	}

	public function testAnUnreadableVersionConstrainsNothing(): Void {
		// A typo must not silently switch rules off — the failure mode this gate is meant to prevent.
		Assert.isTrue(new LintConfig([], null, null, null, null, null, null, 'nightly').allowsLanguageVersion('4.3'));
	}

	/** The rule ids reported for `SOURCE` under a config declaring `version` (null = none declared). */
	private function rulesFor(version: Null<String>): Array<String> {
		final config: LintConfig = new LintConfig([], null, null, null, null, null, null, version);
		final found: Array<Violation> = Linter.run([{ file: 'V.hx', source: SOURCE }], new HaxeQueryPlugin(), null, _ -> config, true);
		return [for (v in found) v.rule];
	}

}
