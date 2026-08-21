package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * The members whose leading run carries an annotation, asked ACROSS a conditional-compilation
 * region — the one seam the grammar's own `NamedDecl.implicitlyReachable` cannot cross:
 *
 * ```haxe
 * @:op(A << B) #if (haxe_ver >= 4.2) extern #else @:extern #end
 * private inline function add_op(listener: Listener0): Signal0 return add(listener);
 * ```
 *
 * The projection is right — `MetaCall`, `Conditional`, `Private`, `Inline`, `FnMember` are five
 * siblings of the class body — but the walk that answers "does an annotation precede this member"
 * accepts only modifier kinds between the two and stops at the region. Every member written in the
 * cross-version `extern` idiom therefore reads as unannotated, and `unused-private` deleted six of
 * `pony/events/Signal0.hx`'s operator overloads plus its `@:from` conversion. Nothing NAMES an
 * operator overload or an implicit conversion, so no reference scan can save one: `signal << listener`
 * then resolved to the builtin integer shift, and 77 of the wave's 82 compiler errors read
 * `pony.events.Signal0 should be Int`.
 *
 * A region is a SEAM in the run, not a member of it. Annotations it carries in its own branches are
 * NOT counted — `#if x extern #else @:extern #end` says nothing about reachability, and counting it
 * would exempt every `extern inline` private in the tree. A region that HOLDS a declaration DOES end
 * the run, since an annotation written before it belongs to that declaration rather than to the next
 * one.
 *
 * Grammar-agnostic: a grammar with no conditional-region kind, no annotation kinds or no
 * member-declaration kinds gets an empty answer — which is what its own projection already returns.
 */
@:nullSafety(Strict)
final class AnnotatedMemberScan {

	/** Whether `span` starts one of `starts` — the exemption test a member rule shares. */
	public static inline function covers(span: Null<Span>, starts: Array<Int>): Bool {
		return span != null && starts.contains(span.from);
	}

	/**
	 * The span starts of every member declaration in `tree` whose leading run carries an annotation —
	 * `metaName` when given, any annotation otherwise. Span starts, not nodes: a check parses
	 * INDEPENDENTLY in `run` and in `fix`, so a node from one walk is never the node from the other.
	 */
	public static function starts(plugin: GrammarPlugin, tree: QueryNode, ?metaName: String): Array<Int> {
		final shape: RefShape = plugin.refShape();
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final condKind: Null<String> = shape.conditionalMemberKind;
		final metas: Array<String> = plugin.metaShape().metaKinds;
		final out: Array<Int> = [];
		if (members.length == 0 || condKind == null || metas.length == 0) return out;
		final cond: String = condKind;
		collect(tree, {
			members: members,
			condKind: cond,
			metas: metas,
			metaName: metaName,
			modifiers: CheckScan.modifierKinds(shape)
		}, out, false);
		return out;
	}

	/**
	 * Walk `node`'s children in source order, pushing every member declaration whose contiguous
	 * leading run carries an annotation. `seams.modifiers` and the annotations themselves do NOT
	 * end that run, and any other kind ends it — so an annotation written for one declaration
	 * cannot reach the next. A conditional region is the exception the grammar's own walk gets
	 * wrong: one holding no member is transparent and the run continues past it, one HOLDING a
	 * member takes the run with it (`seed`) and ends it, the annotation belonging to that
	 * declaration.
	 */
	private static function collect(node: QueryNode, seams: Seams, out: Array<Int>, seed: Bool): Void {
		var annotated: Bool = seed;
		for (child in node.children) {
			final kind: String = child.kind;
			if (seams.metas.contains(kind)) {
				if (seams.metaName == null || child.name == seams.metaName) annotated = true;
				continue;
			}
			if (kind == seams.condKind) {
				final owns: Bool = holdsMember(child, seams.members);
				collect(child, seams, out, owns && annotated);
				if (owns) annotated = false;
				continue;
			}
			if (seams.members.contains(kind)) {
				final span: Null<Span> = child.span;
				if (annotated && span != null) out.push(span.from);
				annotated = false;
			} else if (!seams.modifiers.contains(kind))
				annotated = false;
			collect(child, seams, out, false);
		}
	}

	/** Whether `region` declares a member in any branch, at any nesting depth. */
	private static function holdsMember(region: QueryNode, members: Array<String>): Bool {
		return region.children.exists(child -> members.contains(child.kind) || holdsMember(child, members));
	}

}

/** The resolved seams the member walk threads through every frame — read once per tree. */
private typedef Seams = {

	/** The member-declaration kinds (`RefShape.memberDeclKinds`). */
	final members: Array<String>;

	/** The conditional-compilation region kind (`RefShape.conditionalMemberKind`). */
	final condKind: String;

	/** The annotation kinds (`MetaShape.metaKinds`). */
	final metas: Array<String>;

	/** The one annotation name that counts, or null when any annotation does. */
	final metaName: Null<String>;

	/** The modifier kinds a declaration's leading run may hold; any other kind ENDS the run. */
	final modifiers: Array<String>;
};
