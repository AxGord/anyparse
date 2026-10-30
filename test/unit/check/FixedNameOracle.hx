package unit.check;

import anyparse.check.Check.NameOracle;

/**
 * A `NameOracle` answering from the rewritten text alone and counting the questions — what a rule's planning fixtures
 * install in place of the compiler, so the compiler's own answer stays the subject of the tests that start one.
 */
final class FixedNameOracle implements NameOracle {

	/** How many questions were asked. */
	public var asked(default, null): Int = 0;

	private final _answer: (String, Int) -> Bool;

	/** An oracle answering `answer(after, afterAt)` for the rewritten text and offset of each question. */
	public function new(answer: (String, Int) -> Bool) {
		_answer = answer;
	}

	public function sameDeclaration(file: String, before: String, beforeAt: Int, after: String, afterAt: Int): Bool {
		asked++;
		return _answer(after, afterAt);
	}

	/** An oracle that confirms every rewrite. */
	public static function agreeing(): FixedNameOracle {
		return new FixedNameOracle((_, _) -> true);
	}

}
