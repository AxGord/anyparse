package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Rename;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The bare arrow lambda's parameter is a BINDER, not a read of the enclosing scope.
 *
 * `HxExpr.ThinArrow` is a Pratt infix ctor with two `HxExpr` operands, so `q -> q > 0`
 * reached the query tree as `ThinArrow(IdentExpr q, …)` while `(q: Int) -> q > 0` and
 * `function(q) return q > 0` reached it as a `Required` parameter node. `Refs` — the
 * resolver behind `refs`, `rename` and the `shadowing-local` /
 * `join-override-chain` / `prefer-switch-expression-assignment` / `try-catch-null-guard`
 * checks — therefore read the parameter as a reference to whatever enclosed the lambda,
 * and the body's read bound there too.
 *
 * `HxArrowParamProjection` re-labels that child `Required`, and `ThinArrow` joins
 * `POSITION_SCOPED_SCOPE_KINDS` so the binding is confined to the lambda.
 *
 * The rename half is pinned as well as the resolver half, because that is where the
 * blindness turned into silent corruption: both directions of the mis-binding re-parse
 * and still compile, so the mutation ops' re-parse gate could never have caught them.
 *
 * Pre-fix `testThinArrowParameterBindsLikeTheParenthesisedForm` reads
 * `decl read->0 read->0 read->0` instead of `decl decl read->1 read->0`; both rename
 * assertions come back with the lambda rewritten (or the enclosing local rewritten).
 */
class ThinArrowParamBindingSliceTest extends Test {

	/** One enclosing local `q`, one lambda whose parameter shadows it, one read of the local after it. */
	private static final SHADOWED: String =
		'class X {\n\tstatic function f():Void {\n\t\tvar q:Int = 1;\n\t\tvar g = q -> q > 0;\n\t\ttrace(q, g);\n\t}\n}';

	/**
	 * The bare `q ->` form binds exactly as the two spellings that always did.
	 *
	 * `decl decl read->1 read->0` reads: the enclosing local declares, the lambda parameter
	 * declares, the body's read resolves to the PARAMETER, and the read after the lambda
	 * resolves to the enclosing local. One signature for all three spellings is the whole
	 * claim — the asymmetry was that the first one answered differently.
	 */
	public function testThinArrowParameterBindsLikeTheParenthesisedForm(): Void {
		final expected: String = 'decl decl read->1 read->0';
		Assert.equals(expected, signature(findIn(SHADOWED, 'q')), 'bare `q -> …`');
		Assert.equals(expected, signature(findIn(lambda('(q:Int) -> q > 0'), 'q')), 'parenthesised `(q:Int) -> …`');
		Assert.equals(expected, signature(findIn(lambda('function(q) return q > 0'), 'q')), 'anonymous `function(q) …`');
	}

	/** The parameter reaches the tree on the same ctor the parenthesised form spells its own on. */
	public function testThinArrowParameterProjectsAsAParameterNode(): Void {
		final arrow: Null<QueryNode> = firstOfKind(new HaxeQueryPlugin().parseFile(SHADOWED), 'ThinArrow');
		Assert.notNull(arrow, 'fixture must contain a ThinArrow');
		if (arrow == null) return;
		Assert.equals('Required', arrow.children[0].kind);
		Assert.equals('q', arrow.children[0].name);
	}

	/**
	 * Currying binds each `->` separately: the innermost body read resolves to the INNER
	 * parameter, and the read after the lambda still reaches the enclosing local. The
	 * right-associative parse nests one `ThinArrow` inside the other, so a fix that opened
	 * one frame for the whole chain would bind the body to the outer parameter here.
	 */
	public function testCurriedThinArrowBindsEachParameterSeparately(): Void {
		Assert.equals('decl decl decl read->2 read->0', signature(findIn(lambda('q -> q -> q'), 'q')));
	}

	/**
	 * The parameter does NOT leak out of its lambda: with no enclosing declaration at all,
	 * the read after the lambda resolves to nothing rather than to the parameter.
	 */
	public function testThinArrowParameterDoesNotEscapeItsLambda(): Void {
		final source: String = 'class X {\n\tstatic function f():Void {\n\t\tvar g = q -> q > 0;\n\t\ttrace(q, g);\n\t}\n}';
		Assert.equals('decl read->0 read->-1', signature(findIn(source, 'q')));
	}

	/**
	 * Renaming the ENCLOSING local leaves the lambda verbatim. Pre-fix the parameter and its
	 * body read were occurrences of that local, so both were rewritten — consistently, hence
	 * still compiling, hence invisible to every gate.
	 */
	public function testRenamingTheEnclosingLocalLeavesTheLambdaVerbatim(): Void {
		final expected: String =
			'class X {\n\tstatic function f():Void {\n\t\tvar w:Int = 1;\n\t\tvar g = q -> q > 0;\n\t\ttrace(w, g);\n\t}\n}';
		assertRename(SHADOWED, 3, 3, 'w', expected);
	}

