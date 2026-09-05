package anyparse.check;

import anyparse.check.MemberOrder.DirectiveGap;
import anyparse.check.MemberOrder.LayoutIssue;
import anyparse.check.MemberOrder.OrderedMember;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The BLANK-LINE half of `member-order`: what has to sit in the gap BETWEEN two collected
 * member slots. Two independent gap rules live here — one blank line between rank groups and
 * none inside one field group, and one blank line around a member-level `#if` / `#end` — plus
 * the gate that switches both off for a container whose gaps hold code the rule cannot model.
 *
 * Each rule answers twice, in the same shape the check needs: as the first `LayoutIssue` for
 * the REPORT path, and as the edits for the spacing-only FIX arm. Split out of `MemberOrder`,
 * which keeps the ORDER of the slots; the two are independent — a container whose order is
 * frozen still gets its spacing normalised.
 */
@:nullSafety(Strict)
final class MemberSpacing {

	/** The inter-slot separator carrying exactly one blank line - what both fix arms (the reorder rebuild and the spacing-only fallback) place between rank groups. */
	public static final GROUP_SEPARATOR: String = '\n\n';

	/**
	 * The spacing-only degradation for a container whose member order cannot be rewritten safely
	 * (`reorderRefusal` named a gate): normalise every violating inter-slot gap over the
	 * ORIGINAL member sequence - one blank line between
	 * rank groups, none inside a tight field group - and, via `emitDirectiveSpacing`,
	 * set every member-level `#if`/`#end` block off with a blank line before and
	 * after, leaving the order itself untouched (the order finding stays report-only).
	 * Shares `spacingViolation` with `firstSpacingIssue` and `directiveGapEdits` with
	 * `firstDirectiveSpacingIssue`, so the fix emits nothing exactly where the check
	 * finds no issue and a re-run converges.
	 */
	public static function emitSpacingOnly(
		edits: Array<{ span: Span, text: String }>, members: Array<OrderedMember>, source: String
	): Void {
		if (spacingDisabled(members, source)) return;
		for (i in 0...members.length - 1) {
			final a: OrderedMember = members[i];
			final b: OrderedMember = members[i + 1];
			final want: Null<Int> = spacingViolation(a, b, source);
			if (want == null) continue;
			final gap: String = source.substring(a.span.to, b.span.from);
			final indent: String = gap.substring(gap.lastIndexOf('\n') + 1);
			edits.push({ span: new Span(a.span.to, b.span.from), text: (want == 1 ? GROUP_SEPARATOR : '\n') + indent });
		}
		emitDirectiveSpacing(edits, members, source);
	}

	/**
	 * The first member separated from its predecessor by the wrong number of blank
	 * lines, or null. The per-pair policy lives in `spacingViolation` (shared with
	 * the fixer's spacing-only fallback): different-rank neighbours want exactly one
	 * blank line; same-rank FIELD neighbours want none (a tight group), unless either
	 * slot leads with a comment - the writer itself keeps a blank line after a
	 * doc-commented member, and a blank before a doc comment is never stripped or
	 * demanded. Same-rank methods are left alone - they are conventionally
	 * blank-separated. Disabled outright (`spacingDisabled`) for a non-conditional
	 * container with a non-whitespace inter-slot gap (a stray `;`, a trailing
	 * comment): the fixer falls back to order-only slot swaps there, so a spacing
	 * finding could never converge. Skips pairs sharing a line, crossing an `#if`
	 * boundary, or whose gap holds directive / stray text.
	 */
	public static function firstSpacingIssue(members: Array<OrderedMember>, source: String): Null<LayoutIssue> {
		if (spacingDisabled(members, source)) return null;
		for (i in 0...members.length - 1) {
			final want: Null<Int> = spacingViolation(members[i], members[i + 1], source);
			if (want != null) return {
				member: members[i + 1],
				message: want == 1
					? 'rank groups are not separated by a blank line'
					: 'members of one rank group are separated by a blank line'
			};
		}
		return null;
	}

