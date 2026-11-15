package unit.check.scan;

import anyparse.check.scan.CheckScan.NegationSeams;
import anyparse.check.scan.NegationScan;
import anyparse.query.BooleanLogic.BooleanLogicSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.LexicalRegions;
import anyparse.query.QueryNode;

/**
 * `NegationScan` read through real lexical regions: a `//` spelled inside a string operand is not a comment, so
 * the De Morgan tier runs, while the regions-free call keeps the string-blind marker scan and its verbatim wrap.
 */
class NegationScanRegionsTest extends Test {

	@:pin('control')
	@:killer('M-NEGATION-REGIONS-IGNORED')
	public function testStringMarkerTakesDeMorganWithRegions(): Void {
		final r: Run = run("'a//b' == x && y");
		Assert.equals("'a//b' != x || !y", NegationScan.negateConditionText(r.cond, r.src, r.seams, r.support, null, null, r.regions));
	}

	@:pin('control')
	@:killer('M-NEGATION-MARKER-SCAN-DROPPED')
	public function testStringMarkerKeepsTextTierWithoutRegions(): Void {
		final r: Run = run("'a//b' == x && y");
		Assert.equals("!('a//b' == x && y)", NegationScan.negateConditionText(r.cond, r.src, r.seams, r.support));
	}

	public function testRealCommentKeepsTextTierWithRegions(): Void {
		final r: Run = run('a /* c */ == x && y');
		Assert.equals('!(a /* c */ == x && y)', NegationScan.negateConditionText(r.cond, r.src, r.seams, r.support, null, null, r.regions));
	}

	@:pin('control')
	@:killer('M-NEGATION-GAP-COMMENT-FLIPPED')
	public function testOperatorGapCommentDeclinesFlipWithRegions(): Void {
		final r: Run = run('a /* c */ == x');
		Assert.equals('!(a /* c */ == x)', NegationScan.negateConditionText(r.cond, r.src, r.seams, null, null, null, r.regions));
	}

	public function testStringMarkerInGapStillFlipsWithRegions(): Void {
		final r: Run = run("'a//b' == x");
		Assert.equals("'a//b' != x", NegationScan.negateConditionText(r.cond, r.src, r.seams, null, null, null, r.regions));
	}

	public function testNegationIsCleanReadsRegions(): Void {
		final r: Run = run("'a//b' == x && y");
		Assert.isTrue(NegationScan.negationIsClean(r.cond, r.src, r.support, null, r.regions));
		Assert.isTrue(NegationScan.negationIsClean(r.cond, r.src, r.support));
	}

	private function run(cond: String): Run {
		final src: String = 'class C { function f() { if ($cond) {} } }';
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		final at: Int = src.indexOf(cond);
		final node: Null<QueryNode> = find(plugin.parseFile(src), at, at + cond.length);
		final support: Null<BooleanLogicSupport> = plugin.booleanLogicSupport();
		if (node == null || support == null) throw 'no condition node';
		return {
			cond: node,
			src: src,
			seams: NegationScan.negationSeams(shape),
			support: support,
			regions: plugin.lexicalRegions(src)
		};
	}

	private function find(n: QueryNode, from: Int, to: Int): Null<QueryNode> {
		final s: Null<Span> = n.span;
		if (s != null && s.from == from && s.to == to) return n;
		for (c in n.children) {
			final hit: Null<QueryNode> = find(c, from, to);
			if (hit != null) return hit;
		}
		return null;
	}

}

private typedef Run = {
	final cond: QueryNode;
	final src: String;
	final seams: NegationSeams;
	final support: BooleanLogicSupport;
	final regions: Array<LexRegion>;
}
