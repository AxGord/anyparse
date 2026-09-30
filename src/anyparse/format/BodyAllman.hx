package anyparse.format;

import anyparse.core.BreakToken;
import anyparse.core.Doc;

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
 * `tailBreak` is the recogniser, for a construct laid out BEFORE that body decides (`WrapList.emit`, which offers the
 * list both ways through a `Doc.BreakCommit`). The rewrite and the recogniser share one shape, which is why they live
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
	 * `d` with the body `gluedLayout` rewrote in its tail resolved to the break side, laid out as the real
	 * `BodyFit.breakLayout` the next rewrite reads from its own source, or `null` when the tail carries no such body.
	 * The walk follows only the last non-`Empty` element of each `Concat`: the body sits at the tail of its construct,
	 * and anything earlier belongs to the head.
	 */
	public static function tailBreak(d: Doc): Null<{ brk: Doc, token: BreakToken }> {
		return switch d {
			case Doc.IfFirstLineExceeds(_, Doc.LeadingBreak(cols, brk, token), _),
				Doc.GroupWithRestProbe(Doc.IfBreak(Doc.LeadingBreak(cols, brk, token), _)) if (token != null):
				{ brk: BodyFit.breakLayout(cols, brk), token: token };
			case Doc.WrapBoundary(inner):
				final t: Null<{ brk: Doc, token: BreakToken }> = tailBreak(inner);
				t == null ? null : { brk: Doc.WrapBoundary(t.brk), token: t.token };
			case Doc.Concat(items):
				final i: Int = BodyFit.lastNonEmptyIdx(items);
				final t: Null<{ brk: Doc, token: BreakToken }> = i < 0 ? null : tailBreak(items[i]);
				t == null ? null : { brk: replacedAt(items, i, t.brk), token: t.token };
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
				Doc.IfFirstLineExceeds(n, Doc.LeadingBreak(cols, brk, new BreakToken()), flat);
			case Doc.GroupWithRestProbe(Doc.IfBreak(brk, flat)):
				Doc.GroupWithRestProbe(Doc.IfBreak(Doc.LeadingBreak(cols, brk, new BreakToken()), flat));
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
