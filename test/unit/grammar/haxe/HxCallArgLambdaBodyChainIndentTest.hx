package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-stmt-list-callarg-barrier: a wrapped binary-operator continuation inside
 * the BODY of a lambda / anonymous function / arrow-body `switch` that is a
 * leading-break call argument sits one indent level below its own statement,
 * exactly as in a plain function body. The `_callArgChainNest` flag the call
 * sets on each argument used to travel into the body and reach its first
 * chain, which then dropped its continuation Nest and wrapped the operator at
 * the statement's own indent. Both statement-list Stars now clear the flag for
 * every element. Identifiers are fully synthetic.
 */
@:nullSafety(Strict)
final class HxCallArgLambdaBodyChainIndentTest extends Test {

	/** The client-shaped config the sister `_callArgChainNest` leak test pins. */
	private static final CFG: String = HxTernaryBranchChainIndentTest.CFG;

	public function new(): Void {
		super();
	}

	/**
	 * RETURN, the lambda the call's ONLY argument: the `&&` continuation sits
	 * one level below the `return` line, as it does in a plain function body.
	 */
	@:pin('control')
	@:killer('M-STMT-LIST-CALLARG-BARRIER')
	public function testReturnInSoleLambdaArgChainIndents(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvisitAll(() -> {\n\t\t\treturn pendingMarkers.length == 0 && sessionChanged && '
			+ 'requestedAnchors.count() == 0\n\t\t\t\t&& !seenBefore(index, spanPath, trailingNode);\n\t\t});\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvisitAll(() -> {\n\t\t\treturn pendingMarkers.length == 0 &&'
				+ ' sessionChanged && requestedAnchors.count() == 0 && !seenBefore(index, spanPath, trailingNode);\n\t\t});\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * FINAL declaration, the lambda the FIRST of two arguments.
	 */
	@:pin('control')
	@:killer('M-STMT-LIST-CALLARG-BLOCK')
	public function testFinalInFirstLambdaArgChainIndents(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvisitAll(() -> {\n\t\t\tfinal ready:Bool = pendingMarkers.'
			+ 'length == 0 && sessionChanged && requestedAnchors.length == 0\n\t\t\t\t&& !seenBefore(index, spanPat'
			+ 'h, trailingNode);\n\t\t}, onDone);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvisitAll(() -> {\n\t\t\tfinal ready:Bool = pendingMarkers.length == 0 && '
				+ 'sessionChanged && requestedAnchors.length == 0 && !seenBefore(index, spanPath, trailingNode);\n\t\t}, onDone);\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * ASSIGNMENT with a `+` chain, the lambda the LAST of two arguments.
	 */
	public function testAssignmentInLastLambdaArgChainIndents(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvisitAll(alpha, () -> {\n\t\t\ttotalWidth = leadingMarkerW'
			+ 'idth + sessionPaddingWidth + requestedAnchorWidth + trailingMarkerWidth + closingAnchorWidth\n\t\t\t'
			+ '\t+ gutterWidth;\n\t\t});\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvisitAll(alpha, () -> {\n\t\t\ttotalWidth = leadingMarkerWidth + '
				+ 'sessionPaddingWidth + requestedAnchorWidth + trailingMarkerWidth + closingAnchorWidth + gutterWidth;\n\t\t});\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * A lambda inside a lambda argument: the inner body's chain also indents one level below its own statement.
	 */
	public function testNestedLambdaArgChainIndents(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvisitAll(() -> {\n\t\t\tvisitEach(alpha, () -> {\n\t\t\t\t'
			+ 'final ready:Bool = pendingMarkers.length == 0 && sessionChanged && requestedAnchors.length == 0\n\t'
			+ '\t\t\t\t&& !seenBefore(index, spanPath);\n\t\t\t});\n\t\t});\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvisitAll(() -> {\n\t\t\tvisitEach(alpha, () -> {\n\t\t\t\tfi'
				+ 'nal ready:Bool = pendingMarkers.length == 0 && sessionChanged && requestedAnchors.length == 0 && !se'
				+ 'enBefore(index, spanPath);\n\t\t\t});\n\t\t});\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * An anonymous `function` argument's body (`HxFnBlock.stmts`) takes the same barrier.
	 */
	public function testAnonymousFunctionArgChainIndents(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvisitAll(function() {\n\t\t\treturn pendingMarkers.length == 0 && sessionChanged '
			+ '&& requestedAnchors.count() == 0\n\t\t\t\t&& !seenBefore(index, spanPath, trailingNode);\n\t\t});\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvisitAll(function() {\n\t\t\treturn pendingMarkers.length =='
				+ ' 0 && sessionChanged && requestedAnchors.count() == 0 && !seenBefore(index, spanPath, trailingNode);\n\t\t});\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * An arrow-body `switch` argument: a CASE body statement (the tryparse statement Star) takes the barrier too.
	 */
	@:pin('control')
	@:killer('M-STMT-LIST-CALLARG-CASE')
	public function testArrowSwitchCaseBodyChainIndents(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvisitAll(() -> switch (kind) {\n\t\t\tcase 1:\n\t\t\t\tret'
			+ 'urn pendingMarkers.length == 0 && sessionChanged && requestedAnchors.length == 0\n\t\t\t\t\t&& !seen'
			+ 'Before(index, spanPath, trailingNode);\n\t\t\tcase _:\n\t\t\t\tfalse;\n\t\t});\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvisitAll(() -> switch (kind) {\n\t\t\tcase 1:\n\t\t\t\tretur'
				+ 'n pendingMarkers.length == 0 && sessionChanged && requestedAnchors.length == 0 && !seenBefore(index,'
				+ ' spanPath, trailingNode);\n\t\t\tcase _:\n\t\t\t\tfalse;\n\t\t});\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * REGRESSION PIN (does NOT discriminate the fix): an object-literal argument's field value is not
	 * a statement, so it keeps the call-argument base (fork parity: the `&&` at the field's column).
	 */
	public function testObjectLiteralFieldArgChainKeepsCallArgBase(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvisitAll(alpha, {\n\t\t\tready: pendingMarkers.length == 0 && sessionChanged && '
			+ 'requestedAnchors.length == 0\n\t\t\t&& !seenBefore(index, spanPath, trailingNode, closingNode)\n\t\t});\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvisitAll(alpha, {\n\t\t\tready: pendingMarkers.length == 0 && sessionChanged && '
				+ 'requestedAnchors.length == 0 && !seenBefore(index, spanPath, trailingNode, closingNode)\n\t\t});\n\t}\n}',
				CFG
			)
		);
	}

	/**
	 * REGRESSION PIN (does NOT discriminate the fix): an arrow EXPRESSION body is not
	 * a statement list either, so its chain keeps the call-argument base (fork parity).
	 */
	public function testArrowExpressionBodyArgChainKeepsCallArgBase(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\tvisitAll(\n\t\t\t() ->\n\t\t\t\tpendingMarkers.length == 0 && sessionChanged && '
			+ 'requestedAnchors.length == 0\n\t\t\t\t&& !seenBefore(index, spanPath, trailingNode, closingNode)\n\t\t);\n\t}\n\n}',
			triviaWrite(
				'class Sample {\n\tfunction run() {\n\t\tvisitAll(() -> pendingMarkers.length == 0 && sessionChanged '
				+ '&& requestedAnchors.length == 0 && !seenBefore(index, spanPath, trailingNode, closingNode));\n\t}\n}',
				CFG
			)
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		return HxWriteFixture.triviaWrite(src, cfg);
	}

}
