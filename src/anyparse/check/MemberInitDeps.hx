package anyparse.check;

import anyparse.check.MemberOrder.OrderedMember;
import anyparse.query.GrammarPlugin;
import anyparse.query.OccurrenceScan;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * One member pair whose CURRENT relative order the init phase fixes: `before` must keep running
 * before `after`, and `kind` names the dependency that says so.
 */
typedef InitOrderConstraint = {
	var before: OrderedMember;
	var after: OrderedMember;
	var kind: InitConstraintKind;
}

/**
 * The INITIALIZER-DEPENDENCY layer of `member-order`: the one reason a reorder of a type's
 * members can change behaviour, asked as three questions and nothing else.
 *
 * Field initializers run in declaration order - statics at class-load, instance fields in the
 * constructor, two independent phases - so moving a member past another is observable exactly
 * when one of them initializes a field whose initializer has a side effect, or reads a
 * same-phase sibling. Everything here answers some form of that, and everything here reads the
 * same three things to do it: a member's `initNode` / `isField` / `isStatic` / `isInline`, the
 * container's source text, and the grammar `RefShape` naming the node kinds an initializer may
 * not contain. Nothing here reads a rank, a section, a sort plan, a `#if` condition or a
 * directive - which is what makes it a layer below both of `MemberOrder`'s families rather
 * than a third family beside them.
 *
 * Three unrelated callers, one per path, which is the other half of the same evidence: the
 * REPORT path asks `initReadsSibling` for the one pair it must skip, the PLAN path asks
 * `blockInitInert` whether a conditional block may take a content rank, and the FIX path asks `orderConstraints`
 * which member pairs the init phase pins in their current relative order. None of them reads config, so the
 * gates cannot disagree - `MemberOrder`'s standing requirement, and the reason the shared
 * `unsafeInitKinds` list lives here as ONE list rather than once per caller.
 *
 * Split out of `MemberOrder`, which keeps the ordering model itself (ranks, sections, the sort
 * plan, the conditional-region rebuild), as `MemberSlots` earlier took the collection half.
 */
@:nullSafety(Strict)
final class MemberInitDeps {

