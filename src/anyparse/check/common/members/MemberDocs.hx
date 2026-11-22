package anyparse.check.common.members;

import anyparse.check.common.members.MemberSlots.OrderedMember;
import anyparse.check.common.members.MemberSpacing.LayoutIssue;

/**
 * The one answer to "which members of a container form the documented subgroup": the unconditional fields headed by a
 * doc-block comment that describes them alone. A doc that also NAMES the next same-kind field (a word of that field's
 * name, case-insensitive, that is not a word of the documented field's own name) describes a pair, so the member is
 * marked `docShared` instead and stays in its run - moving it apart from that neighbour would orphan half of what the doc
 * says. The answer reads source text only, never an option, so the report and the fix derive it identically.
 */
@:nullSafety(Strict)
final class MemberDocs {

	/** The shortest name word that counts as a mention; shorter ones (`id`, `x`) collide with ordinary prose. */
	private static inline final MIN_WORD: Int = 3;

	/**
	 * Set `documented` and `docShared` on every member of `members` (the container's collected members, source order).
	 * Walks from the end so a neighbour's verdict is known before the member above it asks whether it stays alongside.
	 */
	public static function mark(members: Array<OrderedMember>): Void {
		var i: Int = members.length - 1;
		while (i >= 0) {
			final m: OrderedMember = members[i];
			if (plainField(m) && hasDocBlock(m)) {
				final next: Null<OrderedMember> = i + 1 < members.length ? members[i + 1] : null;
				final shared: Bool = next != null && sameKind(m, next) && !next.documented && namesSibling(m, next);
				m.docShared = shared;
				m.documented = !shared;
			}
			i--;
		}
	}

	/**
	 * The first member whose doc names its next same-kind field, with an undocumented field of the same kind above it that
	 * it would otherwise have moved ahead of - or null. It is `reportOnly`: the cure is a human one (a line-comment heading,
	 * or one doc per field), so the fix never edits for it. Read under `separateDocumentedSubgroup` only.
	 */
	public static function firstSharedIssue(members: Array<OrderedMember>): Null<LayoutIssue> {
		for (m in members) if (m.docShared && members.exists(e -> e.index < m.index && sameKind(m, e) && !e.documented && !e.docShared)) {
			final next: OrderedMember = members[m.index + 1];
			final message: String = 'the doc comment of \'${m.node.name}\' also names the next field \'${next.node.name}'
				+ '\', so it stays in its run instead of joining the documented subgroup: turn it into a // heading, or '
				+ 'give each field its own doc';
			return { member: m, message: message, reportOnly: true };
		}
		return null;
	}

	/** Whether `m` is an unconditional field outside an enum abstract's value list - the members the subgroup is about. */
	private static function plainField(m: OrderedMember): Bool {
		return m.isField && m.condition == null && m.rank != EnumValue;
	}

	/** Whether `next` is a plain field of the same rank and `inline`-ness as `m` - the same run. */
	private static function sameKind(m: OrderedMember, next: OrderedMember): Bool {
		return plainField(next) && next.rank == m.rank && next.isInline == m.isInline;
	}

	/** Whether one of the comments the slot opens with is a doc block: it opens with two stars and is not the empty block comment. */
	private static function hasDocBlock(m: OrderedMember): Bool {
		return m.leadComments.exists((c: String) -> c.startsWith('/**') && !c.startsWith('/**/'));
	}

	/** Whether the doc of `m` mentions a word of `sibling`'s name that `m`'s own name does not carry. */
	private static function namesSibling(m: OrderedMember, sibling: OrderedMember): Bool {
		final own: Array<String> = words(m.node.name ?? '');
		final docWords: Array<String> = [ for (c in m.leadComments) for (w in words(c)) w ];
		return words(sibling.node.name ?? '').exists((w: String) -> w.length >= MIN_WORD && !own.contains(w) && docWords.contains(w));
	}

	/** The lower-cased words of `text`: runs of letters and digits, split at every other character and at a lower-to-upper case change. */
	private static function words(text: String): Array<String> {
		final out: Array<String> = [];
		var word: String = '';
		var afterLower: Bool = false;
		for (i in 0...text.length) {
			final code: Int = text.fastCodeAt(i);
			final upper: Bool = code >= 'A'.code && code <= 'Z'.code;
			final lower: Bool = (code >= 'a'.code && code <= 'z'.code) || (code >= '0'.code && code <= '9'.code);
			if (!upper && !lower) {
				if (word != '') out.push(word.toLowerCase());
				word = '';
				afterLower = false;
				continue;
			}
			if (upper && afterLower && word != '') {
				out.push(word.toLowerCase());
				word = '';
			}
			word += String.fromCharCode(code);
			afterLower = lower;
		}
		if (word != '') out.push(word.toLowerCase());
		return out;
	}

}
