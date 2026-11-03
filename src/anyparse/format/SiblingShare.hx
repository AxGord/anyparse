package anyparse.format;

import anyparse.core.BreakCommits;
import anyparse.core.BreakToken;
import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.DocIdentityMap;
import anyparse.core.LineSpan;
import anyparse.format.wrap.WrapList;

/**
 * The one answer to "do these sibling slots take one placement decision".
 *
 * A slot is an `IfIndentWidthExceeds` whose width is still a vote: a band of negative numbers no width can
 * reach, so a slot is told apart from a verdict by the number alone. Walkers read a negative width as "never
 * exceeds" and forward to the flat form, so an unresolved slot measures as the sibling deciding alone; the
 * enclosing list calls `decide` over its finished Doc, which collects the votes and leaves no slot behind.
 * `anyparse.macro.SiblingScope` refuses a grammar where a slot can reach the renderer outside such a list.
 */
final class SiblingShare {

	private static inline final MEASURED: Int = -0x10000001;
	private static inline final LEADS: Int = -0x10000002;
	private static inline final MEASURED_CONTROL_FLOW: Int = -0x10000003;
	private static inline final MEASURED_COMMENTED: Int = -0x10000004;
	private static inline final FORCE_BREAK: Int = 0x0FFFFFF0;

	/** A sibling already placed below its head by shape: `own` is both of its forms; `leads` says whether it spreads. */
	public static inline function placedSlot(policy: SiblingPolicy, leads: Bool, own: Doc): Doc {
		return policy == SiblingPolicy.Off ? own : Doc.IfIndentWidthExceeds(leads ? LEADS : MEASURED, 0, own, own);
	}

	/**
	 * A sibling a comment holds below its head although its one statement could stand beside it: `body` is that
	 * statement. The slot keeps the placed form in `own` and, in its break arm, the statement glued to the head as it
	 * would stand without the comment, which is the form `decide` measures, so the branch leads exactly when it would not
	 * have fit without it. A statement with no flat form keeps the plain vote, and leads when `refuseGlue` says its glued
	 * form is refused.
	 */
	public static function commentedSlot(policy: SiblingPolicy, own: Doc, body: Doc, refuseGlue: Bool): Doc {
		return policy == SiblingPolicy.Off || WrapList.flatLength(body) < 0
			? placedSlot(policy, refuseGlue, own)
			: Doc.IfIndentWidthExceeds(MEASURED_COMMENTED, 0, Doc.Concat([Doc.Text(' '), body]), own);
	}

	/**
	 * `BodyFit.fitLineLayout` with its vote; `refuseGlue` leads when the body has no flat form. `belowWrappedLabel` says the
	 * head began a `LineSpan`: `fitLine` asks whether the whole construct stands on one line, so a head that took more
	 * than one has already answered, whatever room its last row leaves. It takes no part in the vote, which measures flat.
	 */
	public static function fitLineSlot(
		policy: SiblingPolicy, cols: Int, body: Doc, nestGluedBody: Bool, lineWidth: Int, refuseGlue: Bool, belowWrappedLabel: Bool
	): Doc {
		final fit: Doc = BodyFit.fitLineLayout(cols, body, nestGluedBody, lineWidth, refuseGlue);
		final own: Doc = belowWrappedLabel ? LineSpan.ifLeft(BodyFit.breakLayout(cols, body), fit) : fit;
		if (policy == SiblingPolicy.Off) return own;
		final vote: Int = if (!refuseGlue)
			MEASURED
		else if (WrapList.flatLength(body) == -1)
			LEADS
		else
			MEASURED_CONTROL_FLOW;
		return Doc.IfIndentWidthExceeds(vote, lineWidth, BodyFit.breakLayout(cols, body), own);
	}

	/** Resolves every slot of `list` to one verdict: below its head when one sibling leads or the widest does not fit. */
	public static function decide(list: Doc, policy: SiblingPolicy, lineWidth: Int): Doc {
		if (policy == SiblingPolicy.Off) return list;
		final seen: DocIdentityMap<Bool> = new DocIdentityMap();
		final holds: DocIdentityMap<Bool> = new DocIdentityMap();
		var slots: Int = 0;
		var force: Bool = false;
		function holdsSlot(d: Doc): Bool {
			final hit: Null<Bool> = holds.get(d);
			if (hit != null) return hit;
			var found: Bool = false;
			switch d {
				case Doc.IfIndentWidthExceeds(v, _, _, _) if (isVote(v)):
					found = true;
					if (seen.get(d) == null) {
						seen.set(d, true);
						slots++;
						if (v == LEADS) force = true;
					}
				case _:
					eachChild(d, c -> if (holdsSlot(c)) found = true);
			}
			holds.set(d, found);
			return found;
		}
		if (!holdsSlot(list) || slots < 2) return resolved(list, -1, lineWidth, null);
		if (force) return resolved(list, FORCE_BREAK, lineWidth, null);
		var widest: Int = -1;
		var second: Int = -1;
		var widestDoc: Null<Doc> = null;
		function consider(unit: Doc, flat: Int): Void {
			if (flat > widest) {
				second = widest;
				widest = flat;
				widestDoc = unit;
			} else if (flat > second) {
				second = flat;
			}
		}
		function measure(d: Doc): Void {
			if (!holdsSlot(d)) return;
			switch d {
				case Doc.IfIndentWidthExceeds(v, _, _, _) if (isVote(v)):
					if (v == MEASURED_CONTROL_FLOW) force = true;
					return;
				case _:
			}
			final unit: Null<Doc> = measurable(d);
			if (unit == null)
				eachChild(d, measure)
			else
				consider(unit, WrapList.flatLength(unit));
		}
		measure(list);
		if (force) return resolved(list, FORCE_BREAK, lineWidth, null);
		final top: Null<Doc> = widestDoc;
		return resolved(list, widest, lineWidth, top != null && widest > second ? breakOffer(top, second) : null);
	}

