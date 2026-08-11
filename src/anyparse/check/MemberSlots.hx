package anyparse.check;

import anyparse.check.MemberOrder.BranchInfo;
import anyparse.check.MemberOrder.MemberRank;
import anyparse.check.MemberOrder.OrderedMember;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The COLLECTION half of `member-order`: turning a container's raw child list into the
 * `OrderedMember` slots the check and its autofix then reason over. That is one job with
 * one entry point (`collectMembers`) and four sub-answers no other part of the rule asks
 * for — a member's canonical rank, its full source slot, the `#if` condition stack it was
 * declared under, and which branch of that construct it sits in.
 *
 * Split out of `MemberOrder`, which keeps the questions asked OF the collected slots
 * (are they in order, is reordering safe, how are they spaced, how is the region rebuilt).
 */
@:nullSafety(Strict)
final class MemberSlots {

	/** The branch a member sits in - 0 for an unconditional member or for the then-branch of a construct. */
	public static inline function branchIndexOf(m: OrderedMember): Int {
		final b: Null<BranchInfo> = m.branch;
		return b == null ? 0 : b.index;
	}

	/** A member's construct branch shape, `''` when it is in none - part of the block key, so only same-shaped constructs merge into one block. */
	public static inline function branchSignatureOf(m: OrderedMember): String {
		final b: Null<BranchInfo> = m.branch;
		return b == null ? '' : b.opens.join('\n');
	}

	/** The branch-opening directives of a member's construct, empty when it is in none: `opens[k - 1]` opens branch `k`. */
	public static inline function branchOpensOf(m: OrderedMember): Array<String> {
		final b: Null<BranchInfo> = m.branch;
		return b == null ? [] : b.opens;
	}

	/**
	 * Collect `container`'s members in source (pre-order) order with each member's
	 * rank and full slot span, descending into `#if` conditional regions so a guarded
	 * member is recorded with the condition it is declared under (see `collectInto`).
	 */
	public static function collectMembers(
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
		if (isField) return fieldRankOf(node, isStatic, isPublic, accessors, shape);
		final name: String = node.name ?? '';
		return if (shape.constructorName != null && name == shape.constructorName)
			Constructor
		else if (isAccessor(name, shape))
			Accessor
		else if (isStatic)
			(isPublic ? StaticPublicMethod : StaticPrivateMethod)
		else
			(isPublic ? PublicMethod : PrivateMethod);
	}

	/**
	 * The canonical-order rank of a FIELD: mutability splits stored fields, and a span present in
	 * the accessor map marks the declaration as a property slot ranked by its getter/read-only form.
	 */
	private static function fieldRankOf(
		node: QueryNode, isStatic: Bool, isPublic: Bool, accessors: Map<Int, Bool>, shape: RefShape
	): MemberRank {
		final mutable: Bool = (shape.mutableFieldDeclKinds ?? []).contains(node.kind);
		if (isStatic)
			return !mutable
				? (isPublic ? StaticPublicImmutableField : StaticPrivateImmutableField)
				: (isPublic ? StaticPublicMutableField : StaticPrivateMutableField);
		final span: Null<Span> = node.span;
		if (span == null || !accessors.exists(span.from))
			return !mutable
				? (isPublic ? PublicImmutableField : PrivateImmutableField)
				: (isPublic ? PublicMutableField : PrivateMutableField);
		final getter: Bool = accessors[span.from] == true;
		return isPublic
			? (getter ? PublicGetterProperty : PublicReadOnlyProperty)
			: (getter ? PrivateGetterProperty : PrivateReadOnlyProperty);
	}

	/** Whether `name` begins with a property-accessor prefix (`get_` / `set_`). */
	private static function isAccessor(name: String, shape: RefShape): Bool {
		for (prefix in shape.accessorMethodPrefixes ?? []) if (name.startsWith(prefix)) return true;
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
		final inlineKind: Null<String> = shape.inlineModifierKind;
		var isStatic: Bool = false;
		var isPublic: Bool = false;
		var isInline: Bool = false;
		inline function resetModifiers(): Void {
			isStatic = false;
			isPublic = false;
			isInline = false;
		}
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
				resetModifiers();
			} else if (members.contains(child.kind)) {
				pushMember(out, child, parent, source, shape, comments, condStack, outerCond, isStatic, isPublic, isInline, accessors);
				resetModifiers();
			} else {
				if (staticKind != null && child.kind == staticKind) isStatic = true;
				if (inlineKind != null && child.kind == inlineKind) isInline = true;
				if (visibility.contains(child.kind)) {
					final s: Null<Span> = child.span;
					if (s != null && source.substring(s.from, s.to).trim() != defaultVis) isPublic = true;
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
		final childSpan: Null<Span> = firstChild?.span;
		final childFrom: Int = childSpan != null ? childSpan.from : span.to;
		final nl: Int = source.indexOf('\n', condStart);
		final lineEnd: Int = nl < 0 ? span.to : nl;
		final condEnd: Int = childFrom < lineEnd ? childFrom : lineEnd;
		if (condEnd <= condStart) return null;
		final raw: String = source.substring(condStart, condEnd).trim();
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
		if (!cond.startsWith('(') || !cond.endsWith(')')) return false;
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

	/** Build and push the `OrderedMember` for member `child` of `parent`, ranked under the running modifier flags and the `condStack` condition. */
	private static function pushMember(
		out: Array<OrderedMember>, child: QueryNode, parent: QueryNode, source: String, shape: RefShape,
		comments: Array<{ from: Int, to: Int, isLine: Bool }>, condStack: Array<String>, outerCond: Null<Span>, isStatic: Bool,
		isPublic: Bool, isInline: Bool, accessors: Map<Int, Bool>
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
			isInline: isInline,
			initNode: isField && child.children.length > 0 ? child.children[0] : null,
			condition: condStack.length == 0 ? null : joinConds(condStack),
			branch: null,
			regionFrom: region.from,
			regionTo: region.to,
			leadTrivia: '',
			leadFrom: full.from
		});
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
		if (condition == null || !isFlatBranchSet(out, firstIdx, condition)) {
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
			final line: String = source.substring(pos, end).trim();
			for (k in keywords) if (line.startsWith(k)) {
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

	/** Whether `out[firstIdx...]` is ONE flat, single-section branch set: no member under a nested conditional, none already branched, none whose rank crosses into another section. */
	private static function isFlatBranchSet(out: Array<OrderedMember>, firstIdx: Int, condition: Null<String>): Bool {
		for (i in firstIdx ... out.length) if (out[i].branch != null || out[i].condition != condition) return false;
		return true;
	}

}
