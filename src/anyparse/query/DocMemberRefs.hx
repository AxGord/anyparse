package anyparse.query;

import anyparse.runtime.Span;
import anyparse.util.Strings;

/**
 * The one answer to "where does a comment name `Type.member` in backticks": the spans of the TYPE
 * word of each such mention, so a rename or a move that repoints the member repoints its prose
 * with it.
 *
 * A comment is prose, not code, so the convention is the one doc comments themselves use: the
 * dotted pair directly after an opening backtick, ending where the member's identifier does
 * (`Type.member`, `Type.member()`, `Type.member.field` match; `Type.memberOther` and an unticked
 * `Type.member` do not). Which type the word denotes is the caller's question, asked of the file
 * as a whole (`TypingService.bareBinding`).
 */
@:nullSafety(Strict)
final class DocMemberRefs {

	/** The span of `typeName` in every backticked `typeName.member` mention inside one of `comments`. */
	public static function typeSpans(source: String, comments: Array<Span>, typeName: String, member: String): Array<Span> {
		final needle: String = '`$typeName.$member';
		final out: Array<Span> = [];
		for (comment in comments) {
			var from: Int = comment.from;
			while (true) {
				final at: Int = source.indexOf(needle, from);
				if (at < 0 || at + needle.length > comment.to) break;
				from = at + 1;
				final end: Int = at + needle.length;
				if (end < source.length && Strings.isIdentChar(source.fastCodeAt(end))) continue;
				out.push(new Span(at + 1, at + 1 + typeName.length));
			}
		}
		return out;
	}

}
