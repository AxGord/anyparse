package anyparse.check;

import anyparse.check.MemberSlots.OrderedMember;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * One container's first layout finding: the member the check flags plus the
 * violation message describing what is wrong (member order vs group spacing).
 */
typedef LayoutIssue = {
	var member: OrderedMember;
	var message: String;
}

/**
 * The spacing context of one container: the opt-in `separateInlineSubgroup` option, and `writer`, the writer's
 * member-gap policy under the file's format config (`GrammarPlugin.memberGapPolicy`) - null when the grammar's writer
 * forces no member gaps, or does not run that policy on this container's kind (`forContainer`).
 */
typedef SpacingPolicy = {
	final separateInline: Bool;
	final writer: Null<MemberGapPolicy>;
}

/** Why a member gap wants the blank lines it wants - the rule `wantedBlanks` answered from, which picks the finding's message. */
private enum abstract GapRule(Int) {

	/** Two different rank groups: one blank line. */
	final RankBoundary = 0;

	/** Two fields of one rank group: none. */
	final TightGroup = 1;

	/** A rank's `inline` subgroup and the rest of it, under `separateInlineSubgroup`: one blank line. */
	final InlineBoundary = 2;

	/** The writer's doc-comment rule: a doc-commented member is set off as the format config says. */
	final DocComment = 3;

	/** The writer's multi-line rule: a member written over several lines is set off by `aroundMultilineFields` blank lines. */
	final Multiline = 4;

}

/**
 * The blank lines one member gap wants and the rule that decided it (`MemberSpacing.wantedBlanks`). `atLeast` marks a
 * MINIMUM - the writer's own answer, which fills an empty gap with `count` blank lines and keeps a fuller one as the
 * source has it - where the check's own rules ask for exactly `count`.
 */
private typedef GapWant = {
	final count: Int;
	final atLeast: Bool;
	final rule: GapRule;
}

/**
 * The two optional blank-line edits `directiveGapEdits` computes for one cross-condition
 * member gap: `ifEdit` the blank before the gap's `#if`, `endEdit` the blank after its
 * `#end`; each null when that blank already exists or the gap has no such directive.
 */
private typedef DirectiveGap = {
	var ifEdit: Null<{ span: Span, text: String }>;
	var endEdit: Null<{ span: Span, text: String }>;
}

/**
 * The BLANK-LINE half of `member-order`: what has to sit in the gap BETWEEN two collected
 * member slots. Two independent gap rules live here — the member gap (`wantedBlanks`: what the
 * writer forces there under the file's format config - a doc-commented member set off, a member
 * written over several lines set off - and otherwise one blank line between rank groups and
 * none inside one field group, optionally one between a rank's `inline` subgroup and the rest of
 * it, `separateInlineSubgroup`), and one blank line around a member-level `#if` / `#end` — plus
 * the gate that switches both off for a container whose gaps hold code the rule cannot model.
 *
 * Each rule answers twice, in the same shape the check needs: as the first `LayoutIssue` for
 * the REPORT path, and as the edits for the spacing-only FIX arm. Split out of `MemberOrder`,
 * which keeps the ORDER of the slots; the two are independent — a container whose order is
 * frozen still gets its spacing normalised.
 */
@:nullSafety(Strict)
final class MemberSpacing {

	/**
	 * The inter-slot separator carrying exactly one blank line - what both fix arms
	 * (the reorder rebuild and the spacing-only fallback) place between rank groups.
	 */
	public static final GROUP_SEPARATOR: String = '\n\n';

	/**
	 * `file`'s spacing context, the same for the report and the fix: its `separateInlineSubgroup` option
	 * (`separateInline`, read off the file's `apqlint.json` by the caller) and the writer's member-gap policy under the
	 * file's own `hxformat.json` (discovered from its path, as `fmt` does), so the blank lines the rule demands are the
	 * ones the writer keeps.
	 */
	public static function policyOf(file: String, plugin: GrammarPlugin, separateInline: Bool): SpacingPolicy {
		return { separateInline: separateInline, writer: plugin.memberGapPolicy(FormatConfigDiscovery.discover(file)) };
	}

