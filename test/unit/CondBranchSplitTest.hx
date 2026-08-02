package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CondBranchProjection;
import anyparse.query.CondBranchProjection.CondBranchRun;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * `CondBranchProjection`'s conditional-region splitter (`conditionalBranchRuns`) and the
 * branch-aware projection built on it (`GrammarPlugin.projectBranchAware`).
 *
 * The splitter reads ONLY the source gaps BETWEEN a region's child spans, so a nested `#if` costs
 * nothing, a `#else` inside a comment cannot split a run, and a directive in the head or trailing
 * gap is never read at all; a branch with no statements yields no run, and any shape the gaps
 * cannot describe (a missing or non-monotonic child span) bails and leaves the region flat. The
 * projection wraps a run only when the region's PARENT is a statement list, which is what keeps
 * member-position, un-braced-`if`-body and switch-body regions — all spelled `Conditional` too —
 * untouched, and it SHARES every subtree it did not rewrite.
 */
class CondBranchSplitTest extends Test {

	private static final ELSE_KEYWORDS: Array<String> = ['#else', '#elseif'];

	public function testThreeBranchesSplitOnDirectiveGaps(): Void {
		final src: String = fn('#if A\n\t\ta();\n\t\tb();\n\t\t#elseif B\n\t\tc();\n\t\t#else\n\t\td();\n\t\t#end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(3, runs.length);
		Assert.equals(2, runs[0].nodes.length);
		Assert.equals(1, runs[1].nodes.length);
		Assert.equals(1, runs[2].nodes.length);
		Assert.isTrue(noDirectiveInSpans(src, runs));
		Assert.equals('a();\n\t\tb();', src.substring(runs[0].span.from, runs[0].span.to));
		Assert.equals('d();', src.substring(runs[2].span.from, runs[2].span.to));
	}

	public function testNestedRegionIsOneChildNoDepthCounting(): Void {
		// The nested `#if B … #end` projects as ONE child whose span covers its whole region, so
		// its `#end` is never read as a gap directive and the outer run stays intact.
		final src: String = fn('#if A\n\t\ta();\n\t\t#if B\n\t\tb();\n\t\t#end\n\t\tz();\n\t\t#else\n\t\td();\n\t\t#end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(2, runs.length);
		Assert.equals(3, runs[0].nodes.length);
		Assert.equals(1, runs[1].nodes.length);
	}

	public function testEmptyFirstBranchYieldsNoRun(): Void {
		final src: String = fn('#if A\n\t\t#else\n\t\ta();\n\t\t#end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(1, runs.length);
		Assert.equals(1, runs[0].nodes.length);
	}

	public function testEmptyLastBranchYieldsNoRun(): Void {
		final src: String = fn('#if A\n\t\ta();\n\t\t#else\n\t\t#end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(1, runs.length);
		Assert.equals(1, runs[0].nodes.length);
	}

	public function testFullyEmptyRegionYieldsNoRuns(): Void {
		final src: String = fn('#if A\n\t\t#else\n\t\t#end');
		Assert.equals(0, runsOf(src).length);
		Assert.equals(0, countOfKind(branchTree(src), CondBranchProjection.COND_BRANCH_KIND));
	}

	public function testNoElseRegionIsOneRun(): Void {
		final src: String = fn('#if A\n\t\ta();\n\t\tb();\n\t\t#end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(1, runs.length);
		Assert.equals(2, runs[0].nodes.length);
	}

	public function testGapWithTwoDirectivesSplitsOnce(): Void {
		// `#elseif B` opens a branch with no statements, so the gap holds two directives and the
		// two surviving branches still come out as two runs.
		final src: String = fn('#if A\n\t\ta();\n\t\t#elseif B\n\t\t#elseif C\n\t\tc();\n\t\t#end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(2, runs.length);
		Assert.equals(1, runs[0].nodes.length);
		Assert.equals(1, runs[1].nodes.length);
	}

	public function testHeadGapWithElseOnOneLineIsOneRun(): Void {
		// `#if A #else trace(1); #end` — the empty `#if` branch leaves the region with ONE child,
		// so there is no gap BETWEEN children to scan and the head gap's directives are never read.
		final src: String = fn('#if A #else trace(1); #end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(1, runs.length);
		Assert.equals(1, runs[0].nodes.length);
	}

	public function testSingleLineRegionSplitsOnTheGapSubstring(): Void {
		// A whole region on ONE line still splits: the ` #else ` gap between the two statements
		// ltrims to a `#else` prefix because anchoring is relative to the GAP SUBSTRING, never to
		// a real source line. A true line anchor would silently stop splitting these.
		final src: String = fn('#if A x(); #else y(); #end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(2, runs.length);
		Assert.equals('x();', src.substring(runs[0].span.from, runs[0].span.to));
		Assert.equals('y();', src.substring(runs[1].span.from, runs[1].span.to));
	}

	public function testCommentedOutElseDoesNotSplit(): Void {
		final src: String = fn('#if A\n\t\ta();\n\t\t/*\n#else\n\t\t*/\n\t\tb();\n\t\t#end');
		final runs: Array<CondBranchRun> = runsOf(src);
		Assert.equals(1, runs.length);
		Assert.equals(2, runs[0].nodes.length);
	}

	public function testNullChildSpanBails(): Void {
		final region: QueryNode = new QueryNode('Conditional', null, [new QueryNode('ExprStmt', null, [])], new Span(0, 10));
		Assert.isNull(CondBranchProjection.conditionalBranchRuns(region, 'x', ELSE_KEYWORDS, []));
	}

	public function testNonMonotonicChildSpansBail(): Void {
		final region: QueryNode = new QueryNode('Conditional', null, [
			new QueryNode('ExprStmt', null, [], new Span(5, 9)),
			new QueryNode('ExprStmt', null, [], new Span(7, 12))
		], new Span(0, 20));
		Assert.isNull(CondBranchProjection.conditionalBranchRuns(region, 'x', ELSE_KEYWORDS, []));
	}

	public function testChildSpanOutsideRegionBails(): Void {
		final region: QueryNode = new QueryNode(
			'Conditional', null, [new QueryNode('ExprStmt', null, [], new Span(5, 30))], new Span(0, 20)
		);
		Assert.isNull(CondBranchProjection.conditionalBranchRuns(region, 'x', ELSE_KEYWORDS, []));
	}

	public function testStatementRegionIsWrapped(): Void {
		final src: String = fn('#if A\n\t\ta();\n\t\t#else\n\t\tb();\n\t\t#end');
		final tree: QueryNode = branchTree(src);
		Assert.equals(2, countOfKind(tree, CondBranchProjection.COND_BRANCH_KIND));
		final region: Null<QueryNode> = firstOfKind(tree, 'Conditional');
		Assert.notNull(region);
		if (region == null) return;
		Assert.equals(2, region.children.length);
		for (branch in region.children) {
			Assert.equals(CondBranchProjection.COND_BRANCH_KIND, branch.kind);
			Assert.equals(1, branch.children.length);
		}
	}

	public function testNestedRegionInsideBranchIsWrappedToo(): Void {
		final src: String = fn('#if A\n\t\ta();\n\t\t#if B\n\t\tb();\n\t\t#end\n\t\tz();\n\t\t#else\n\t\td();\n\t\t#end');
		// Two outer branches plus the single branch of the region nested inside the first one.
		Assert.equals(3, countOfKind(branchTree(src), CondBranchProjection.COND_BRANCH_KIND));
	}

	public function testMemberRegionNotWrapped(): Void {
		final src: String = 'class C {\n\t#if A\n\tfunction a():Void {}\n\t#else\n\tfunction b():Void {}\n\t#end\n}';
		Assert.equals(0, countOfKind(branchTree(src), CondBranchProjection.COND_BRANCH_KIND));
	}

	public function testUnbracedIfBodyRegionNotWrapped(): Void {
		final src: String = fn('if (x) #if A\n\t\ta();\n\t\tb();\n\t\t#end');
		Assert.equals(0, countOfKind(branchTree(src), CondBranchProjection.COND_BRANCH_KIND));
	}

	public function testSwitchBodyRegionNotWrapped(): Void {
		final src: String = fn('switch v {\n\t\t#if A\n\t\tcase 1: a();\n\t\t#else\n\t\tcase 2: b();\n\t\t#end\n\t\t}');
		Assert.equals(0, countOfKind(branchTree(src), CondBranchProjection.COND_BRANCH_KIND));
	}

	public function testConditionalExprUntouched(): Void {
		final src: String = fn('var x = #if A 1 #else 2 #end;\n\t\ttrace(x);');
		final tree: QueryNode = branchTree(src);
		Assert.equals(0, countOfKind(tree, CondBranchProjection.COND_BRANCH_KIND));
		Assert.equals(1, countOfKind(tree, 'ConditionalExpr'));
	}

	public function testCondSpliceUntouched(): Void {
		final src: String = 'class C { function f():Void { #if A if (x) { #else if (y) { #end a(); } } }';
		Assert.equals(0, countOfKind(branchTree(src), CondBranchProjection.COND_BRANCH_KIND));
	}

	public function testUnrewrittenFileSharesTheSameTree(): Void {
		// A MEMBER-position region passes the `#if` fast path and is then left alone by the parent
		// gate, so the walk runs and must still hand back the IDENTICAL root object. `RefsCache`
		// keys its per-file index by tree identity, so a gratuitous copy re-indexes once per check.
		final src: String = 'class C {\n\t#if A\n\tfunction a():Void {}\n\t#else\n\tfunction b():Void {}\n\t#end\n}';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final plain: QueryNode = plugin.parseFile(src);
		Assert.isTrue(plain == plugin.projectBranchAware(plain, src));
	}

	public function testUntouchedSiblingIsSharedByIdentity(): Void {
		// The first class IS rewritten, so the root is a copy — but the second class was not
		// touched and must come back as the same node instance.
		final src: String =
			'class A {\n\tfunction f():Void {\n\t\t#if X\n\t\ta();\n\t\t#else\n\t\tb();\n\t\t#end\n\t}\n}\n\nclass B {\n\tfunction g():Void {\n\t\tc();\n\t}\n}';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final plain: QueryNode = plugin.parseFile(src);
		final projected: QueryNode = plugin.projectBranchAware(plain, src);
		Assert.isFalse(plain == projected);
		Assert.notNull(namedClass(plain, 'B'));
		Assert.isTrue(namedClass(plain, 'B') == namedClass(projected, 'B'));
	}

	/** The statements of `body` inside a class + function, so a region lands in a `BlockBody`. */
	private static inline function fn(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	/** The runs of the first `Conditional` in `src`, or `[]` when the splitter bailed. */
	private static function runsOf(src: String): Array<CondBranchRun> {
		final region: Null<QueryNode> = firstOfKind(new HaxeQueryPlugin().parseFile(src), 'Conditional');
		Assert.notNull(region);
		return region == null
			? []
			: CondBranchProjection.conditionalBranchRuns(region, src, ELSE_KEYWORDS, RefactorSupport.collectCommentTokens(src)) ?? [];
	}

	private static function branchTree(src: String): QueryNode {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return plugin.projectBranchAware(plugin.parseFile(src), src);
	}

	/** Whether no run's span reaches a `#` — the "a branch span never covers a directive line" invariant. */
	private static function noDirectiveInSpans(src: String, runs: Array<CondBranchRun>): Bool {
		for (run in runs) if (src.substring(run.span.from, run.span.to).indexOf('#') != -1) return false;
		return true;
	}

	/** The first `ClassDecl` named `name` under `node` — the anchor for the structural-sharing identity checks. */
	private static function namedClass(node: QueryNode, name: String): Null<QueryNode> {
		if (node.kind == 'ClassDecl' && node.name == name) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = namedClass(c, name);
			if (hit != null) return hit;
		}
		return null;
	}

	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

	private static function countOfKind(node: QueryNode, kind: String): Int {
		var n: Int = node.kind == kind ? 1 : 0;
		for (c in node.children) n += countOfKind(c, kind);
		return n;
	}

}
