package anyparse.check;

using StringTools;

/**
 * The two masking primitives a `Check.VolatileMessage` builds its message IDENTITY from:
 * blank out the source COORDINATE that sits immediately after — or immediately before —
 * a literal fragment of the message the check itself wrote.
 *
 * A coordinate here is one run of decimal digits. AFTER an anchor it continues through `:`
 * into further digit groups, so a `line:col` pair (`43:12`) masks as one unit rather than as
 * two numbers with a stray colon between them; BEFORE one it does not, because there the run
 * is always a single number and walking back over a `:` would reach into whatever precedes it
 * (see `coordinateStart`).
 *
 * ## What an anchor may not be
 *
 * It must not end in a digit or `:`, and must not contain `#`. Either breaks idempotence,
 * which `Check.VolatileMessage` requires: a mask can create a new anchor occurrence, or free a
 * walk-back an earlier pass had blocked. Every anchor in use ends in a space, a letter or `)`.
 *
 * ## Why an anchored mask and not a blanket one
 *
 * The blanket answer — mask every digit run in the message — is what `lint-diff` did for
 * two rules, and its cost is measured: it also ate `duplicate-code`'s statement COUNT and
 * any digit in the partner FILENAME, merging 57% (anyparse) and 78% (tm) of that rule's
 * findings into shared keys, where a real substitution is invisible. An anchor is the
 * narrowest thing that still says WHICH number drifts, and the check passes the same
 * constant it built the message from, so the anchor cannot fall out of step with the
 * wording it points at.
 *
 * ## The failure direction
 *
 * A missing anchor is a no-op: the text comes back unchanged, and the finding key keeps
 * a number that drifts. That is the safe direction for correctness (nothing is ever
 * merged that should not be) and the unsafe one for noise — so every implementor pins its
 * `messageIdentity` against a message its OWN `run` produced, not against a hand-written
 * one, and a wording change that orphans an anchor turns that test red.
 *
 * Written as a scan rather than an `EReg`: a shared `EReg` would be exactly the
 * module-level mutable state this project refuses, and building one per message would pay
 * for a regex object on every finding in the report. Non-coordinate stretches are copied
 * with `addSub` rather than re-encoded one code unit at a time — a `charCodeAt`/`addChar`
 * round trip reads ONE BYTE of a multi-byte character on a byte-string target and re-emits
 * it as a character, so an em dash in a real lint message would print as mojibake there.
 * The digit and `:` tests are byte-safe either way: every UTF-8 continuation byte is
 * >= 0x80, so it can never be mistaken for an ASCII digit or a colon.
 */
@:nullSafety(Strict)
final class MessageMask {

	/** What a masked coordinate reads as — one character, so the key stays readable in a failing assertion. */
	private static inline final MASK: String = '#';

	/**
	 * `text` with the coordinate that immediately FOLLOWS each occurrence of `anchor`
	 * replaced by `#`. An occurrence with no coordinate after it, an absent anchor and an
	 * empty anchor all leave the text alone.
	 */
	public static inline function maskAfter(text: String, anchor: String): String {
		return maskAnchored(text, anchor, false);
	}

	/**
	 * `text` with the coordinate that immediately PRECEDES each occurrence of `anchor`
	 * replaced by `#` — the form a message needs when the number comes first and its unit
	 * word follows it (`4194 lines (max 2000)`). Same no-op cases as `maskAfter`.
	 */
	public static inline function maskBefore(text: String, anchor: String): String {
		return maskAnchored(text, anchor, true);
	}

	/** Whether `code` is an ASCII decimal digit. Byte-safe: UTF-8 continuation bytes are all >= 0x80. */
	private static inline function isDigit(code: Int): Bool {
		return code >= '0'.code && code <= '9'.code;
	}

	/**
	 * The one scan behind both directions: walk every occurrence of `anchor` and blank the
	 * coordinate on the requested SIDE of it, copying everything else through.
	 *
	 * The two directions differ only in where the blanked slice `[from, to)` sits relative to
	 * the occurrence — `before` masks the run ENDING at the anchor and re-emits the anchor
	 * after the mask, while the other masks the run STARTING past it, which the copy up to
	 * `past` already precedes. That is one loop with two slice choices, not two algorithms.
	 */
	private static function maskAnchored(text: String, anchor: String, before: Bool): String {
		// An empty anchor matches at every position, so the loop below would never advance.
		if (anchor == '') return text;
		final out: StringBuf = new StringBuf();
		var pos: Int = 0;
		while (true) {
			final at: Int = text.indexOf(anchor, pos);
			if (at < 0) break;
			final past: Int = at + anchor.length;
			final from: Int = before ? coordinateStart(text, at) : past;
			final to: Int = before ? at : coordinateEnd(text, past);
			// `from == to` is "no coordinate on that side"; `from < pos` is a run reaching back
			// into text an earlier occurrence already emitted (`<= pos` would also reject the
			// ordinary case of a message OPENING with its coordinate). Both copy through.
			if (from == to || from < pos) {
				out.addSub(text, pos, past - pos);
				pos = past;
				continue;
			}
			out.addSub(text, pos, from - pos);
			out.add(MASK);
			// Both re-derive the DIRECTION, which is why they read as `before` rather than as
			// arithmetic: in the after-branch `to` is past the anchor (the copy above already
			// emitted it), in the before-branch `to` is the anchor's own start.
			if (before) out.addSub(text, to, past - to);
			pos = before ? past : to;
		}
		out.addSub(text, pos, text.length - pos);
		return out.toString();
	}

	/** Where the coordinate starting at `from` ends, or `from` itself when no digit starts there. */
	private static function coordinateEnd(text: String, from: Int): Int {
		if (from >= text.length || !isDigit(text.fastCodeAt(from))) return from;
		var i: Int = from;
		while (i < text.length && isDigit(text.fastCodeAt(i))) i++;
		while (i + 1 < text.length && text.fastCodeAt(i) == ':'.code && isDigit(text.fastCodeAt(i + 1))) {
			i++;
			while (i < text.length && isDigit(text.fastCodeAt(i))) i++;
		}
		return i;
	}

	/**
	 * Where the coordinate ending at `to` starts, or `to` itself when no digit ends there.
	 *
	 * ONE digit run, deliberately: unlike `coordinateEnd` this does NOT walk back through a
	 * `:` into a further group. The two directions want different things. A coordinate written
	 * AFTER its lead-in is a `line:col` pair (`re-declared at 43:12`) and has to mask as one
	 * unit. A coordinate written BEFORE its unit word never is — `4194 lines`, `<partner>:501`
	 * — while walking back over the `:` would reach into whatever precedes it, and for a
	 * partner path ending in a digit that is the PATH: `from src/v2:501` and `from src/v3:501`
	 * would share a key, so a clone whose origin file changed would report as no movement.
	 * Backward continuation is also what made this direction non-idempotent for an anchor
	 * ending in `:` — the second pass masked what the first had been blocked from reaching.
	 */
	private static function coordinateStart(text: String, to: Int): Int {
		if (to <= 0 || !isDigit(text.fastCodeAt(to - 1))) return to;
		var i: Int = to;
		while (i > 0 && isDigit(text.fastCodeAt(i - 1))) i--;
		return i;
	}

}
