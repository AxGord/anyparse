package unit;

import anyparse.check.CompilerOracle.OracleOutcome;
import anyparse.query.LintFixSafePass;
import utest.Assert;
import utest.Test;

/**
 * `lint --fix`'s safe-pass revert net, as a pure decision over two oracle measurements.
 *
 * The defect it replaces: `FixVerifier` takes its baseline AFTER the safe fixes are on
 * disk, so a run whose OWN fixes broke the build reported
 * `risky-fix skipped (oracle baseline does not typecheck)` — a statement about the tree
 * before `--fix`, which had been green. The insurance switched itself off at exactly the
 * moment it was needed, and the tree was left un-typecheckable with no hint of the cause.
 *
 * Measuring BEFORE the writes is what tells the two apart. The classifier below is the
 * whole of that judgement; keeping it free of IO is what lets every arm be exercised
 * without spawning a compiler (the suite asserts elsewhere that no oracle is spawned
 * unless a project configures one).
 */
class LintFixSafePassRevertTest extends Test {

	public function testGreenThenRedRevertsTheWholePass(): Void {
		switch LintFixSafePass.classify(OracleOutcome.Confirmed, OracleOutcome.Rejected('Cannot assign to final')) {
			case Revert(errors):
				Assert.equals('Cannot assign to final', errors);
			case other:
				Assert.fail('expected Revert, got $other');
		}
	}

	public function testGreenThenGreenProceeds(): Void {
		Assert.isTrue(isProceed(LintFixSafePass.classify(OracleOutcome.Confirmed, OracleOutcome.Confirmed)));
	}

	public function testAlreadyRedBaselineSaysSoAndKeepsTheWrites(): Void {
		// The case the OLD message claimed and almost never was. A second red verdict proves
		// nothing here, so the pass stands and the run says the net is off.
		switch LintFixSafePass.classify(OracleOutcome.Rejected('pre-existing'), null) {
			case NoNet(tail):
				Assert.stringContains('did NOT typecheck before --fix ran', tail);
			case other:
				Assert.fail('expected NoNet, got $other');
		}
	}

	public function testUnavailableBeforeMeansNoNet(): Void {
		switch LintFixSafePass.classify(OracleOutcome.Unavailable('no haxe'), null) {
			case NoNet(tail):
				Assert.stringContains('no haxe', tail);
			case other:
				Assert.fail('expected NoNet, got $other');
		}
	}

	public function testUnavailableAfterKeepsTheWritesRatherThanRevertingOnNoEvidence(): Void {
		switch LintFixSafePass.classify(OracleOutcome.Confirmed, OracleOutcome.Unavailable('spawn failed')) {
			case NoNet(tail):
				Assert.stringContains('could not close', tail);
			case other:
				Assert.fail('expected NoNet, got $other');
		}
	}

	public function testADeclinedSecondMeasurementProceeds(): Void {
		Assert.isTrue(isProceed(LintFixSafePass.classify(OracleOutcome.Confirmed, null)));
	}

	public function testErrorFilesTakesTheLeadingPathAndSkipsWarningsAndContinuations(): Void {
		final errors: String = 'src/pony/ds/ROArray.hx:20: characters 3-8 : Type not found : Foo\n'
			+ '/lib/hxbitmini/Serializer.hx:445: characters 26-49 : Warning : (WDeprecated) Std.is is deprecated.\n'
			+ '  ... have no common ground\nsrc/pony/Tools.hx:9: lines 9-12 : Int should be String\nError: Build failed\n'
			+ 'src/pony/ds/ROArray.hx:31: characters 1-4 : and here again';
		Assert.same(['src/pony/ds/ROArray.hx', 'src/pony/Tools.hx'], LintFixSafePass.errorFiles(errors));
	}

