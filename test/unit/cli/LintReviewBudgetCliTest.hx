package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import anyparse.query.ExitCode;
import anyparse.query.cli.command.LintArgs;
import anyparse.query.cli.command.LintFixLedger;

/**
 * `apq lint --fix --review-budget <n>`: the budget a run lifts for the reorders of `member-order`, and the `--fix`
 * headline that says it did. The run is the real command over a real file, so what is proved is the flag reaching the
 * rule, not the rule reading an option.
 */
@:nullSafety(Strict)
final class LintReviewBudgetCliTest extends Test {

	/** The flag lifts the budget for its run: the type the default declines is reordered, and the headline names the budget. */
	@:killer('M-LINT-REVIEW-BUDGET-UNWIRED', 'M-FIX-HEADLINE-BUDGET-DROPPED', 'M-FIX-BUDGET-NOT-PASSED')
	@:pin('control')
	public function testTheFlagLiftsTheBudgetAndTheHeadlineNamesIt(): Void {
		#if (sys || nodejs)
		final plain: BudgetRun = fixRun([]);
		Assert.equals(plain.before, plain.after, 'without the flag the oversized type is left as written');
		Assert.equals(-1, plain.err.indexOf('review budget'), 'and the headline names no budget');
		final lifted: BudgetRun = fixRun(['--review-budget', '100000']);
		Assert.notEquals(lifted.before, lifted.after, 'with the flag it is reordered: ${lifted.err}');
		Assert.notEquals(
			-1, lifted.err.indexOf('review budget set to 100000 lines (--review-budget)'),
			'and the headline names the budget: ${lifted.err}'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The headline carries the budget after its counts, and is byte-for-byte the old line when no budget was given. */
	public function testTheHeadlineAppendsTheBudgetOnly(): Void {
		Assert.equals('apq lint --fix: 4 edit(s) in 1 file(s) over 2 pass(es)', LintFixLedger.lintFixSummary(4, 1, 2));
		Assert.equals(
			'apq lint --fix: 4 edit(s) in 1 file(s) over 2 pass(es), review budget set to 900 lines (--review-budget)',
			LintFixLedger.lintFixSummary(4, 1, 2, 900)
		);
	}

	/** The flag sets a budget of at least one line; anything else is a usage error rather than a silent default. */
	@:killer('M-LINT-REVIEW-BUDGET-ZERO', 'M-STRICT-INT-ABOVE-INT32')
	@:pin('control')
	public function testABudgetBelowOneLineIsAUsageError(): Void {
		Assert.equals(5000, LintArgs.parseLintArgs(['--fix', '--review-budget', '5000', 'C.hx']).reviewBudget);
		for (bad in ['0', '-3', 'many', '', '2147483648', '4294967295', '99999999999'])
			Assert.equals(ExitCode.EXIT_USAGE, LintArgs.parseLintArgs(['--fix', '--review-budget', bad, 'C.hx']).errExit, 'budget "$bad"');
	}

	/** A report run reorders nothing, so the flag with no `--fix` is refused instead of pretending to have lifted something. */
	@:killer('M-LINT-REVIEW-BUDGET-NEEDS-FIX')
	@:pin('control')
	public function testTheFlagWithoutFixIsRefused(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('apq_review_budget_report', [{ name: 'C.hx', source: oversized() }]);
		var code: Int = 0;
		CliFixture.always(
			CliFixture.removeDir.bind(dir),
			() -> CliFixture.captureStderr(() -> code = Cli.run(['lint', '--review-budget', '9', '$dir/C.hx']))
		);
		Assert.equals(ExitCode.EXIT_USAGE, code);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The flag outranks the project's own `maxRelocatedLines`: a small type the config declines is reordered under the flag,
	 * and the same type under an empty config needs neither.
	 */
	@:killer('M-LINT-REVIEW-BUDGET-UNWIRED', 'M-MO-BUDGET-OPTION-IGNORED')
	@:pin('control')
	public function testTheFlagOverridesTheProjectBudget(): Void {
		#if (sys || nodejs)
		final strict: String = '{"rules":{"member-order":{"maxRelocatedLines":2}}}';
		final empty: BudgetRun = fixRun([], 3);
		Assert.notEquals(empty.before, empty.after, 'under the default budget the small type is reordered');
		final declined: BudgetRun = fixRun([], 3, strict);
		Assert.equals(declined.before, declined.after, 'the project budget declines it');
		final lifted: BudgetRun = fixRun(['--review-budget', '100000'], 3, strict);
		Assert.notEquals(lifted.before, lifted.after, 'and the flag lifts it for the run: ${lifted.err}');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A type whose canonical order moves every member: 80 public/private-static pairs, far over the default budget. */
	private static function oversized(count: Int = 80): String {
		final filler: String = '\t\tvar v: Int = 0;';
		final pairs: Array<String> = [
			for (i in 0...count) '\tpublic function m$i(): Void {\n$filler\n\t}\n\n\tprivate static function s$i(): Void {\n$filler\n\t}'
		];
		final body: String = pairs.join('\n\n');
		return 'class C {\n\n$body\n\n}\n';
	}

	/** One `lint --fix --rule member-order` run over a fresh copy of the oversized type: its stderr and the file afterwards. */
	private static function fixRun(extra: Array<String>, count: Int = 80, config: String = '{}'): BudgetRun {
		final dir: String = CliFixture.writeTree('apq_review_budget', [
			{ name: 'C.hx', source: oversized(count) },
			{ name: 'apq.json', source: config }
		]);
		var before: String = '';
		var err: String = '';
		var after: String = '';
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			CliFixture.captureStderr(() -> Cli.run(['fmt', '--write', '$dir/C.hx']));
			before = File.getContent('$dir/C.hx');
			err = CliFixture.captureStderr(
				() -> Cli.run(['lint', '--fix', '--no-oracle', '--rule', 'member-order'].concat(extra).concat(['$dir/C.hx']))
			);
			after = File.getContent('$dir/C.hx');
		});
		return { before: before, err: err, after: after };
	}
	#end

}

/** One run's stderr, and the file it was run over afterwards. */
private typedef BudgetRun = {
	final before: String;
	final err: String;
	final after: String;
};