	/** The number of whitespace-only lines wholly inside `gap` (the inter-slot text) - a tab-only line counts. */
	public static function blankLineCount(gap: String): Int {
		final lines: Array<String> = gap.split('\n');
		var count: Int = 0;
		for (i in 1...lines.length - 1) if (StringTools.trim(lines[i]) == '') count++;
		return count;
	}

	/**
	 * The separator between two consecutive reordered members: a blank line between rank
	 * groups, before a method, or before a comment-led slot (a member whose leading doc the
	 * writer keeps blank-separated); a single newline between two same-rank plain fields. Note
	 * this drives the raw joins INSIDE a rebuilt `#if` region, where the writer preserves them
	 * verbatim; outside `#if`, the writer re-inserts blank-after-doc during canonicalization.
	 */
	public static function separatorBetween(prev: OrderedMember, next: OrderedMember, source: String): String {
		return prev.rank != next.rank || !next.isField || slotStartsWithComment(next, source) ? GROUP_SEPARATOR : '\n';
	}

	/** Whether any inter-member gap in the region holds non-whitespace (a stray `;`, a trailing comment) a rebuild would silently drop - the guard that falls the reorder back to per-slot swaps. */
	public static function hasNonWhitespaceGap(members: Array<OrderedMember>, source: String): Bool {
		for (i in 0...members.length - 1) if (source.substring(members[i].span.to, members[i + 1].span.from).trim() != '') return true;
		return false;
	}

	/** Join `sorted` member slots for the reordered region, blank-separating rank groups and members that lead with a comment. */
	public static function joinMembers(sorted: Array<OrderedMember>, source: String): String {
		final parts: Array<String> = [source.substring(sorted[0].span.from, sorted[0].span.to)];
		for (i in 1...sorted.length)
			parts.push(separatorBetween(sorted[i - 1], sorted[i], source) + source.substring(sorted[i].span.from, sorted[i].span.to));
		return parts.join('');
	}

	/** Whether any member is `#if`-guarded - such a container rebuilds through `buildConditionalRegion`, never the slot-swap path. */
	public static function hasConditionalMember(members: Array<OrderedMember>): Bool {
		return members.exists(m -> m.condition != null);
	}

	/**
	 * The first member preceded (across an `#if`) by a missing blank line: a member-level
	 * `#if` must have a blank line before it and its `#end` a blank line after, so a
	 * conditional block stands apart from its neighbours. Reads `directiveGapEdits` (shared
	 * with the spacing-only fix so the two agree on which blanks are missing); the container's
	 * leading `#if` / trailing `#end` (no member pair spans them) are exempt, as is an `#else`
	 * gap (same condition on both sides).
	 */
	@:access(anyparse.check.MemberOrder)
	public static function firstDirectiveSpacingIssue(members: Array<OrderedMember>, source: String): Null<LayoutIssue> {
		if (MemberOrder.hasUnmodelledElse(members, source)) return null;
		for (i in 0...members.length - 1) {
			final gap: DirectiveGap = directiveGapEdits(members[i], members[i + 1], source);
			if (gap.ifEdit != null) return { member: members[i + 1], message: 'a member-level #if is not preceded by a blank line' };
			if (gap.endEdit != null) return { member: members[i + 1], message: 'a member-level #end is not followed by a blank line' };
		}
		return null;
	}

	/**
	 * The blank-line count the spacing rule demands between the adjacent slots `a`
	 * and `b` when the pair currently violates it, or null when the pair is exempt
	 * (different `#if` condition, same-line, directive / stray text in the gap,
	 * same-rank non-field or comment-led pair) or already correct. The single source
	 * of the per-pair spacing policy - shared by the check (`firstSpacingIssue`) and
	 * the fixer's spacing-only fallback (`emitSpacingOnly`) so the two cannot drift.
	 */
	private static function spacingViolation(a: OrderedMember, b: OrderedMember, source: String): Null<Int> {
		if (a.condition != b.condition) return null;
		final gap: String = source.substring(a.span.to, b.span.from);
		if (gap.indexOf('\n') < 0 || gap.trim() != '') return null;
		final blanks: Int = blankLineCount(gap);
		return if (a.rank != b.rank)
			blanks != 1 ? 1 : null
		else if (b.isField && blanks != 0 && !slotStartsWithComment(a, source) && !slotStartsWithComment(b, source))
			0
		else
			null;
	}

