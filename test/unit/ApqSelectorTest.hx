package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Engine;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.runtime.Span;

/**
 * Unit tests for the `--select` selector grammar (parser + matcher).
 *
 * The matcher is language-agnostic — these tests build synthetic
 * `QueryNode` trees directly, no grammar plugin involved.
 */
class ApqSelectorTest extends Test {

	public function testKindOnly():Void {
		final s:Selector = Selector.parse('FnDecl');
		Assert.equals(1, s.segments.length);
		Assert.equals('FnDecl', s.segments[0].kind);
		Assert.isNull(s.segments[0].name);
	}

	public function testKindWithName():Void {
		final s:Selector = Selector.parse('FnDecl:foo');
		Assert.equals('FnDecl', s.segments[0].kind);
		Assert.equals('foo', s.segments[0].name);
	}

	public function testKindWithNameSpace():Void {
		// Space is an accepted alias for `:` — the natural form.
		final s:Selector = Selector.parse('FnMember paramBody');
		Assert.equals('FnMember', s.segments[0].kind);
		Assert.equals('paramBody', s.segments[0].name);
	}

	public function testKindWithNameMultiSpace():Void {
		final s:Selector = Selector.parse('FnMember   bar');
		Assert.equals('FnMember', s.segments[0].kind);
		Assert.equals('bar', s.segments[0].name);
	}

	public function testKindNameSpaceMatches():Void {
		final tree:QueryNode = mkTree();
		final r:Array<QueryNode> = Engine.select(tree, Selector.parse('FnMember bar'));
		Assert.equals(1, r.length);
		Assert.equals('bar', r[0].name);
	}

	public function testDirectChildChain():Void {
		final s:Selector = Selector.parse('class > field');
		Assert.equals(2, s.segments.length);
		Assert.equals('class', s.segments[0].kind);
		Assert.equals('field', s.segments[1].kind);
	}

	public function testWhitespaceTolerance():Void {
		final s:Selector = Selector.parse('  ClassDecl  >  FnDecl:foo  ');
		Assert.equals('ClassDecl', s.segments[0].kind);
		Assert.equals('FnDecl', s.segments[1].kind);
		Assert.equals('foo', s.segments[1].name);
	}

	public function testEmptySegmentRejected():Void {
		Assert.raises(() -> Selector.parse('A >'));
		Assert.raises(() -> Selector.parse('> A'));
		Assert.raises(() -> Selector.parse(':bar'));
		Assert.raises(() -> Selector.parse('A:'));
	}

	public function testMatchTopLevelByKind():Void {
		final tree:QueryNode = mkTree();
		final r:Array<QueryNode> = Engine.select(tree, Selector.parse('ClassDecl'));
		Assert.equals(1, r.length);
		Assert.equals('Foo', r[0].name);
	}

	public function testMatchByKindAndName():Void {
		final tree:QueryNode = mkTree();
		final r:Array<QueryNode> = Engine.select(tree, Selector.parse('FnMember:bar'));
		Assert.equals(1, r.length);
		Assert.equals('bar', r[0].name);
	}

	public function testMatchByKindAndNameMisses():Void {
		final tree:QueryNode = mkTree();
		final r:Array<QueryNode> = Engine.select(tree, Selector.parse('FnMember:nope'));
		Assert.equals(0, r.length);
	}

	public function testDirectChildOnlyMatchesDirectChildren():Void {
		final tree:QueryNode = mkTree();
		// VarMember is a direct child of ClassDecl
		Assert.equals(1, Engine.select(tree, Selector.parse('ClassDecl > VarMember')).length);
		// IntLit is NOT a direct child of ClassDecl (it's deeper)
		Assert.equals(0, Engine.select(tree, Selector.parse('ClassDecl > IntLit')).length);
	}

	public function testFirstSegmentMatchesAtAnyDepth():Void {
		final tree:QueryNode = mkTree();
		// IntLit lives deep in the tree but the first segment matches at any depth
		Assert.equals(1, Engine.select(tree, Selector.parse('IntLit')).length);
	}

	public function testTruncateFlattensChildrenBelowDepth():Void {
		final tree:QueryNode = mkTree();
		final t1:QueryNode = Engine.truncate(tree, 1);
		// depth 1 keeps the root's direct children but clears their children
		Assert.equals('module', t1.kind);
		Assert.equals(1, t1.children.length);
		Assert.equals('ClassDecl', t1.children[0].kind);
		Assert.equals(0, t1.children[0].children.length);
	}

	public function testTruncateDepthZeroClearsAll():Void {
		final tree:QueryNode = mkTree();
		final t0:QueryNode = Engine.truncate(tree, 0);
		Assert.equals(0, t0.children.length);
	}

	public function testTruncateNegativeIsNoOp():Void {
		final tree:QueryNode = mkTree();
		final t:QueryNode = Engine.truncate(tree, -1);
		Assert.equals(tree, t);
	}

	private function mkTree():QueryNode {
		// module > ClassDecl(Foo) > [VarMember(x), FnMember(bar) > ReturnExpr > IntLit]
		final intLit:QueryNode = new QueryNode('IntLit', null, []);
		final ret:QueryNode = new QueryNode('ReturnExpr', null, [intLit]);
		final fn:QueryNode = new QueryNode('FnMember', 'bar', [ret]);
		final varM:QueryNode = new QueryNode('VarMember', 'x', []);
		final cls:QueryNode = new QueryNode('ClassDecl', 'Foo', [varM, fn]);
		return new QueryNode('module', null, [cls]);
	}

	public function testAtReturnsInnermostContainingNode():Void {
		final tree:QueryNode = mkSpannedTree();
		// Offset 22 is inside IdentExpr[20,25) ⊂ FnMember[10,40) ⊂ ClassDecl[0,50).
		final n:Null<QueryNode> = Engine.at(tree, 22);
		Assert.notNull(n);
		Assert.equals('IdentExpr', n.kind);
	}

	public function testAtPicksEnclosingWhenBetweenInnerNodes():Void {
		final tree:QueryNode = mkSpannedTree();
		// Offset 12 is in FnMember[10,40) but before IdentExpr[20,25).
		final n:Null<QueryNode> = Engine.at(tree, 12);
		Assert.notNull(n);
		Assert.equals('FnMember', n.kind);
	}

	public function testAtFallsBackToOuterNode():Void {
		final tree:QueryNode = mkSpannedTree();
		// Offset 5 is in ClassDecl[0,50) only (before FnMember[10,40)).
		final n:Null<QueryNode> = Engine.at(tree, 5);
		Assert.notNull(n);
		Assert.equals('ClassDecl', n.kind);
	}

	public function testAtEndExclusiveAndOutOfRangeReturnNull():Void {
		final tree:QueryNode = mkSpannedTree();
		// 50 == ClassDecl.to (end-exclusive) and 60 past everything; the
		// spanless module root never wins.
		Assert.isNull(Engine.at(tree, 50));
		Assert.isNull(Engine.at(tree, 60));
	}

	private function mkSpannedTree():QueryNode {
		// module(no span) > ClassDecl[0,50) > FnMember[10,40) > IdentExpr[20,25)
		final id:QueryNode = new QueryNode('IdentExpr', 'v', [], new Span(20, 25));
		final fn:QueryNode = new QueryNode('FnMember', 'bar', [id], new Span(10, 40));
		final cls:QueryNode = new QueryNode('ClassDecl', 'Foo', [fn], new Span(0, 50));
		return new QueryNode('module', null, [cls]);
	}
}
