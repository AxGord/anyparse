package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.check.MemberOrderReason.OrderKeys;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * One type-member paired with its canonical-order rank and its full source slot (leading doc +
 * modifier/`@:meta` run + decl), for the order check and the reordering autofix. `hasMeta` says
 * the slot carries an annotation, which is what pins a member's relative position inside a type
 * whose build macro reads the field list in declaration order (`macroBuiltMetaOrderKept`).
 *
 * Slots are DISJOINT and each ends at the member's own last code byte: the parser stretches some
 * expression-body spans over the trailing trivia, and `MemberSlots.ownSourceEnd` cuts that back
 * off - an overlap would make the reorder duplicate or strand a neighbour's doc comment.
 */
typedef OrderedMember = {
	var node: QueryNode;
	var rank: MemberRank;
	var index: Int;
	var span: Span;
	var isField: Bool;
	var isStatic: Bool;
	var isInline: Bool;
	var hasMeta: Bool;
	var initNode: Null<QueryNode>;

	var condition: Null<String>;
	var branch: Null<BranchInfo>;
	var regionFrom: Int;
	var regionTo: Int;

	var leadTrivia: String;
	var leadFrom: Int;
}

/**
 * Where a member sits inside a branched `#if` / `#elseif` / `#else` / `#end` construct.
 * The grammar flattens EVERY branch into one `Conditional` node, so the branch a member
 * was declared in is recovered from the construct's directive lines (`assignBranches`)
 * and carried here - it is part of the member's identity, not layout the sort may drop.
 * `opens` is the construct's whole branch shape, shared by all its members: `opens[k - 1]`
 * is the directive text opening branch `k` (branch 0 is opened by the `#if` itself), so
 * two constructs merge into one block only when their shapes are equal. A negative
 * `index` marks a construct `assignBranches` refused to model - the reorder bails on it.
 */
typedef BranchInfo = {
	var index: Int;
	var opens: Array<String>;
}

/**
 * One container's first layout finding: the member the check flags plus the
 * violation message describing what is wrong (member order vs group spacing).
 */
typedef LayoutIssue = {
	var member: OrderedMember;
	var message: String;
}

/**
 * The two optional blank-line edits `directiveGapEdits` computes for one cross-condition
 * member gap: `ifEdit` the blank before the gap's `#if`, `endEdit` the blank after its
 * `#end`; each null when that blank already exists or the gap has no such directive.
 */
typedef DirectiveGap = {
	var ifEdit: Null<{ span: Span, text: String }>;
	var endEdit: Null<{ span: Span, text: String }>;
}

/**
 * One container's sort context, its maps keyed by `groupKey` (section, condition, branch
 * shape). `groupFirst` is the first-occurrence source index of every conditional block - it
 * orders the PINNED blocks at their section end (the pre-existing shape) and doubles as the
 * ordinal that keeps a content-ranked block contiguous.
 * `ranked` carries the same index for exactly those blocks that passed all
 * three content-ranking gates, and `rankedInline` names those of them that hold nothing but
 * `inline` fields - the blocks that LEAD the plain members of their rank instead of trailing
 * them.
 */
typedef SortPlan = {
	var groupFirst: Map<String, Int>;
	var ranked: Map<String, Int>;
	var rankedInline: Array<String>;
}

/**
 * The `member-order` check and its reordering autofix: verifies a types members follow the canonical rank order (constants, properties, fields, constructor, accessors, instance methods, static methods; public before private) with rank groups blank-line separated, and rewrites them into that order when fixing. Within one rank plain unconditional members carry a sub-order (`subRank`): `inline` members lead, then initialized fields lead init-less ones; the Accessor rank is exempt so a get/set pair keeps its source adjacency. The side-effecting-flip bail counts only flips between the side-effecting initializer and another INITIALIZED same-phase field - an init-less field runs no code in the init phase, so crossing it is unobservable. A conditional block still moves as ONE atomic unit, branches and all: `#if` / `#elseif` / `#else` / `#end` is a single group whose members sort within their own branch, so the construct is regenerated rather than flattened. Such a block sorts by its CONTENT: when every member of the block carries the same `MemberRank`, the block sorts at that rank among the plain members of its section, trailing them WITHIN the rank - crossing a rank boundary is what content ranking is for, position inside one rank is not, save for the inline-field block below - so a guarded `public var` no longer trails the private instance fields it outranks. A block that holds nothing but `inline` FIELDS is the single exception to that trailing: it LEADS the plain members of its rank (`uniformInline` / `leadsRank`), which extends the inline-leads sub-order across the conditional boundary - an `#if` of `static inline final` constants belongs with the constants at the top of the type, not below the initialized `static final` fields it shares rank 0 with. Methods and accessors are excluded there even when `inline`, so a guarded platform implementation still goes to its section end and a get/set pair keeps its adjacency; a block mixing inline and non-inline members has no sub-order of its own and keeps trailing its rank. A block is one `groupKey` bucket (section, condition, branch shape), the same granularity the pinned order already used: a construct declaring both fields and methods under one condition splits into one block per section, and each is ranked on its own. Content ranking is gated three ways, and any doubt pins the block back to its section end (`comparePinned`, the pre-existing shape): (1) all members of the block must share ONE rank, since a mixed-rank block would have to be split and atomicity beats ordering; (2) every byte of the conditional construct must be accounted for by a member slot, an absorbed lead doc, a REGENERABLE directive line, or whitespace, and the `#end` line must end there - anything else (a stray `;`, which projects as `EmptySemiMember` and is no collected member; a note on a directive line, which the regenerated directive has nowhere to put; a note after the `#end`, which the rebuild drops or re-attaches to the wrong member) would be lost or misplaced; (3) no field initializer may tie the block to its position, in EITHER direction - a field in the block whose initializer has a side effect or reads another same-phase field, or a field outside it whose initializer reads one inside. Those gates are deliberately INDEPENDENT of the `movableArglessNew` option below: `compareOrder` is shared by the REPORT path (`run` -> `walk` -> `firstLayoutIssue`) and the FIX path, and the report path resolves no per-file config, so a rank that depended on an option would make the two disagree and the fix would never converge. A gate on position-sensitive constructs in the CONDITION of the `#if` itself is a documented NO-OP for this grammar: a Haxe conditional-compilation condition is a pure compile-time define expression evaluated before parsing, with no ordered declaration and no `#define`, so nothing in it has a position that could matter - a grammar that grows one must add that gate here. A container whose field initializers make reordering unsafe - or which holds an `#else` shape the branch model refuses (nested, spanning two sections, or with an empty first branch), a conditional region holding bytes no member slot covers, an `@:meta` run written above a member-level `#if` (covered by no slot at all, so the rebuild would DROP it - `rebuiltSpanCovered`), or a construct whose COEXISTING members span two sections (`splitsCoexistingRegion`: splitting it per section lifts a field out of the region its author wrote, away from the method that uses it, and re-derives a nested condition as a conjunct at the new site) - keeps its order (the finding stays report-only) but still gets its rank-group spacing normalised, including the blank lines that set each member-level `#if`/`#end` block off from its neighbours. One residual report-only case is specific to content ranking: a moved block that flips with a same-phase side-effecting UNCONDITIONAL initializer is flagged and then bails to spacing-only. Demoting the block and re-sorting would close it, but the sole trigger is `hasSideEffectingFieldFlip` - the one gate the `movableArglessNew` option relaxes - so a retry would reintroduce exactly the report/fix option disagreement the config-independent gates exist to prevent. The finding is the same advisory shape the rule already produces for a plain unsafe container, and neither TM nor this repo holds an instance of it. A container in a type that transitively carries a BUILD MACRO is gated separately, and only on the FIX path (`macroBuiltMetaOrderKept`, which needs the run`\s `SymbolIndex`): the relative order of its ANNOTATED members is preserved, because a build macro reads the field list in declaration order and dispatches on metadata - Pony`\s `DeclaratorBuilder` turns `@:arg` fields into constructor PARAMETERS that way. The opt-in `movableArglessNew` option (apqlint.json rule options, default OFF) relaxes that unsafe bail for a pure argless-`new` initializer (`x = new T()`), which the project accepts as order-movable - reordering two independent allocations only changes their relative construction order, unobservable without cross-init data flow.
 */
