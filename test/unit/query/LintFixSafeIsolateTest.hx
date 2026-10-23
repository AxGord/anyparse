package unit.query;

import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.check.FailerBisect;
import anyparse.query.LintFixSafePass;

using Lambda;
using StringTools;

/**
 * `lint --fix`'s safe-pass net when the compiler blames a file the run never wrote: the wave is bisected over the
 * files it wrote, a culprit file is split by rule, and only the rejected edits go back.
 *
 * Every fixture drives `LintFixSafePass.isolate` through a FAKE seat — no compiler, no disk: a probe answers from the
 * candidate it is handed, a replay spells the rules it applied.
 */
@:nullSafety(Strict)
class LintFixSafeIsolateTest extends Test {

	/** What the compiler said about the round: an error in a file the round never wrote. */
	private static final ERRORS: String = '/p/Reader.hx:9: characters 12-20 : p.Holder has no field drop';

	/** The surrender `narrow` hands over when the errors name nothing the run wrote. */
	private static final SURRENDER: SafePassNarrowing = WholeWave('the compiler blames no file this run wrote', ERRORS);

	/** One poisoning file among eight: it alone goes back, the seven innocent ones stay. */
	@:pin('control')
	@:killer('M-SAFE-BISECT-OFF')
	public function testABisectionKeepsEveryFileButTheOneThatBreaksTheBuild(): Void {
		final changed: Array<String> = [for (name in 'ABCDEFGH'.split('')) '/p/$name.hx'];
		var probes: Int = 0;
		final outcome: SafePassNarrowing = LintFixSafePass.isolate(
			SURRENDER, changed, [], seat((keep, _) -> {
				probes++;
				return keep.contains('/p/C.hx') ? OracleOutcome.Rejected(ERRORS) : OracleOutcome.Confirmed;
			})
		);
		switch outcome {
			case Bisected(culprits, spent):
				Assert.same(['/p/C.hx'], [for (culprit in culprits) culprit.file]);
				Assert.isNull(culprits[0].kept, 'a file that cannot be split goes back whole');
				Assert.same(['rule-of-/p/C.hx'], culprits[0].rules);
				Assert.equals(probes, spent);
				Assert.isTrue(spent <= FailerBisect.searchBudget(changed.length) + 1, 'the search and its confirm stay in budget: $spent');
			case other:
				Assert.fail('expected Bisected, got $other');
		}
	}

	/** A cross-file fix's files are one unit: the culprit pulls back the file it was committed with, and nothing else. */
	public function testFilesACrossFileFixCommittedTogetherAreBisectedAsOne(): Void {
		final changed: Array<String> = ['/p/A.hx', '/p/B.hx', '/p/C.hx', '/p/D.hx'];
		final outcome: SafePassNarrowing = LintFixSafePass.isolate(
			SURRENDER, changed, [['/p/B.hx', '/p/D.hx']],
			seat((keep, _) -> keep.contains('/p/B.hx') ? OracleOutcome.Rejected(ERRORS) : OracleOutcome.Confirmed)
		);
		switch outcome {
			case Bisected(culprits, _):
				Assert.same(['/p/B.hx', '/p/D.hx'], [for (culprit in culprits) culprit.file]);
			case other:
				Assert.fail('expected Bisected, got $other');
		}
	}

	/**
	 * A culprit file holding several rules' edits keeps the ones the compiler accepts: the bisection moves inside the
	 * file, one rule at a time, and the text it keeps is the first pass replayed without the rejected rule.
	 */
	@:pin('control')
	@:killer('M-SAFE-SPLIT-OFF')
	public function testACulpritFileKeepsTheEditsOfEveryRuleTheCompilerAccepts(): Void {
		final rules: Array<String> = ['import-order', 'poison', 'unused-import'];
		final outcome: SafePassNarrowing = LintFixSafePass.isolate(SURRENDER, ['/p/A.hx', '/p/B.hx'], [], {
			probe: (keep, partial) ->
				keep.contains('/p/B.hx') || (partial['/p/B.hx'] ?? '').contains('poison')
					? OracleOutcome.Rejected(ERRORS)
					: OracleOutcome.Confirmed,
			splitRules: file -> file == '/p/B.hx' ? rules : [],
			replay: (_, subset) -> subset.length == 0 ? null : subset.join('+'),
			rulesOf: file -> file == '/p/B.hx' ? rules : ['import-order'],
			fixed: file -> file == '/p/B.hx' ? rules.join('+') : 'fixed'
		});
		switch outcome {
			case Bisected(culprits, _):
				Assert.equals(1, culprits.length);
				Assert.equals('/p/B.hx', culprits[0].file);
				Assert.same(['poison'], culprits[0].rules);
				Assert.equals('import-order+unused-import', culprits[0].kept);
			case other:
				Assert.fail('expected Bisected, got $other');
		}
	}

