package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;

/**
 * The declarations whose leading run carries ONE NAMED annotation, asked ACROSS a
 * conditional-compilation region:
 *
 * ```haxe
 * @:op(A == B) #if (haxe_ver >= 4.2) extern #else @:extern #end
 * private static function srNull(a: DT, b: Null<Float>): Bool return false;
 * ```
 *
 * An operator overload's arity is dictated by the OPERATOR, so an ignored operand is mandated
 * rather than dead - and nothing NAMES such a method, so `unused-parameter`'s in-file call-set
 * proof completes on ZERO call sites and hands the removal a `Warning`. `--fix` then took the
 * two-operand signature down to one and the build failed with `Static @:op functions must accept
 * exactly two arguments`. The projection is right - `MetaCall`, `Conditional`, `Private`,
 * `Static`, `FnMember` are five siblings of the type body - but a leading run walked without the
 * region as a seam reads every member of the cross-version `extern` idiom as unannotated.
 *
 * The UNNAMED question this file also used to answer - "does ANY annotation precede this member",
 * the one `unused-private` consumed - now belongs to the grammar's own
 * `NamedDecl.implicitReach`, whose run walk crosses the seam in both directions. That is one
 * question with one answer; this file keeps only the NAME-FILTERED one, which no reachability
 * mechanism can express: exempting every annotated method's parameters is a far wider rule
 * than exempting an operator overload's operands.
 *
 * The walk is told which declarations it walks between (`memberStarts` / `typeStarts`) rather than
 * knowing only about members, because that is what decides where a run ENDS. `unused-private`
 * reads the type-scope answer for a class's `@:build` / `@:keep`, which it used to answer with a
 * private third copy of this walk that had no region seam at all: a member-free `#if` between the
 * annotation and the class then dropped the whole class's protection and `--fix` deleted its
 * privates.
 *
 * A region is a SEAM in the run, not a member of it. Annotations it carries in its own branches
 * are NOT counted - `#if x extern #else @:extern #end` says nothing about the declaration that
 * follows it. A region that HOLDS one of the walked declarations DOES end the run, since an
 * annotation written before it belongs to that declaration rather than to the next one.
 *
 * Grammar-agnostic: a grammar with no conditional-region kind, no annotation kinds, no declaration
 * kinds at the requested scope, or no name to filter on gets an empty answer - which is what its
 * own projection already returns.
 */
@:nullSafety(Strict)
final class AnnotatedDeclScan {

	/** Whether `span` starts one of `starts` — the exemption test a rule shares with the walk. */
	public static inline function covers(span: Null<Span>, starts: Array<Int>): Bool {
		return span != null && starts.contains(span.from);
	}

	/**
	 * The span starts of every MEMBER declaration in `tree` whose leading run carries the `metaName`
	 * annotation; empty when the grammar names none. Span starts, not nodes: a check parses
	 * INDEPENDENTLY in `run` and in `fix`, so a node from one walk is never the node from the other.
	 */
	public static function memberStarts(plugin: GrammarPlugin, tree: QueryNode, metaName: Null<String>): Array<Int> {
		return startsOf(plugin, tree, oneOf(metaName), plugin.refShape().memberDeclKinds ?? []);
	}

	/**
	 * The same answer one scope out: the span starts of every TYPE declaration in `tree` whose
	 * leading run carries `metaName`. A type's run is ended by a type and a member's by a member —
	 * one walk, told which declarations it is walking between.
	 */
	public static function typeStarts(plugin: GrammarPlugin, tree: QueryNode, metaName: Null<String>): Array<Int> {
		return startsOf(plugin, tree, oneOf(metaName), plugin.refShape().typeDeclKinds ?? []);
	}

	/**
	 * `typeStarts` for a SEAM that names several annotations at once — the span starts of every TYPE
	 * declaration whose leading run carries ANY of `metaNames` (`RefShape.typeBuildMacroMetaNames`
	 * is the one such seam: three spellings of "a macro generates this type's members"). One walk
	 * over the tree, not one per name, and the same empty answer for a grammar that declares none.
	 */
	public static function typeStartsAny(plugin: GrammarPlugin, tree: QueryNode, metaNames: Null<Array<String>>): Array<Int> {
		return startsOf(plugin, tree, metaNames ?? [], plugin.refShape().typeDeclKinds ?? []);
	}