@:nullSafety(Strict)
final class MemberOrder implements Check implements ConfigAware {

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`) - read for the `movableArglessNew` option in `fix`. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'member-order';
	}

	public function description(): String {
		return 'type members not in canonical order ('
			+ 'constants, properties, fields, constructor, accessors, instance methods, static methods; public before private; within one '
			+ 'rank inline members lead, then initialized declarations lead init-less ones; conditional members grouped into one #if block '
			+ 'per condition and branch shape, sorted at the rank their members share and leading it when the block holds only inline '
			+ 'fields - or pinned to the end of their '
			+ 'section when they span several ranks) or rank groups and conditional blocks not separated by blank lines';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		if (!applicable(shape)) return [];
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final accessors: Map<Int, Bool> = provider != null ? provider.propertyAccessors(entry.source) : [];
			walk(violations, entry.file, entry.source, tree, shape, accessors);
		}
		return violations;
	}

	/**
	 * Reorder each flagged container's members into canonical order and normalise the
	 * blank lines between rank groups. Re-parses `source`, emits edits only for a
	 * container whose first flagged member's slot matches a passed violation; a
	 * container whose field initializers make reordering unsafe degrades to
	 * spacing-only edits - the blank-line normalisation still lands, the order
	 * finding stays report-only (see the class doc).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		if (!applicable(shape)) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final accessors: Map<Int, Bool> = provider != null ? provider.propertyAccessors(source) : [];
		final movableArglessNew: Bool = violations.length > 0
			&& LintConfig.resolveWith(_resolveConfig, violations[0].file).boolOption('member-order', 'movableArglessNew') == true;
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		// The file this pass is rewriting, for the build-macro gate: every violation a fix pass is
		// handed belongs to ONE file, the same source the per-file config option above is read from.
		// Null when the pass carries no violation — nothing to reorder anyway — which the gate reads
		// as "no file named" and answers from the whole index, as it did before it could be told.
		final file: Null<String> = violations.length > 0 ? violations[0].file : null;
		fixWalk(edits, source, tree, shape, flagged, accessors, movableArglessNew, index, file);
		return edits;
	}

	/** The section a rank belongs to: 0 = fields, 1 = constructor, 2 = methods. A conditional member sorts to the END of its own section, never across one. */
	private static inline function sectionOf(rank: MemberRank): Int {
		return if (rank < Constructor)
			0
		else if (rank == Constructor)
			1
		else
			2;
	}

	/**
	 * The within-rank sub-order of a plain unconditional member: `inline` members lead their
	 * rank, and among fields an initialized declaration leads an init-less one — `inline`
	 * weighs over the initializer key, so the two compose lexicographically. The caller
	 * exempts the Accessor rank: a get/set pair must keep its source adjacency even when
	 * only one half is inline.
	 */
	private static inline function subRank(m: OrderedMember): Int {
		return (m.isInline ? 0 : 2) + (m.initNode != null ? 0 : 1);
	}

	/**
	 * The block ordinal of a member whose conditional block earned a content rank - the source
	 * index of the block's first member, shared by every member of the block so the block sorts
	 * as one contiguous unit - or null when the member is unconditional or its block stayed
	 * pinned.
	 */
	private static inline function rankedOrdinalOf(m: OrderedMember, plan: SortPlan): Null<Int> {
		final cond: Null<String> = m.condition;
		return cond == null ? null : plan.ranked[groupKey(sectionOf(m.rank), cond, MemberSlots.branchSignatureOf(m))];
	}

	/**
	 * The `computeGroupFirst` / `compareOrder` map key for a member's conditional block: keyed by
	 * section so a condition shared across two sections keeps a distinct block per section, and by
	 * branch shape (`branchSignatureOf`) so only constructs with the SAME `#elseif` / `#else` chain
	 * merge - two `#if X` blocks still coalesce, an `#if X` and an `#if X ... #else` never do.
	 */
	private static inline function groupKey(section: Int, cond: String, signature: String): String {
		return '$section $cond $signature';
	}

	/**
	 * Order two members of ONE construct by the branch they were declared in, so its branches keep
	 * their source order and each sorts internally instead of interleaving.
	 */
	private static inline function compareBranch(a: OrderedMember, b: OrderedMember): Int {
		return MemberSlots.branchIndexOf(a) - MemberSlots.branchIndexOf(b);
	}

	/** Whether the grammar supplies the kind-sets the check needs. */
	private static function applicable(shape: RefShape): Bool {
		return (shape.visibilityContainerKinds ?? []).length > 0 && (shape.memberDeclKinds ?? []).length > 0
			&& (shape.visibilityModifierKinds ?? []).length > 0 && shape.defaultVisibilityModifierText != null;
	}

