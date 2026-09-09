package unit.query;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.query.LintBaseline;
import anyparse.query.LintDiff;
import anyparse.query.format.json.LintFindingJson;
import utest.Assert;
import utest.Test;

/**
 * Unit cover for `apq lint --baseline` — the delta a `PostToolUse` nudge reports instead of
 * every finding standing on the file an op just wrote.
 *
 * Driven straight through `LintBaseline.added` over hand-built `Violation`s and a hand-built
 * snapshot: the CLI layer only reads one file, prints, and writes the refreshed snapshot, so
 * what is worth locking is the multiset arithmetic and — the whole reason this module exists
 * rather than a text diff in the hook — that a COORDINATE SHIFT is not a delta.
 *
 * The identity map is asked of the real check registry (`Linter.messageIdentities`), like
 * `LintDiffTest`, so these cases run against the declarations the builtins actually make about
 * their own messages rather than a local imitation of them.
 */
@:nullSafety(Strict)
class LintBaselineTest extends Test {

	/**
	 * The delta is empty when nothing changed, and a MOVED finding has not changed.
	 *
	 * The second half is the load-bearing one and the reason a plain text diff of two reports
	 * cannot do this job: an edit that inserts a line above a finding moves its `line` and
	 * `col`, and every naive comparison then reports it as new. The pair is written as a pair
	 * because an empty delta also passes when the two sides were never different.
	 */
	@:pin('control')
	@:killer('M-LINT-BASELINE-NO-SUBTRACTION')
	public function testAFindingThatONLYMOVEDIsNotNew(): Void {
		final before: LintDiffTally = snapshot([record('src/A.hx', 'warning', 'unused-import', 'import a.B is unused')]);
		Assert.equals(0, delta([violation('src/A.hx', Severity.Warning, 'unused-import', 'import a.B is unused')], before).length);
		// The discriminating half: same key, different rule text -> a real addition.
		Assert.equals(1, delta([violation('src/A.hx', Severity.Warning, 'unused-import', 'import a.C is unused')], before).length);
	}

	/** A finding the snapshot never carried comes back, in the order the run found it. */
	public function testOnlyTheSurplusIsReported(): Void {
		final before: LintDiffTally = snapshot([record('src/A.hx', 'info', 'member-order', 'member out of order')]);
		final out: Array<Violation> = delta([
			violation('src/A.hx', Severity.Info, 'member-order', 'member out of order'),
			violation('src/A.hx', Severity.Warning, 'unused-local', 'unused local \'x\''),
			violation('src/B.hx', Severity.Error, 'dead-code', 'unreachable statement')
		], before);
		Assert.equals(2, out.length);
		Assert.equals('unused-local', out[0].rule, 'run order is preserved');
		Assert.equals('dead-code', out[1].rule);
	}

	/**
	 * MULTISET, not set: three findings sharing one key against a snapshot holding two leaves
	 * exactly one surplus. A set difference would report none, and the third occurrence — the
	 * one the edit added — would be the finding nobody sees.
	 */
	public function testASharedKeyIsSubtractedOncePerOccurrence(): Void {
		final message: String = 'the literal \'x\' is repeated';
		final before: LintDiffTally = snapshot([
			record('src/A.hx', 'info', 'string-literal-dup', message),
			record('src/A.hx', 'info', 'string-literal-dup', message)
		]);
		final three: Array<Violation> = [
			for (_ in 0...3) violation('src/A.hx', Severity.Info, 'string-literal-dup', message)
		];
		Assert.equals(1, delta(three, before).length);
	}

	/**
	 * An EMPTY snapshot subtracts nothing — the state a first-ever run, a deleted cache and an
	 * unreadable one all reach. Fail-open is the direction a nudge wants: too much beats
	 * silence, because silence reads as "your edit introduced nothing".
	 */
	public function testAnEmptySnapshotReportsEverything(): Void {
		final out: Array<Violation> = delta([violation('src/A.hx', Severity.Warning, 'unused-local', 'unused local \'x\'')], snapshot([]));
		Assert.equals(1, out.length);
	}

	/** The snapshot belongs to the caller: a second `added` over it sees the same counts. */
	public function testTheSnapshotIsNotConsumed(): Void {
		final before: LintDiffTally = snapshot([record('src/A.hx', 'info', 'member-order', 'member out of order')]);
		final live: Array<Violation> = [violation('src/A.hx', Severity.Info, 'member-order', 'member out of order')];
		Assert.equals(0, delta(live, before).length);
		Assert.equals(0, delta(live, before).length, 'the tally was mutated by the first call');
	}

	private static function delta(all: Array<Violation>, before: LintDiffTally): Array<Violation> {
		return LintBaseline.added(all, before, '', identities());
	}

	private static function snapshot(records: Array<LintFindingJson>): LintDiffTally {
		return LintDiff.tally(records, '', identities());
	}

	private static function identities(): LintMessageIdentities {
		return Linter.messageIdentities();
	}

	/** One live finding, span-less: `added` keys on file/rule/severity/message and never on a coordinate. */
	private static function violation(file: String, severity: Severity, rule: String, message: String): Violation {
		return {
			file: file,
			span: null,
			rule: rule,
			severity: severity,
			message: message
		};
	}

	/** One recorded finding, as `apq lint --format json` writes it. */
	private static function record(file: String, severity: String, rule: String, message: String): LintFindingJson {
		return {
			file: file,
			severity: severity,
			rule: rule,
			message: message
		};
	}

}
