package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Engine;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.runtime.Span;

/**
 * Unit tests for the `--select` selector grammar (parser + matcher).
 *
 * The matcher is language-agnostic — most tests build synthetic
 * `QueryNode` trees directly, no grammar plugin involved. The
 * `final`-aware tests additionally exercise `KindEquivalence` (the
 * `--select` kind-folding): the synthetic ones pass an inline relation,
 * and a few drive the real `HaxeQueryPlugin.selectKindEquivalence` to
 * prove `--select ClassDecl` / `FnMember` reach `final class` /
 * `final function` declarations.
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

	// ======== final-aware --select (KindEquivalence) ========

	public function testEquivFoldsWrapperKindOntoPlain():Void {
		// A `final class` projects as FinalDecl > ClassForm(name); a `final
		// function` as FinalModifiedMember. With the equivalence folding
		// ClassForm→ClassDecl and FinalModifiedMember→FnMember, `--select
		// ClassDecl` and `--select FnMember` reach both shapes.
		final tree:QueryNode = mkFinalTree();
		final equiv:KindEquivalence = new KindEquivalence([['ClassDecl', 'ClassForm'], ['FnMember', 'FinalModifiedMember']]);

		final classes:Array<QueryNode> = Engine.select(tree, Selector.parse('ClassDecl'), equiv);
		Assert.equals(2, classes.length); // ClassForm(Widget) + ClassDecl(Plain)
		final fns:Array<QueryNode> = Engine.select(tree, Selector.parse('FnMember'), equiv);
		Assert.equals(2, fns.length); // FinalModifiedMember(compute) + FnMember(plain)
	}

	public function testEquivNullKeepsExactKind():Void {
		// Without an equivalence the matcher is exact: the `final` wrapper
		// shapes are NOT folded — backward-compatible with synthetic callers.
		final tree:QueryNode = mkFinalTree();
		Assert.equals(1, Engine.select(tree, Selector.parse('ClassDecl')).length); // only ClassDecl(Plain)
		Assert.equals(1, Engine.select(tree, Selector.parse('FnMember')).length); // only FnMember(plain)
	}

	public function testEquivChainsThroughFoldedParent():Void {
		// `ClassDecl > FnMember` must reach the methods of a `final class`:
		// the parent folds ClassForm→ClassDecl and the children fold
		// FinalModifiedMember→FnMember. Widget has BOTH a final method
		// (`compute`) and a plain one (`plain`), so the chain yields both —
		// the load-bearing assertion is that the FINAL method is reachable
		// through the folded parent (it was invisible before).
		final tree:QueryNode = mkFinalTree();
		final equiv:KindEquivalence = new KindEquivalence([['ClassDecl', 'ClassForm'], ['FnMember', 'FinalModifiedMember']]);
		final r:Array<QueryNode> = Engine.select(tree, Selector.parse('ClassDecl > FnMember'), equiv);
		final names:Array<String> = [for (m in r) m.name == null ? '?' : m.name];
		Assert.equals(2, r.length);
		Assert.isTrue(names.contains('compute'), 'final method under final class reachable via chain');
		Assert.isTrue(names.contains('plain'), 'plain method also reachable');
	}

	public function testHaxePluginFoldsFinalDeclarations():Void {
		// Drive the REAL HaxeQueryPlugin equivalence end-to-end: `--select
		// ClassDecl` reaches a `final class` and `--select FnMember` a
		// `final function`.
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree:QueryNode = plugin.parseFile('final class Widget {\n\tfinal function compute():Void {}\n}\nclass Plain {}');
		final equiv:KindEquivalence = plugin.selectKindEquivalence();

		final classes:Array<QueryNode> = Engine.select(tree, Selector.parse('ClassDecl'), equiv);
		final classNames:Array<String> = [for (c in classes) c.name == null ? '?' : c.name];
		Assert.isTrue(classNames.contains('Widget'), 'final class Widget must match --select ClassDecl');
		Assert.isTrue(classNames.contains('Plain'), 'plain class Plain must still match');

		final fns:Array<QueryNode> = Engine.select(tree, Selector.parse('FnMember'), equiv);
		Assert.equals(1, fns.length);
		Assert.equals('compute', fns[0].name);
	}

	private function mkFinalTree():QueryNode {
		// module > [ FinalDecl > ClassForm(Widget) > [FinalModifiedMember(compute), FnMember(plain)],
		//           ClassDecl(Plain) ]
		final finalMethod:QueryNode = new QueryNode('FinalModifiedMember', 'compute', []);
		final plainMethod:QueryNode = new QueryNode('FnMember', 'plain', []);
		final classForm:QueryNode = new QueryNode('ClassForm', 'Widget', [finalMethod, plainMethod]);
		final finalDecl:QueryNode = new QueryNode('FinalDecl', null, [classForm]);
		final plain:QueryNode = new QueryNode('ClassDecl', 'Plain', []);
		return new QueryNode('module', null, [finalDecl, plain]);
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