	/** A single seam name as the name SET the walk reads; an unset seam is the empty set. */
	private static inline function oneOf(metaName: Null<String>): Array<String> {
		return metaName == null ? [] : [metaName];
	}

	/** The shared resolution: `decls` names the declarations whose leading runs this walk reads. */
	private static function startsOf(plugin: GrammarPlugin, tree: QueryNode, metaNames: Array<String>, decls: Array<String>): Array<Int> {
		final shape: RefShape = plugin.refShape();
		final condKind: Null<String> = shape.conditionalMemberKind;
		final metas: Array<String> = plugin.metaShape().metaKinds;
		final out: Array<Int> = [];
		if (decls.length == 0 || condKind == null || metas.length == 0 || metaNames.length == 0) return out;
		final cond: String = condKind;
		collect(tree, {
			decls: decls,
			condKind: cond,
			metas: metas,
			metaNames: metaNames,
			modifiers: CheckScan.modifierKinds(shape)
		}, out, false);
		return out;
	}

	/**
	 * Walk `node`'s children in source order, pushing every `seams.decls` declaration whose contiguous
	 * leading run carries one of `seams.metaNames`. `seams.modifiers` and the annotations themselves do NOT
	 * end that run, and any other kind ends it — so an annotation written for one declaration cannot
	 * reach the next. A conditional region is the exception: one holding none of `seams.decls` is
	 * transparent and the run continues past it, one HOLDING one takes the run with it (`seed`) and
	 * ends it, the annotation belonging to that declaration.
	 *
	 * Which declarations end the run is therefore `seams.decls` and nothing else — a type run is
	 * ended by a type, a member run by a member. Asking the member question at type scope let an
	 * annotation step over a member-free `#if class Holder {} #end` onto the NEXT type.
	 *
	 * `seed` is that carried run, and it does NOT expire on the first declaration inside the region:
	 * the projection flattens `#if` / `#elseif` / `#else` into one child list with no branch marker,
	 * so the second declaration there may be the `#else` twin of the first rather than a sibling that
	 * took the annotation. Expiring it dropped the `#else` member of an `@:keep`-ed region out of the
	 * exemption; carrying it at worst exempts a second member of the SAME branch.
	 */
	private static function collect(node: QueryNode, seams: Seams, out: Array<Int>, seed: Bool): Void {
		var annotated: Bool = seed;
		for (child in node.children) {
			final kind: String = child.kind;
			if (seams.metas.contains(kind)) {
				final name: Null<String> = child.name;
				if (name != null && seams.metaNames.contains(name)) annotated = true;
				continue;
			}
			if (kind == seams.condKind) {
				final owns: Bool = holdsDecl(child, seams.decls);
				collect(child, seams, out, owns && annotated);
				if (owns) annotated = seed;
				continue;
			}
			if (seams.decls.contains(kind)) {
				final span: Null<Span> = child.span;
				if (annotated && span != null) out.push(span.from);
				annotated = seed;
			} else if (!seams.modifiers.contains(kind))
				annotated = seed;
			collect(child, seams, out, false);
		}
	}

	/** Whether `region` holds one of `decls` in any branch, at any nesting depth. */
	private static function holdsDecl(region: QueryNode, decls: Array<String>): Bool {
		return region.children.exists(child -> decls.contains(child.kind) || holdsDecl(child, decls));
	}

}

/**
 * The resolved seams the declaration walk threads through every frame — read once per tree.
 */
private typedef Seams = {

	/** The declaration kinds this walk reads the leading runs of (`RefShape.memberDeclKinds` / `typeDeclKinds`). */
	final decls: Array<String>;

	/** The conditional-compilation region kind (`RefShape.conditionalMemberKind`). */
	final condKind: String;

	/** The annotation kinds (`MetaShape.metaKinds`). */
	final metas: Array<String>;

	/** The annotation names that count — one for a single-name seam, several for `typeStartsAny`. */
	final metaNames: Array<String>;

	/** The modifier kinds a declaration's leading run may hold; any other kind ENDS the run. */
	final modifiers: Array<String>;
};
