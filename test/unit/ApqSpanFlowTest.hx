package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;

/**
 * Slice 2B probe — end-to-end check that `HaxeQueryPlugin` populates
 * `QueryNode.span` for grammar-enum nodes by consuming the span-mode
 * parser's side-channel array in post-order lockstep.
 *
 * Invariants asserted:
 *  - `module` root carries `null` span (HxModule is a Seq, no push).
 *  - Top-level decl QueryNodes (ClassDecl, etc.) carry non-null spans
 *    that lie within `[0, source.length]` and satisfy `from <= to`.
 *  - Distinct top-level decls produce distinct spans (strict
 *    `from1 < from2` for source order).
 *
 * Inner-expression spans (Pratt sub-nodes, etc.) are not explicitly
 * asserted here — slice 2A/2B's alignment guarantees per-enum spans
 * via `left = $ctor` instrumentation but real fixtures span-cover the
 * full corpus in `ApqAstIntegrationTest`.
 */
class ApqSpanFlowTest extends Test {

	public function testTopLevelClassDeclCarriesSpan(): Void {
		final source: String = 'class Foo { var x:Int; }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		Assert.equals('module', tree.kind);
		Assert.isNull(tree.span, 'module root has no span (HxModule is Seq)');
		Assert.isTrue(tree.children.length > 0, 'must have at least one decl child');
		final firstDecl: QueryNode = tree.children[0];
		Assert.notNull(firstDecl.span, 'top-level decl must carry a span');
		final span = firstDecl.span;
		if (span != null) {
			Assert.isTrue(span.from >= 0);
			Assert.isTrue(span.to <= source.length);
			Assert.isTrue(span.from <= span.to);
		}
	}

	public function testMultipleTopLevelDeclsHaveOrderedSpans(): Void {
		final source: String = 'class A {}\nclass B {}\nclass C {}';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		Assert.equals(3, tree.children.length);
		var prevFrom: Int = -1;
		for (decl in tree.children) {
			final span = decl.span;
			Assert.notNull(span, 'every top-level decl needs a span');
			if (span == null) continue;
			Assert.isTrue(span.from > prevFrom, 'span order must be strict — got from=${span.from}, prev=$prevFrom');
			prevFrom = span.from;
		}
	}

	public function testSpanMonotonicityAcrossNestedDecls(): Void {
		final source: String = 'class X { function foo():Void { var n:Int = 0; } }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		// Walk the tree pre-order, collecting spans. We don't enforce
		// strict monotonicity across nested nodes (parent's span starts
		// before children's), only that nothing is out of source range.
		walkAssertSpans(tree, source.length);
	}

	private function walkAssertSpans(node: QueryNode, sourceLen: Int): Void {
		final span = node.span;
		if (span != null) {
			Assert.isTrue(span.from >= 0, '${node.kind}: from=${span.from} negative');
			Assert.isTrue(span.to <= sourceLen, '${node.kind}: to=${span.to} > sourceLen=$sourceLen');
			Assert.isTrue(span.from <= span.to, '${node.kind}: from=${span.from} > to=${span.to}');
		}
		for (c in node.children) walkAssertSpans(c, sourceLen);
	}

}
