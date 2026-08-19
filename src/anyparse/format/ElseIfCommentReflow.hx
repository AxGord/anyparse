package anyparse.format;

import anyparse.core.Doc;

using StringTools;

/**
 * `sameLine.elseIfCommentReflow` runtime: move the ONE line comment a source
 * wrote between `else` and its nested `if` onto the end of that nested `if`'s
 * head line.
 *
 * WHAT THE WALK PROVES. The knob promises exactly two placements, and both are
 * the same structural position - the first UNCONDITIONAL break after the
 * condition:
 *
 *  - braced then-body - the break that opens the block's interior, so the
 *    comment lands after `{`: `else if (b) { // note`;
 *  - bare then-body that the body policy puts on the next line - the break the
 *    policy emits after the condition's `)`: `else if (b) // note`.
 *
 * So `scan` is an ACCEPTOR, not a refuser with a list of exceptions. It walks
 * in two phases (`afterCond`) and names only what a head may contain: invisible
 * or width-only glue, rendered head text, the condition unit, and the container
 * constructors that hold them. Its `case _` is the refusal, which is what makes
 * every shape nobody has thought of - a `Fill`, a width probe, a force-flat
 * region, a `Doc` constructor added next year - decline on its own without a
 * gate per discovery. Refusal is always whole (`null`): the caller then emits
 * the untouched pre-knob layout and the comment stays where the source put it.
 *
 * THE CONDITION IS OPAQUE. Every `WrapList.emitCondition` return is a
 * `WrapBoundary`, so the FIRST one the walk meets closes the condition and is
 * stepped over without descending. Its interior is head whatever shape the wrap
 * cascade gave it - probes, `Fill`, a nested boundary, a conditional newline
 * right after the open paren - and none of those breaks ends the head line.
 * Descending instead let a `onePerLine` condition anchor the comment after `(`,
 * where the next pass read the first operand as comment text and lost it.
 * Boundaries met AFTER the condition are ordinary containers: the then-body
 * block arrives as `WrapBoundary(BodyGroup(...))`.
 *
 * TEXT ON THE HEAD LINE. `isHeadText` states what a head may render. It opens
 * its body's block, so `{` is fine; it never CLOSES one, so a `}` means the
 * body has already rendered and finished - an EMPTY then-body arrives as the
 * single token `{}` with no interior break, and walking past it anchored the
 * comment on the nested `if`'s own `else`, re-attributing it to the other
 * branch. A `;` says the same thing for a bare body. A `//` already on the line
 * would swallow the relocated comment (the body-side twin of the `AfterKw`
 * refusal on the `else`), and a newline means the head line being measured is
 * not the one the comment would join. The newline clause and the `afterCond`
 * guard on the `Line` arm are phase assertions that no fixture reaches -
 * nothing in an `if` head emits a break before the condition unit, and no
 * `Text` in one carries a newline. They are kept as cheap statements of the
 * invariant, and deliberately NOT claimed as tested.
 *
 * WIDTH, measured rather than assumed. The splice cannot flip the flat-vs-broken
 * answer of any group it lands INSIDE: that group already holds the hardline the
 * comment is anchored to, so it was committed to breaking before the comment
 * arrived. It IS visible to a probe rendered EARLIER on the same line whose test
 * looks ahead at the rest of the stack - notably the `conditionWrapping`
 * cascade, which will open `if (\n\tcond\n)` when the glued head plus the
 * comment exceeds the limit. That is left alone on purpose: hiding the comment
 * from that probe would make the reflow output non-idempotent (the next pass
 * would re-measure and re-wrap it), and the shape it produces is byte-identical
 * to what the writer emits for the same construct written glued by hand. What
 * the knob never does is REFUSE because the glued line got long - an over-long
 * head line is accepted.
 */
@:nullSafety(Strict)
final class ElseIfCommentReflow {

	/**
	 * Splice `trailing` onto the head line of `bodyDoc` - the Doc the writer has
	 * already built for the nested `if`. Returns `null` unless the walk can
	 * PROVE the anchor is one of the two placements the knob promises; the
	 * caller then emits the untouched pre-knob layout.
	 */
	public static function insertHeadTrail(bodyDoc: Doc, trailing: Doc): Null<Doc> {
		return switch scan(bodyDoc, trailing, false) {
			case Anchored(doc): doc;
			case Scanning(_), Refused: null;
		};
	}

