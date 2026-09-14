package unit.query;

import anyparse.query.NodeShape;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * `NodeShape` — the statement and call shapes the checks read off node kinds, on hand-built
 * nodes so every branch of the gate is reached: the wrapped assignment, the `receiver.method`
 * callee, the assignment a `return` echoes. Green at base by construction: each helper restates
 * a gate its adopters already ran.
 */
@:nullSafety(Strict)
class NodeShapeTest extends Test {

	private static inline final EXPR_STMT: String = 'ExprStmt';
	private static inline final ASSIGN: String = 'Assign';
	private static inline final IDENT: String = 'IdentExpr';
	private static inline final RETURN: String = 'ReturnStmt';
	private static inline final FIELD_ACCESS: String = 'FieldAccess';

	public function testAssignmentOfAnswersTheWrappedBinary(): Void {
		final assign: QueryNode = new QueryNode(ASSIGN, null, [ident('x'), ident('e')]);
		final stmt: QueryNode = new QueryNode(EXPR_STMT, null, [assign]);
		Assert.equals(assign, NodeShape.assignmentOf(stmt, EXPR_STMT, ASSIGN));
	}

	public function testAssignmentOfRefusesEveryOtherShape(): Void {
		final assign: QueryNode = new QueryNode(ASSIGN, null, [ident('x'), ident('e')]);
		final stmt: QueryNode = new QueryNode(EXPR_STMT, null, [assign]);
		Assert.isNull(NodeShape.assignmentOf(stmt, null, ASSIGN));
		Assert.isNull(NodeShape.assignmentOf(stmt, EXPR_STMT, null));
		Assert.isNull(NodeShape.assignmentOf(assign, EXPR_STMT, ASSIGN));
		Assert.isNull(NodeShape.assignmentOf(new QueryNode(EXPR_STMT, null, [assign, assign]), EXPR_STMT, ASSIGN));
		Assert.isNull(NodeShape.assignmentOf(new QueryNode(EXPR_STMT, null, [ident('x')]), EXPR_STMT, ASSIGN));
		final unary: QueryNode = new QueryNode(ASSIGN, null, [ident('x')]);
		Assert.isNull(NodeShape.assignmentOf(new QueryNode(EXPR_STMT, null, [unary]), EXPR_STMT, ASSIGN));
	}

	public function testMethodCallTakesTheCalleeApart(): Void {
		final receiver: QueryNode = ident('obj');
		final callee: QueryNode = new QueryNode(FIELD_ACCESS, 'run', [receiver]);
		final call: QueryNode = new QueryNode('Call', null, [callee, ident('arg')]);
		final parts: Null<MethodCall> = NodeShape.methodCall(call, FIELD_ACCESS);
		Assert.notNull(parts);
		if (parts == null) return;
		Assert.equals(callee, parts.callee);
		Assert.equals(receiver, parts.receiver);
		Assert.equals('run', parts.method);
	}

	public function testMethodCallRefusesABareCalleeAndAnUnsetSeam(): Void {
		final bare: QueryNode = new QueryNode('Call', null, [ident('run')]);
		Assert.isNull(NodeShape.methodCall(bare, FIELD_ACCESS));
		final callee: QueryNode = new QueryNode(FIELD_ACCESS, 'run', [ident('obj')]);
		final call: QueryNode = new QueryNode('Call', null, [callee]);
		Assert.isNull(NodeShape.methodCall(call, null));
		Assert.isNull(NodeShape.methodCall(new QueryNode('Call', null, []), FIELD_ACCESS));
		final twoReceivers: QueryNode = new QueryNode(FIELD_ACCESS, 'run', [ident('a'), ident('b')]);
		Assert.isNull(NodeShape.methodCall(new QueryNode('Call', null, [twoReceivers]), FIELD_ACCESS));
		final nameless: QueryNode = new QueryNode(FIELD_ACCESS, null, [ident('obj')]);
		Assert.isNull(NodeShape.methodCall(new QueryNode('Call', null, [nameless]), FIELD_ACCESS));
	}

	public function testReturnedAssignmentPairsTheWriteWithItsReturn(): Void {
		final lhs: QueryNode = ident('x');
		final assign: QueryNode = new QueryNode(ASSIGN, null, [lhs, ident('e')]);
		final retIdent: QueryNode = ident('x');
		final ret: QueryNode = new QueryNode(RETURN, null, [retIdent]);
		final pair: Null<ReturnedAssignment> = NodeShape.returnedAssignment(assign, ret, IDENT, RETURN);
		Assert.notNull(pair);
		if (pair == null) return;
		Assert.equals(lhs, pair.lhs);
		Assert.equals('x', pair.name);
		Assert.equals(retIdent, pair.retIdent);
	}

	public function testReturnedAssignmentRefusesAnotherNameOrShape(): Void {
		final assign: QueryNode = new QueryNode(ASSIGN, null, [ident('x'), ident('e')]);
		Assert.isNull(NodeShape.returnedAssignment(assign, new QueryNode(RETURN, null, [ident('y')]), IDENT, RETURN));
		Assert.isNull(NodeShape.returnedAssignment(assign, new QueryNode(RETURN, null, []), IDENT, RETURN));
		Assert.isNull(NodeShape.returnedAssignment(assign, new QueryNode('Other', null, [ident('x')]), IDENT, RETURN));
		final fieldWrite: QueryNode = new QueryNode(ASSIGN, null, [new QueryNode(FIELD_ACCESS, 'x', [ident('this')]), ident('e')]);
		Assert.isNull(NodeShape.returnedAssignment(fieldWrite, new QueryNode(RETURN, null, [ident('x')]), IDENT, RETURN));
	}

	private static function ident(name: String): QueryNode {
		return new QueryNode(IDENT, name, [], new Span(0, name.length));
	}

}
