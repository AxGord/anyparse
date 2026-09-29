package anyparse.format;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;

/**
 * A construct whose tail carries a probe `BodyAllman.gluedLayout` hoisted, resolved to each side of that probe.
 */
typedef AllmanSides = {

	/**
	 * The column the body's flat first line may reach and still stay glued, or `BodyAllman.LINE_WIDTH` when the
	 * verdict is a `Group`'s, which fits against the render width.
	 */
	var limit: Int;

	/** The construct with its body in Allman position, on the body's BREAK side. */
	var brk: Doc;

	/** The construct with its body glued, on the body's FLAT side. */
	var flat: Doc;
};

/**
 * The Allman placement of a `@:fmt(bodyAllmanIndentForCtor(...))` body — `{` on its own line one indent below the
 * header — and the one owner of the question that decides it: does the body render multi-line?
 *
 * A body whose Doc carries a forced hardline answers structurally, in the generated writer. A body that breaks only
 * through its OWN width decision (an object literal the source wrote flat and its wrap rule breaks by width) cannot:
 * that decision is taken at the column the body lands on, after every static gate has already placed it. Left to
 * itself the literal breaks GLUED to the header, and the next rewrite reads the newlines it wrote as a
 * source-multi-line literal, goes Allman, and reaches its fixed point one rewrite late. `gluedLayout` hoists the
 * decision to the placement instead, so the `{` moves exactly when the literal breaks, with the literal's own break
 * side, and the output is already the shape the forced-hardline answer gives it.
 *
 * `tailSides` is the recogniser half, for an enclosing decision that must place the construct BEFORE the hoisted
 * decision renders (`WrapList.shapeComprehensionCuddledOpen`): it hands back the construct resolved to either side,
 * so that decision can answer from widths alone. The builder and the recogniser share one shape, which is why they
 * live together.
 */
@:nullSafety(Strict)
final class BodyAllman {

	/** `AllmanSides.limit` for a `Group` verdict: the body breaks once it does not fit the render width. */
	public static inline final LINE_WIDTH: Int = -1;

	/**
	 * `layout` — the placement the body policy chose for a matching body that carries no forced hardline — with the
	 * body's own width decision hoisted to the placement, or `layout` unchanged.
	 *
	 * Only the GLUED placement is rewritten (`OptSpace(' ')` then the body): there the body breaks at the header's
	 * column, which is what the Allman override exists for. A next-line or fit-group placement already puts a broken
	 * body where the Allman shape would, so its own break needs no second answer. A body that is not wholly one
	 * width decision behind transparent wrappers is left alone too — its verdict is nothing this function can repeat.
	 *
	 * The hoisted decision is the body's own ctor, measuring `OptSpace(' ')` plus the body's flat side one column left
	 * of where the body measured it, so the two agree by construction. Each side then carries the body's matching
	 * side, so a body kept glued cannot break there on its own and one moved to Allman position cannot re-flatten.
	 */
	public static function gluedLayout(cols: Int, layout: Doc): Doc {
		return switch layout {
			case Doc.Concat([Doc.OptSpace(' '), body]): hoisted(cols, body, d -> d) ?? layout;
			case _: layout;
		};
	}

	/**
	 * `d` with the decision `gluedLayout` hoisted into its tail resolved to each side, or `null` when its tail carries
	 * none. The walk follows only the last non-`Empty` element of each `Concat`, as `WrapList`'s comprehension walks
	 * do: the body sits at the tail of its construct, and anything earlier belongs to the head.
	 *
	 * The cuddled-open list asks it because its head is placed before the body's break is known: it cuddles
	 * on the Allman side exactly when the flat side at the ladder indent passes `limit` and the head fits,
	 * and otherwise keeps the LIVE construct on the ladder, where the verdict then comes out glued. Both
	 * answers are what a source already holding the break would get, so neither moves on the next write.
	 */
	public static function tailSides(d: Doc): Null<AllmanSides> {
		final own: Null<AllmanSides> = hoistedSides(d);
		if (own != null) return own;
		return switch d {
			case Doc.Concat(items):
				final i: Int = BodyFit.lastNonEmptyIdx(items);
				final inner: Null<AllmanSides> = i < 0 ? null : tailSides(items[i]);
				inner == null ? null : { limit: inner.limit, brk: replacedAt(items, i, inner.brk), flat: replacedAt(items, i, inner.flat) };
			case _:
				null;
		};
	}

	/**
	 * The hoisted decision for `body`, or `null` when `body` is not one of the width decisions it can repeat. `wrap`
	 * re-applies the transparent wrappers peeled on the way down, inside each side.
	 */
	private static function hoisted(cols: Int, body: Doc, wrap: Doc -> Doc): Null<Doc> {
		inline function allman(brk: Doc): Doc {
			return BodyFit.breakLayout(cols, wrap(brk));
		}
		inline function glued(flat: Doc): Doc {
			return Doc.Concat([Doc.OptSpace(' '), wrap(flat)]);
		}
		return switch body {
			// The body measured from behind a PENDING `OptSpace`, which its column did not
			// count yet; the hoisted probe counts that space inside its own flat side, so
			// its threshold moves one column out to ask the same question.
			case Doc.IfFirstLineExceeds(n, brk, flat):
				Doc.IfFirstLineExceeds(n + 1, allman(brk), glued(flat));
			case Doc.GroupWithRestProbe(Doc.IfBreak(brk, flat)):
				Doc.GroupWithRestProbe(Doc.IfBreak(allman(brk), glued(flat)));
			case Doc.Group(Doc.IfBreak(brk, flat)):
				Doc.Group(Doc.IfBreak(allman(brk), glued(flat)));
			case Doc.WrapBoundary(inner):
				hoisted(cols, inner, d -> wrap(Doc.WrapBoundary(d)));
			case Doc.Concat([inner]):
				hoisted(cols, inner, d -> wrap(Doc.Concat([d])));
			case _:
				null;
		};
	}

	/** The sides of a decision `gluedLayout` built, or `null` for any other Doc. */
	private static function hoistedSides(d: Doc): Null<AllmanSides> {
		return switch d {
			case Doc.IfFirstLineExceeds(n, brk, flat) if (isAllman(brk) && isGluedBrace(flat)):
				{ limit: n - 1, brk: brk, flat: flat };
			case Doc.GroupWithRestProbe(Doc.IfBreak(brk, flat)), Doc.Group(Doc.IfBreak(brk, flat)) if (isAllman(brk) && isGluedBrace(flat)):
				{ limit: LINE_WIDTH, brk: brk, flat: flat };
			case _:
				null;
		};
	}

	/** Is `d` the `BodyFit.breakLayout` shape? */
	private static function isAllman(d: Doc): Bool {
		return switch d {
			case Doc.Nest(_, Doc.Concat([Doc.Line('\n'), _])): true;
			case _: false;
		};
	}

	/** Is `d` a `{`-led body glued behind `OptSpace(' ')`? */
	private static function isGluedBrace(d: Doc): Bool {
		return switch d {
			case Doc.Concat([Doc.OptSpace(' '), body]): DocMeasure.firstVisibleTextStartsWith(body, '{'.code);
			case _: false;
		};
	}

	/** A copy of `items` with element `i` replaced by `d`. */
	private static function replacedAt(items: Array<Doc>, i: Int, d: Doc): Doc {
		final copy: Array<Doc> = items.copy();
		copy[i] = d;
		return Doc.Concat(copy);
	}

}
