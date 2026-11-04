package unit.check;

import anyparse.check.Check.NameOracle;
import anyparse.check.Check.NameSite;
import anyparse.runtime.Span;

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

	public function sameDeclarations(
		file: String, before: String, after: String, sites: Array<NameSite>, edits: Array<{ span: Span, text: String }>
	): Array<Bool> {
		asked += sites.length;
		return [for (site in sites) _answer(after, site.after)];
	}

	/** An oracle that confirms every rewrite. */
	public static function agreeing(): FixedNameOracle {
		return new FixedNameOracle((_, _) -> true);
	}

}