	/** Walk `node`; flag each container whose members are out of canonical order or whose rank groups are not blank-line separated. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, shape: RefShape, accessors: Map<Int, Bool>
	): Void {
		if ((shape.visibilityContainerKinds ?? []).contains(node.kind)) {
			final members: Array<OrderedMember> = MemberSlots.collectMembers(node, source, shape, accessors);
			final issue: Null<LayoutIssue> = firstLayoutIssue(members, source, computePlan(members, source, shape));
			if (issue != null) out.push({
				file: file,
				span: issue.member.span,
				rule: 'member-order',
				severity: Severity.Info,
				message: issue.message
			});
		}
		for (c in node.children) walk(out, file, source, c, shape, accessors);
	}

	/**
	 * Walk `node`; reorder each flagged, reorder-safe container (a reorder-unsafe one
	 * degrades to spacing-only fixes).
	 */
	private static function fixWalk(
		edits: Array<{ span: Span, text: String }>, source: String, node: QueryNode, shape: RefShape, flagged: Array<Int>,
		accessors: Map<Int, Bool>, movableArglessNew: Bool, index: Null<SymbolIndex>, file: Null<String>
	): Void {
		if ((shape.visibilityContainerKinds ?? []).contains(node.kind))
			emitReorder(edits, source, node, shape, flagged, accessors, movableArglessNew, index, file);
		for (c in node.children) fixWalk(edits, source, c, shape, flagged, accessors, movableArglessNew, index, file);
	}

	/**
	 * Emit the reorder edits for `container` when its first layout issue (order or
	 * spacing) is one of the passed violations and its fields are reorder-safe:
	 * stable-sort the members by rank, then rebuild the member region as a single
	 * edit - blank-line separating rank groups and comment-led slots - or, for
	 * `#if`-guarded members, a rebuilt region with regenerated `#if`/`#end`
	 * directives. Falls back to in-place slot swaps when an inter-member gap holds
	 * non-whitespace a rebuild would silently drop. A reorder-unsafe container
	 * (`reorderSafe` refused) degrades to `emitSpacingOnly`: the blank-line
	 * normalisation between rank groups still lands, the order stays untouched.
	 */
	private static function emitReorder(
		edits: Array<{ span: Span, text: String }>, source: String, container: QueryNode, shape: RefShape, flagged: Array<Int>,
		accessors: Map<Int, Bool>, movableArglessNew: Bool, index: Null<SymbolIndex>, file: Null<String>
	): Void {
		final members: Array<OrderedMember> = MemberSlots.collectMembers(container, source, shape, accessors);
		if (members.length < 2) return;
		final plan: SortPlan = computePlan(members, source, shape);
		final bad: Null<LayoutIssue> = firstLayoutIssue(members, source, plan);
		if (bad == null || !flagged.contains(bad.member.span.from)) return;
		final sorted: Array<OrderedMember> = members.copy();
		sorted.sort((a, b) -> compareOrder(a, b, plan));
		if (
			!reorderSafe(members, sorted, source, shape, movableArglessNew)
			|| !macroBuiltMetaOrderKept(members, sorted, container, index, file)
		) {
			MemberSpacing.emitSpacingOnly(edits, members, source);
			return;
		}
		if (!MemberSpacing.hasConditionalMember(members)) {
			if (MemberSpacing.hasNonWhitespaceGap(members, source)) {
				for (i in 0...members.length) if (members[i].node != sorted[i].node)
					edits.push({ span: members[i].span, text: source.substring(sorted[i].span.from, sorted[i].span.to) });
				return;
			}
			final region: Span = new Span(members[0].span.from, members[members.length - 1].span.to);
			edits.push({ span: region, text: MemberSpacing.joinMembers(sorted, source) });
			return;
		}
		final rebuilt: Null<String> = buildConditionalRegion(sorted, source, shape);
		if (rebuilt == null) return;
		edits.push({ span: new Span(members[0].regionFrom, members[members.length - 1].regionTo), text: rebuilt });
	}

	/**
	 * The first member that sorts before its predecessor under `compareOrder` (a lower
	 * section, an unconditional member after a PINNED conditional one, a lower sort rank), or
	 * null when the sequence is canonical. Crossing a `#else` / `#elseif` directive RESETS the
	 * comparison: an alternative conditional-compilation branch is a sibling sequence, not a
	 * successor of the branch before it - comparing across the boundary false-flags a
	 * container whose every branch is itself canonical. The directive is detected in the
	 * inter-member gap only (never inside a member's own source, so fixture strings
	 * mentioning `#else` cannot trip it).
	 */
	private static function firstOutOfOrder(members: Array<OrderedMember>, source: String, plan: SortPlan): Null<OrderedMember> {
		final elseExempt: Bool = hasUnmodelledElse(members, source);
		var prev: Null<OrderedMember> = null;
		var prevTo: Int = -1;
		for (m in members) {
			if (prevTo >= 0 && prevTo <= m.span.from && hasBranchDirective(source, prevTo, m.span.from)) prev = null;
			if (prev != null && (elseExempt ? m.rank < prev.rank : compareOrder(m, prev, plan) < 0)) return m;
			prev = m;
			prevTo = m.span.to;
		}
		return null;
	}

	/**
	 * Whether reordering `members` cannot change behaviour. Reordering changes behaviour
	 * only via FIELD initializers (they run in declaration order; statics at class-load,
	 * instance fields in the constructor - independent phases). Bails on stranded trivia
	 * (an `#else` the branch model could not absorb, an orphan comment), on a conditional
	 * region holding bytes no member slot covers, or on a field-init order flip a text scan
	 * cannot prove safe. `movableArglessNew` (the opt-in option) exempts a pure argless-`new`
	 * allocation from the side-effecting-flip bail - see `isMovableAllocation`.
	 */
	private static function reorderSafe(
		members: Array<OrderedMember>, sorted: Array<OrderedMember>, source: String, shape: RefShape, movableArglessNew: Bool
	): Bool {
		return !hasUnmodelledElse(members, source) && !hasOrphanComment(members, source)
			&& !hasSideEffectingFieldFlip(members, sorted, shape, source, movableArglessNew)
			&& !hasSiblingReadFlip(members, sorted, source) && conditionalRegionsCovered(members, source)
			&& !splitsCoexistingRegion(members);
	}

	/**
	 * Whether every conditional region holds only member slots, absorbed lead docs, regenerable
	 * directive lines and whitespace - `regionContentCovered` over every conditional member, in the
	 * same conservative direction the block-ranking gate reads it - AND whether the same holds of the
	 * WHOLE span the rebuild replaces, `[members[0].regionFrom, last.regionTo)`. The first question
	 * refuses an uncovered byte INSIDE a region (a stray `;`, which projects as `EmptySemiMember` and
	 * is no collected member); the second refuses one in the wider span, where exactly one thing
	 * lives that nothing else covers: an `@:meta` run written on the line(s) BEFORE a member-level
	 * `#if`. `MemberSlots.collectInto` reads such a run into the modifier flags it then RESETS across
	 * the guard, and `absorbLeadDoc` absorbs comments only, so the annotation belongs to no slot and
	 * `buildConditionalRegion` drops it outright, silently - measured as two `@SuppressWarnings` lines
	 * deleted from Pony's `tools/src/module/Module.hx` and one from `src/pony/ui/xml/HeapsXmlUi.hx`,
	 * both still parsing, both still green. Refusing degrades the container to the spacing-only
	 * fallback instead. Note the first gate is SHARED with `computePlan`, at a different granularity -
	 * tightening it for a block-local reason also widens this container-wide bail.
	 */
	private static function conditionalRegionsCovered(members: Array<OrderedMember>, source: String): Bool {
		final conditional: Array<OrderedMember> = [for (m in members) if (m.condition != null) m];
		return conditional.length == 0 || regionContentCovered(conditional, members, source)
			&& uncoveredIsDirectiveOnly(source, members[0].regionFrom, members[members.length - 1].regionTo, coveredSlotSpans(members));
	}

