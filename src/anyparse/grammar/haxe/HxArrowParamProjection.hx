package anyparse.grammar.haxe;

import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * Re-projects the PARAMETER a bare arrow lambda hides.
 *
 * `(q: Int) -> q > 0` and `function(q) return q > 0` route their parameter through
 * `HxLambdaParam` / `HxParam`, so it reaches the query tree as a `Required` node — a
 * `HaxeQueryPlugin.DECL_HOST_KINDS` entry, i.e. a binder. The bare spelling `q -> q > 0`
 * does not: `HxExpr.ThinArrow` is an ordinary right-associative Pratt infix operator whose
 * BOTH operands are typed `HxExpr`, so the parameter arrives as a plain `IdentExpr` and
 * `Refs` reads it as a reference to whatever encloses the lambda.
 *
 * That asymmetry is a WRITER decision (the infix path already emits ` -> ` and needs no
 * paren-lambda machinery for the one-parameter form), and it must not be a RESOLVER one.
 * Left alone it was silent in three ways at once:
 *
 *  - `refs q` reported the parameter as a `Read` bound to an enclosing `q`, and the body's
 *    read bound there too — so a lambda that shadows an outer local looked like two extra
 *    uses of it;
 *  - `rename` on that outer binding rewrote the parameter and its body reads along with it,
 *    and a `--scope` rename of a FIELD did so to every same-named arrow parameter in reach;
 *  - `rename` addressed AT the parameter renamed the outer binding and every use of it
 *    instead. All three re-parse and still compile, so the re-parse gate cannot see them.
 *
 * The fix belongs here rather than in each consumer — `Refs` is the resolver behind
 * `shadowing-local`, `join-override-chain`, `prefer-switch-expression-assignment` and
 * `try-catch-null-guard`, and `TrivialGetter` had already grown a private `case 'ThinArrow'`
 * arm reading `children[0]` for exactly this. One pass over the query tree replaces that
 * `IdentExpr` with the same `Required` node the parenthesised form produces, so nothing
 * downstream has to learn that arrows exist.
 *
 * The parameter's SCOPE is the other half and lives in the plugin's vocabulary:
 * `ThinArrow` joins `POSITION_SCOPED_SCOPE_KINDS` beside `ThinParenLambdaExpr` /
 * `ParenLambdaExpr` / `FnExpr`, so the binding is confined to the lambda and a read after
 * `->`'s body still resolves outward.
 *
 * Spans stay RAW-source offsets: the synthesized node covers the same bytes the `IdentExpr`
 * did, so `--at`, `--select` and every span-driven edit address real source. Only the query
 * tree is rewritten — the writer runs off the parse AST, which is untouched, so formatting
 * stays byte-exact.
 *
 * ## What is NOT re-projected
 *
 * A `ThinArrow` whose left operand is anything but a bare `IdentExpr` is left alone. Haxe
 * spells no such lambda — every other parameter shape goes through the parenthesised form —
 * so the node is either inside a construct this grammar parses permissively or not a lambda
 * at all, and inventing a binder there would bind a name the compiler never binds. The
 * `ThinArrow` scope frame still opens for it; for `Refs` an empty frame resolves outward
 * exactly as no frame would (`ScopeStack.resolveInnermost` walks past it, and
 * `currentPositionScoped` answers what the enclosing frame did).
 *
 * The CONVERSE is an assumption, not a proof: a bare-identifier left operand is taken to BE
 * a lambda parameter. Haxe offers no other reading in expression position — but a metadata
 * ARGUMENT is not expression position in that sense, which is why `walk` skips annotations
 * outright rather than filtering them here.
 *
 * `scopeKinds` has one consumer that does not share `Refs`' reading of an empty frame:
 * `ScopeFrames.childScopeNames` RESETS the visible-name set at any `scopeKinds` child, so a
 * `ThinArrow` now resets it where the enclosing frame used to pass through. Inert by
 * construction rather than by measurement — its only consumers (`redundant-else`,
 * `guard-return`) hoist into a statement list, and every Haxe statement-list kind is itself
 * position-scoped, so the set at every hoist target was already empty.
 */
@:nullSafety(Strict)
final class HxArrowParamProjection {