	private static inline function rewrap(scanned: ElseIfHeadScan, wrap: Doc -> Doc): ElseIfHeadScan {
		return switch scanned {
			case Anchored(doc): Anchored(wrap(doc));
			case Scanning(afterCond): Scanning(afterCond);
			case Refused: Refused;
		};
	}

	private static inline function isHardline(flat: String): Bool {
		return flat.length > 0 && flat.fastCodeAt(0) == '\n'.code;
	}

	/**
	 * Whether `s` may sit on the head line ahead of the relocated comment.
	 *
	 * A head line opens its body's block, so `{` is allowed; it never CLOSES one, so
	 * a `}` means the body has already rendered and finished and the walk is past the
	 * head. Same for a `;`: the walk has left the head for a rendered statement, and
	 * anything further right belongs to the body or to the nested `if`'s own `else`.
	 * A `//` already on the line would swallow the relocated comment, and a newline
	 * means the head line being measured is not the one the comment would join.
	 */
	private static inline function isHeadText(s: String): Bool {
		return s.indexOf('//') < 0 && s.indexOf('}') < 0 && s.indexOf(';') < 0 && s.indexOf('\n') < 0;
	}

	/**
	 * One scan step. `afterCond` is the phase: `false` while the walk is still
	 * inside the `if` keyword + condition run, `true` once the condition unit
	 * has been passed and the next unconditional break IS the end of the head
	 * line. Everything the walk cannot name is `Refused`, so a Doc constructor
	 * added later fails closed instead of acquiring an anchor by default.
	 */
	private static function scan(doc: Doc, trailing: Doc, afterCond: Bool): ElseIfHeadScan {
		return switch doc {
			// Invisible or width-only glue - neither ends nor breaks the head line.
			case Empty, OptSpace(_), OptSpaceSkipAfterHardline:
				Scanning(afterCond);
			// Rendered head tokens: the `if` keyword, the body-policy space, the
			// then-body block's `{`.
			case Text(s):
				isHeadText(s) ? Scanning(afterCond) : Refused;
			// THE ACCEPT. An unconditional break, in the body phase, is the end of
			// the head line - after the block's `{` when the body is braced, right
			// after the condition's `)` when the policy breaks a bare body. Both
			// promised placements are this one position.
			case Line(flat):
				afterCond && isHardline(flat) ? Anchored(Doc.Concat([trailing, doc])) : Refused;
			// Every `WrapList.emitCondition` return is a `WrapBoundary`, so the
			// FIRST one closes the condition. Skipped whole: its interior is head
			// by construction, whatever shape the wrap cascade gave it (probes,
			// `Fill`, its own nested boundary, a conditional newline after the
			// open paren). Later boundaries are ordinary containers - the block
			// body arrives as `WrapBoundary(BodyGroup(...))`.
			case WrapBoundary(inner): afterCond ? rewrap(scan(inner, trailing, true), d -> Doc.WrapBoundary(d)) : Scanning(true);
			case Concat(items): scanItems(items, trailing, afterCond);
			case Nest(indent, inner): rewrap(scan(inner, trailing, afterCond), d -> Doc.Nest(indent, d));
			case Group(inner): rewrap(scan(inner, trailing, afterCond), d -> Doc.Group(d));
			case BodyGroup(inner): rewrap(scan(inner, trailing, afterCond), d -> Doc.BodyGroup(d));
			case _: Refused;
		};
	}

	/** Walk `items` left to right, threading the condition phase across siblings. */
	private static function scanItems(items: Array<Doc>, trailing: Doc, afterCond: Bool): ElseIfHeadScan {
		var seenCond: Bool = afterCond;
		for (i in 0...items.length) switch scan(items[i], trailing, seenCond) {
			case Anchored(doc):
				final spliced: Array<Doc> = items.copy();
				spliced[i] = doc;
				return Anchored(Doc.Concat(spliced));
			case Scanning(next):
				seenCond = next;
			case Refused:
				return Refused;
		}
		return Scanning(seenCond);
	}

}

/** Result of one `ElseIfCommentReflow` scan step. */
private enum ElseIfHeadScan {

	/** The anchor was found and `doc` is the rewritten subtree. */
	Anchored(doc: Doc);

	/**
	 * Nothing yet - keep scanning to the right. `afterCond` is `false` while
	 * the walk is still inside the `if` keyword + condition run and `true`
	 * once the condition unit has been passed.
	 */
	Scanning(afterCond: Bool);

	/** Something the walk cannot prove is head - the whole reflow is refused. */
	Refused;
}