	/** Whether `a` and `b`'s relative order differs between source (`index`) and `sorted`. */
	private static function orderFlips(a: OrderedMember, b: OrderedMember, sorted: Array<OrderedMember>): Bool {
		final srcBefore: Bool = a.index < b.index;
		final sortedBefore: Bool = indexOfNode(sorted, a.node) < indexOfNode(sorted, b.node);
		return srcBefore != sortedBefore;
	}

	/**
	 * Whether `m` is a field whose initializer has a side effect (a call / `new` / assignment)
	 * that reordering could make observable. Under `movableArglessNew` a pure argless-`new`
	 * allocation is exempt (returns false) - see `isMovableAllocation`.
	 */
	private static function sideEffecting(
		m: OrderedMember, unsafe: Array<String>, shape: RefShape, source: String, movableArglessNew: Bool
	): Bool {
		final init: Null<QueryNode> = m.initNode;
		return m.isField && init != null && subtreeContainsAny(init, unsafe)
			&& !(movableArglessNew && isMovableAllocation(init, shape, source));
	}

	/**
	 * Whether `init` is a pure argless allocation - a `new T()` whose source ends in an empty
	 * argument list `()` (the `NewLiteral` argless test). A bare `new T()` carries no argument,
	 * so it references no other field/ident bound in the class; reordering it past another field
	 * only changes the relative construction order of two INDEPENDENT allocations, unobservable
	 * without cross-init data flow (which the empty `()` rules out). The opt-in `movableArglessNew`
	 * option is the project's acceptance of that - the rationale for treating such an initializer
	 * as order-movable. An initializer with arguments, a field/param reference, or any other call
	 * is NOT of this shape (its source does not end in `()`), so it keeps blocking as before.
	 */
	private static function isMovableAllocation(init: QueryNode, shape: RefShape, source: String): Bool {
		final newExprKind: Null<String> = shape.newExprKind;
		if (newExprKind == null || init.kind != newExprKind) return false;
		final span: Null<Span> = init.span;
		return span != null && source.substring(span.from, span.to).rtrim().endsWith('()');
	}

	/** Index of `node` (by identity) in `members`, or -1. */
	private static function indexOfNode(members: Array<OrderedMember>, node: QueryNode): Int {
		for (i in 0...members.length) if (members[i].node == node) return i;
		return -1;
	}

	/** Whether `node`'s subtree contains a node of any kind in `kinds`. */
	private static function subtreeContainsAny(node: QueryNode, kinds: Array<String>): Bool {
		return kinds.contains(node.kind) || node.children.exists(c -> subtreeContainsAny(c, kinds));
	}

	/**
	 * Rebuild a container's whole member region from `sorted` (canonical order): each maximal
	 * run of members sharing one `#if` condition AND branch shape is wrapped in a single
	 * `#if <cond> ... #end`, set off by a blank line before the `#if` and after the `#end`;
	 * unconditional runs stay bare. Inside a block, each rise in branch index re-emits the
	 * construct's own `#elseif` / `#else` directives (every skipped one too, so an empty middle
	 * branch survives). A member's absorbed lead-doc is emitted just before it, inside the
	 * regenerated `#if`. The writer round-trip re-indents the rough newline joins. Returns null
	 * if the self-check finds any member no longer under its recorded condition and branch.
	 */
	private static function buildConditionalRegion(sorted: Array<OrderedMember>, source: String, shape: RefShape): Null<String> {
		final ifKw: String = shape.conditionalIfKeyword ?? '#if';
		final parts: Array<String> = [];
		var prevCond: Null<String> = null;
		var prevSignature: String = '';
		var prevBranch: Int = 0;
		var prevMember: Null<OrderedMember> = null;
		var blockJustClosed: Bool = false;
		var hoisted: Null<QueryNode> = null;
		inline function emit(text: String, blankBefore: Bool): Void parts.push(parts.length == 0 ? text : (blankBefore ? '\n' : '') + text);
		for (m in sorted) {
			final signature: String = MemberSlots.branchSignatureOf(m);
			if (m.condition != prevCond || signature != prevSignature) {
				hoisted = null;
				if (prevCond != null) {
					emit('#end', false);
					blockJustClosed = true;
				}
				final cond: Null<String> = m.condition;
				if (cond != null) {
					if (signature != '' && StringTools.trim(m.leadTrivia) != '') {
						emit(StringTools.rtrim(m.leadTrivia), true);
						hoisted = m.node;
					}
					emit('$ifKw $cond', hoisted == null);
					blockJustClosed = false;
				}
				prevCond = m.condition;
				prevSignature = signature;
				prevBranch = 0;
				prevMember = null;
			}
			final branch: Int = MemberSlots.branchIndexOf(m);
			if (branch > prevBranch) {
				final opens: Array<String> = MemberSlots.branchOpensOf(m);
				while (prevBranch < branch) {
					emit(opens[prevBranch], false);
					prevBranch++;
				}
				prevMember = null;
			}
			final blankBefore: Bool = if (prevMember != null)
				MemberSpacing.separatorBetween(prevMember, m, source) == MemberSpacing.GROUP_SEPARATOR;
			else if (m.condition != null)
				false;
			else
				blockJustClosed;
			emit((m.node == hoisted ? '' : m.leadTrivia) + source.substring(m.span.from, m.span.to), blankBefore);
			blockJustClosed = false;
			prevMember = m;
		}
		if (prevCond != null) emit('#end', false);
		return verifyRegion(parts, sorted, ifKw) ? parts.join('\n') : null;
	}

	/** Re-derive each emitted member's surrounding condition and branch index from the directive stream and confirm both equal the recorded ones. */
	private static function verifyRegion(parts: Array<String>, sorted: Array<OrderedMember>, ifKw: String): Bool {
		final ifPrefix: String = '$ifKw ';
		var current: Null<String> = null;
		var branch: Int = 0;
		var si: Int = 0;
		for (p in parts) {
			final t: String = p.trim();
			if (t == '#end') {
				current = null;
				branch = 0;
			} else if (t.startsWith(ifPrefix)) {
				current = t.substring(ifPrefix.length).trim();
				branch = 0;
			} else if (t.startsWith('#else'))
				branch++;
			else if (isTriviaOnly(t))
				continue;
			else {
				if (si >= sorted.length || current != sorted[si].condition || branch != MemberSlots.branchIndexOf(sorted[si])) return false;
				si++;
			}
		}
		return si == sorted.length;
	}

