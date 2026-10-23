package unit.cli;

import anyparse.query.Cli;

/**
 * `apq lint --category <id>` NARROWS a run to the rules of that category the config enables — it never force-enables a
 * rule the way `--rule` does, so the two are refused together — and names the twelve ids when given an unknown one.
 */
class LintCategoryCliTest extends Test {

	private static inline final SOURCE: String = 'package p;\n\n/** C. */\nclass C {\n\t//\n\tpublic static final S:String = "a";\n}\n';

	@:pin('control') @:killer('M-CATEGORY-FILTER-IGNORED')
	public function testACategoryNarrowsTheRunToItsRules(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('lintcategory', [{ name: 'C.hx', source: SOURCE }]);
		final all: String = CliFixture.captureStdout(() -> Cli.run(['lint', '--no-oracle', '--format', 'json', '$dir/C.hx']));
		final docs: String = CliFixture.captureStdout(() ->
			Cli.run(['lint', '--no-oracle', '--format', 'json', '--category', 'docs', '$dir/C.hx'])
		);
		CliFixture.removeDir(dir);
		#if nodejs
		Assert.stringContains('"prefer-single-quotes"', all, 'the control run reports the literals finding');
		Assert.stringContains('"empty-comment"', docs, 'the docs rule still runs');
		Assert.isFalse(docs.indexOf('"prefer-single-quotes"') >= 0, 'a rule of another category does not: $docs');
		#end
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control') @:killer('M-CATEGORY-FORCES-RULES')
	public function testACategoryNeverEnablesWhatTheConfigDisables(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('lintcategory', [
			{ name: 'C.hx', source: SOURCE },
			{ name: 'apqlint.json', source: '{"rules": {"empty-comment": false}}' }
		]);
		final docs: String = CliFixture.captureStdout(() ->
			Cli.run(['lint', '--no-oracle', '--format', 'json', '--category', 'docs', '$dir/C.hx'])
		);
		CliFixture.removeDir(dir);
		#if nodejs
		Assert.isFalse(docs.indexOf('"empty-comment"') >= 0, 'a disabled rule stays off under its category: $docs');
		#end
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAnUnknownCategoryOrOneBesideRuleIsAUsageError(): Void {
		#if (sys || nodejs)
		final unknown: String = CliFixture.captureStderr(() -> Assert.equals(2, Cli.run(['lint', '--category', 'style', 'x.hx'])));
		Assert.equals(
			2, Cli.run(['lint', '--category', 'docs', '--rule', 'empty-comment', 'x.hx']), '--rule and --category are one choice'
		);
		#if nodejs
		Assert.stringContains('unknown category "style" (expected imports|docs|', unknown);
		#end
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testListRulesNarrowsToTheCategoryAndItsJsonNamesIt(): Void {
		#if (sys || nodejs)
		final listed: String = CliFixture.captureStdout(() ->
			Cli.run(['lint', '--list-rules', '--category', 'imports', '--format', 'json'])
		);
		#if nodejs
		final records: Array<{ id: String, category: String }> = haxe.Json.parse(listed);
		Assert.isTrue(records.length > 0, 'the category holds rules');
		for (r in records) Assert.equals('imports', r.category, '${r.id} is listed under its own category');
		#end
		#else
		Assert.pass('non-sys target');
		#end
	}

}
