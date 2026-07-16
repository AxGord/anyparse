package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

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
	var regionFrom: Int;
	var regionTo: Int;

	var leadTrivia: String;
	var leadFrom: Int;
}
@:nullSafety(Strict)
final class MemberOrder implements Check {

	public function new() {}

	public function id(): String {
		return 'member-order';
	}

	public function description(): String {
		return 'type members not in canonical order (constants, fields, constructor, methods; public before private)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		if (!applicable(shape)) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, shape);
		}
		return violations;
	}

	/**
	 * Reorder each flagged container's members into canonical order. Re-parses
	 * `source`, emits edits only for a container whose first out-of-order member's
	 * slot matches a passed violation, and bails a container whose field initializers
	 * make reordering unsafe (see the class doc).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		if (!applicable(shape)) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final flagged: Array<Int> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push(span.from);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		fixWalk(edits, source, tree, shape, flagged);
		return edits;
	}

	/** Whether the grammar supplies the kind-sets the check needs. */
	private static function applicable(shape: RefShape): Bool {
		return (shape.visibilityContainerKinds ?? []).length > 0 && (shape.memberDeclKinds ?? []).length > 0
			&& (shape.visibilityModifierKinds ?? []).length > 0 && shape.defaultVisibilityModifierText != null;
	}

	/** Walk `node`; flag each container whose members are out of canonical order. */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, shape: RefShape): Void {
		if ((shape.visibilityContainerKinds ?? []).contains(node.kind)) {
			final members: Array<OrderedMember> = collectMembers(node, source, shape);
			final bad: Null<OrderedMember> = firstOutOfOrder(members, source);
			if (bad != null) out.push({
				file: file,
				span: bad.span,
				rule: 'member-order',
				severity: Severity.Info,
				message: 'type members are not in canonical order (constants, fields, constructor, methods; public before private)'
			});
		}
		for (c in node.children) walk(out, file, source, c, shape);
	}

	/** Walk `node`; reorder each flagged, reorder-safe container. */
	private static function fixWalk(
		edits: Array<{ span: Span, text: String }>, source: String, node: QueryNode, shape: RefShape, flagged: Array<Int>
	): Void {
		if ((shape.visibilityContainerKinds ?? []).contains(node.kind)) emitReorder(edits, source, node, shape, flagged);
		for (c in node.children) fixWalk(edits, source, c, shape, flagged);
	}

	/**
	 * Emit the reorder edits for `container` when its first out-of-order member is
	 * flagged and its fields are reorder-safe: stable-sort the members by rank, then
	 * either swap each source slot in place (no conditionals) or rebuild the whole
	 * member region with regrouped `#if`/`#end` directives (conditional members).
	 */
	private static function emitReorder(
		edits: Array<{ span: Span, text: String }>, source: String, container: QueryNode, shape: RefShape, flagged: Array<Int>
	): Void {
		final members: Array<OrderedMember> = collectMembers(container, source, shape);
		if (members.length < 2) return;
		final bad: Null<OrderedMember> = firstOutOfOrder(members, source);
		if (bad == null || !flagged.contains(bad.span.from)) return;
		final sorted: Array<OrderedMember> = members.copy();
		sorted.sort((a, b) -> a.rank != b.rank ? a.rank - b.rank : a.index - b.index);
		if (!reorderSafe(members, sorted, source, shape)) return;
		var hasConditional: Bool = false;
		for (m in members) if (m.condition != null) {
			hasConditional = true;
			break;
		}
		if (!hasConditional) {
			for (i in 0...members.length) if (members[i].node != sorted[i].node)
				edits.push({ span: members[i].span, text: source.substring(sorted[i].span.from, sorted[i].span.to) });
			return;
		}
		final rebuilt: Null<String> = buildConditionalRegion(sorted, source, shape);
		if (rebuilt == null) return;
		edits.push({ span: new Span(members[0].regionFrom, members[members.length - 1].regionTo), text: rebuilt });
	}

	/**
	 * Collect `container`'s members in source (pre-order) order with each member's
	 * rank and full slot span, descending into `#if` conditional regions so a guarded
	 * member is recorded with the condition it is declared under (see `collectInto`).
	 */
	private static function collectMembers(container: QueryNode, source: String, shape: RefShape): Array<OrderedMember> {
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final out: Array<OrderedMember> = [];
		collectInto(out, container, source, shape, comments, [], null);
		return out;
	}

	/** The canonical-order rank of a member given its static / public flags and whether it is a field. */
	private static function rankOf(node: QueryNode, isStatic: Bool, isPublic: Bool, isField: Bool, shape: RefShape): MemberRank {
		if (isField) {
			if (isStatic) return isPublic ? StaticPublicField : StaticPrivateField;
			final mutable: Bool = (shape.mutableFieldDeclKinds ?? []).contains(node.kind);
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
	 * The first member whose rank drops below its predecessor's, or null when the
	 * sequence is canonical. Crossing a `#else` / `#elseif` directive RESETS the
	 * comparison: an alternative conditional-compilation branch is a sibling
	 * sequence, not a successor of the branch before it — comparing across the
	 * boundary false-flags a container whose every branch is itself canonical.
	 * The directive is detected in the inter-member gap only (never inside a
	 * member's own source, so fixture strings mentioning `#else` cannot trip it).
	 */
	private static function firstOutOfOrder(members: Array<OrderedMember>, source: String): Null<OrderedMember> {
		var prev: Null<MemberRank> = null;
		var prevTo: Int = -1;
		for (m in members) {
			if (prevTo >= 0 && prevTo <= m.span.from && hasBranchDirective(source, prevTo, m.span.from)) prev = null;
			if (prev != null && m.rank < prev) return m;
			prev = m.rank;
			prevTo = m.span.to;
		}
		return null;
	}

	/**
	 * Whether reordering `members` cannot change behaviour. Reordering changes behaviour
	 * only via FIELD initializers (they run in declaration order; statics at class-load,
	 * instance fields in the constructor — independent phases). Bails on stranded trivia
	 * (an `#else`, an orphan comment) or a field-init order flip a text scan cannot prove
	 * safe.
	 */
	private static function reorderSafe(
		members: Array<OrderedMember>, sorted: Array<OrderedMember>, source: String, shape: RefShape
	): Bool {
		return !hasElseBetweenMembers(members, source, shape) && !hasOrphanComment(members, source)
			&& !hasSideEffectingFieldFlip(members, sorted, shape) && !hasSiblingReadFlip(members, sorted, source);
	}

	/** Whether `a` and `b`'s relative order differs between source (`index`) and `sorted`. */
	private static function orderFlips(a: OrderedMember, b: OrderedMember, sorted: Array<OrderedMember>): Bool {
		final srcBefore: Bool = a.index < b.index;
		final sortedBefore: Bool = indexOfNode(sorted, a.node) < indexOfNode(sorted, b.node);
		return srcBefore != sortedBefore;
	}

	/** Whether `m` is a field whose initializer has a side effect (a call / `new` / assignment). */
	private static function sideEffecting(m: OrderedMember, unsafe: Array<String>): Bool {
		final init: Null<QueryNode> = m.initNode;
		return m.isField && init != null && subtreeContainsAny(init, unsafe);
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
	 * conditional's span — the rebuild-region bound for every member under it.
	 */
	private static function collectInto(
		out: Array<OrderedMember>, parent: QueryNode, source: String, shape: RefShape,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, condStack: Array<String>, outerCond: Null<Span>
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
				collectInto(out, child, source, shape, comments, nextStack, outerCond ?? span);
				if (span != null && out.length > firstIdx) absorbLeadDoc(out, firstIdx, source, comments, span.from);
				isStatic = false;
				isPublic = false;
			} else if (members.contains(child.kind)) {
				pushMember(out, child, parent, source, shape, comments, condStack, outerCond, isStatic, isPublic);
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
		return stack.length == 1 ? stack[0] : '(' + stack.map(parenthesiseConjunct).join(' && ') + ')';
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
	 * Rebuild a container's whole member region from `sorted` (rank order): each maximal
	 * run of members sharing one `#if` condition is wrapped in a single `#if <cond> …
	 * #end`; unconditional runs stay bare. A member's absorbed lead-doc is emitted just
	 * before it, inside the regenerated `#if`. The writer round-trip re-indents the rough
	 * newline joins. Returns null if the self-check finds any member no longer under its
	 * recorded condition.
	 */
	private static function buildConditionalRegion(sorted: Array<OrderedMember>, source: String, shape: RefShape): Null<String> {
		final ifKw: String = shape.conditionalIfKeyword ?? '#if';
		final parts: Array<String> = [];
		var prevCond: Null<String> = null;
		var started: Bool = false;
		for (m in sorted) {
			if (!sameCondition(m.condition, prevCond)) {
				if (started && prevCond != null) parts.push('#end');
				final cond: Null<String> = m.condition;
				if (cond != null) parts.push('$ifKw $cond');
				prevCond = m.condition;
			}
			parts.push(m.leadTrivia + source.substring(m.span.from, m.span.to));
			started = true;
		}
		if (prevCond != null) parts.push('#end');
		return verifyRegion(parts, sorted, ifKw) ? parts.join('\n') : null;
	}

	/** Re-derive each emitted member's surrounding condition from the directive stream and confirm it equals the recorded one. */
	private static function verifyRegion(parts: Array<String>, sorted: Array<OrderedMember>, ifKw: String): Bool {
		final ifPrefix: String = '$ifKw ';
		var current: Null<String> = null;
		var si: Int = 0;
		for (p in parts) {
			final t: String = StringTools.trim(p);
			if (t == '#end')
				current = null;
			else if (StringTools.startsWith(t, ifPrefix))
				current = StringTools.trim(t.substring(ifPrefix.length));
			else {
				if (si >= sorted.length || !sameCondition(current, sorted[si].condition)) return false;
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

	/** Whether an `#else` / `#elseif` sits between member slots — the projection flattens then-body and else-body members, so their conditions cannot be split. */
	private static function hasElseBetweenMembers(members: Array<OrderedMember>, source: String, shape: RefShape): Bool {
		final elseKeywords: Array<String> = shape.conditionalElseKeywords ?? [];
		if (elseKeywords.length == 0) return false;
		for (i in 0...members.length - 1) {
			final gap: String = source.substring(members[i].span.to, members[i + 1].span.from);
			for (line in gap.split('\n')) {
				final t: String = StringTools.trim(line);
				for (k in elseKeywords) if (StringTools.startsWith(t, k)) return true;
			}
		}
		return false;
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

	/** Whether a side-effecting field initializer would flip order with a same-phase field — its callee may read/mutate that field (invisible to a text scan). */
	private static function hasSideEffectingFieldFlip(members: Array<OrderedMember>, sorted: Array<OrderedMember>, shape: RefShape): Bool {
		final unsafe: Array<String> = shape.writeParentKinds.copy();
		if (shape.callKind != null) unsafe.push(shape.callKind);
		if (shape.newExprKind != null) unsafe.push(shape.newExprKind);
		final fields: Array<OrderedMember> = [for (m in members) if (m.isField) m];
		for (f in fields) if (sideEffecting(f, unsafe)) for (g in fields) if (
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
		isPublic: Bool
	): Void {
		final span: Null<Span> = child.span;
		if (span == null) return;
		final group: Span = RefactorSupport.declGroupSpan(child, parent, span);
		final full: Span = RefactorSupport.memberTriviaSpan(source, group, comments);
		final isField: Bool = (shape.fieldDeclKinds ?? []).contains(child.kind);
		final region: Span = outerCond ?? full;
		out.push({
			node: child,
			rank: rankOf(child, isStatic, isPublic, isField, shape),
			index: out.length,
			span: full,
			isField: isField,
			isStatic: isStatic,
			initNode: isField && child.children.length > 0 ? child.children[0] : null,
			condition: condStack.length == 0 ? null : joinConds(condStack),
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

}

/**
 * The canonical member-order ranks — a smaller rank sorts earlier. Fields precede
 * the constructor precede accessors precede methods; within each group public
 * precedes private; static fields lead, static methods trail. A distinct type
 * rather than a bare `Int` so a rank can never be confused with an unrelated count;
 * the two `@:op` forwards give it the `<` ordering and `-` difference that the sort
 * comparator and `firstOutOfOrder` need (Haxe otherwise forbids ordered comparison
 * on an abstract).
 */
private enum abstract MemberRank(Int) {
	final StaticPublicField = 0;
	final StaticPrivateField = 1;
	final PublicImmutableField = 2;
	final PublicMutableField = 3;
	final PrivateImmutableField = 4;
	final PrivateMutableField = 5;
	final Constructor = 6;
	final Accessor = 7;
	final PublicMethod = 8;
	final PrivateMethod = 9;
	final StaticPublicMethod = 10;
	final StaticPrivateMethod = 11;

	@:op(A < B) static function lt(a: MemberRank, b: MemberRank): Bool;

	@:op(A - B) static function sub(a: MemberRank, b: MemberRank): Int;
}