	/** Whether a comment in the member region is covered by no member's slot or absorbed lead-doc — an orphan note the reorder would strand. Directives are regenerated, so need no coverage. */
	private static function hasOrphanComment(members: Array<OrderedMember>, source: String): Bool {
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final regionFrom: Int = members[0].regionFrom;
		final regionTo: Int = members[members.length - 1].regionTo;
		for (c in comments) if (!(c.to <= regionFrom || c.from >= regionTo)) {
			var covered: Bool = false;
			for (m in members) {
				final leadEnd: Int = m.leadFrom + m.leadTrivia.length;
				if (c.from >= m.leadFrom && c.to <= leadEnd || c.from >= m.span.from && c.to <= m.span.to) {
					covered = true;
					break;
				}
			}
			if (!covered) return true;
		}
		return false;
	}

	/**
	 * Whether a side-effecting field initializer would flip order with a same-phase INITIALIZED
	 * non-inline field — reordering two initializers changes their relative execution, and the
	 * side-effecting one's callee may read/mutate state the other observes (invisible to a text
	 * scan). Exempt as flip partners: an init-less field (contributes no code to the init phase)
	 * and an `inline` field (this grammar's language requires an inline variable's initializer to
	 * be a constant, so it is folded at compile time — a grammar supplying `inlineModifierKind`
	 * without that guarantee must not share this exemption). Under `movableArglessNew` a pure
	 * argless-`new` allocation is not counted side-effecting (see `sideEffecting`).
	 */
	private static function hasSideEffectingFieldFlip(
		members: Array<OrderedMember>, sorted: Array<OrderedMember>, shape: RefShape, source: String, movableArglessNew: Bool
	): Bool {
		final unsafe: Array<String> = unsafeInitKinds(shape);
		final fields: Array<OrderedMember> = [for (m in members) if (m.isField) m];
		for (f in fields)
			if (sideEffecting(f, unsafe, shape, source, movableArglessNew))
				for (g in fields)
					if (g.node != f.node && f.isStatic == g.isStatic && g.initNode != null && !g.isInline && orderFlips(f, g, sorted))
						return true;
		return false;
	}

	/**
	 * Whether a field initializer that textually reads a same-phase sibling field would flip order
	 * with it (a cross-phase read is safe — statics init first). Exempt as read targets: an INLINE
	 * sibling (its initializer is a language-mandated constant, folded at compile time, no runtime
	 * order dependency) and an INIT-LESS sibling (it runs no init code, so the reader sees the
	 * default value on either side of it).
	 */
	private static function hasSiblingReadFlip(members: Array<OrderedMember>, sorted: Array<OrderedMember>, source: String): Bool {
		for (m in members) {
			final init: Null<QueryNode> = m.initNode;
			if (init == null) continue;
			final s: Null<Span> = init.span;
			if (s == null) continue;
			for (g in members) if (
				g.isField && !g.isInline && g.initNode != null && g.node != m.node && g.isStatic == m.isStatic && g.node.name != null
				&& RefactorSupport.referencedInRange(source, (g.node.name: String), s.from, s.to, []) && orderFlips(m, g, sorted)
			)
				return true;
		}
		return false;
	}

	/** Whether a line in `source[from,to)` starts (after indentation) with `#else` or `#elseif`. */
	private static function hasBranchDirective(source: String, from: Int, to: Int): Bool {
		for (line in source.substring(from, to).split('\n')) {
			final t: String = StringTools.ltrim(line);
			if (t.startsWith('#else')) return true;
		}
		return false;
	}

	/**
	 * The first layout issue the check reports: the first out-of-order member, or -
	 * when the order is canonical - the first spacing offender. Shared by the check
	 * and the fix so both agree on which member is flagged, and with which message.
	 */
	private static function firstLayoutIssue(members: Array<OrderedMember>, source: String, plan: SortPlan): Null<LayoutIssue> {
		return
			firstOrderIssue(members, source, plan) ?? MemberSpacing.firstSpacingIssue(members, source) ?? MemberSpacing.firstDirectiveSpacingIssue(
				members, source
			);
	}

	/**
	 * The first out-of-order member wrapped as a `LayoutIssue`, or null when the sequence is canonical.
	 *
	 * The message names the member AND the neighbour whose comparison it lost, because a rank
	 * vocabulary alone cannot state the within-rank keys (`inline`, initializer) that decide most
	 * findings. `members[bad.index - 1]` IS that neighbour: `index` is the position `pushMember`
	 * assigned in this very array, and `firstOutOfOrder` reports nothing until it has a non-null
	 * predecessor - so the flagged member is never the one at index 0.
	 */
	private static function firstOrderIssue(members: Array<OrderedMember>, source: String, plan: SortPlan): Null<LayoutIssue> {
		final bad: Null<OrderedMember> = firstOutOfOrder(members, source, plan);
		if (bad == null) return null;
		final prev: OrderedMember = members[bad.index - 1];
		final section: Int = sectionOf(bad.rank);
		final keys: OrderKeys = {
			elseExempt: hasUnmodelledElse(members, source),
			section: section,
			otherSection: sectionOf(prev.rank),
			ranked: rankedOrdinalOf(bad, plan),
			otherRanked: rankedOrdinalOf(prev, plan),
			pinnedOrdinal: pinnedOrdinal(bad, plan.groupFirst, section),
			otherPinnedOrdinal: pinnedOrdinal(prev, plan.groupFirst, section),
			branch: compareBranch(bad, prev)
		};
		return {
			member: bad,
			message: 'type member ${MemberOrderReason.nameOf(bad)} is out of canonical order: ${MemberOrderReason.of(bad, prev, keys)}'
		};
	}