	/**
	 * Whether the spacing rule is disabled for this container outright: a
	 * non-conditional container with non-whitespace in an inter-slot gap (a stray
	 * `;`, a trailing comment) - the order fixer falls back to slot swaps there, so
	 * a spacing finding could never converge.
	 */
	private static function spacingDisabled(members: Array<OrderedMember>, source: String): Bool {
		return !hasConditionalMember(members) && hasNonWhitespaceGap(members, source);
	}

	/** Whether `m`'s slot text begins (after trimming) with a comment - a doc/line comment the spacing rule never strips or demands a blank against. */
	private static function slotStartsWithComment(m: OrderedMember, source: String): Bool {
		final t: String = source.substring(m.span.from, m.span.to).trim();
		return t.startsWith('/*') || t.startsWith('//');
	}

	/**
	 * The directive-spacing arm of the spacing-only fallback: set every member-level `#if` off
	 * with a blank line before it and its `#end` with a blank line after it - the blanks
	 * `directiveGapEdits` reports - so a reorder-unsafe container whose guarded block cannot
	 * move still gets that block visually separated from its neighbours (the CheckBox shape).
	 * Exempts a container with an unmodelled `#else`, as the check does.
	 */
	@:access(anyparse.check.MemberOrder)
	private static function emitDirectiveSpacing(
		edits: Array<{ span: Span, text: String }>, members: Array<OrderedMember>, source: String
	): Void {
		if (MemberOrder.hasUnmodelledElse(members, source)) return;
		for (i in 0...members.length - 1) {
			final gap: DirectiveGap = directiveGapEdits(members[i], members[i + 1], source);
			final ifEdit: Null<{ span: Span, text: String }> = gap.ifEdit;
			if (ifEdit != null) edits.push(ifEdit);
			final endEdit: Null<{ span: Span, text: String }> = gap.endEdit;
			if (endEdit != null) edits.push(endEdit);
		}
	}

	/**
	 * The blank-line edits the directive-spacing rule wants for the cross-condition gap between
	 * two consecutive members `a` and `b`: `ifEdit` inserts a blank line before the gap's first
	 * `#if`, `endEdit` a blank line after its last `#end`; each null when that blank already
	 * exists, the gap holds no such directive, or the pair shares a condition. The single source
	 * of the directive-spacing policy - the check (`firstDirectiveSpacingIssue`, its message from
	 * which edit is present) and the spacing-only fix (`emitDirectiveSpacing`, both applied) read
	 * it, so the two cannot drift.
	 */
	private static function directiveGapEdits(a: OrderedMember, b: OrderedMember, source: String): DirectiveGap {
		if (a.condition == b.condition) return { ifEdit: null, endEdit: null };
		final gapFrom: Int = a.span.to;
		final gapTo: Int = b.span.from;
		var firstIfStart: Int = -1;
		var lastEndTo: Int = -1;
		var cursor: Int = gapFrom;
		for (seg in source.substring(gapFrom, gapTo).split('\n')) {
			final t: String = StringTools.trim(seg);
			if (firstIfStart < 0 && t.startsWith('#if')) firstIfStart = cursor;
			if (t == '#end') lastEndTo = cursor + seg.length;
			cursor += seg.length + 1;
		}
		final ifEdit: Null<{ span: Span, text: String }> =
			firstIfStart >= 0 && blankLineCount(source.substring(gapFrom, firstIfStart)) < 1 ? {
				span: new Span(gapFrom, firstIfStart),
				text: GROUP_SEPARATOR
			} : null;
		final endEdit: Null<{ span: Span, text: String }> = if (lastEndTo >= 0 && blankLineCount(source.substring(lastEndTo, gapTo)) < 1) {
			final tail: String = source.substring(lastEndTo, gapTo);
			{ span: new Span(lastEndTo, gapTo), text: GROUP_SEPARATOR + tail.substring(tail.lastIndexOf('\n') + 1) };
		} else
			null;
		return { ifEdit: ifEdit, endEdit: endEdit };
	}

}
