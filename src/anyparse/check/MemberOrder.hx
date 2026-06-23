package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * One type-member paired with its canonical-order rank and its full source slot
 * (leading doc + modifier/`@:meta` run + decl), for the order check and the
 * reordering autofix.
 */
typedef OrderedMember = {
	var node: QueryNode;
	var rank: Int;
	var index: Int;
	var span: Span;
	var isField: Bool;
	var initNode: Null<QueryNode>;
}

/**
 * Flags a type whose members are not in the canonical declaration order and
 * reorders them. Purely cosmetic (the order carries no meaning to the compiler), so
 * `Severity.Info`; the sibling of `modifier-order` one level up — where that orders
 * the keywords of one member, this orders the members of one type. The order:
 *
 *   1. constants (static fields) — public, then private
 *   2. instance fields — public final, public var, private final, private var
 *   3. constructor
 *   4. property accessors (`get_*` / `set_*`)
 *   5. instance methods — public, then private
 *   6. static methods — public, then private
 *
 * ## Grammar-agnostic
 *
 * Every category test is a `RefShape` kind-set / text comparison: container kinds,
 * member kinds, the field subset and its mutable (`var`) subset, the visibility
 * modifiers (a member is public when a visibility modifier's text differs from the
 * default), the `static` modifier, the constructor name, and the accessor prefixes.
 * Any required field unset makes the check a no-op.
 *
 * ## Autofix soundness — field init order is preserved
 *
 * Reordering METHODS is always safe (declaration order never affects behaviour).
 * Reordering FIELDS is NOT: a field initializer runs in declaration order, so moving
 * one past another can change the order of its side effects or read a sibling field
 * before it is initialized — a silent behaviour change the compiler will not catch.
 * The autofix therefore BAILS the whole container (report-only) when any field has an
 * initializer that is not side-effect-free, or that references a sibling field name.
 * Otherwise the members are reordered by replacing each source slot with the member
 * now ranked for it (the `modifier-order` slot-permutation, at member granularity),
 * so inter-member trivia keeps its position and the writer re-canonicalises spacing.
 */
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
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
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
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
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
			final bad: Null<OrderedMember> = firstOutOfOrder(members);
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
	 * Emit the slot-permutation edits for `container` when its first out-of-order
	 * member is flagged and its fields are reorder-safe: stable-sort the members by
	 * rank and replace each source slot with the member now ranked for it.
	 */
	private static function emitReorder(
		edits: Array<{ span: Span, text: String }>, source: String, container: QueryNode, shape: RefShape, flagged: Array<Int>
	): Void {
		final members: Array<OrderedMember> = collectMembers(container, source, shape);
		if (members.length < 2) return;
		final bad: Null<OrderedMember> = firstOutOfOrder(members);
		if (bad == null || !flagged.contains(bad.span.from)) return;
		final sorted: Array<OrderedMember> = members.copy();
		sorted.sort((a, b) -> a.rank != b.rank ? a.rank - b.rank : a.index - b.index);
		if (!reorderSafe(members, sorted, source, shape)) return;
		for (i in 0...members.length) if (members[i].node != sorted[i].node)
			edits.push({ span: members[i].span, text: source.substring(sorted[i].span.from, sorted[i].span.to) });
	}

	/**
	 * Collect `container`'s direct members in source order, each with its rank and
	 * full slot span. The modifier / `@:meta` siblings preceding a member set its
	 * `static` and public flags (public = a visibility modifier whose text differs
	 * from the default); both reset at each member.
	 */
	private static function collectMembers(container: QueryNode, source: String, shape: RefShape): Array<OrderedMember> {
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final fields: Array<String> = shape.fieldDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final staticKind: Null<String> = shape.staticModifierKind;
		final defaultVis: String = shape.defaultVisibilityModifierText ?? '';
		final out: Array<OrderedMember> = [];
		var isStatic: Bool = false;
		var isPublic: Bool = false;
		for (child in container.children) {
			if (members.contains(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null) {
					final group: Span = RefactorSupport.declGroupSpan(child, container, span);
					final full: Span = RefactorSupport.docExtendedSpan(source, group);
					final isField: Bool = fields.contains(child.kind);
					out.push({
						node: child,
						rank: rankOf(child, isStatic, isPublic, isField, shape),
						index: out.length,
						span: full,
						isField: isField,
						initNode: isField && child.children.length > 0 ? child.children[0] : null
					});
				}
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
		return out;
	}

	/** The canonical-order rank of a member given its static / public flags and whether it is a field. */
	private static function rankOf(node: QueryNode, isStatic: Bool, isPublic: Bool, isField: Bool, shape: RefShape): Int {
		if (isField) {
			if (isStatic) return isPublic ? 0 : 1;
			final mutable: Bool = (shape.mutableFieldDeclKinds ?? []).contains(node.kind);
			if (!mutable) return isPublic ? 2 : 4;
			return isPublic ? 3 : 5;
		}
		final name: String = node.name ?? '';
		if (shape.constructorName != null && name == shape.constructorName) return 6;
		if (isAccessor(name, shape)) return 7;
		if (isStatic) return isPublic ? 10 : 11;
		return isPublic ? 8 : 9;
	}

	/** Whether `name` begins with a property-accessor prefix (`get_` / `set_`). */
	private static function isAccessor(name: String, shape: RefShape): Bool {
		for (prefix in shape.accessorMethodPrefixes ?? []) if (StringTools.startsWith(name, prefix)) return true;
		return false;
	}

	/** The first member whose rank is below a preceding member's — the order break — or null when sorted. */
	private static function firstOutOfOrder(members: Array<OrderedMember>): Null<OrderedMember> {
		var maxRank: Int = -1;
		for (m in members) {
			if (m.rank < maxRank) return m;
			maxRank = m.rank;
		}
		return null;
	}

	/**
	 * Whether reordering `members` cannot change behaviour: every field with an
	 * initializer is side-effect-free AND references no sibling field name, so its
	 * declaration order is immaterial. Methods are always safe.
	 */
	private static function reorderSafe(members: Array<OrderedMember>, sorted: Array<OrderedMember>, source: String, shape: RefShape): Bool {
		// Reordering changes behaviour only via FIELD initializers (they run in
		// declaration order — the constructor for instance fields, static-init for
		// statics; method order is immaterial).
		//
		// (0) Orphan trivia between two member slots (a `//` note, a trailing comment)
		// belongs to no slot and would be left behind while members move around it, so
		// any non-whitespace gap bails the container (report-only). Leading `/**` docs
		// are absorbed into the following slot by `docExtendedSpan` and travel with it.
		for (i in 0...members.length - 1) {
			final gapFrom: Int = members[i].span.to;
			final gapTo: Int = members[i + 1].span.from;
			if (gapTo > gapFrom && StringTools.trim(source.substring(gapFrom, gapTo)) != '') return false;
		}
		// (1) A side-effecting field init (a call / `new` / assignment) can read or
		// mutate ANY other field, so it must keep its relative order to EVERY field —
		// not merely to other side-effecting ones (the dependency can flow through the
		// callee, invisible to a text scan).
		final unsafe: Array<String> = shape.writeParentKinds.copy();
		if (shape.callKind != null) unsafe.push(shape.callKind);
		if (shape.newExprKind != null) unsafe.push(shape.newExprKind);
		final fields: Array<OrderedMember> = [for (m in members) if (m.isField) m];
		for (f in fields) if (sideEffecting(f, unsafe)) for (g in fields) if (g.node != f.node && orderFlips(f, g, sorted)) return false;
		// (2) A field whose init TEXT reads a sibling field must keep its relative order
		// to that sibling (the read-after-init order).
		for (m in members) {
			final init: Null<QueryNode> = m.initNode;
			if (init == null) continue;
			final s: Null<Span> = init.span;
			if (s == null) continue;
			for (g in members)
				if (g.isField && g.node != m.node && g.node.name != null && RefactorSupport.referencedInRange(
					source, (g.node.name: String), s.from, s.to, []
				) && orderFlips(m, g, sorted)) return false;
		}
		return true;
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

}
