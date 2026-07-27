package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.TypeInfoProvider;
import anyparse.check.Check.ConfigAware;

/**
 * One type-member paired with its canonical-order rank and its full source slot
 * (leading doc + modifier/`@:meta` run + decl), for the order check and the
 * reordering autofix.
 */
typedef OrderedMember = {
	var node: QueryNode;
	var rank: MemberRank;
	var index: Int;
	var span: Span;
	var isField: Bool;
	var isStatic: Bool;
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
 * The `member-order` check and its reordering autofix: verifies a types members follow the canonical rank order (constants, fields, constructor, methods; public before private) with rank groups blank-line separated, and rewrites them into that order when fixing. A conditional block moves as one unit to the end of its section, branches and all: `#if` / `#elseif` / `#else` / `#end` is a single group whose members sort within their own branch, so the construct is regenerated rather than flattened. A container whose field initializers make reordering unsafe - or which holds an `#else` shape the branch model refuses (nested, spanning two sections, or with an empty first branch) - keeps its order (the finding stays report-only) but still gets its rank-group spacing normalised, including the blank lines that set each member-level `#if`/`#end` block off from its neighbours. The opt-in `movableArglessNew` option (apqlint.json rule options, default OFF) relaxes that unsafe bail for a pure argless-`new` initializer (`x = new T()`), which the project accepts as order-movable - reordering two independent allocations only changes their relative construction order, unobservable without cross-init data flow.
 */
@:nullSafety(Strict)
final class MemberOrder implements Check implements ConfigAware {

	/** The inter-slot separator carrying exactly one blank line - what both fix arms (the reorder rebuild and the spacing-only fallback) place between rank groups. */
	private static final GROUP_SEPARATOR: String = '\n\n';

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
		return
			'type members not in canonical order (constants, properties, fields, constructor, methods; public before private; conditional members grouped into one #if block per condition and branch shape at the end of their section) or rank groups and conditional blocks not separated by blank lines';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		if (!applicable(shape)) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
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
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final accessors: Map<Int, Bool> = provider != null ? provider.propertyAccessors(source) : [];
		final movableArglessNew: Bool = violations.length > 0
			&& LintConfig.resolveWith(_resolveConfig, violations[0].file).boolOption('member-order', 'movableArglessNew') == true;
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		fixWalk(edits, source, tree, shape, flagged, accessors, movableArglessNew);
		return edits;
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
			final members: Array<OrderedMember> = collectMembers(node, source, shape, accessors);
			final issue: Null<LayoutIssue> = firstLayoutIssue(members, source);
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
		accessors: Map<Int, Bool>, movableArglessNew: Bool
	): Void {
		if ((shape.visibilityContainerKinds ?? []).contains(node.kind))
			emitReorder(edits, source, node, shape, flagged, accessors, movableArglessNew);
		for (c in node.children) fixWalk(edits, source, c, shape, flagged, accessors, movableArglessNew);
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
		accessors: Map<Int, Bool>, movableArglessNew: Bool
	): Void {
		final members: Array<OrderedMember> = collectMembers(container, source, shape, accessors);
		if (members.length < 2) return;
		final bad: Null<LayoutIssue> = firstLayoutIssue(members, source);
		if (bad == null || !flagged.contains(bad.member.span.from)) return;
		final groupFirst: Map<String, Int> = computeGroupFirst(members);
		final sorted: Array<OrderedMember> = members.copy();
		sorted.sort((a, b) -> compareOrder(a, b, groupFirst));
		if (!reorderSafe(members, sorted, source, shape, movableArglessNew)) {
			emitSpacingOnly(edits, members, source);
			return;
		}
		if (!hasConditionalMember(members)) {
			if (hasNonWhitespaceGap(members, source)) {
				for (i in 0...members.length) if (members[i].node != sorted[i].node)
					edits.push({ span: members[i].span, text: source.substring(sorted[i].span.from, sorted[i].span.to) });
				return;
			}
			final region: Span = new Span(members[0].span.from, members[members.length - 1].span.to);
			edits.push({ span: region, text: joinMembers(sorted, source) });
			return;
		}
		final rebuilt: Null<String> = buildConditionalRegion(sorted, source, shape);
		if (rebuilt == null) return;
		edits.push({ span: new Span(members[0].regionFrom, members[members.length - 1].regionTo), text: rebuilt });
	}

	/**
	 * The spacing-only degradation for a container whose member order cannot be
	 * rewritten safely (`reorderSafe` refused): normalise every violating
	 * inter-slot gap over the ORIGINAL member sequence - one blank line between
	 * rank groups, none inside a tight field group - and, via `emitDirectiveSpacing`,
	 * set every member-level `#if`/`#end` block off with a blank line before and
	 * after, leaving the order itself untouched (the order finding stays report-only).
	 * Shares `spacingViolation` with `firstSpacingIssue` and `directiveGapEdits` with
	 * `firstDirectiveSpacingIssue`, so the fix emits nothing exactly where the check
	 * finds no issue and a re-run converges.
	 */
	private static function emitSpacingOnly(
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
	 * Collect `container`'s members in source (pre-order) order with each member's
	 * rank and full slot span, descending into `#if` conditional regions so a guarded
	 * member is recorded with the condition it is declared under (see `collectInto`).
	 */
	private static function collectMembers(
		container: QueryNode, source: String, shape: RefShape, accessors: Map<Int, Bool>
	): Array<OrderedMember> {
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final out: Array<OrderedMember> = [];
		collectInto(out, container, source, shape, comments, [], null, accessors);
		return out;
	}

	/** The canonical-order rank of a member given its static / public flags and whether it is a field. */
	private static function rankOf(
		node: QueryNode, isStatic: Bool, isPublic: Bool, isField: Bool, accessors: Map<Int, Bool>, shape: RefShape
	): MemberRank {
		if (isField) {
			final mutable: Bool = (shape.mutableFieldDeclKinds ?? []).contains(node.kind);
			if (isStatic)
				return !mutable
					? (isPublic ? StaticPublicImmutableField : StaticPrivateImmutableField)
					: (isPublic ? StaticPublicMutableField : StaticPrivateMutableField);
			final span: Null<Span> = node.span;
			if (span != null && accessors.exists(span.from)) {
				final getter: Bool = accessors[span.from] == true;
				return isPublic
					? (getter ? PublicGetterProperty : PublicReadOnlyProperty)
					: (getter ? PrivateGetterProperty : PrivateReadOnlyProperty);
			}
			return !mutable
				? (isPublic ? PublicImmutableField : PrivateImmutableField)
				: (isPublic ? PublicMutableField : PrivateMutableField);
		}
		final name: String = node.name ?? '';
		return shape.constructorName != null && name == shape.constructorName
			? Constructor
			: isAccessor(name, shape)
				? Accessor
				: isStatic ? (isPublic ? StaticPublicMethod : StaticPrivateMethod) : (isPublic ? PublicMethod : PrivateMethod);
	}

	/** Whether `name` begins with a property-accessor prefix (`get_` / `set_`). */
	private static function isAccessor(name: String, shape: RefShape): Bool {
		for (prefix in shape.accessorMethodPrefixes ?? []) if (StringTools.startsWith(name, prefix)) return true;
		return false;
	}

	/**
	 * The first member that sorts before its predecessor under `compareOrder` (a lower
	 * section, an unconditional member after a conditional one, a lower rank), or null when
	 * the sequence is canonical. Crossing a `#else` / `#elseif` directive RESETS the
	 * comparison: an alternative conditional-compilation branch is a sibling sequence, not a
	 * successor of the branch before it - comparing across the boundary false-flags a
	 * container whose every branch is itself canonical. The directive is detected in the
	 * inter-member gap only (never inside a member's own source, so fixture strings
	 * mentioning `#else` cannot trip it).
	 */
	private static function firstOutOfOrder(members: Array<OrderedMember>, source: String): Null<OrderedMember> {
		final groupFirst: Map<String, Int> = computeGroupFirst(members);
		final elseExempt: Bool = hasUnmodelledElse(members, source);
		var prev: Null<OrderedMember> = null;
		var prevTo: Int = -1;
		for (m in members) {
			if (prevTo >= 0 && prevTo <= m.span.from && hasBranchDirective(source, prevTo, m.span.from)) prev = null;
			if (prev != null && (elseExempt ? m.rank < prev.rank : compareOrder(m, prev, groupFirst) < 0)) return m;
			prev = m;
			prevTo = m.span.to;
		}
		return null;
	}

	/**
	 * Whether reordering `members` cannot change behaviour. Reordering changes behaviour
	 * only via FIELD initializers (they run in declaration order; statics at class-load,
	 * instance fields in the constructor - independent phases). Bails on stranded trivia
	 * (an `#else` the branch model could not absorb, an orphan comment) or a field-init
	 * order flip a text scan cannot prove safe. `movableArglessNew` (the opt-in option)
	 * exempts a pure argless-`new` allocation from the side-effecting-flip bail - see
	 * `isMovableAllocation`.
	 */
	private static function reorderSafe(
		members: Array<OrderedMember>, sorted: Array<OrderedMember>, source: String, shape: RefShape, movableArglessNew: Bool
	): Bool {
		return !hasUnmodelledElse(members, source) && !hasOrphanComment(members, source)
			&& !hasSideEffectingFieldFlip(members, sorted, shape, source, movableArglessNew)
			&& !hasSiblingReadFlip(members, sorted, source);
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
		if (!m.isField || init == null) return false;
		if (!subtreeContainsAny(init, unsafe)) return false;
		return !(movableArglessNew && isMovableAllocation(init, shape, source));
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
		return span != null && StringTools.endsWith(StringTools.rtrim(source.substring(span.from, span.to)), '()');
	}

	/** Index of `node` (by identity) in `members`, or -1. */
	private static function indexOfNode(members: Array<OrderedMember>, node: QueryNode): Int {
		for (i in 0...members.length) if (members[i].node == node) return i;
		return -1;
	}

	/** Whether `node`'s subtree contains a node of any kind in `kinds`. */
	private static function subtreeContainsAny(node: QueryNode, kinds: Array<String>): Bool {
		if (kinds.contains(node.kind)) return true;
		for (c in node.children) if (subtreeContainsAny(c, kinds)) return true;
		return false;
	}

	/**
	 * Collect `parent`'s direct member declarations into `out` in source (pre-order)
	 * order, descending into `conditionalMemberKind` (`#if`) regions so each guarded
	 * member is recorded with the condition it is declared under. `condStack` holds the
	 * enclosing `#if` condition conjuncts (an identical conjunct is deduped, collapsing
	 * a redundant `#if X` nested in `#if X`); `outerCond` is the outermost enclosing
	 * conditional's span - the rebuild-region bound for every member under it. On the way
	 * out of each conditional, `assignBranches` recovers which `#elseif` / `#else` branch
	 * each of its members sits in, since the parse tree carries no branch structure.
	 */
	private static function collectInto(
		out: Array<OrderedMember>, parent: QueryNode, source: String, shape: RefShape,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, condStack: Array<String>, outerCond: Null<Span>, accessors: Map<Int, Bool>
	): Void {
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final staticKind: Null<String> = shape.staticModifierKind;
		final defaultVis: String = shape.defaultVisibilityModifierText ?? '';
		final condKind: Null<String> = shape.conditionalMemberKind;
		var isStatic: Bool = false;
		var isPublic: Bool = false;
		for (child in parent.children) {
			if (condKind != null && child.kind == condKind) {
				final span: Null<Span> = child.span;
				final cond: Null<String> = extractConditionText(child, source, shape);
				final nextStack: Array<String> = cond != null && !condStack.contains(cond) ? condStack.concat([cond]) : condStack;
				final firstIdx: Int = out.length;
				collectInto(out, child, source, shape, comments, nextStack, outerCond ?? span, accessors);
				if (span != null && out.length > firstIdx) {
					absorbLeadDoc(out, firstIdx, source, comments, span.from);
					assignBranches(out, firstIdx, span, source, shape);
				}
				isStatic = false;
				isPublic = false;
			} else if (members.contains(child.kind)) {
				pushMember(out, child, parent, source, shape, comments, condStack, outerCond, isStatic, isPublic, accessors);
				isStatic = false;
				isPublic = false;
			} else {
				if (staticKind != null && child.kind == staticKind) isStatic = true;
				if (visibility.contains(child.kind)) {
					final s: Null<Span> = child.span;
					if (s != null && StringTools.trim(source.substring(s.from, s.to)) != defaultVis) isPublic = true;
				}
			}
		}
	}

	/**
	 * The `#if` condition text of a conditional-member node, whitespace-normalised, or
	 * null. The condition ends at the first newline after `#if` (it is a single-line
	 * directive) or at the first member, whichever comes first — so a doc comment that
	 * sits between the `#if` line and the first member is NOT captured into the condition.
	 */
	private static function extractConditionText(node: QueryNode, source: String, shape: RefShape): Null<String> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final ifKw: String = shape.conditionalIfKeyword ?? '#if';
		final ifIdx: Int = source.indexOf(ifKw, span.from);
		if (ifIdx < 0) return null;
		final condStart: Int = ifIdx + ifKw.length;
		final firstChild: Null<QueryNode> = node.children.length > 0 ? node.children[0] : null;
		final childSpan: Null<Span> = firstChild != null ? firstChild.span : null;
		final childFrom: Int = childSpan != null ? childSpan.from : span.to;
		final nl: Int = source.indexOf('\n', condStart);
		final lineEnd: Int = nl < 0 ? span.to : nl;
		final condEnd: Int = childFrom < lineEnd ? childFrom : lineEnd;
		if (condEnd <= condStart) return null;
		final raw: String = StringTools.trim(source.substring(condStart, condEnd));
		return raw == '' ? null : normalizeCondition(raw);
	}

	/** Collapse internal whitespace runs in a condition to single spaces for stable comparison. */
	private static function normalizeCondition(cond: String): String {
		return (~/\s+/g).replace(cond, ' ');
	}

	/**
	 * Join condition conjuncts into one parenthesised `#if` expression. Each conjunct is
	 * itself parenthesised unless already balanced-parenthesised, and the whole is wrapped
	 * in an outer pair — the grammar's `#if` accepts a single (parenthesised) condition, not
	 * a bare top-level `&&`, so `((A) && (B))`, never `(A) && (B)`.
	 */
	private static function joinConds(stack: Array<String>): String {
		return stack.length == 1 ? stack[0] : '(${stack.map(parenthesiseConjunct).join(' && ')})';
	}

	/** Wrap `cond` in parentheses unless it is already a single balanced parenthesised group. */
	private static function parenthesiseConjunct(cond: String): String {
		return isBalancedParenWrapped(cond) ? cond : '($cond)';
	}

	/** Whether `cond` is wrapped in one outer pair of balanced parentheses spanning the whole string. */
	private static function isBalancedParenWrapped(cond: String): Bool {
		if (!StringTools.startsWith(cond, '(') || !StringTools.endsWith(cond, ')')) return false;
		var depth: Int = 0;
		for (i in 0...cond.length) {
			switch cond.charAt(i) {
				case '(':
					depth++;
				case ')':
					depth--;
					if (depth == 0 && i < cond.length - 1) return false;
				case _:
			}
		}
		return depth == 0;
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
			final signature: String = branchSignatureOf(m);
			if (!sameCondition(m.condition, prevCond) || signature != prevSignature) {
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
			final branch: Int = branchIndexOf(m);
			if (branch > prevBranch) {
				final opens: Array<String> = branchOpensOf(m);
				while (prevBranch < branch) {
					emit(opens[prevBranch], false);
					prevBranch++;
				}
				prevMember = null;
			}
			final blankBefore: Bool = if (prevMember != null)
				separatorBetween(prevMember, m, source) == GROUP_SEPARATOR;
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
			final t: String = StringTools.trim(p);
			if (t == '#end') {
				current = null;
				branch = 0;
			} else if (StringTools.startsWith(t, ifPrefix)) {
				current = StringTools.trim(t.substring(ifPrefix.length));
				branch = 0;
			} else if (StringTools.startsWith(t, '#else'))
				branch++;
			else if (isTriviaOnly(t))
				continue;
			else {
				if (si >= sorted.length || !sameCondition(current, sorted[si].condition) || branch != branchIndexOf(sorted[si]))
					return false;
				si++;
			}
		}
		return si == sorted.length;
	}

	/** Whether two optional `#if` conditions are equal (both null = unconditional). */
	private static function sameCondition(a: Null<String>, b: Null<String>): Bool {
		return a == b;
	}

	/**
	 * Attach a doc/comment block sitting on the lines immediately before a conditional's
	 * `#if` (the parser puts it outside the conditional) to the conditional's first
	 * member `out[firstIdx]`, so the rebuild re-emits it with that member inside the
	 * regenerated `#if`. Extends the member's rebuild-region start back over the block.
	 */
	private static function absorbLeadDoc(
		out: Array<OrderedMember>, firstIdx: Int, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, ifPos: Int
	): Void {
		final nl: Int = source.lastIndexOf('\n', ifPos);
		final ifLineStart: Int = nl < 0 ? 0 : nl + 1;
		final leadFrom: Int = RefactorSupport.leadingCommentBlockStart(source, comments, ifPos);
		if (leadFrom >= ifLineStart) return;
		out[firstIdx].leadTrivia = source.substring(leadFrom, ifLineStart);
		out[firstIdx].leadFrom = leadFrom;
		if (leadFrom < out[firstIdx].regionFrom) out[firstIdx].regionFrom = leadFrom;
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
	 * Whether a side-effecting field initializer would flip order with a same-phase field — its
	 * callee may read/mutate that field (invisible to a text scan). Under `movableArglessNew` a
	 * pure argless-`new` allocation is not counted side-effecting (see `sideEffecting`).
	 */
	private static function hasSideEffectingFieldFlip(
		members: Array<OrderedMember>, sorted: Array<OrderedMember>, shape: RefShape, source: String, movableArglessNew: Bool
	): Bool {
		final unsafe: Array<String> = shape.writeParentKinds.copy();
		if (shape.callKind != null) unsafe.push(shape.callKind);
		if (shape.newExprKind != null) unsafe.push(shape.newExprKind);
		final fields: Array<OrderedMember> = [for (m in members) if (m.isField) m];
		for (f in fields) if (sideEffecting(f, unsafe, shape, source, movableArglessNew)) for (g in fields) if (
			g.node != f.node && f.isStatic == g.isStatic && orderFlips(f, g, sorted)
		)
			return true;
		return false;
	}

	/** Whether a field initializer that textually reads a same-phase sibling field would flip order with it (a cross-phase read is safe — statics init first). */
	private static function hasSiblingReadFlip(members: Array<OrderedMember>, sorted: Array<OrderedMember>, source: String): Bool {
		for (m in members) {
			final init: Null<QueryNode> = m.initNode;
			if (init == null) continue;
			final s: Null<Span> = init.span;
			if (s == null) continue;
			for (g in members) if (
				g.isField && g.node != m.node && g.isStatic == m.isStatic && g.node.name != null
				&& RefactorSupport.referencedInRange(source, (g.node.name: String), s.from, s.to, []) && orderFlips(m, g, sorted)
			)
				return true;
		}
		return false;
	}

	/** Build and push the `OrderedMember` for member `child` of `parent`, ranked under the running modifier flags and the `condStack` condition. */
	private static function pushMember(
		out: Array<OrderedMember>, child: QueryNode, parent: QueryNode, source: String, shape: RefShape,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, condStack: Array<String>, outerCond: Null<Span>, isStatic: Bool,
		isPublic: Bool, accessors: Map<Int, Bool>
	): Void {
		final span: Null<Span> = child.span;
		if (span == null) return;
		final group: Span = RefactorSupport.declGroupSpan(child, parent, span);
		final full: Span = RefactorSupport.memberTriviaSpan(source, group, comments);
		final isField: Bool = (shape.fieldDeclKinds ?? []).contains(child.kind);
		final region: Span = outerCond ?? full;
		out.push({
			node: child,
			rank: rankOf(child, isStatic, isPublic, isField, accessors, shape),
			index: out.length,
			span: full,
			isField: isField,
			isStatic: isStatic,
			initNode: isField && child.children.length > 0 ? child.children[0] : null,
			condition: condStack.length == 0 ? null : joinConds(condStack),
			branch: null,
			regionFrom: region.from,
			regionTo: region.to,
			leadTrivia: '',
			leadFrom: full.from
		});
	}


	/** Whether a line in `source[from,to)` starts (after indentation) with `#else` or `#elseif`. */
	private static function hasBranchDirective(source: String, from: Int, to: Int): Bool {
		for (line in source.substring(from, to).split('\n')) {
			final t: String = StringTools.ltrim(line);
			if (StringTools.startsWith(t, '#else')) return true;
		}
		return false;
	}

	/**
	 * The first layout issue the check reports: the first out-of-order member, or -
	 * when the order is canonical - the first spacing offender. Shared by the check
	 * and the fix so both agree on which member is flagged, and with which message.
	 */
	private static function firstLayoutIssue(members: Array<OrderedMember>, source: String): Null<LayoutIssue> {
		return firstOrderIssue(members, source) ?? firstSpacingIssue(members, source) ?? firstDirectiveSpacingIssue(members, source);
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
	private static function firstSpacingIssue(members: Array<OrderedMember>, source: String): Null<LayoutIssue> {
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
		if (gap.indexOf('\n') < 0 || StringTools.trim(gap) != '') return null;
		final blanks: Int = blankLineCount(gap);
		return a.rank != b.rank
			? blanks != 1 ? 1 : null
			: b.isField && blanks != 0 && !slotStartsWithComment(a, source) && !slotStartsWithComment(b, source) ? 0 : null;
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

	/** The number of whitespace-only lines wholly inside `gap` (the inter-slot text) - a tab-only line counts. */
	private static function blankLineCount(gap: String): Int {
		final lines: Array<String> = gap.split('\n');
		var count: Int = 0;
		for (i in 1...lines.length - 1) if (StringTools.trim(lines[i]) == '') count++;
		return count;
	}

	/** Whether `m`'s slot text begins (after trimming) with a comment - a doc/line comment the spacing rule never strips or demands a blank against. */
	private static function slotStartsWithComment(m: OrderedMember, source: String): Bool {
		final t: String = StringTools.trim(source.substring(m.span.from, m.span.to));
		return StringTools.startsWith(t, '/*') || StringTools.startsWith(t, '//');
	}

	/**
	 * The separator between two consecutive reordered members: a blank line between rank
	 * groups, before a method, or before a comment-led slot (a member whose leading doc the
	 * writer keeps blank-separated); a single newline between two same-rank plain fields. Note
	 * this drives the raw joins INSIDE a rebuilt `#if` region, where the writer preserves them
	 * verbatim; outside `#if`, the writer re-inserts blank-after-doc during canonicalization.
	 */
	private static function separatorBetween(prev: OrderedMember, next: OrderedMember, source: String): String {
		return prev.rank != next.rank || !next.isField || slotStartsWithComment(next, source) ? GROUP_SEPARATOR : '\n';
	}

	/** Whether any inter-member gap in the region holds non-whitespace (a stray `;`, a trailing comment) a rebuild would silently drop - the guard that falls the reorder back to per-slot swaps. */
	private static function hasNonWhitespaceGap(members: Array<OrderedMember>, source: String): Bool {
		for (i in 0...members.length - 1) if (StringTools.trim(source.substring(members[i].span.to, members[i + 1].span.from)) != '')
			return true;
		return false;
	}

	/** Join `sorted` member slots for the reordered region, blank-separating rank groups and members that lead with a comment. */
	private static function joinMembers(sorted: Array<OrderedMember>, source: String): String {
		final parts: Array<String> = [source.substring(sorted[0].span.from, sorted[0].span.to)];
		for (i in 1...sorted.length)
			parts.push(separatorBetween(sorted[i - 1], sorted[i], source) + source.substring(sorted[i].span.from, sorted[i].span.to));
		return parts.join('');
	}

	/** The first out-of-order member wrapped as a `LayoutIssue`, or null when the sequence is canonical. */
	private static function firstOrderIssue(members: Array<OrderedMember>, source: String): Null<LayoutIssue> {
		final bad: Null<OrderedMember> = firstOutOfOrder(members, source);
		return bad == null ? null : {
			member: bad,
			message: 'type members are not in canonical order (constants, fields, constructor, methods; public before private)'
		};
	}

	/** Whether any member is `#if`-guarded - such a container rebuilds through `buildConditionalRegion`, never the slot-swap path. */
	private static function hasConditionalMember(members: Array<OrderedMember>): Bool {
		for (m in members) if (m.condition != null) return true;
		return false;
	}


	/** The section a rank belongs to: 0 = fields, 1 = constructor, 2 = methods. A conditional member sorts to the END of its own section, never across one. */
	private static inline function sectionOf(rank: MemberRank): Int {
		return rank < Constructor ? 0 : rank == Constructor ? 1 : 2;
	}

	/**
	 * First-occurrence source index of each conditional `#if` block, keyed by `groupKey`
	 * (section, condition and branch shape). Within a section the merged condition blocks are
	 * ordered by this index, so a block keeps the position of its earliest member - and every
	 * branch of one construct shares the key, which is what holds the branches together.
	 */
	private static function computeGroupFirst(members: Array<OrderedMember>): Map<String, Int> {
		final firstOf: Map<String, Int> = [];
		for (m in members) {
			final cond: Null<String> = m.condition;
			if (cond == null) continue;
			final key: String = groupKey(sectionOf(m.rank), cond, branchSignatureOf(m));
			if (!firstOf.exists(key)) firstOf[key] = m.index;
		}
		return firstOf;
	}

	/**
	 * Compare two members by the canonical order: section (fields, constructor, methods)
	 * first; within a section unconditional members precede conditional ones; conditional
	 * members group by `#if` block (ordered by first occurrence), then by branch within that
	 * block, then by rank; ties break on source index. Branch outranks rank so a construct's
	 * branches keep their source order and each sorts internally, instead of interleaving.
	 * `groupFirst` is `computeGroupFirst`'s block-order map.
	 */
	private static function compareOrder(a: OrderedMember, b: OrderedMember, groupFirst: Map<String, Int>): Int {
		final sa: Int = sectionOf(a.rank);
		final sb: Int = sectionOf(b.rank);
		if (sa != sb) return sa - sb;
		final condA: Null<String> = a.condition;
		final condB: Null<String> = b.condition;
		final ca: Int = condA == null ? 0 : 1;
		final cb: Int = condB == null ? 0 : 1;
		if (ca != cb) return ca - cb;
		if (condA != null && condB != null) {
			final ga: Int = groupFirst[groupKey(sa, condA, branchSignatureOf(a))] ?? a.index;
			final gb: Int = groupFirst[groupKey(sb, condB, branchSignatureOf(b))] ?? b.index;
			if (ga != gb) return ga - gb;
			final ba: Int = branchIndexOf(a);
			final bb: Int = branchIndexOf(b);
			if (ba != bb) return ba - bb;
		}
		return a.rank != b.rank ? a.rank - b.rank : a.index - b.index;
	}

	/**
	 * The first member preceded (across an `#if`) by a missing blank line: a member-level
	 * `#if` must have a blank line before it and its `#end` a blank line after, so a
	 * conditional block stands apart from its neighbours. Reads `directiveGapEdits` (shared
	 * with the spacing-only fix so the two agree on which blanks are missing); the container's
	 * leading `#if` / trailing `#end` (no member pair spans them) are exempt, as is an `#else`
	 * gap (same condition on both sides).
	 */
	private static function firstDirectiveSpacingIssue(members: Array<OrderedMember>, source: String): Null<LayoutIssue> {
		if (hasUnmodelledElse(members, source)) return null;
		for (i in 0...members.length - 1) {
			final gap: DirectiveGap = directiveGapEdits(members[i], members[i + 1], source);
			if (gap.ifEdit != null) return { member: members[i + 1], message: 'a member-level #if is not preceded by a blank line' };
			if (gap.endEdit != null) return { member: members[i + 1], message: 'a member-level #end is not followed by a blank line' };
		}
		return null;
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
	 * The directive-spacing arm of the spacing-only fallback: set every member-level `#if` off
	 * with a blank line before it and its `#end` with a blank line after it - the blanks
	 * `directiveGapEdits` reports - so a reorder-unsafe container whose guarded block cannot
	 * move still gets that block visually separated from its neighbours (the CheckBox shape).
	 * Exempts a container with an unmodelled `#else`, as the check does.
	 */
	private static function emitDirectiveSpacing(
		edits: Array<{ span: Span, text: String }>, members: Array<OrderedMember>, source: String
	): Void {
		if (hasUnmodelledElse(members, source)) return;
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
			if (firstIfStart < 0 && StringTools.startsWith(t, '#if')) firstIfStart = cursor;
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


	/**
	 * Recover the branch layout of the `#if` / `#elseif` / `#else` / `#end` construct spanning
	 * `constructSpan` and record it on the members `collectInto` just pushed (`out[firstIdx...]`).
	 * The grammar exposes NO branch structure - every branch's members arrive as flat children of
	 * one `Conditional` node - so the boundaries come from the directive lines in the construct's
	 * own source, the same textual read `extractConditionText` already does for the condition.
	 * An unbranched construct is left alone: `branch` stays null, which is today's shape.
	 *
	 * Records a negative `index` (which bails the reorder) when the construct is not a flat,
	 * single-section branch set: a nested conditional inside a branch, an already-branched nested
	 * construct, members spread over more than one section, or a condition text that could not be
	 * read. A rebuild would then have to split the construct across sections, emit a branch with no
	 * members, or emit branches under no `#if` at all - none worth the risk of rewriting
	 * conditional compilation.
	 */
	private static function assignBranches(
		out: Array<OrderedMember>, firstIdx: Int, constructSpan: Span, source: String, shape: RefShape
	): Void {
		final opens: Array<{ at: Int, text: String }> = [
			for (o in branchOpenings(constructSpan, source, shape)) if (!insideAnyMember(out, firstIdx, o.at)) o
		];
		if (opens.length == 0) return;
		final texts: Array<String> = [for (o in opens) o.text];
		final condition: Null<String> = out[firstIdx].condition;
		final section: Int = sectionOf(out[firstIdx].rank);
		if (condition == null || !isFlatSingleSection(out, firstIdx, condition, section)) {
			final refused: BranchInfo = { index: -1, opens: texts };
			for (i in firstIdx ... out.length) out[i].branch = refused;
			return;
		}
		for (i in firstIdx ... out.length) {
			final decl: Null<Span> = out[i].node.span;
			final at: Int = decl != null ? decl.from : out[i].span.from;
			var index: Int = 0;
			for (o in opens) if (o.at < at) index++;
			out[i].branch = { index: index, opens: texts };
		}
	}

	/** Every `#elseif` / `#else` directive line inside `constructSpan`, in source order - each opens the next branch. */
	private static function branchOpenings(constructSpan: Span, source: String, shape: RefShape): Array<{ at: Int, text: String }> {
		final keywords: Array<String> = shape.conditionalElseKeywords ?? [];
		final out: Array<{ at: Int, text: String }> = [];
		if (keywords.length == 0) return out;
		var pos: Int = constructSpan.from;
		while (pos < constructSpan.to) {
			final nl: Int = source.indexOf('\n', pos);
			final end: Int = nl < 0 || nl > constructSpan.to ? constructSpan.to : nl;
			final line: String = StringTools.trim(source.substring(pos, end));
			for (k in keywords) if (StringTools.startsWith(line, k)) {
				out.push({ at: pos, text: line });
				break;
			}
			pos = end + 1;
		}
		return out;
	}

	/** Whether `at` falls inside one of the member slots `out[firstIdx...]` - a directive in a member's own body is not a branch boundary. */
	private static function insideAnyMember(out: Array<OrderedMember>, firstIdx: Int, at: Int): Bool {
		for (i in firstIdx ... out.length) if (at >= out[i].span.from && at < out[i].span.to) return true;
		return false;
	}

	/** The branch a member sits in - 0 for an unconditional member or for the then-branch of a construct. */
	private static inline function branchIndexOf(m: OrderedMember): Int {
		final b: Null<BranchInfo> = m.branch;
		return b == null ? 0 : b.index;
	}

	/** A member's construct branch shape, `''` when it is in none - part of the block key, so only same-shaped constructs merge into one block. */
	private static inline function branchSignatureOf(m: OrderedMember): String {
		final b: Null<BranchInfo> = m.branch;
		return b == null ? '' : b.opens.join('\n');
	}

	/** The branch-opening directives of a member's construct, empty when it is in none: `opens[k - 1]` opens branch `k`. */
	private static inline function branchOpensOf(m: OrderedMember): Array<String> {
		final b: Null<BranchInfo> = m.branch;
		return b == null ? [] : b.opens;
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
			if (before == null || after == null) return true;
			if (before.opens != after.opens || after.index <= before.index) return true;
		}
		return false;
	}


	/** Whether `out[firstIdx...]` is ONE flat, single-section branch set: no member under a nested conditional, none already branched, none whose rank crosses into another section. */
	private static function isFlatSingleSection(out: Array<OrderedMember>, firstIdx: Int, condition: Null<String>, section: Int): Bool {
		for (i in firstIdx ... out.length) if (out[i].branch != null || out[i].condition != condition || sectionOf(out[i].rank) != section)
			return false;
		return true;
	}


	/** Whether an emitted part is comment text only - the lead doc hoisted above a branched block's `#if`, which occupies no member slot. */
	private static function isTriviaOnly(text: String): Bool {
		return StringTools.trim((~/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g).replace(text, '')) == '';
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
private enum abstract MemberRank(Int) {
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
