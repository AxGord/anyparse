package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import unit.cli.CliFixture;
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

	/** A null-guarded call `prefer-safe-nav` (4.3) rewrites to `a?.push(1)`. */
	private static final SAFE_NAV: String =
		'class V {\n\tpublic static function f(a:Null<Array<Int>>):Void {\n\t\tif (a != null) a.push(1);\n\t}\n}\n';

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
		Assert.isTrue(new LintConfig([], null, null, null, null, null, '4.10').allowsLanguageVersion('4.9'));
		Assert.isFalse(new LintConfig([], null, null, null, null, null, '4.9').allowsLanguageVersion('4.10'));
	}

	public function testAnUnreadableVersionConstrainsNothing(): Void {
		// A typo must not silently switch rules off — the failure mode this gate is meant to prevent.
		Assert.isTrue(new LintConfig([], null, null, null, null, null, 'nightly').allowsLanguageVersion('4.3'));
	}

	/**
	 * An explicit rule selection lifts `enabled:false` but never the version floor: the finding stays out of the
	 * report, and `--fix --rule` writes no `?.` into a 4.0 project while a 4.3 one still gets it.
	 */
	@:pin('control') @:killer('M-VERSION-LIFTED-BY-RULE')
	public function testAnExplicitRuleSelectionKeepsTheVersionFloor(): Void {
		final config: LintConfig = new LintConfig([], null, null, null, null, null, '4.0');
		final found: Array<Violation> = Linter.run([{ file: 'V.hx', source: SOURCE }], new HaxeQueryPlugin(), null, _ -> config, false);
		Assert.same([], [
			for (v in found) if (v.rule == 'prefer-null-coalescing' || v.rule == 'catch-dynamic') v.rule
		]);
		#if (sys || nodejs)
		for (version => rewrites in ['4.0' => false, '4.3' => true]) {
			final dir: String = CliFixture.writeDir('versionrule', [
				{ name: 'V.hx', source: SAFE_NAV },
				{ name: 'apqlint.json', source: '{"languageVersion":"$version"}' }
			]);
			Cli.run(['lint', '--fix', '--no-oracle', '--rule', 'prefer-safe-nav', '$dir/V.hx']);
			Assert.equals(rewrites, File.getContent('$dir/V.hx').indexOf('a?.push(1)') != -1, 'languageVersion $version');
			CliFixture.removeDir(dir);
		}
		#end
	}

	/** The rule ids reported for `SOURCE` under a config declaring `version` (null = none declared). */
	private function rulesFor(version: Null<String>): Array<String> {
		final config: LintConfig = new LintConfig([], null, null, null, null, null, version);
		final found: Array<Violation> = Linter.run([{ file: 'V.hx', source: SOURCE }], new HaxeQueryPlugin(), null, _ -> config, true);
		return [for (v in found) v.rule];
	}

}
