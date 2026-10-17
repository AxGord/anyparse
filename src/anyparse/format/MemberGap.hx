package anyparse.format;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;

using Lambda;
using StringTools;

/**
 * What the doc-comment rules say about ONE member gap, read from the two members' leading comments and the
 * `afterFieldsWithDocComments` / `beforeDocCommentEmptyLines` policies (`MemberGap.docGap`).
 */
enum abstract DocGapVerdict(Int) {

	/** No doc-comment rule touches the gap: the source blank and the other rules decide. */
	final Keep = 0;

	/** A `One` policy adds a blank line (after a doc-led member, or before one). */
	final Blank = 1;

	/** The after-doc `None` policy drops the SOURCE blank; another rule may still add one. */
	final StripsSource = 2;

	/** The before-doc `None` policy forces the gap to zero blanks and vetoes every adding rule. */
	final NoBlank = 3;

}

/**
 * The blank-line policy a writer applies to the gap BETWEEN two adjacent members of a type body, as the runtime
 * predicates both sides read: the macro-generated writer splices calls to `docLed` / `docStrips` / `docVetoes` /
 * `docAdds` (`TriviaBlockLowering`) and to `multiline` (`WriterBlankLowering.blankAroundMultilineExprs`), and the
 * `member-order` check reaches the same functions through `GrammarPlugin.memberGapPolicy`, so the blank lines the
 * check demands are the ones `fmt` writes.
 *
 * Two rules live here. The doc-comment rule: a member whose leading comments carry a doc comment gets a blank line
 * after it (`afterFieldsWithDocComments`) and before it (`beforeDocCommentEmptyLines`) under `One`, none under `None`
 * - and the before-policy is the last write to the gap, so its `None` wins over every adding rule. The multi-line
 * rule (`aroundMultilineFields`): a gap next to a member whose rendered Doc breaks over several lines gets that many
 * blank lines when nothing else put one there; it is measured on the Doc, so it runs after every source-driven rule
 * and is not vetoed by them.
 */
@:nullSafety(Strict)
final class MemberGap {

	/** The opening of a doc comment - the leading-comment prefix the doc-comment rule keys on. */
	private static inline final DOC_OPEN: String = '/**';

	/**
	 * Whether the doc-comment rule drops the gap's SOURCE blank: after a
	 * doc-led member under `after = None`, or before one under `before = None`.
	 */
	public static inline function docStrips(
		prevDocLed: Bool, nextDocLed: Bool, after: CommentEmptyLinesPolicy, before: CommentEmptyLinesPolicy
	): Bool {
		return (prevDocLed && after == None) || (nextDocLed && before == None);
	}

	/** Whether the before-doc `None` policy vetoes every rule that would ADD a blank to the gap - it is the gap's last write. */
	public static inline function docVetoes(nextDocLed: Bool, before: CommentEmptyLinesPolicy): Bool {
		return nextDocLed && before == None;
	}

	/** Whether the doc-comment rule adds a blank line: after a doc-led member under `after = One`, or before one under `before = One`. */
	public static inline function docAdds(
		prevDocLed: Bool, nextDocLed: Bool, after: CommentEmptyLinesPolicy, before: CommentEmptyLinesPolicy
	): Bool {
		return (prevDocLed && after == One) || (nextDocLed && before == One);
	}

	/** Whether a member's leading comments carry a doc comment (`/**`), which is what the doc-comment rule keys on. */
	public static function docLed(leadingComments: Array<String>): Bool {
		return leadingComments.exists(c -> c.startsWith(DOC_OPEN));
	}

	/** The doc-comment rule's whole verdict on one gap, composed from `docVetoes`, `docAdds` and `docStrips` in the writer's precedence. */
	public static function docGap(
		prevDocLed: Bool, nextDocLed: Bool, after: CommentEmptyLinesPolicy, before: CommentEmptyLinesPolicy
	): DocGapVerdict {
		return if (docVetoes(nextDocLed, before))
			NoBlank
		else if (docAdds(prevDocLed, nextDocLed, after, before))
			Blank
		else if (docStrips(prevDocLed, nextDocLed, after, before))
			StripsSource
		else
			Keep;
	}

	/**
	 * Whether the member Doc `d` renders over several lines: it carries a forced break, or its flat width plus ONE
	 * indent level overflows the line. One level is exact for a top-level type and under-counts for a nested one,
	 * which can only cost a blank a stricter measure would have added - never a spurious one.
	 */
	public static function multiline(d: Doc, opt: WriteOptions): Bool {
		final cols: Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;
		return DocMeasure.hasForcedBreak(d) || cols + DocMeasure.flatTokenWidth(d) > opt.lineWidth;
	}

	/**
	 * The blank lines the writer FORCES into a member gap, whatever the source holds there, or null when it leaves the
	 * gap to the source and the other rules: `doc` is the doc-comment verdict (`docGap`), `multilineNeighbour` whether
	 * either member renders over several lines (`multiline`), `aroundMultiline` the `aroundMultilineFields` knob. The
	 * composition of the writer's two steps: the doc-comment rule writes its blank (`Blank`) or forces zero (`NoBlank`),
	 * and only then does the multi-line rule top an EMPTY gap up to the knob - so it lifts a forced zero too, while a
	 * gap that already holds the doc blank keeps that one. `StripsSource` answers null: whether the gap ends up blank
	 * depends on rules outside this policy.
	 */
	public static function forcedBlanks(doc: DocGapVerdict, multilineNeighbour: Bool, aroundMultiline: Int): Null<Int> {
		return if (doc == Blank)
			1
		else if (multilineNeighbour && aroundMultiline > 0)
			aroundMultiline
		else if (doc == NoBlank)
			0
		else
			null;
	}

}
