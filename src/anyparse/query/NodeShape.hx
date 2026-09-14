package anyparse.query;

/** The pieces a `receiver.method(…)` call spells: the field-access callee, its one receiver child and the method name. */
typedef MethodCall = {
	final callee: QueryNode;
	final receiver: QueryNode;
	final method: String;
};

/** An `x = e` binary whose next statement is `return x;`: the written identifier, its name and the returned identifier. */
typedef ReturnedAssignment = {
	final lhs: QueryNode;
	final name: String;
	final retIdent: QueryNode;
};

/**
 * The child shapes a statement or a call projects, read off the kinds a caller names: the assignment an
 * expression statement wraps, the receiver and method a call spells, the identifier an assignment writes and
 * the next statement returns. Every answer is null when the shape is not there, and a seam the grammar
 * leaves unset matches nothing.
 */
@:nullSafety(Strict)
final class NodeShape {

	/** An expression statement wraps exactly one expression. */
	private static inline final EXPR_STMT_CHILD_COUNT: Int = 1;

	/** A binary assignment has exactly [target, value] children. */
	private static inline final ASSIGN_CHILD_COUNT: Int = 2;

	/** A `return x;` carries exactly its value. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	/**
	 * The `x = e` binary an expression statement wraps, or null when `stmt` is not an expression statement
	 * holding exactly one two-operand assignment.
	 */
	public static function assignmentOf(stmt: QueryNode, exprStmtKind: Null<String>, assignKind: Null<String>): Null<QueryNode> {
		if (exprStmtKind == null || assignKind == null) return null;
		if (stmt.kind != exprStmtKind || stmt.children.length != EXPR_STMT_CHILD_COUNT) return null;
		final assign: QueryNode = stmt.children[0];
		return assign.kind == assignKind && assign.children.length == ASSIGN_CHILD_COUNT ? assign : null;
	}

	/**
	 * The callee of `call` read as a `receiver.method` access — one receiver child and a name — or null when
	 * `call` has no callee or its callee is another shape. The call kind and the argument count stay with the
	 * caller: the count it accepts differs per question.
	 */
	public static function methodCall(call: QueryNode, fieldAccessKind: Null<String>): Null<MethodCall> {
		if (fieldAccessKind == null || call.children.length == 0) return null;
		final callee: QueryNode = call.children[0];
		final method: Null<String> = callee.name;
		return callee.kind != fieldAccessKind || method == null || callee.children.length != 1
			? null
			: { callee: callee, receiver: callee.children[0], method: method };
	}

	/**
	 * `assign` (an `x = e` binary) read together with the statement after it: the written identifier, its
	 * name and the identifier `ret` returns, or null unless `ret` is a `return x;` of the very name written.
	 */
	public static function returnedAssignment(
		assign: QueryNode, ret: QueryNode, identKind: String, returnKind: String
	): Null<ReturnedAssignment> {
		final lhs: QueryNode = assign.children[0];
		final name: Null<String> = lhs.name;
		if (lhs.kind != identKind || name == null) return null;
		if (ret.kind != returnKind || ret.children.length != RETURN_VALUE_CHILD_COUNT) return null;
		final retIdent: QueryNode = ret.children[0];
		return retIdent.kind == identKind && retIdent.name == name ? { lhs: lhs, name: name, retIdent: retIdent } : null;
	}

}