	public function testARelativeCompilerPathFindsTheAbsolutePathTheRunWrote(): Void {
		// The compiler spells its positions relative to the hxml's directory; the lint knows the
		// same files by whatever path the caller passed. Neither side can normalise to the other,
		// so the match is a segment-aligned suffix.
		final changed: Array<String> = ['/tmp/pony/src/pony/ds/ROArray.hx', '/tmp/pony/src/pony/Tools.hx'];
		Assert.same(
			['/tmp/pony/src/pony/ds/ROArray.hx'],
			LintFixSafePass.implicated('src/pony/ds/ROArray.hx:20: characters 3-8 : Type not found : Foo', changed, [])
		);
	}

	public function testASuffixMatchNeedsASeparatorBoundary(): Void {
		// 'Array.hx' must not claim 'ROArray.hx' — a basename match would revert the wrong file.
		Assert.equals(0, LintFixSafePass.implicated('Array.hx:2: characters 1-2 : boom', ['/tmp/p/src/ROArray.hx'], []).length);
	}

	public function testAnImplicatedFilePullsInEveryFileItsCrossFileFixCommittedWith(): Void {
		// A cross-file rename is committed whole; reverting half of it leaves the tree worse than
		// reverting all of it, so the whole component goes back together.
		final changed: Array<String> = ['/p/A.hx', '/p/B.hx', '/p/C.hx', '/p/D.hx'];
		final coupled: Array<Array<String>> = [['/p/A.hx', '/p/B.hx'], ['/p/B.hx', '/p/C.hx']];
		final hit: Array<String> = LintFixSafePass.implicated('/p/A.hx:1: characters 1-2 : boom', changed, coupled);
		Assert.same(['/p/A.hx', '/p/B.hx', '/p/C.hx'], hit);
	}

	public function testOneRoundRevertsOnlyTheBlamedFileAndKeepsTheRest(): Void {
		final reverted: Array<String> = [];
		final changed: Array<String> = ['/p/A.hx', '/p/B.hx', '/p/C.hx'];
		final outcome: SafePassNarrowing = LintFixSafePass.narrow(
			'/p/B.hx:4: characters 1-2 : boom', changed, [], list -> for (f in list) reverted.push(f), () -> OracleOutcome.Confirmed,
			LintFixSafePass.NARROW_ROUNDS
		);
		switch outcome {
			case Narrowed(files, probes):
				Assert.same(['/p/B.hx'], files);
				Assert.equals(1, probes);
			case other:
				Assert.fail('expected Narrowed, got $other');
		}
		Assert.same(['/p/B.hx'], reverted);
	}

	public function testASecondRoundWidensByWhateverTheFreshErrorsBlame(): Void {
		final reverted: Array<String> = [];
		final answers: Array<OracleOutcome> = [
			OracleOutcome.Rejected('/p/C.hx:9: characters 1-2 : still broken'),
			OracleOutcome.Confirmed
		];
		final outcome: SafePassNarrowing = LintFixSafePass.narrow(
			'/p/A.hx:4: characters 1-2 : boom', ['/p/A.hx', '/p/B.hx', '/p/C.hx'],
			[], list -> for (f in list) reverted.push(f), () -> answers.shift() ?? OracleOutcome.Confirmed, LintFixSafePass.NARROW_ROUNDS
		);
		switch outcome {
			case Narrowed(files, probes):
				Assert.same(['/p/A.hx', '/p/C.hx'], files);
				Assert.equals(2, probes);
			case other:
				Assert.fail('expected Narrowed, got $other');
		}
		Assert.same(['/p/A.hx', '/p/C.hx'], reverted);
	}

	public function testAnErrorInAFileTheRunNeverWroteFallsBackToTheWholeWave(): Void {
		// The broken thing is the CALLER of an edited declaration. There is nothing to narrow to,
		// so the caller is told to roll everything back — and told WHY, rather than looping.
		var reverts: Int = 0;
		var probes: Int = 0;
		final outcome: SafePassNarrowing = LintFixSafePass.narrow(
			'/p/Z.hx:4: characters 1-2 : boom', ['/p/A.hx', '/p/B.hx'], [], _ -> reverts++, () -> {
				probes++;
				OracleOutcome.Confirmed;
			},
			LintFixSafePass.NARROW_ROUNDS
		);
		switch outcome {
			case WholeWave(why, _):
				Assert.stringContains('blames no file this run wrote', why);
			case other:
				Assert.fail('expected WholeWave, got $other');
		}
		Assert.equals(0, reverts);
		Assert.equals(0, probes);
	}