	/**
	 * Whether no field initializer ties `block` to a position in the container. Refuses in BOTH
	 * directions: a field inside the block whose initializer has a side effect (call / allocation /
	 * assignment) or reads another field of the container, and a field OUTSIDE the block whose
	 * initializer reads a field inside it - moving the block would then change what an initializer
	 * sees. Deliberately independent of the `movableArglessNew` option, since `compareOrder` is
	 * shared by the report path, which resolves no per-file config.
	 */
	public static function blockInitInert(block: Array<OrderedMember>, all: Array<OrderedMember>, shape: RefShape, source: String): Bool {
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

	/**
	 * Every member pair whose CURRENT relative order the init phase fixes, so a reorder can be built
	 * as a linear extension of them instead of being refused whole. Two kinds, the same two questions
	 * the flip bails used to ask of one candidate permutation: a field initializer that READS a
	 * same-phase sibling (`SiblingRead`), and a side-effecting field initializer beside another
	 * INITIALIZED non-inline field of the same phase (`SideEffect`). Exempt as partners in both: an
	 * init-less field (it contributes no code to the init phase) and an `inline` field (this
	 * grammar's language requires an inline variable's initializer to be a constant, so it is folded
	 * at compile time - a grammar supplying `inlineModifierKind` without that guarantee must not
	 * share the exemption). Under `movableArglessNew` a pure argless-`new` allocation is not counted
	 * side-effecting (see `sideEffecting`).
	 *
	 * Neither question asks where the pair would END UP - `before` and `after` are the pair's own
	 * source positions - which is what makes the answer permutation-independent, the sort's INPUT
	 * rather than its judge.
	 *
	 * `SiblingRead` pairs are emitted FIRST because the caller names its decline after the first
	 * constraint holding the reported member: a field that reads its sibling almost always also
	 * carries a call, so the coarser sentence would otherwise be told for a member whose real
	 * constraint is a NAMED dependency on the field above it.
	 */
	public static function orderConstraints(
		members: Array<OrderedMember>, shape: RefShape, source: String, movableArglessNew: Bool
	): Array<InitOrderConstraint> {
		final out: Array<InitOrderConstraint> = [
			for (m in members) for (g in members) if (initReadsSibling(m, g, source)) constraintOf(m, g, SiblingRead)
		];
		final unsafe: Array<String> = unsafeInitKinds(shape);
		final fields: Array<OrderedMember> = [for (m in members) if (m.isField) m];
		for (f in fields)
			if (sideEffecting(f, unsafe, shape, source, movableArglessNew))
				for (g in fields)
					if (g.node != f.node && f.isStatic == g.isStatic && g.initNode != null && !g.isInline)
						out.push(constraintOf(f, g, SideEffect));
		return out;
	}

	/**
	 * Whether `owner`'s field initializer READS the sibling field `target` — the one dependency a
	 * member order can carry, since a same-phase field initialized from another one must run
	 * after it.
	 *
	 * The single answer to that question, asked from both paths: the fix path's
	 * `orderConstraints` turns it into an EDGE the reorder must respect, and
	 * `firstOutOfOrder` pairs it with adjacency to drop ONE report. Neither reads config, so the
	 * two gates cannot disagree — the class doc's standing requirement.
	 *
	 * `target` must be an initialized, NON-inline field of the same static phase: an `inline`
	 * constant is substituted at compile time and has no initialization order to violate, an
	 * uninitialized field cannot be read too early, and a static and an instance field never
	 * share an initialization phase. The read test is a word-boundary occurrence scan over
	 * `owner`'s initializer span — the same conservative scan the fix path always used.
	 */
	public static function initReadsSibling(owner: OrderedMember, target: OrderedMember, source: String): Bool {
		final init: Null<QueryNode> = owner.initNode;
		if (init == null) return false;
		final span: Null<Span> = init.span;
		final name: Null<String> = target.node.name;
		return span != null && name != null && target.isField && !target.isInline && target.initNode != null && target.node != owner.node
			&& target.isStatic == owner.isStatic && OccurrenceScan.referencedInRange(source, name, span.from, span.to, []);
	}

	/** The pair as a constraint, oriented by CURRENT source position - the order the sort must keep. */
	private static inline function constraintOf(a: OrderedMember, b: OrderedMember, kind: InitConstraintKind): InitOrderConstraint {
		return a.index < b.index ? { before: a, after: b, kind: kind } : { before: b, after: a, kind: kind };
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

	/**
	 * The node kinds whose presence in a field initializer makes its position observable - an assignment, a call, an allocation. One
	 * list, two consumers (`orderConstraints` and `blockInitInert`), so the pair constraint and the block gate cannot drift apart.
	 */
	private static function unsafeInitKinds(shape: RefShape): Array<String> {
		final kinds: Array<String> = shape.writeParentKinds.copy();
		if (shape.callKind != null) kinds.push(shape.callKind);
		if (shape.newExprKind != null) kinds.push(shape.newExprKind);
		return kinds;
	}

	/** Whether `node`'s subtree contains a node of any kind in `kinds`. */
	private static function subtreeContainsAny(node: QueryNode, kinds: Array<String>): Bool {
		return kinds.contains(node.kind) || node.children.exists(c -> subtreeContainsAny(c, kinds));
	}

	/**
	 * Whether `init` (the initializer of field `owner`) textually reads the name of another
	 * SAME-PHASE field in `fields` - statics initialise at class-load and instance fields in the
	 * constructor, so a cross-phase read can never observe declaration order, the same phase gate
	 * `initReadsSibling` applies. The scan is a raw identifier-boundary read, so within a phase it
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
				&& OccurrenceScan.referencedInRange(source, name, span.from, span.to, [])
			)
				return true;
		}
		return false;
	}

}

/** Which initializer dependency pins an `InitOrderConstraint`'s pair in its current order. */
enum abstract InitConstraintKind(Int) {

	/** One of the pair's initializers READS the other field, so swapping them changes what it sees. */
	final SiblingRead = 0;

	/** One of the pair initializes with a side effect, so swapping them runs the two in the other order. */
	final SideEffect = 1;

}