	/** The query-tree kind of the bare `arg -> body` lambda — `HxExpr.ThinArrow`, a Pratt infix ctor. */
	private static inline final ARROW_KIND: String = 'ThinArrow';

	/** The kind the parameter arrives as: an ordinary identifier reference. */
	private static inline final IDENT_KIND: String = 'IdentExpr';

	/**
	 * The kind it leaves as — `HxLambdaParam.Required`, the very ctor the parenthesised
	 * form spells its parameters on. Reusing it rather than minting a kind of this pass's
	 * own is what makes the two spellings indistinguishable to every consumer, which is the
	 * whole point: `Required` is already in `DECL_HOST_KINDS` and in `RefShape.paramKinds`.
	 */
	private static inline final PARAM_KIND: String = 'Required';

	/**
	 * The annotation kinds this pass refuses to descend into — `HaxeQueryPlugin.metaShape`'s
	 * `metaKinds`, restated here the way `HxInterpProjection` restates its own three kinds:
	 * a projection runs statically, with no plugin instance to ask.
	 */
	private static final META_KINDS: Array<String> = ['MetaCall', 'Meta', 'PlainMeta'];

	/**
	 * Rewrite every bare-identifier `ThinArrow` parameter in `tree` into a `Required` binder.
	 * Mutates in place — `QueryNode.children` is the array the walker just built, so the pass
	 * allocates one node per arrow lambda and nothing else.
	 *
	 * Skipped whole for a source with no `->` at all: without the operator the grammar can
	 * emit no `ThinArrow`, and the walk would visit every node to learn that.
	 */
	public static function reproject(tree: QueryNode, source: String): Void {
		if (source.indexOf('->') < 0) return;
		walk(tree);
	}

	/** Depth-first walk re-projecting each bare arrow lambda's parameter slot.
	 *
	 * An ANNOTATION's arguments are not descended into. `@:foo(A -> B)` parses as
	 * `MetaCall(@:foo, ThinArrow(IdentExpr A, IdentExpr B))` - a metadata argument is an
	 * unevaluated expression handed to a macro, and `A` there names nothing the compiler
	 * binds. Manufacturing a binder for it was not merely inert: `Required` is a
	 * `HaxeNamingSupport` PARAMETER category, so `naming` began reporting the annotation's
	 * own text and `--fix` rewrote `@:foo(A -> B)` to `@:foo(a -> B)` - measured, and the
	 * shape `@:op(A * B)` sits one operator away from a contract-bearing spelling. Skipping
	 * the subtree leaves annotations exactly as they were before this pass existed.
	 *
	 * Only the annotation node is skipped, never its host: `@:baz(P -> Q) var v = 1;`
	 * projects `MetaExpr(MetaCall(..), VarExpr v ..)` with the two as SIBLINGS, so the
	 * declaration it decorates is still walked.
	 *
	 * A `macro { .. }` reification needs no stop here: `Refs` already treats an `opaqueKinds`
	 * subtree as emitted code rather than references, and `naming` carries its own
	 * reification gate - verified silent on `macro A -> A + 1`. */
	private static function walk(node: QueryNode): Void {
		if (META_KINDS.contains(node.kind)) return;
		if (node.kind == ARROW_KIND) rebind(node);
		for (c in node.children) walk(c);
	}

	/**
	 * Replace `node`'s left operand with the binder it spells, when it spells one.
	 *
	 * The replacement carries the identifier's own span, children and declared-type slot over
	 * verbatim: it IS the same source token, re-labelled.
	 *
	 * The null-name / null-span guards buy nothing semantically — `Refs.walkMulti` tests both
	 * slots BEFORE it classifies anything, so an unspanned or unnamed node is invisible to it
	 * in either shape. They are kept because a projection must not construct a `QueryNode` it
	 * cannot address.
	 */
	private static function rebind(node: QueryNode): Void {
		final children: Array<QueryNode> = node.children;
		if (children.length == 0) return;
		final left: QueryNode = children[0];
		if (left.kind != IDENT_KIND) return;
		final name: Null<String> = left.name;
		final span: Null<Span> = left.span;
		if (name == null || span == null) return;
		children[0] = new QueryNode(PARAM_KIND, name, left.children, span, left.type);
	}

}