	public function testEveryWrittenFileImplicatedIsTheWholeWaveWithNoExtraTypecheck(): Void {
		var probes: Int = 0;
		var reverts: Int = 0;
		final outcome: SafePassNarrowing = LintFixSafePass.narrow(
			'/p/A.hx:1: characters 1-2 : boom\n/p/B.hx:1: characters 1-2 : boom', ['/p/A.hx', '/p/B.hx'],
			[], _ -> reverts++, () -> {
				probes++;
				OracleOutcome.Confirmed;
			},
			LintFixSafePass.NARROW_ROUNDS
		);
		switch outcome {
			case WholeWave(why, _):
				Assert.stringContains('every file this run wrote', why);
			case other:
				Assert.fail('expected WholeWave, got $other');
		}
		// Neither a probe nor a partial revert: reverting everything IS the caller's fallback, so
		// spending a typecheck to discover that would be a whole project build for nothing.
		Assert.equals(0, probes);
		Assert.equals(0, reverts);
	}

	public function testAnOracleThatStopsAnsweringMidNarrowingGivesUpOnTheWholeWave(): Void {
		final outcome: SafePassNarrowing = LintFixSafePass.narrow(
			'/p/A.hx:1: characters 1-2 : boom', ['/p/A.hx', '/p/B.hx'],
			[], _ -> {}, OracleOutcome.Unavailable.bind('spawn failed'), LintFixSafePass.NARROW_ROUNDS
		);
		switch outcome {
			case WholeWave(why, _):
				Assert.stringContains('spawn failed', why);
			case other:
				Assert.fail('expected WholeWave, got $other');
		}
	}

	public function testTheRoundBudgetIsSpentAtMostOncePerNewlyBlamedFile(): Void {
		// Worst case: every round blames exactly one new file and the tree never goes green. The
		// loop must stop at the budget rather than walk the wave file by file.
		final blame: Array<String> = ['/p/B.hx', '/p/C.hx', '/p/D.hx', '/p/E.hx', '/p/F.hx'];
		var probes: Int = 0;
		final outcome: SafePassNarrowing = LintFixSafePass.narrow(
			'/p/A.hx:1: characters 1-2 : boom', ['/p/A.hx', '/p/B.hx', '/p/C.hx', '/p/D.hx', '/p/E.hx', '/p/F.hx', '/p/G.hx'],
			[], _ -> {}, () -> {
				probes++;
				OracleOutcome.Rejected('${blame.shift()}:1: characters 1-2 : still broken');
			},
			LintFixSafePass.NARROW_ROUNDS
		);
		switch outcome {
			case WholeWave(why, _):
				Assert.stringContains('after ${LintFixSafePass.NARROW_ROUNDS} narrowing round(s)', why);
			case other:
				Assert.fail('expected WholeWave, got $other');
		}
		Assert.equals(LintFixSafePass.NARROW_ROUNDS, probes);
	}

	public function testTheNoticeNamesTheFileItRolledBack(): Void {
		// The message this replaces said only `REVERTED N file(s), nothing was written` — on a
		// 228-file wave that is a bisect, one compile at a time, to learn which file it meant.
		final notice: String = LintFixSafePass.revertNotice(
			SafePassNarrowing.Narrowed(['/p/B.hx'], 1), 3, '/p/B.hx:4: characters 1-2 : boom'
		);
		Assert.stringContains('REVERTED 1 of 3 file(s), KEPT the other 2', notice);
		Assert.stringContains('safe-fix REVERTED /p/B.hx', notice);
	}

	public function testTheWholeWaveNoticeSaysWhyAndNamesWhoTheCompilerBlamed(): Void {
		final notice: String = LintFixSafePass.revertNotice(
			SafePassNarrowing.WholeWave('the compiler blames no file this run wrote', '/p/Z.hx:4: characters 1-2 : boom'), 3,
			'/p/Z.hx:4: characters 1-2 : boom'
		);
		Assert.stringContains('REVERTED all 3 file(s), nothing was written', notice);
		Assert.stringContains('the compiler blames no file this run wrote', notice);
		Assert.stringContains('the compiler blames: /p/Z.hx', notice);
	}

