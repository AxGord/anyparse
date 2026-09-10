package anyparse.format;

import anyparse.core.Doc;

using StringTools;

/**
 * `sameLine.elseIfCommentReflow` runtime: move the ONE line comment a source wrote
 * between `else` and its nested `if` onto the end of that nested `if`'s head line.
 *
 * Both placements the knob promises are the same structural position — the first
 * UNCONDITIONAL break after the condition: the break that opens a braced body, so
 * the comment lands after `{`, or the break the body policy emits after the
 * condition's `)` for a bare body on the next line. `scan` is therefore an
 * ACCEPTOR, naming only what a head may contain, and its `case _` is the refusal —
 * every shape nobody has thought of declines on its own instead of needing a gate
 * per discovery. Refusal is always whole (`null`), and the caller then emits the
 * untouched pre-knob layout with the comment where the source put it.
 *
 * The CONDITION is opaque: the first `WrapBoundary` the walk meets closes it and is
 * stepped over without descending, whatever shape the wrap cascade gave its
 * interior, because descending let a `onePerLine` condition anchor the comment
 * after `(` where the next pass read the first operand as comment text and lost it.
 * Boundaries met after the condition are ordinary containers.
 *
 * `isHeadText` states what a head may render: it opens its body's block, so `{` is
 * fine, but it never CLOSES one, so a `}` (an empty then-body arrives as the single
 * token `{}`) or a `;` says the body already finished and walking past it would
 * re-attribute the comment to the other branch; a `//` already on the line would
 * swallow the relocated comment, and a newline means this is not the line the
 * comment would join. The newline clause and the `afterCond` guard on the `Line`
 * arm are phase assertions kept as cheap statements of the invariant and
 * deliberately not claimed as tested.
 *
 * The splice cannot flip the flat-vs-broken answer of a group it lands INSIDE —
 * that group already holds the hardline the comment anchors to — but it IS visible
 * to a probe rendered earlier on the same line, notably the `conditionWrapping`
 * cascade. That is deliberate: hiding the comment from the probe would make the
 * reflow non-idempotent, and the glued shape is byte-identical to the same
 * construct written glued by hand. An over-long glued head line is accepted; a long
 * line is never a reason to refuse.
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