	/**
	 * One container's sort context: the block-order map plus every conditional block that
	 * earned a content rank.
	 *
	 * `groupFirst` keeps its historical meaning exactly - first-occurrence source index of each
	 * conditional `#if` block, keyed by `groupKey` (section, condition and branch shape) - so a
	 * PINNED block still keeps the position of its earliest member, and every branch of one
	 * construct shares the key that holds the branches together.
	 *
	 * `ranked` carries that same index for the buckets that passed all three gates - uniform
	 * rank, `regionContentCovered`, `blockInitInert`. Failing any of them simply leaves the
	 * bucket out, which is exactly the pre-existing pinned behaviour. Buckets are keyed by
	 * `groupKey` too, SECTION INCLUDED: a construct declaring both fields and methods under one
	 * condition already splits into one block per section, and keying without the section would
	 * merge those two blocks and pin both on the mixed rank.
	 */
	private static function computePlan(members: Array<OrderedMember>, source: String, shape: RefShape): SortPlan {
		final groupFirst: Map<String, Int> = [];
		final buckets: Map<String, Array<OrderedMember>> = [];
		final order: Array<String> = [];
		for (m in members) {
			final cond: Null<String> = m.condition;
			if (cond == null) continue;
			final key: String = groupKey(sectionOf(m.rank), cond, MemberSlots.branchSignatureOf(m));
			final bucket: Null<Array<OrderedMember>> = buckets[key];
			if (bucket == null) {
				groupFirst[key] = m.index;
				buckets[key] = [m];
				order.push(key);
			} else
				bucket.push(m);
		}
		final ranked: Map<String, Int> = [];
		final rankedInline: Array<String> = [];
		for (key in order) {
			final bucket: Null<Array<OrderedMember>> = buckets[key];
			final ordinal: Null<Int> = groupFirst[key];
			if (bucket == null || ordinal == null || !uniformRank(bucket)) continue;
			if (!regionContentCovered(bucket, members, source)) continue;
			if (!blockInitInert(bucket, members, shape, source)) continue;
			ranked[key] = ordinal;
			if (uniformInline(bucket)) rankedInline.push(key);
		}
		return { groupFirst: groupFirst, ranked: ranked, rankedInline: rankedInline };
	}

	/** Whether every member of `bucket` carries the same rank - the first gate a conditional block passes to sort by its content. A mixed-rank bucket stays pinned: the block moves as one unit or not at all, and atomicity beats ordering. */
	private static function uniformRank(bucket: Array<OrderedMember>): Bool {
		return bucket.foreach(m -> m.rank == bucket[0].rank);
	}

	/**
	 * Whether every member of `bucket` is an `inline` FIELD - the block then holds nothing but
	 * compile-time constants, and leads the plain members of its rank instead of trailing them.
	 * A single non-inline member is enough to disqualify it: the block moves as one unit, so a
	 * mixed block has no sub-order of its own. Methods and accessors are excluded even when
	 * `inline`, so a guarded platform implementation keeps going to its section end and a get/set
	 * pair keeps its source adjacency.
	 */
	private static function uniformInline(bucket: Array<OrderedMember>): Bool {
		return bucket.foreach(m -> m.isField && m.isInline);
	}

	/**
	 * Whether the content-ranked conditional block holding `m` leads the plain members of its
	 * rank rather than trailing them - it does when the block holds only `inline` fields, which
	 * extends the inline-leads sub-order across the conditional boundary: a compile-time constant
	 * guarded by `#if` belongs with the constants at the top of the type, not below the
	 * initialized fields it shares a rank with. A PINNED block never reaches here (`compareOrder`
	 * returns on it first).
	 */
	private static function leadsRank(m: OrderedMember, plan: SortPlan): Bool {
		final cond: Null<String> = m.condition;
		return cond != null && plan.rankedInline.contains(groupKey(sectionOf(m.rank), cond, MemberSlots.branchSignatureOf(m)));
	}

	/**
	 * Whether every byte of the conditional construct(s) `block` occupies is accounted for by a
	 * member slot, a member's absorbed lead doc, a conditional-compilation directive line, or
	 * whitespace. Anything else - a member the projection does not model (a stray `;` projects as
	 * `EmptySemiMember`, which is no collected member) or opaque region text - would be dropped or
	 * duplicated when `buildConditionalRegion` regenerates the region from member slots and
	 * directives alone, so the block must not move.
	 *
	 * Coverage is collected from EVERY member in `all`, not just from `block`: a nested,
	 * differently-conditioned member shares the outer construct's region and covers its own bytes
	 * there.
	 */
	private static function regionContentCovered(block: Array<OrderedMember>, all: Array<OrderedMember>, source: String): Bool {
		final covered: Array<Span> = coveredSlotSpans(all);
		final seen: Array<String> = [];
		for (m in block) {
			final key: String = '${m.regionFrom} ${m.regionTo}';
			if (seen.contains(key)) continue;
			seen.push(key);
			if (!uncoveredIsDirectiveOnly(source, m.regionFrom, m.regionTo, covered)) return false;
			if (!tailOfLineBlank(source, m.regionTo)) return false;
		}
		return true;
	}

	/** Whether every maximal chunk of `[from, to)` left uncovered by the from-sorted `covered` spans holds only blank or directive lines. */
	private static function uncoveredIsDirectiveOnly(source: String, from: Int, to: Int, covered: Array<Span>): Bool {
		var cursor: Int = from;
		for (c in covered) {
			if (c.from >= to) break;
			if (c.to <= cursor) continue;
			if (c.from > cursor && !isDirectiveOrBlank(source.substring(cursor, c.from))) return false;
			cursor = c.to;
			if (cursor >= to) return true;
		}
		return isDirectiveOrBlank(source.substring(cursor, to));
	}

	/**
	 * Whether `text` holds only blank lines and conditional-compilation directive lines the rebuild
	 * regenerates. A directive line carrying a COMMENT is refused: `buildConditionalRegion` re-emits
	 * the directive from the recorded condition and branch shape alone, so the note has nowhere to
	 * go. `hasOrphanComment` already refuses the REBUILD for that shape, so what this clause adds is
	 * keeping the block pinned - without it the container reads as out of order and reports a finding
	 * the fixer can never apply.
	 */
	private static function isDirectiveOrBlank(text: String): Bool {
		for (line in text.split('\n')) {
			final trimmed: String = StringTools.ltrim(line);
			if (trimmed == '') continue;
			if (!trimmed.startsWith('#')) return false;
			if (RefactorSupport.textHasCommentMarker(trimmed)) return false;
		}
		return true;
	}

	/**
	 * Whether no field initializer ties `block` to a position in the container. Refuses in BOTH
	 * directions: a field inside the block whose initializer has a side effect (call / allocation /
	 * assignment) or reads another field of the container, and a field OUTSIDE the block whose
	 * initializer reads a field inside it - moving the block would then change what an initializer
	 * sees. Deliberately independent of the `movableArglessNew` option, since `compareOrder` is
	 * shared by the report path, which resolves no per-file config.
	 */
	private static function blockInitInert(block: Array<OrderedMember>, all: Array<OrderedMember>, shape: RefShape, source: String): Bool {
		final unsafe: Array<String> = unsafeInitKinds(shape);
		for (m in block) {
			final init: Null<QueryNode> = m.initNode;
			if (!m.isField || init == null) continue;
			if (subtreeContainsAny(init, unsafe)) return false;
			if (readsAnyFieldName(init, all, m, source)) return false;
		}
		for (g in all) {
			final init: Null<QueryNode> = g.initNode;
			if (!g.isField || init == null || block.contains(g)) continue;
			if (readsAnyFieldName(init, block, g, source)) return false;
		}
		return true;
	}

