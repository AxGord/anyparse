package unit;

import utest.Assert;
import utest.Test;

/**
 * omega-ternary-operand-chain-nest: a wrapped binary-operator continuation that
 * belongs to a ternary OPERAND (condition, then, else) sits one indent level
 * DEEPER than that operand's own line, in every enclosing context. The ternary
 * dispatch never suppresses its own `?` / `:` Nest, so the `_callArgChainNest`
 * flag a leading-break call argument sets is stale for its operands; it is
 * cleared there the way the infix dispatch clears it. Identifiers are fully
 * synthetic.
 */
@:nullSafety(Strict)
final class HxTernaryBranchChainIndentTest extends Test {

	private static final CFG: String = '{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,'
		+ '"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove",'
		+ '"afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},'
		+ '"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,'
		+ '"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{'
		+ '"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},'
		+ '{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},'
		+ '"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],'
		+ '"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap",'
		+ '"rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{'
		+ '"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{'
		+ '"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine",'
		+ '"location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},'
		+ '"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength",'
		+ '"value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],'
		+ '"type":"fillLine","location":"beforeLast"}]},' + '"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak",'
		+ '"rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},'
		+ '"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around",'
		+ '"forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around",'
		+ '"arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none",'
		+ '"functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around",'
		+ '"openingBracketPolicy":"none","closingBracketPolicy":"none",'
		+ '"bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},'
		+ '"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},'
		+ '"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},'
		+ '"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},'
		+ '"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},'
		+ '"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},'
		+ '"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},' + '"lineEnds":{"emptyCurly":"noBreak"},'
		+ '"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine",'
		+ '"functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';

	public function new(): Void {
		super();
	}

	/**
	 * A ternary that is a leading-break CALL ARGUMENT: its THEN-branch `+` chain
	 * continues one indent level BELOW the `?` line, exactly as it does in every
	 * other host. Before the fix the branch operand inherited the call-arg
	 * `_callArgChainNest` flag, suppressed its own continuation Nest, and the `+`
	 * landed at the `?` / `:` column -- reading as a third ternary rung.
	 */
	public function testCallArgTernaryThenBranchChainIndentsBelowBranchLine(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\temitTrace(\n\t\t\tactionName, spanPath, succeeded,\n\t\t\tmarkerNode != null\n'
			+ "\t\t\t\t? ', local span path -> resolved span path of the marker node, kept verbatim'\n\t\t\t\t\t+ ', node id and node "
			+ "stamp plus the resolved parent chain of that marker'\n\t\t\t\t: '',\n\t\t\tposInfo\n\t\t);\n\t}\n\n}",
			triviaWrite(
				"class Sample {\n\tfunction run() {\n\t\temitTrace(actionName, spanPath, succeeded, markerNode != null ? ', local span "
				+ "path -> resolved span path of the marker node, kept verbatim' + ', node id and node stamp plus the resolved parent "
				+ "chain of that marker' : '', posInfo);\n\t}\n}",
				CFG
			)
		);
	}

	/**
	 * Same leak on the ELSE branch: the `+` continues below the `:` line, not at it.
	 */
	public function testCallArgTernaryElseBranchChainIndentsBelowBranchLine(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\temitTrace(\n\t\t\tactionName, spanPath, succeeded,\n\t\t\tmarkerNode == null\n'
			+ "\t\t\t\t? ''\n\t\t\t\t: ', local span path -> resolved span path of the marker node, kept verbatim'\n"
			+ "\t\t\t\t\t+ ', node id and node stamp plus the resolved parent chain of that marker',\n\t\t\tposInfo\n\t\t);\n\t}\n\n}",
			triviaWrite(
				"class Sample {\n\tfunction run() {\n\t\temitTrace(actionName, spanPath, succeeded, markerNode == null ? '' : ', local "
				+ "span path -> resolved span path of the marker node, kept verbatim' + ', node id and node stamp plus the resolved parent "
				+ "chain of that marker', posInfo);\n\t}\n}",
				CFG
			)
		);
	}

	/**
	 * Same leak on the CONDITION operand: an `&&` chain condition continues one
	 * level below its own line. All three operands are written with the ternary's
	 * opt, so one clear fixes all three.
	 */
	public function testCallArgTernaryConditionChainIndentsBelowConditionLine(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\temitTrace(\n\t\t\tactionName, spanPath, succeeded,\n'
			+ '\t\t\tmarkerNode != null && parentNode != null && resolvedSpan != null && pendingStamp != null && trailingAnchor != null\n'
			+ "\t\t\t\t&& closingAnchor != null\n\t\t\t\t? 'yes'\n\t\t\t\t: '',\n\t\t\tposInfo\n\t\t);\n\t}\n\n}",
			triviaWrite(
				'class Sample {\n\tfunction run() {\n'
				+ '\t\temitTrace(actionName, spanPath, succeeded, markerNode != null && parentNode != null && resolvedSpan != null && '
				+ "pendingStamp != null && trailingAnchor != null && closingAnchor != null ? 'yes' : '', posInfo);\n\t}\n}",
				CFG
			)
		);
	}

