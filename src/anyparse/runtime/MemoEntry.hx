package anyparse.runtime;

/**
 * One recorded run of a `@:memo` rule from one start position under one
 * pending-trivia content: where it stopped, the value it returned or the
 * `ParseError` it threw, and what it did to `Parser.pendingTrivia`. Replaying
 * it must be indistinguishable from re-running the rule, so the trivia effect
 * is recorded as well: the flags and the comments the run left on the stash it
 * was handed, and which stash it left behind.
 */
@:nullSafety(Strict)
final class MemoEntry {

	public final end: Int;
	public final value: Null<Dynamic>;
	public final error: Null<ParseError>;

	/** The entry stash's flags and appended comments after the run; null when the run was handed none. */
	public final handedAfter: Null<PendingTrivia>;

	/** What the run left pending. */
	public final exit: MemoExit;

	/** A copy of the stash the run created and left pending, for `Own`. */
	public final own: Null<PendingTrivia>;

	public function new(
		end: Int, value: Null<Dynamic>, error: Null<ParseError>, handedAfter: Null<PendingTrivia>, exit: MemoExit, own: Null<PendingTrivia>
	) {
		this.end = end;
		this.value = value;
		this.error = error;
		this.handedAfter = handedAfter;
		this.exit = exit;
		this.own = own;
	}

}

/** Which stash a recorded run left in `Parser.pendingTrivia`. */
enum abstract MemoExit(Int) {

	/** None. */
	final Nothing = 0;

	/** The one it was handed. */
	final Handed = 1;

	/** One it created (`MemoEntry.own`). */
	final Own = 2;

}