	/** `spacing` for one container of kind `containerKind`: the writer policy is kept only when the writer runs it on that kind. */
	public static function forContainer(spacing: SpacingPolicy, containerKind: String): SpacingPolicy {
		final writer: Null<MemberGapPolicy> = spacing.writer;
		return writer == null || writer.containerKinds.contains(containerKind)
			? spacing
			: { separateInline: spacing.separateInline, writer: null };
	}

	/**
	 * The spacing-only degradation for a container whose member order cannot be rewritten safely
	 * (`reorderRefusal` named a gate): normalise every violating inter-slot gap over the
	 * ORIGINAL member sequence to the blank lines `wantedBlanks` asks for and, via `emitDirectiveSpacing`,
	 * set every member-level `#if`/`#end` block off with a blank line before and
	 * after, leaving the order itself untouched (the order finding stays report-only).
	 * Shares `spacingViolation` with `firstSpacingIssue` and `directiveGapEdits` with
	 * `firstDirectiveSpacingIssue`, so the fix emits nothing exactly where the check
	 * finds no issue and a re-run converges.
	 */
	public static function emitSpacingOnly(
		edits: Array<{ span: Span, text: String }>, members: Array<OrderedMember>, source: String, spacing: SpacingPolicy
	): Void {
		if (spacingDisabled(members, source)) return;
		for (i in 0...members.length - 1) {
			final a: OrderedMember = members[i];
			final b: OrderedMember = members[i + 1];
			final want: Null<GapWant> = spacingViolation(a, b, source, spacing);
			if (want == null) continue;
			final gap: String = source.substring(a.span.to, b.span.from);
			final indent: String = gap.substring(gap.lastIndexOf('\n') + 1);
			edits.push({ span: new Span(a.span.to, b.span.from), text: separatorOf(want.count) + indent });
		}
		emitDirectiveSpacing(edits, members, source);
	}

