package anyparse.query;

import anyparse.runtime.Span;

using Lambda;

/**
 * The run's record of every text `CanonicalEdit.canonicalize` produced, with the edits it spliced to get there — the
 * only evidence of where a declaration of an earlier text now stands. A `--fix` run keeps one (`CachingGrammarPlugin`),
 * so a reader of facts the compiler recorded against a file's run-start text can place them in the file as it is now.
 *
 * A position maps back only through text the edits left alone, by exact offset arithmetic: one inside a replaced span,
 * inside inserted text, or across a deletion has no counterpart — a member MOVED by a reorder is deleted in one place and
 * inserted in another, so nothing inside it maps. The writer's settling after a splice may move whitespace and nothing
 * else: a step whose settled text differs from its splice in anything but whitespace maps nothing. When several recorded
 * histories lead from one text to the other, they must agree, or nothing maps.
 */
@:nullSafety(Strict)
final class EditJournal {

	/** How many distinct histories between two texts are compared before the answer is refused. */
	private static inline final MAX_PATHS: Int = 64;

	/** Text before -> the steps recorded from it. */
	private final _steps: Map<String, Array<EditStep>> = [];

	public function new() {}

	/** Record that `edits` spliced into `before` settled as `after`. */
	public function record(before: String, edits: Array<{ span: Span, text: String }>, after: String): Void {
		if (before == after) return;
		final from: Array<EditStep> = _steps[before] ?? [];
		_steps[before] = from;
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> a.span.from != b.span.from ? a.span.from - b.span.from : a.span.to - b.span.to);
		final key: String = [for (e in sorted) '${e.span.from}:${e.span.to}:${e.text}'].join('\u0000');
		if (!from.exists(s -> s.after == after && s.key == key)) from.push(new EditStep(before, sorted, after, key));
	}

	/**
	 * Where `span` of `now` stands in `then`: `Mapped` with the span there, or `Unmapped` with the reason — no recorded
	 * history leads from `then` to `now`, the span lies in or across text some step rewrote, or two histories disagree.
	 */
	public function back(then: String, now: String, span: Span): SpanBack {
		if (then == now) return Mapped(span);
		final paths: Array<Array<EditStep>> = [];
		if (!collect(then, now, [], [then], paths)) return Unmapped(UNMAPPED_AMBIGUOUS);
		if (paths.length == 0) return Unmapped(UNMAPPED_NO_HISTORY);
		var answer: Null<Span> = null;
		for (path in paths) {
			var at: Null<Span> = span;
			var i: Int = path.length - 1;
			while (at != null && i >= 0) at = path[i--].back(at);
			if (at == null) return Unmapped(UNMAPPED_REWRITTEN);
			final seen: Null<Span> = answer;
			if (seen != null && (seen.from != at.from || seen.to != at.to)) return Unmapped(UNMAPPED_AMBIGUOUS);
			answer = at;
		}
		return answer == null ? Unmapped(UNMAPPED_NO_HISTORY) : Mapped(answer);
	}

	/** Every history from `text` to `goal` extending `path` into `out`; false once more than `MAX_PATHS` are found. */
	private function collect(
		text: String, goal: String, path: Array<EditStep>, visited: Array<String>, out: Array<Array<EditStep>>
	): Bool {
		for (step in _steps[text] ?? []) {
			if (step.after == goal) {
				if (out.length >= MAX_PATHS) return false;
				out.push(path.concat([step]));
			} else if (!visited.contains(step.after) && !collect(step.after, goal, path.concat([step]), visited.concat([step.after]), out))
				return false;
		}
		return true;
	}

	public static inline final UNMAPPED_NO_HISTORY: String = 'the run rewrote this file along a path whose edits it did not record';

	public static inline final UNMAPPED_REWRITTEN: String =
		"the run rewrote or moved the declaration's own text after the compiler typed it, so no fact names it";

	public static inline final UNMAPPED_AMBIGUOUS: String = 'the run recorded histories of this file that place the declaration apart';

}

/** Where a span stands in an earlier text (`EditJournal.back`). */
enum SpanBack {
	Mapped(span: Span);
	Unmapped(reason: String);
}