	/**
	 * REGRESSION PIN (does NOT discriminate the fix): the same ternary inside an
	 * expression paren inside a `+` chain already indented its branch continuation
	 * correctly -- the enclosing chain consumed `_callArgChainNest` before the
	 * ternary saw it. Pinned so the call-arg fix cannot drift this host.
	 */
	public function testParenHostTernaryThenBranchChainKeepsItsIndent(): Void {
		Assert.equals(
			"class Sample {\n\n\tfunction run() {\n\t\treturn emitTrace('prefix span: ' + (\n\t\t\tmarkerNode != null\n"
			+ "\t\t\t\t? ', local span path -> resolved span path of the marker node, kept verbatim'\n"
			+ "\t\t\t\t\t+ ', node id and node stamp plus the resolved parent chain of that marker'\n\t\t\t\t: ''\n\t\t));\n\t}\n\n}",
			triviaWrite(
				'class Sample {\n\tfunction run() {\n'
				+ "\t\treturn emitTrace('prefix span: ' + (markerNode != null ? ', local span path -> resolved span path of the marker "
				+ "node, kept verbatim' + ', node id and node stamp plus the resolved parent chain of that marker' : ''));\n\t}\n}",
				CFG
			)
		);
	}

	/**
	 * BOUNDARY PIN (does NOT discriminate the fix): the then-branch's flat `A + B`
	 * physical line is EXACTLY maxLineLength (140) at the `?` column, so the chain
	 * stays glued and no continuation indent is chosen at all. Guards the
	 * fits-probe width+1 off-by-one against the sister case below.
	 */
	public function testBranchChainStaysFlatAtExactLimit(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\temitTrace(\n\t\t\talpha, beta,\n\t\t\tmarkerNode != null\n'
			+ "\t\t\t\t? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' + "
			+ "'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'\n\t\t\t\t: '',\n\t\t\tgamma\n\t\t);\n\t}\n\n}",
			triviaWrite(
				'class Sample {\n\tfunction run() {\n'
				+ "\t\temitTrace(alpha, beta, markerNode != null ? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' + "
				+ "'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' : '', gamma);\n\t}\n}",
				CFG
			)
		);
	}

	/**
	 * BOUNDARY: one character past the limit the same chain breaks, and the
	 * continuation sits one level below the `?` line.
	 */
	public function testBranchChainBreaksOneOverLimit(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\temitTrace(\n\t\t\talpha, beta,\n\t\t\tmarkerNode != null\n'
			+ "\t\t\t\t? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\n"
			+ "\t\t\t\t\t+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'\n\t\t\t\t: '',\n\t\t\tgamma\n\t\t);\n\t}\n\n}",
			triviaWrite(
				'class Sample {\n\tfunction run() {\n'
				+ "\t\temitTrace(alpha, beta, markerNode != null ? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' + "
				+ "'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' : '', gamma);\n\t}\n}",
				CFG
			)
		);
	}

	/**
	 * BOUNDARY, fill-packing axis: a 3-operand branch chain whose two tail
	 * operands together FIT one continuation line at the old (branch-line) column
	 * but not at the deeper one. They must land on separate lines -- the deeper
	 * indent is charged to the fill budget, not applied after packing.
	 */
	public function testBranchChainFillPackingCountsTheDeeperIndent(): Void {
		Assert.equals(
			'class Sample {\n\n\tfunction run() {\n\t\temitTrace(\n\t\t\talpha, beta,\n\t\t\tmarkerNode != null\n'
			+ "\t\t\t\t? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\n"
			+ "\t\t\t\t\t+ 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'\n"
			+ "\t\t\t\t\t+ 'ccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'\n\t\t\t\t: '',\n\t\t\tgamma\n\t\t);\n\t}\n\n}",
			triviaWrite(
				'class Sample {\n\tfunction run() {\n'
				+ "\t\temitTrace(alpha, beta, markerNode != null ? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' + "
				+ "'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' + "
				+ "'ccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' : '', gamma);\n\t}\n}",
				CFG
			)
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		return HxWriteFixture.triviaWrite(src, cfg);
	}

}