	private static inline function isVote(width: Int): Bool {
		return width <= MEASURED;
	}

	/** `d` when it has a flat width, else `d` as its comment-held slots would stand without the comment, else `null`. */
	private static function measurable(d: Doc): Null<Doc> {
		if (WrapList.flatLength(d) >= 0) return d;
		final bare: Doc = withoutComments(d);
		return bare != d && WrapList.flatLength(bare) >= 0 ? bare : null;
	}

	/** `d` with every comment-held slot written as the room its statement takes beside the head, or `d` itself when it holds none. */
	private static function withoutComments(d: Doc): Doc {
		final memo: DocIdentityMap<Doc> = new DocIdentityMap();
		function walk(n: Doc): Doc {
			final hit: Null<Doc> = memo.get(n);
			if (hit != null) return hit;
			final out: Doc = switch n {
				case Doc.IfIndentWidthExceeds(v, _, glued, _) if (v == MEASURED_COMMENTED):
					walk(glued);
				case _:
					D.mapChildrenShared(n, walk);
			};
			memo.set(n, out);
			return out;
		}
		return walk(d);
	}

	/** Every slot of `d` holding the verdict `width`, and the verdict `offer` when `offer`'s break is committed. */
	private static function resolved(d: Doc, width: Int, lineWidth: Int, offer: Null<Offer>): Doc {
		final memo: DocIdentityMap<Doc> = new DocIdentityMap();
		function walk(n: Doc): Doc {
			final hit: Null<Doc> = memo.get(n);
			if (hit != null) return hit;
			final out: Doc = switch n {
				case Doc.IfIndentWidthExceeds(v, _, _, own) if (v == MEASURED_COMMENTED):
					offer == null ? own : walk(own);
				case Doc.IfIndentWidthExceeds(v, _, brk, own) if (isVote(v)):
					final o: Doc = offer == null ? own : walk(own);
					final b: Doc = offer == null ? brk : walk(brk);
					final plain: Doc = width < 0 ? o : Doc.IfIndentWidthExceeds(width, lineWidth, b, o);
					offer == null ? plain : Doc.BreakCommit(Doc.IfIndentWidthExceeds(offer.width, lineWidth, b, o), plain, offer.alias);
				case Doc.BreakMark(inner, token) if (offer != null && token == offer.token):
					Doc.BreakMark(Doc.BreakMark(walk(inner), token), offer.alias);
				case _:
					D.mapChildrenShared(n, walk);
			};
			memo.set(n, out);
			return out;
		}
		return walk(d);
	}

	/** What the list measures once the one named break inside its widest unit is committed, as the next rewrite reads it. */
	private static function breakOffer(widest: Doc, second: Int): Null<Offer> {
		final commits: Array<Doc> = BreakCommits.outermostPerToken(BreakCommits.nested(widest));
		if (commits.length != 1) return null;
		return switch commits[0] {
			case Doc.BreakCommit(brk, _, token) if (token != null):
				final committed: Int = WrapList.flatLength(BreakCommits.replaced(widest, commits[0], brk));
				final width: Int = if (committed >= 0)
					(committed > second ? committed : second)
				else if (controlFlowSlot(widest))
					FORCE_BREAK
				else
					second;
				width == WrapList.flatLength(widest) ? null : { width: width, token: token, alias: new BreakToken() };
			case _:
				null;
		};
	}

	private static function controlFlowSlot(d: Doc): Bool {
		var found: Bool = false;
		function walk(n: Doc): Void {
			switch n {
				case Doc.IfIndentWidthExceeds(v, _, _, _) if (isVote(v)):
					found = found || v == MEASURED_CONTROL_FLOW;
				case _:
					eachChild(n, walk);
			}
		}
		walk(d);
		return found;
	}

	private static function eachChild(d: Doc, visit: Doc -> Void): Void {
		D.mapChildrenShared(d, c -> {
			visit(c);
			c;
		});
	}

}

private typedef Offer = {
	final width: Int;
	final token: BreakToken;
	final alias: BreakToken;
}
