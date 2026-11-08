package unit.check.common.control;

import anyparse.check.common.control.BranchChain;
import anyparse.query.QueryNode;

/**
 * `BranchChain`'s positional accessors: which child of an if (or ternary) node is its condition, its then
 * branch and its else branch, and whether a node is the else branch of an `if` - an `else if` link.
 */
@:nullSafety(Strict)
final class BranchChainTest extends Test {

	private static final IF_KINDS: Array<String> = ['IfStmt'];

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-BRANCHCHAIN-COND-IS-THEN')
	public function testCondIsTheFirstChild(): Void {
		final shape: Shape = withElse();
		Assert.equals(shape.cond, BranchChain.condOf(shape.node));
	}

	@:pin('control')
	@:killer('M-BRANCHCHAIN-THEN-IS-COND')
	public function testThenIsTheSecondChild(): Void {
		final shape: Shape = withElse();
		Assert.equals(shape.then, BranchChain.thenOf(shape.node));
	}

	@:pin('control')
	@:killer('M-BRANCHCHAIN-ELSE-IS-THEN')
	public function testElseIsTheThirdChild(): Void {
		final shape: Shape = withElse();
		Assert.equals(shape.elseNode, BranchChain.elseBranch(shape.node));
	}

	@:pin('control')
	@:killer('M-BRANCHCHAIN-HAS-ELSE-ALWAYS')
	public function testHasElseTellsTheTwoShapesApart(): Void {
		Assert.isTrue(BranchChain.hasElse(withElse().node));
		Assert.isFalse(BranchChain.hasElse(withoutElse().node));
	}

	@:pin('control')
	@:killer('M-BRANCHCHAIN-ELSEIF-ANY-CHILD')
	public function testOnlyTheElseBranchIsAnElseIfLink(): Void {
		final shape: Shape = withElse();
		Assert.isTrue(BranchChain.isElseIfLink(shape.elseNode, shape.node, IF_KINDS));
		Assert.isFalse(BranchChain.isElseIfLink(shape.then, shape.node, IF_KINDS));
		Assert.isFalse(BranchChain.isElseIfLink(shape.elseNode, null, IF_KINDS));
		Assert.isFalse(BranchChain.isElseIfLink(shape.elseNode, shape.node, ['Other']));
	}

	@:pin('guard')
	public function testHasThenNeedsTheConditionAndTheThenBranch(): Void {
		final shape: Shape = withElse();
		Assert.isTrue(BranchChain.hasThen(shape.node));
		Assert.isTrue(BranchChain.hasThen(new QueryNode('IfStmt', null, [shape.cond, shape.then])));
		Assert.isFalse(BranchChain.hasThen(new QueryNode('IfStmt', null, [shape.cond])));
	}

	private static function leaf(kind: String): QueryNode {
		return new QueryNode(kind, null, []);
	}

	private static function withElse(): Shape {
		final cond: QueryNode = leaf('Cond');
		final then: QueryNode = leaf('Then');
		final elseNode: QueryNode = leaf('Else');
		return {
			node: new QueryNode('IfStmt', null, [cond, then, elseNode]),
			cond: cond,
			then: then,
			elseNode: elseNode
		};
	}

	private static function withoutElse(): Shape {
		final cond: QueryNode = leaf('Cond');
		final then: QueryNode = leaf('Then');
		return {
			node: new QueryNode('IfStmt', null, [cond, then]),
			cond: cond,
			then: then,
			elseNode: leaf('Else')
		};
	}

}

private typedef Shape = {
	final node: QueryNode;
	final cond: QueryNode;
	final then: QueryNode;
	final elseNode: QueryNode;
}
