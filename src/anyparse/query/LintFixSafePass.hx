package anyparse.query;

import anyparse.check.CompilerOracle.OracleOutcome;

/**
 * What the two safe-pass oracle measurements decided: carry on, carry on but say the
 * net is off (and why), or roll the whole pass back with the compiler's errors.
 */
enum SafePassDecision {
	Proceed;
	NoNet(tail: String);
	Revert(errors: String);
}

/**
 * `apq lint --fix`'s safe-pass revert net: the judgement that decides whether the
 * non-risky fixes may stand, kept apart from the CLI so every arm is exercisable
 * without spawning a compiler.
 *
 * ## The defect it replaces
 *
 * `FixVerifier` takes its baseline AFTER the safe fixes are already on disk. A run
 * whose OWN fixes broke the build therefore reported `risky-fix skipped (oracle
 * baseline does not typecheck)` — a statement about the tree BEFORE `--fix`, which
 * had been green. The message named the wrong cause, the risky-fix insurance
 * switched itself off at exactly the moment it was needed, and the tree was left
 * un-typecheckable with nothing to say `--fix` had done it.
 *
 * Measuring once BEFORE the writes is the whole fix: it is the only way to tell
 * "already broken" from "we broke it".
 */
@:nullSafety(Strict)
final class LintFixSafePass {

	/** Whether an oracle verdict is the green one — the only case worth taking a second measurement for. */
	public static inline function isConfirmed(outcome: OracleOutcome): Bool {
		return switch outcome {
			case Confirmed: true;
			case _: false;
		};
	}

	/**
	 * The verdict, given the oracle reading taken before the safe writes (`pre`) and the
	 * one taken after (`post`).
	 *
	 * `post` is meaningful only when `pre` was green — the other arms cannot use it — so a
	 * null `post` there means the caller declined to measure and the pass is left alone.
	 *
	 *  - pre RED: the tree was already broken, so a red `post` proves nothing about the
	 *    fixes. Report it, keep the writes. This is the case the old message CLAIMED, and
	 *    almost never was.
	 *  - pre UNAVAILABLE: no measurement, no net.
	 *  - green then red: the safe fixes did it — revert.
	 *  - green then UNAVAILABLE: the oracle answered once and then could not run.
	 *    Reverting on no evidence would throw away a good pass, so the writes stand and
	 *    the run says the net could not close.
	 */
	public static function classify(pre: OracleOutcome, post: Null<OracleOutcome>): SafePassDecision {
		switch pre {
			case Rejected(_):
				return NoNet(', the tree did NOT typecheck before --fix ran — the safe-pass revert net is off');
			case Unavailable(reason):
				return NoNet(', safe-pass revert net off (oracle unavailable: $reason)');
			case Confirmed:
		}
		return switch post {
			case null, Confirmed: Proceed;
			case Unavailable(reason): NoNet(', safe-pass revert net could not close (oracle unavailable: $reason)');
			case Rejected(errors): Revert(errors);
		};
	}

}

/**
 * What the CLI does with `LintFixSafePass.classify`'s verdict: whether the whole safe
 * pass was rolled back (the caller then aborts), the summary tail to append, and the
 * compiler errors to print when it was.
 */
typedef SafePassOutcome = {
	final reverted: Bool;
	final tail: String;
	final errors: String;
};
