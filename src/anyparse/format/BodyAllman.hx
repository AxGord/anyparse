package anyparse.format;

import anyparse.core.Doc;

/**
 * A construct whose tail carries a body `BodyAllman.gluedLayout` rewrote, resolved to each side of the body's own
 * width decision.
 */
typedef AllmanSides = {

	/**
	 * The widest the construct's flat line may be, measured from the indent it starts at, before the body breaks.
	 */
	var limit: Int;

	/** The construct with its body on the break side — in Allman position. */
	var brk: Doc;

	/** The construct with its body on the flat side — glued. */
	var flat: Doc;
};

/**
 * The Allman placement of a `@:fmt(bodyAllmanIndentForCtor(...))` body — `{` on its own line one indent below the
 * header — and the one owner of the question that decides it: does the body render multi-line?
 *
 * A body whose Doc carries a forced hardline answers structurally, in the generated writer. A body that breaks only
 * through its OWN width decision (an object literal the source wrote flat and its wrap rule breaks by width) answers
 * at the column it lands on. Left alone, that decision breaks the literal GLUED to the header, and the next rewrite
 * reads the newlines it wrote as a source-multi-line literal and goes Allman — the fixed point one rewrite late.
 * `gluedLayout` rewrites the decision's BREAK side into the Allman shape and leaves everything else where it was: the
 * same decision, at the same column, behind the same wrappers, with the same flat side. A body that stays flat is
 * therefore byte-identical, and one that breaks lands directly on the shape the forced-hardline answer gives it.
 *
 * `tailSides` is the recogniser, for an enclosing decision that must place the construct BEFORE that body decides
 * (`WrapList.shapeComprehensionCuddledOpen`). The rewrite and the recogniser share one shape, which is why they live
 * together.
 */
@:nullSafety(Strict)
final class BodyAllman {

	/**
	 * `layout` — the placement the body policy chose for a matching body that carries no forced hardline — with the
	 * body's break side moved to Allman position, or `layout` unchanged.
	 *
	 * Only the GLUED placement is rewritten (`OptSpace(' ')` then the body): there the body breaks at the header's
	 * column, which is what the Allman override exists for, and the pending `OptSpace` is dropped by the break the
	 * Allman side opens with. A next-line or fit-group placement already puts a broken body where the Allman shape
	 * would. A body that is not wholly one width decision behind transparent wrappers is left alone — there is no
	 * break side to move.
	 */
	public static function gluedLayout(cols: Int, layout: Doc): Doc {
		return switch layout {
			case Doc.Concat([Doc.OptSpace(' '), body]):
				final moved: Null<Doc> = allmanBreakSide(cols, body);
				moved == null ? layout : Doc.Concat([Doc.OptSpace(' '), moved]);
			case _:
				layout;
		};
	}

	/**
	 * `d` with the body `gluedLayout` rewrote resolved to each side of its decision, or `null` when its tail carries
	 * no such body. The walk follows only the last non-`Empty` element of each `Concat`, as `WrapList`'s comprehension
	 * walks do: the body sits at the tail of its construct, and anything earlier belongs to the head.
	 *
	 * `limit` restates the body's own verdict for the construct's flat line measured from its start, where the
	 * construct sits right after a line break with `trail` more columns (a separator) behind it on that line — so an
	 * enclosing decision asks the question the body will ask, from widths alone. The two decisions count
	 * different things: `IfFirstLineExceeds` its probe column without the pending separator space and nothing
	 * after it, `GroupWithRestProbe` the pending space and the trailing rest. The break side comes back as the
	 * real `BodyFit.breakLayout`, so a decision measured on it sees the hardline the next rewrite will read.
	 */
	public static function tailSides(d: Doc, lineWidth: Int, trail: Int): Null<AllmanSides> {
		return switch d {
			case Doc.IfFirstLineExceeds(n, Doc.LeadingBreak(cols, brk), flat):
				{ limit: n, brk: BodyFit.breakLayout(cols, brk), flat: flat };
			case Doc.GroupWithRestProbe(Doc.IfBreak(Doc.LeadingBreak(cols, brk), flat)):
				{ limit: lineWidth - trail, brk: BodyFit.breakLayout(cols, brk), flat: flat };
			case Doc.WrapBoundary(inner):
				final s: Null<AllmanSides> = tailSides(inner, lineWidth, trail);
				s == null ? null : { limit: s.limit, brk: Doc.WrapBoundary(s.brk), flat: Doc.WrapBoundary(s.flat) };
			case Doc.Concat(items):
				final i: Int = BodyFit.lastNonEmptyIdx(items);
				final inner: Null<AllmanSides> = i < 0 ? null : tailSides(items[i], lineWidth, trail);
				inner == null ? null : { limit: inner.limit, brk: replacedAt(items, i, inner.brk), flat: replacedAt(items, i, inner.flat) };
			case _:
				null;
		};
	}

	/**
	 * `body` with its width decision's break side in Allman position, or `null` when `body` is not wholly one of the
	 * decisions it can rewrite behind `WrapBoundary` / one-element `Concat` wrappers.
	 */
	private static function allmanBreakSide(cols: Int, body: Doc): Null<Doc> {
		return switch body {
			case Doc.IfFirstLineExceeds(n, brk, flat):
				Doc.IfFirstLineExceeds(n, Doc.LeadingBreak(cols, brk), flat);
			case Doc.GroupWithRestProbe(Doc.IfBreak(brk, flat)):
				Doc.GroupWithRestProbe(Doc.IfBreak(Doc.LeadingBreak(cols, brk), flat));
			case Doc.WrapBoundary(inner):
				final moved: Null<Doc> = allmanBreakSide(cols, inner);
				moved == null ? null : Doc.WrapBoundary(moved);
			case Doc.Concat([inner]):
				final moved: Null<Doc> = allmanBreakSide(cols, inner);
				moved == null ? null : Doc.Concat([moved]);
			case _:
				null;
		};
	}

	/** A copy of `items` with element `i` replaced by `d`. */
	private static function replacedAt(items: Array<Doc>, i: Int, d: Doc): Doc {
		final copy: Array<Doc> = items.copy();
		copy[i] = d;
		return Doc.Concat(copy);
	}

}