	public function testAPrettyReportedDiagnosticIsAttributedDespiteItsAnsiBadge(): Void {
		// `-D message.reporting=pretty` (Pony's own tools/build.hxml sets it) puts an
		// ANSI-coloured ` ERROR ` badge before the position, so the path is NOT the line's first
		// token. Verbatim shape, measured on Haxe 4.3.7.
		final esc: String = String.fromCharCode(27);
		final errors: String = '$esc[30;41m ERROR $esc[0m src/Main5.hx:3: characters 3-31\n\n 3 | $esc[2m  $esc[0m$esc[1mfinal a: Int = '
			+ '\'not an int\';$esc[0m\n   |   $esc[31m^^^^^^^^^^^^^^^^^^^^^^^^^^^^$esc[0m\n   | String should be Int';
		Assert.same(['src/Main5.hx'], LintFixSafePass.errorFiles(errors));
	}

	public function testAPrettyReportedWarningIsNotWhyTheBuildFailed(): Void {
		// The classic spelling is ` : Warning :`; pretty writes a WARNING badge instead, and the
		// excerpt lines below it carry no position at all. Neither may implicate a written file.
		final esc: String = String.fromCharCode(27);
		final errors: String = '$esc[30;43m WARNING $esc[0m src/Main6.hx:4: characters 9-15\n 4 | $esc[2m  trace($esc[0m$esc[1mStd.is$esc'
			+ '[0m$esc[2m(a, Int));$esc[0m\n   | (WDeprecated) Std.is is deprecated. Use Std.isOfType instead.';
		Assert.equals(0, LintFixSafePass.errorFiles(errors).length);
	}

	public function testAColonDigitRunThatIsNotAPositionIsNotAPath(): Void {
		// A position is `<path>:<line>: ` — the trailing colon is what tells it from a message
		// that merely ends in a number, and a candidate with no extension is not a file either.
		Assert.equals(0, LintFixSafePass.errorFiles('Error: Could not process argument foo:1').length);
		Assert.equals(0, LintFixSafePass.errorFiles('Error: Build failed').length);
		Assert.equals(0, LintFixSafePass.errorFiles('  ... have: (Int) -> Void').length);
	}

	public function testAWindowsDriveLetterSurvivesTheColonScan(): Void {
		Assert.same(['C:\\proj\\src\\A.hx'], LintFixSafePass.errorFiles('C:\\proj\\src\\A.hx:20: characters 3-8 : Type not found : Foo'));
	}

	public function testASurrenderAfterARoundReportsTHATRoundsErrorsNotTheFirstRounds(): Void {
		// The narrowing reverted /p/A.hx, the tree stayed red, and the fresh errors blame a file
		// nothing wrote. Carrying the round-1 text here would name /p/A.hx as blamed — a file the
		// narrowing had already rolled back — and hide /p/Z.hx, the one that actually blocked it.
		final outcome: SafePassNarrowing = LintFixSafePass.narrow(
			'/p/A.hx:1: characters 1-2 : boom', ['/p/A.hx', '/p/B.hx'],
			[], _ -> {}, OracleOutcome.Rejected.bind('/p/Z.hx:9: characters 1-2 : the caller broke'), LintFixSafePass.NARROW_ROUNDS
		);
		final notice: String = switch outcome {
			case WholeWave(why, _):
				Assert.stringContains('no further file this run wrote', why);
				LintFixSafePass.revertNotice(outcome, 2, '/p/A.hx:1: characters 1-2 : boom');
			case other:
				Assert.fail('expected WholeWave, got $other');
				'';
		};
		Assert.stringContains('the compiler blames: /p/Z.hx', notice);
		Assert.isFalse(notice.indexOf('blames: /p/A.hx') != -1);
	}

	private function isProceed(decision: SafePassDecision): Bool {
		return switch decision {
			case Proceed: true;
			case _: false;
		};
	}

}