	/** A culprit a LATER pass made: the first pass alone typechecks, so the file keeps exactly that. */
	public function testAPoisonALaterPassMadeCostsOnlyTheLaterPass(): Void {
		final outcome: SafePassNarrowing = LintFixSafePass.isolate(Narrowed(['/p/B.hx'], 1), ['/p/A.hx', '/p/B.hx'], [], {
			probe: (_, partial) -> partial.exists('/p/B.hx') ? OracleOutcome.Confirmed : OracleOutcome.Rejected(ERRORS),
			splitRules: _ -> ['import-order'],
			replay: (_, subset) -> subset.join('+'),
			rulesOf: _ -> ['import-order', 'late-rule'],
			fixed: _ -> 'import-order+late-rule'
		});
		switch outcome {
			case Bisected(culprits, probes):
				Assert.same(['late-rule'], culprits[0].rules);
				Assert.equals('import-order', culprits[0].kept);
				Assert.equals(2, probes, 'the attributing round and the one replay');
			case other:
				Assert.fail('expected Bisected, got $other');
		}
	}

	/** An attributed narrowing whose file cannot be split stays the narrowing it was, at no extra typecheck. */
	public function testAnUnsplittableAttributedFileStaysNarrowed(): Void {
		final outcome: SafePassNarrowing = LintFixSafePass.isolate(
			Narrowed(['/p/B.hx'], 1), ['/p/A.hx', '/p/B.hx'], [], seat((_, _) -> {
				Assert.fail('no probe is owed');
				return OracleOutcome.Confirmed;
			})
		);
		switch outcome {
			case Narrowed(files, probes):
				Assert.same(['/p/B.hx'], files);
				Assert.equals(1, probes);
			case other:
				Assert.fail('expected Narrowed, got $other');
		}
	}

	/**
	 * Every file breaks the build on its own: the search exhausts its budget and the net falls back to the whole-wave
	 * revert — fail closed — saying both why the narrowing surrendered and why the bisection could not help.
	 */
	@:pin('control')
	@:killer('M-SAFE-BISECT-NO-FALLBACK')
	public function testABisectionThatCannotIsolateFallsBackToTheWholeWave(): Void {
		final changed: Array<String> = [for (name in 'ABCDEFGH'.split('')) '/p/$name.hx'];
		var probes: Int = 0;
		final outcome: SafePassNarrowing = LintFixSafePass.isolate(
			SURRENDER, changed, [], seat((keep, _) -> {
				probes++;
				return keep.length > 0 ? OracleOutcome.Rejected(ERRORS) : OracleOutcome.Confirmed;
			})
		);
		switch outcome {
			case WholeWave(why, errors):
				Assert.stringContains('the compiler blames no file this run wrote', why);
				Assert.stringContains('isolated no culprit within ${FailerBisect.searchBudget(changed.length)} typecheck(s)', why);
				Assert.equals(ERRORS, errors);
			case other:
				Assert.fail('expected WholeWave, got $other');
		}
		Assert.isTrue(probes <= FailerBisect.searchBudget(changed.length), 'the search stops at its budget: $probes');
	}

	/** An oracle that stops answering mid-bisection proves nothing about any half: the whole wave goes back. */
	public function testAnOracleThatStopsAnsweringMidBisectionFallsBack(): Void {
		final outcome: SafePassNarrowing = LintFixSafePass.isolate(
			SURRENDER, ['/p/A.hx', '/p/B.hx', '/p/C.hx'], [], seat((_, _) -> OracleOutcome.Unavailable('spawn failed'))
		);
		switch outcome {
			case WholeWave(why, _):
				Assert.stringContains('the oracle could not re-run (spawn failed)', why);
			case other:
				Assert.fail('expected WholeWave, got $other');
		}
	}

	/**
	 * The notice of a bisected revert says what went back — the whole file or the rules cut out of it — and, whatever the
	 * verbosity, which files the compiler blamed and what it said: without them the revert cannot be diagnosed.
	 */
	@:pin('control')
	@:killer('M-SAFE-BLAME-UNSAID')
	public function testTheBisectedNoticeNamesTheCutAndWhatTheCompilerSaid(): Void {
		final notice: String = LintFixSafePass.revertNotice(Bisected([
			{ file: '/p/B.hx', rules: ['poison'], kept: 'kept' },
			{ file: '/p/C.hx', rules: ['other'], kept: null }
		], 5), 8, ERRORS);
		Assert.stringContains('REVERTED 1 of 8 file(s) and part of 1 more, KEPT everything else on disk (5 extra typecheck(s)', notice);
		Assert.stringContains('safe-fix REVERTED the poison edit(s) of /p/B.hx, KEPT its other edits', notice);
		Assert.stringContains('safe-fix REVERTED /p/C.hx (other)', notice);
		Assert.stringContains('the compiler blames: /p/Reader.hx', notice);
		Assert.stringContains(ERRORS, notice);
		final narrowed: String = LintFixSafePass.revertNotice(Narrowed(['/p/Reader.hx'], 1), 3, ERRORS);
		Assert.stringContains('the compiler blames: /p/Reader.hx', narrowed);
	}

	/** A seat whose files cannot be split, answering every probe through `probe`. */
	private static function seat(probe: (Array<String>, Map<String, String>) -> OracleOutcome): SafeBisectSeat {
		return {
			probe: probe,
			splitRules: _ -> [],
			replay: (_, _) -> null,
			rulesOf: file -> ['rule-of-$file'],
			fixed: _ -> null
		};
	}

}