	/**
	 * The first member separated from its predecessor by the wrong number of blank
	 * lines, or null. The per-pair policy lives in `wantedBlanks` (read through `spacingViolation`, shared with
	 * the fixer's spacing-only fallback and the rebuild's `separatorBetween`). Disabled outright (`spacingDisabled`)
	 * for a non-conditional container with a non-whitespace inter-slot gap (a stray `;`, a trailing
	 * comment): the fixer falls back to order-only slot swaps there, so a spacing
	 * finding could never converge. Skips pairs sharing a line, crossing an `#if`
	 * boundary, or whose gap holds directive / stray text.
	 */
	public static function firstSpacingIssue(members: Array<OrderedMember>, source: String, spacing: SpacingPolicy): Null<LayoutIssue> {
		if (spacingDisabled(members, source)) return null;
		for (i in 0...members.length - 1) {
			final want: Null<GapWant> = spacingViolation(members[i], members[i + 1], source, spacing);
			if (want != null) return { member: members[i + 1], message: messageOf(want) };
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
	 * The separator between two consecutive reordered members: the blank lines `wantedBlanks` asks for between
	 * them - the predicate `spacingViolation` reads, so the rebuild lands exactly what the check demands - and,
	 * where it leaves the pair to the source (a same-rank method pair, a comment-led slot), a blank line before a
	 * method or a comment-led slot and a single newline otherwise. Note
	 * this drives the raw joins INSIDE a rebuilt `#if` region, where the writer preserves them
	 * verbatim; outside `#if`, the writer re-inserts blank-after-doc during canonicalization.
	 */
	public static function separatorBetween(prev: OrderedMember, next: OrderedMember, source: String, spacing: SpacingPolicy): String {
		final want: Null<GapWant> = wantedBlanks(prev, next, source, spacing);
		return if (want != null)
			separatorOf(want.count)
		else if (!next.isField || slotStartsWithComment(next, source))
			GROUP_SEPARATOR
		else
			'\n';
	}

	/**
	 * Whether any inter-member gap in the region holds non-whitespace (a stray `;`, a trailing
	 * comment) a rebuild would silently drop - the guard that falls the reorder back to per-slot swaps.
	 */
	public static function hasNonWhitespaceGap(members: Array<OrderedMember>, source: String): Bool {
		for (i in 0...members.length - 1) if (source.substring(members[i].span.to, members[i + 1].span.from).trim() != '') return true;
		return false;
	}

	/** Join `sorted` member slots for the reordered region, each pair separated by `separatorBetween`. */
	public static function joinMembers(sorted: Array<OrderedMember>, source: String, spacing: SpacingPolicy): String {
		final parts: Array<String> = [source.substring(sorted[0].span.from, sorted[0].span.to)];
		for (i in 1...sorted.length)
			parts.push(
				separatorBetween(sorted[i - 1], sorted[i], source, spacing) + source.substring(sorted[i].span.from, sorted[i].span.to)
			);
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
	public static function firstDirectiveSpacingIssue(members: Array<OrderedMember>, source: String): Null<LayoutIssue> {
		if (MemberSlots.hasUnmodelledElse(members, source)) return null;
		for (i in 0...members.length - 1) {
			final gap: DirectiveGap = directiveGapEdits(members[i], members[i + 1], source);
			if (gap.ifEdit != null) return { member: members[i + 1], message: 'a member-level #if is not preceded by a blank line' };
			if (gap.endEdit != null) return { member: members[i + 1], message: 'a member-level #end is not followed by a blank line' };
		}
		return null;
	}

	/**
	 * Whether the same-rank FIELD pair `a` / `b` straddles the boundary between the rank's
	 * `inline` subgroup and the rest of it - the one gap the opt-in `separateInlineSubgroup`
	 * option (`separateInline`) wants exactly one blank line in, where a tight field group
	 * otherwise wants none. Only an UNCONDITIONAL pair qualifies: the inline-leads sub-order is
	 * a key of plain members alone (`MemberOrder.subRank`), so inside an `#if` block inline and
	 * non-inline members interleave freely and a boundary there would be noise. The caller has
	 * already established the shared rank and that `b` is a field; `a` shares that rank, so it
	 * is a field too. Spacing only: no ORDER question reads it, so the rank and the sort stay
	 * the config-independent answer the report and the fix share.
	 */
	private static inline function inlineSubgroupBoundary(a: OrderedMember, b: OrderedMember, separateInline: Bool): Bool {
		return separateInline && a.condition == null && b.condition == null && a.isInline != b.isInline;
	}

	/**
	 * The blank lines the gap between the adjacent slots `a` and `b` wants, or null when the pair is left to the
	 * source - THE per-pair spacing policy, read by the report, the spacing-only fix and the rebuild alike.
	 *
	 * The writer decides first wherever it forces the gap (`spacing.writer`, unconditional pairs only: the members of
	 * an `#if` body are written with their source gaps): its doc-comment rule sets a doc-commented member off as the
	 * format config says (`docBlanks`), so a comment-led slot the writer blank-separates is REQUIRED to be, not
	 * exempt. Otherwise the check's own rule (`ownWant`) answers. Where that rule wants a tight gap, the writer's
	 * multi-line rule is asked as well: a member it renders over several lines is set off by `aroundMultilineFields`
	 * blank lines (`multilineBlanks`), measured on the member's Doc (`multiline`) only when the answer depends on it -
	 * and a slot the measure cannot read leaves the pair to the source rather than guessing. A writer answer is a minimum
	 * (`GapWant.atLeast`): the writer keeps a fuller gap as the source has it, so only an empty one is reported. The multi-line rule is
	 * not asked where the check's own rule already wants a blank or has no opinion: it only ever adds blanks there.
	 */
	private static function wantedBlanks(a: OrderedMember, b: OrderedMember, source: String, spacing: SpacingPolicy): Null<GapWant> {
		final writer: Null<MemberGapPolicy> = a.condition == null && b.condition == null ? spacing.writer : null;
		final own: Null<GapWant> = ownWant(a, b, source, spacing.separateInline);
		if (writer == null) return own;
		final forced: Null<Int> = writer.docBlanks(a.leadComments, b.leadComments);
		final base: Null<GapWant> = if (forced == null)
			own
		else if (forced == 0)
			own != null && own.count == 0 ? own : { count: 0, atLeast: false, rule: DocComment }
		else if (own != null && own.count >= forced)
			own
		else
			{ count: forced, atLeast: true, rule: DocComment };
		if (base == null || base.count != 0) return base;
		final lifted: Null<Int> = writer.multilineBlanks(a.leadComments, b.leadComments);
		if (lifted == null || lifted == 0) return base;
		final multiA: Null<Bool> = writer.multiline(source.substring(a.span.from, a.span.to));
		if (multiA == true) return { count: lifted, atLeast: true, rule: Multiline };
		final multiB: Null<Bool> = writer.multiline(source.substring(b.span.from, b.span.to));
		return if (multiB == true)
			{ count: lifted, atLeast: true, rule: Multiline }
		else if (multiA == null || multiB == null)
			null
		else
			base;
	}

	/**
	 * The check's own spacing rule for the adjacent slots `a` and `b`, or null when it has no opinion: different-rank
	 * neighbours want exactly one blank line; same-rank FIELD neighbours want none (a tight group) - save, under the
	 * opt-in `separateInlineSubgroup` option (`separateInline`), exactly one at the boundary between the rank's `inline`
	 * subgroup and the rest of it (`inlineSubgroupBoundary`). A same-rank pair of methods (conventionally
	 * blank-separated) and a same-rank pair either of whose slots leads with a comment are left alone.
	 */
	private static function ownWant(a: OrderedMember, b: OrderedMember, source: String, separateInline: Bool): Null<GapWant> {
		return if (a.rank != b.rank)
			{ count: 1, atLeast: false, rule: RankBoundary }
		else if (!b.isField || slotStartsWithComment(a, source) || slotStartsWithComment(b, source))
			null
		else if (inlineSubgroupBoundary(a, b, separateInline))
			{ count: 1, atLeast: false, rule: InlineBoundary }
		else
			{ count: 0, atLeast: false, rule: TightGroup };
	}

	/** The finding message for a gap that does not hold the blank lines `want` asks for. */
	private static function messageOf(want: GapWant): String {
		final blanks: String = want.count == 1 ? 'one blank line' : '${want.count} blank lines';
		return switch want.rule {
			case RankBoundary: 'rank groups are not separated by a blank line';
			case TightGroup: 'members of one rank group are separated by a blank line';
			case InlineBoundary: 'the inline members of a rank group are not separated from the rest of it by a blank line';
			case DocComment if (want.count == 0): 'a doc-commented member is separated by a blank line the formatter removes';
			case DocComment: 'a doc-commented member is not separated from its neighbour by $blanks, as the formatter writes it';
			case Multiline: 'a member written over several lines is not separated from its neighbour by $blanks, as the formatter writes it';
		};
	}

	/** The inter-slot text holding exactly `blanks` blank lines (before the next slot's indentation). */
	private static function separatorOf(blanks: Int): String {
		return blanks == 1 ? GROUP_SEPARATOR : [for (_ in 0...blanks + 1) '\n'].join('');
	}

	/**
	 * What the adjacent slots `a` and `b` want when the pair currently violates it, or null when the pair is exempt
	 * (different `#if` condition, same line, directive / stray text in the gap, `wantedBlanks` leaves it to the source)
	 * or already correct. Shared by the check (`firstSpacingIssue`) and the fixer's spacing-only fallback
	 * (`emitSpacingOnly`) so the two cannot drift.
	 */
	private static function spacingViolation(a: OrderedMember, b: OrderedMember, source: String, spacing: SpacingPolicy): Null<GapWant> {
		if (a.condition != b.condition) return null;
		final gap: String = source.substring(a.span.to, b.span.from);
		if (gap.indexOf('\n') < 0 || gap.trim() != '') return null;
		final want: Null<GapWant> = wantedBlanks(a, b, source, spacing);
		final blanks: Int = blankLineCount(gap);
		return want != null && (want.atLeast ? blanks < want.count : blanks != want.count) ? want : null;
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

	/**
	 * Whether `m`'s slot text begins (after trimming) with a comment - a
	 * doc/line comment the spacing rule never strips or demands a blank against.
	 */
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
	private static function emitDirectiveSpacing(
		edits: Array<{ span: Span, text: String }>, members: Array<OrderedMember>, source: String
	): Void {
		if (MemberSlots.hasUnmodelledElse(members, source)) return;
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