	/** The node kinds whose presence in a field initializer makes its position observable - an assignment, a call, an allocation. One list, two consumers (`hasSideEffectingFieldFlip` and `blockInitInert`), so the flip bail and the block gate cannot drift apart. */
	private static function unsafeInitKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = shape.writeParentKinds.copy();
		if (shape.callKind != null) kinds.push(shape.callKind);
		if (shape.newExprKind != null) kinds.push(shape.newExprKind);
		return kinds;
	}

	/**
	 * Compare two members by the canonical order: section (fields, constructor, methods) first;
	 * within a section every PINNED conditional member sinks behind the rest (`comparePinned`
	 * orders those among themselves); the remaining members sort by their SORT rank, which for a
	 * member of a content-ranked block is that block's rank; ties break on the within-rank
	 * sub-order (`subRank` — plain unconditional members only, Accessor rank exempt), then on
	 * source index.
	 *
	 * Within one rank a content-ranked block trails the plain members of that rank (the `ca` / `cb`
	 * step). That is the minimal-motion choice: crossing a rank boundary is what content ranking
	 * exists for, position inside one rank is not, so every pre-existing expectation about a
	 * conditional block trailing its same-rank peers survives untouched.
	 *
	 * Every member of one ranked block shares that block's ordinal, which is what keeps the block
	 * atomic and contiguous; branch index then keeps a construct's branches in source order, each
	 * sorting internally.
	 */
	private static function compareOrder(a: OrderedMember, b: OrderedMember, plan: SortPlan): Int {
		final sa: Int = sectionOf(a.rank);
		final sb: Int = sectionOf(b.rank);
		if (sa != sb) return sa - sb;
		final oa: Null<Int> = rankedOrdinalOf(a, plan);
		final ob: Null<Int> = rankedOrdinalOf(b, plan);
		final pa: Int = a.condition != null && oa == null ? 1 : 0;
		final pb: Int = b.condition != null && ob == null ? 1 : 0;
		if (pa != pb) return pa - pb;
		if (pa == 1) return comparePinned(a, b, plan.groupFirst, sa);
		if (a.rank != b.rank) return a.rank - b.rank;
		final ca: Int = oa == null ? 0 : (leadsRank(a, plan) ? -1 : 1);
		final cb: Int = ob == null ? 0 : (leadsRank(b, plan) ? -1 : 1);
		if (ca != cb) return ca - cb;
		if (oa != null && ob != null) {
			if (oa != ob) return oa - ob;
			final branch: Int = compareBranch(a, b);
			if (branch != 0) return branch;
		}
		if (oa == null && ob == null && a.rank != Accessor) {
			final sub: Int = subRank(a) - subRank(b);
			if (sub != 0) return sub;
		}
		return a.index - b.index;
	}

	/**
	 * The pre-content-ranking comparison, unchanged: two PINNED conditional members order by their
	 * `#if` block's first occurrence, then by branch within that block, then by rank, then by
	 * source index. `section` is the section both sort into - a pinned member's sort rank IS its
	 * own rank, so it equals `sectionOf(a.rank)`.
	 */
	private static function comparePinned(a: OrderedMember, b: OrderedMember, groupFirst: Map<String, Int>, section: Int): Int {
		final ga: Int = pinnedOrdinal(a, groupFirst, section);
		final gb: Int = pinnedOrdinal(b, groupFirst, section);
		if (ga != gb) return ga - gb;
		final branch: Int = compareBranch(a, b);
		return if (branch != 0)
			branch
		else if (a.rank != b.rank)
			a.rank - b.rank
		else
			a.index - b.index;
	}

	/**
	 * The block-order index of a PINNED conditional member. `computePlan` records one for every
	 * conditional member under this exact key, and `comparePinned` only ever sees conditional
	 * members, so both fallbacks to the member's own source index are null-safety floors that
	 * cannot fire.
	 */
	private static function pinnedOrdinal(m: OrderedMember, groupFirst: Map<String, Int>, section: Int): Int {
		final cond: Null<String> = m.condition;
		return cond == null ? m.index : groupFirst[groupKey(section, cond, MemberSlots.branchSignatureOf(m))] ?? m.index;
	}

	/**
	 * Whether the container holds an `#else` / `#elseif` the branch model could not absorb: a
	 * construct `assignBranches` refused, or a directive between two members that are not an
	 * ascending branch pair of ONE construct. `opens` is compared by identity because
	 * `assignBranches` hands every member of a construct the same array - two constructs of
	 * equal shape are still two constructs, and a directive between them is not a branch
	 * boundary. A construct whose FIRST branch is empty lands here too: its directive then sits
	 * between an outside member and an inside one, which no branch pair explains.
	 */
	private static function hasUnmodelledElse(members: Array<OrderedMember>, source: String): Bool {
		for (m in members) {
			final b: Null<BranchInfo> = m.branch;
			if (b != null && b.index < 0) return true;
		}
		for (i in 0...members.length - 1) if (hasBranchDirective(source, members[i].span.to, members[i + 1].span.from)) {
			final before: Null<BranchInfo> = members[i].branch;
			final after: Null<BranchInfo> = members[i + 1].branch;
			// A construct whose FIRST branch is empty puts its own `#if` AND the
			// openings it skips in this gap. The directives then belong to the
			// construct `after` is in, not to a boundary between two walked members,
			// so the gap is accounted for as long as the gap OPENS that construct.
			if (after != null && after.index > 0 && opensConstruct(source, members[i].span.to, members[i + 1].span.from)) continue;
			if (before == null || after == null) return true;
			if (before.opens != after.opens || after.index <= before.index) return true;
		}
		return false;
	}

	/** Whether an emitted part is comment text only - the lead doc hoisted above a branched block's `#if`, which occupies no member slot. */
	private static function isTriviaOnly(text: String): Bool {
		return StringTools.trim((~/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g).replace(text, '')) == '';
	}

	/** Whether a line in `source[from,to)` starts (after indentation) with the conditional-open keyword - the gap begins a new construct rather than continuing one. */
	private static function opensConstruct(source: String, from: Int, to: Int): Bool {
		return source.substring(from, to).split('\n').exists(line -> StringTools.startsWith(StringTools.ltrim(line), '#if'));
	}

	/**
	 * Whether the rest of the line after `at` is blank. The region a conditional member reports ends
	 * right after its `#end`, so a comment written on that line (`#end // note`) sits just OUTSIDE
	 * the region and `uncoveredIsDirectiveOnly` never scans it. The rebuild replaces
	 * `[first.regionFrom, last.regionTo)`: for the LAST construct the note falls after that span and
	 * is left behind for whichever member ends up last, for any earlier construct it falls inside and
	 * is dropped outright. Refusing here keeps the note attached to the construct it annotates.
	 */
	private static function tailOfLineBlank(source: String, at: Int): Bool {
		final nl: Int = source.indexOf('\n', at);
		return source.substring(at, nl < 0 ? source.length : nl).trim() == '';
	}

	/**
	 * Whether `init` (the initializer of field `owner`) textually reads the name of another
	 * SAME-PHASE field in `fields` - statics initialise at class-load and instance fields in the
	 * constructor, so a cross-phase read can never observe declaration order, the same phase gate
	 * `hasSiblingReadFlip` applies. The scan is a raw identifier-boundary read, so within a phase it
	 * over-reports (a mention in a comment or a `$name` interpolation counts) - the conservative
	 * direction for a gate that must refuse anything it cannot prove independent.
	 */
	private static function readsAnyFieldName(init: QueryNode, fields: Array<OrderedMember>, owner: OrderedMember, source: String): Bool {
		final span: Null<Span> = init.span;
		if (span == null) return false;
		for (f in fields) {
			final name: Null<String> = f.node.name;
			if (
				f.isField && f.isStatic == owner.isStatic && f.node != owner.node && name != null
				&& RefactorSupport.referencedInRange(source, name, span.from, span.to, [])
			)
				return true;
		}
		return false;
	}

	/**
	 * Whether some `#if` construct would be SPLIT across sections with members that COEXIST.
	 * `groupKey` carries the section, so two members of ONE construct sharing a condition AND a
	 * branch but ranking into different sections become two blocks - the fields lift out of the
	 * region their author wrote, away from the method that uses them, and a nested condition is
	 * re-derived as a conjunct at the new site (`#if !openfl` inside `#if !macro` re-emitted as
	 * `#if ((!macro) && (!openfl))`). The BRANCH index is part of the key on purpose: members in
	 * different branches of one construct are mutually exclusive - at most one of them ever
	 * compiles - so a per-section split there can separate a field from no user, which is why the
	 * branched shape keeps splitting.
	 */
	private static function splitsCoexistingRegion(members: Array<OrderedMember>): Bool {
		final sections: Map<String, Int> = [];
		for (m in members) {
			final cond: Null<String> = m.condition;
			if (cond == null) continue;
			final key: String = '${m.regionTo} $cond ${MemberSlots.branchSignatureOf(m)} ${MemberSlots.branchIndexOf(m)}';
			final section: Int = sectionOf(m.rank);
			final seen: Null<Int> = sections[key];
			if (seen == null)
				sections[key] = section;
			else if (seen != section)
				return true;
		}
		return false;
	}

	/**
	 * Whether the sort keeps the relative order of every ANNOTATED member of a container whose type
	 * transitively carries a build macro. A build macro reads `getBuildFields()` in DECLARATION order
	 * and dispatches on metadata, so the annotated members are exactly the ones whose order it can turn
	 * into generated output - Pony's `DeclaratorBuilder` turns `@:arg` fields into constructor
	 * PARAMETERS in that order, so swapping two of them rewrites the signature for every caller with no
	 * local error (measured on `DTimer` / `Timeline` / `ParseBoy`: the callers fail, four files away).
	 * Which tag matters is unknowable from here - and inventing a per-tag meaning in the core would
	 * violate the declarative-format invariant - so the relative order of ALL annotated members is
	 * preserved and only unannotated ones move.
	 *
	 * Without an `index` (a check invoked directly, no lint scope) there is nothing to ask, and without
	 * the type in scope the answer is no: same narrow-scope limitation the seven other consumers of
	 * `transitivelyCarriesBuildMacro` carry. `file` is the source this fix pass is rewriting, and it is
	 * what makes the gate answer about THIS container rather than about a same-named type in another
	 * package - see the predicate's own doc for the measured cost of not naming it.
	 */
	private static function macroBuiltMetaOrderKept(
		members: Array<OrderedMember>, sorted: Array<OrderedMember>, container: QueryNode, index: Null<SymbolIndex>, file: Null<String>
	): Bool {
		if (index == null) return true;
		final owner: Null<String> = container.name;
		if (owner == null || !index.transitivelyCarriesBuildMacro(owner, file)) return true;
		final before: Array<Int> = [for (m in members) if (m.hasMeta) m.index];
		final after: Array<Int> = [for (m in sorted) if (m.hasMeta) m.index];
		return before.join(',') == after.join(',');
	}

	/** Every byte range a rebuild re-emits verbatim - each member's own slot plus its absorbed lead doc - from-sorted for the linear scan `uncoveredIsDirectiveOnly` does over it. */
	private static function coveredSlotSpans(members: Array<OrderedMember>): Array<Span> {
		final covered: Array<Span> = [];
		for (m in members) {
			covered.push(m.span);
			if (m.leadTrivia.length > 0) covered.push(new Span(m.leadFrom, m.leadFrom + m.leadTrivia.length));
		}
		covered.sort((x, y) -> x.from - y.from);
		return covered;
	}

}