	/**
	 * Renaming AT the parameter renames the parameter. Pre-fix the cursor landed on an
	 * `IdentExpr` the resolver had bound to the enclosing local, so the op renamed THAT and
	 * every use of it across the function — and reported success.
	 */
	public function testRenamingTheThinArrowParameterLeavesTheEnclosingLocalVerbatim(): Void {
		final expected: String =
			'class X {\n\tstatic function f():Void {\n\t\tvar q:Int = 1;\n\t\tvar g = z -> z > 0;\n\t\ttrace(q, g);\n\t}\n}';
		assertRename(SHADOWED, 4, 11, 'z', expected);
	}

	/**
	 * A metadata ARGUMENT is not a lambda, however much `@:foo(A -> B)` looks like one: it is
	 * an unevaluated expression handed to a macro, and `A` names nothing the compiler binds.
	 * The projection skips annotations outright, so the operand keeps its `IdentExpr` kind.
	 *
	 * Without the skip this is not merely a spurious binding: `Required` is a
	 * `HaxeNamingSupport` parameter category, so `naming --fix` rewrote the annotation's own
	 * text — `@:foo(A -> B)` became `@:foo(a -> B)`. Only the annotation is skipped, never the
	 * declaration it decorates, which the second assertion pins.
	 */
	public function testAnnotationArgumentIsNotReprojected(): Void {
		final meta: Null<QueryNode> = firstOfKind(new HaxeQueryPlugin().parseFile('@:foo(A -> B)\nclass X {}'), 'ThinArrow');
		Assert.notNull(meta, 'fixture must contain a ThinArrow');
		if (meta != null) Assert.equals('IdentExpr', meta.children[0].kind);
		final decorated: String = 'class X {\n\tstatic function f():Void {\n\t\t@:baz(P -> Q) var v = q -> q > 0;\n\t\ttrace(v);\n\t}\n}';
		final arrows: Array<String> = kindsOfArrowOperands(new HaxeQueryPlugin().parseFile(decorated));
		Assert.equals('IdentExpr,Required', arrows.join(','), 'the annotation is skipped, the declaration it decorates is not');
	}

	/** `SHADOWED` with its lambda replaced by `body` — the one variable across the spellings. */
	private static function lambda(body: String): String {
		return 'class X {\n\tstatic function f():Void {\n\t\tvar q:Int = 1;\n\t\tvar g = $body;\n\t\ttrace(q, g);\n\t}\n}';
	}

	private static function findIn(source: String, name: String): Array<RefHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: RefShape = plugin.refShape();
		return Refs.find(name, tree, shape);
	}

	/**
	 * The hit list as `kind` per hit, each non-decl carrying the INDEX of the hit it binds to
	 * (`-1` when unresolved). Positions would pin the same facts but read as coordinates; the
	 * index says which declaration won, which is the thing under test.
	 */
	private static function signature(hits: Array<RefHit>): String {
		final parts: Array<String> = [];
		for (h in hits) {
			if (h.kind == RefKind.Decl) {
				parts.push('decl');
				continue;
			}
			final bind: Null<Span> = h.bindingSpan;
			parts.push('${h.kind}->${bind == null ? -1 : indexOfSpan(hits, bind)}');
		}
		return parts.join(' ');
	}

	/** The index of the hit whose own span starts where `span` does, or `-1`. */
	private static function indexOfSpan(hits: Array<RefHit>, span: Span): Int {
		for (i in 0...hits.length) if (hits[i].span.from == span.from) return i;
		return -1;
	}

	/** The first node of `kind` in pre-order, or null. */
	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

	private static function assertRename(source: String, line: Int, col: Int, newName: String, expected: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		switch Rename.rename(source, line, col, newName, plugin, plugin.refShape()) {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/** Every `ThinArrow`'s child-0 kind in pre-order — the one slot this projection rewrites. */
	private static function kindsOfArrowOperands(node: QueryNode): Array<String> {
		final out: Array<String> = [];
		collectArrowOperandKinds(node, out);
		return out;
	}

	/** Pre-order accumulation behind `kindsOfArrowOperands`. */
	private static function collectArrowOperandKinds(node: QueryNode, out: Array<String>): Void {
		if (node.kind == 'ThinArrow' && node.children.length > 0) out.push(node.children[0].kind);
		for (c in node.children) collectArrowOperandKinds(c, out);
	}

}