/**
 * The canonical member-order ranks - a smaller rank sorts earlier. Fields precede
 * the constructor precede accessors precede methods; within each group public
 * precedes private; static fields lead (immutable `final` / constant before mutable
 * `var`), static methods trail. Non-static property fields (those with a `(get, set)`-style
 * accessor clause) sub-split ahead of the plain fields: a read-only property (stored read)
 * before a getter property, both before the `final` field, before the plain `var`. A
 * distinct type rather than a bare `Int` so a rank can never be confused with an unrelated
 * count; the two `@:op` forwards give it the `<` ordering and `-` difference that the sort
 * comparator and `firstOutOfOrder` need (Haxe otherwise forbids ordered comparison on an
 * abstract).
 */
enum abstract MemberRank(Int) {
	final StaticPublicImmutableField = 0;
	final StaticPublicMutableField = 1;
	final StaticPrivateImmutableField = 2;
	final StaticPrivateMutableField = 3;
	final PublicReadOnlyProperty = 4;
	final PublicGetterProperty = 5;
	final PublicImmutableField = 6;
	final PublicMutableField = 7;
	final PrivateReadOnlyProperty = 8;
	final PrivateGetterProperty = 9;
	final PrivateImmutableField = 10;
	final PrivateMutableField = 11;
	final Constructor = 12;
	final Accessor = 13;
	final PublicMethod = 14;
	final PrivateMethod = 15;
	final StaticPublicMethod = 16;
	final StaticPrivateMethod = 17;

	@:op(A < B) static function lt(a: MemberRank, b: MemberRank): Bool;

	@:op(A - B) static function sub(a: MemberRank, b: MemberRank): Int;
}
