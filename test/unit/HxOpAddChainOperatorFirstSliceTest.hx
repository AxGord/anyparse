package unit;

import utest.Assert;
import utest.Test;

/**
 * omega-opadd-op-first: under a fillLine-family `expressionWrapping`
 * (TM's config), an overflowing 3+-operand `+`/`-` chain breaks at its
 * top-level operator seams per `opAddSubChain` (fillLine, beforeLast --
 * the operator LEADS the continuation) and leaves every operand's own
 * delimited group intact. The pre-slice engine committed the FORWARD
 * chain glue (`CollapsePass.chainGluedIfOpens`) the moment ANY inner
 * expression paren was measured as opening, regardless of how wide the
 * glued head then became -- so a 13-operand chain cascaded into glue with
 * every operator trailing at a line end. `CollapsePass.commitChainGlue`
 * now width-gates that commit for a tagged pure-opAddSub chain. Glue
 * survives where the glued head genuinely fits (the fallback pin below).
 * Identifiers and string contents are synthetic, length-preserving
 * renames of the reported TM site.
 */
@:nullSafety(Strict)
final class HxOpAddChainOperatorFirstSliceTest extends Test {

	private static final CFG: String =
		'{"indentation":{"character":"tab","tabWidth":4,"trailingWhitespace":false,"alignInlineSwitchCaseBody":true},"emptyLines":{"maxAnywhereInFile":2,"afterBlocks":"remove","afterLeftCurly":"keep","beforeRightCurly":"keep","classEmptyLines":{"beginType":1,"endType":1},"interfaceEmptyLines":{"beginType":1,"endType":1},"abstractEmptyLines":{"beginType":1,"endType":1}},"wrapping":{"functionSignature":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"totalItemLength <= n","value":100},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1}],"type":"noWrap"}]},"maxLineLength":140,"callParameter":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"itemCount <= n","value":1},{"cond":"totalItemLength <= n","value":100}],"type":"noWrap"}]},"opBoolChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"itemCount <= n","value":3},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"totalItemLength <= n","value":120},{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"expressionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]},"opAddSubChain":{"defaultWrap":"noWrap","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"},{"conditions":[{"cond":"exceedsMaxLineLength","value":1}],"type":"fillLine","location":"beforeLast"}]},"conditionWrapping":{"defaultWrap":"fillLineWithLeadingBreak","rules":[{"conditions":[{"cond":"exceedsMaxLineLength","value":0}],"type":"noWrap"}]}},"whitespace":{"addLineCommentSpace":false,"commaPolicy":"after","ifPolicy":"around","forPolicy":"around","whilePolicy":"around","switchPolicy":"around","catchPolicy":"around","arrowFunctionsPolicy":"around","functionTypeHaxe3Policy":"none","functionTypeHaxe4Policy":"none","binopPolicy":"around","intervalPolicy":"around","openingBracketPolicy":"none","closingBracketPolicy":"none","bracesConfig":{"objectLiteralBraces":{"openingPolicy":"after","closingPolicy":"before"},"anonTypeBraces":{"openingPolicy":"after","closingPolicy":"before"},"typedefBraces":{"openingPolicy":"after","closingPolicy":"before"},"blockBraces":{"openingPolicy":"around","closingPolicy":"before"},"unknownBraces":{"openingPolicy":"after","closingPolicy":"before"}},"parenConfig":{"callParens":{"openingPolicy":"none","closingPolicy":"none"},"funcParamParens":{"openingPolicy":"none","closingPolicy":"none"},"conditionParens":{"openingPolicy":"before","closingPolicy":"after"},"anonFuncParamParens":{"openingPolicy":"none","closingPolicy":"none"},"forLoopParens":{"openingPolicy":"before","closingPolicy":"after"},"expressionParens":{"openingPolicy":"none","closingPolicy":"none"}}},"lineEnds":{"emptyCurly":"noBreak"},"sameLine":{"ifBody":"fitLine","forBody":"fitLine","whileBody":"fitLine","functionBody":"fitLine","expressionIf":"next","comprehensionFor":"fitLine"}}';
	private static final MANY_OPERAND_SRC: String = 'class Sample {\n\tfunction run() {\n'
		+ "\t\tdatalinkPort.execute('INSERT INTO items (itempath,bucket,link_key,bucket_link_key,verbid,itempath_sourcekey,itempath_sourceoriginkey,stampedat) VALUES (' + datalinkPort.quote(record.itemPath) + ',' + (record.bucket ? '1' : '0') + ',' + (!record.bucket && record.linkKey != -1 ? Std.string(record.linkKey) : 'NULL') + ',' + (record.bucket && record.linkKey != -1 ? Std.string(record.linkKey) : 'NULL') + ',${datalinkPort.quote(RemoteCatalog.remoteActionToLabel(record.verbId))},' + (record.itemPathSourceKey == null ? 'NULL' : datalinkPort.quote(record.itemPathSourceKey)) + ',' + (record.itemPathSourceOriginKey == null ? (record.itemPathSourceKey == null ? 'NULL' : datalinkPort.quote(record.itemPathSourceKey)) : datalinkPort.quote(record.itemPathSourceOriginKey)) + ',${record.stampedAt});');\n"
		+ '\t}\n}';
	private static final SHORT_HEAD_SRC: String = 'class Sample {\n\tfunction run() {\n'
		+ "\t\tport.execute('rows=' + (record.itemPathSourceOriginKey == null ? (record.itemPathSourceKey == null ? 'NULL' : port.quote(record.itemPathSourceKey)) : port.quote(record.itemPathSourceOriginKey)) + ';');\n"
		+ '\t}\n}';
	private static final BOUNDARY_GLUE_SRC: String = 'class Sample {\n\tfunction run() {\n'
		+ "\t\tquery = 'SELECT itempath, bucket, link_key, tags FROM items WHERE bucket = 1 AND link_key <> -1 ORDER BY stampedat DESC OFFSET ' + (record.itemPathSourceOriginKey == null ? (record.itemPathSourceKey == null ? 'NULL' : port.quote(record.itemPathSourceKey)) : port.quote(record.itemPathSourceOriginKey)) + ';';\n"
		+ '\t}\n}';
	private static final BOUNDARY_BREAK_SRC: String = 'class Sample {\n\tfunction run() {\n'
		+ "\t\tquery = 'SELECT itempath, bucket, link_key, tagid FROM items WHERE bucket = 1 AND link_key <> -1 ORDER BY stampedat DESC OFFSET ' + (record.itemPathSourceOriginKey == null ? (record.itemPathSourceKey == null ? 'NULL' : port.quote(record.itemPathSourceKey)) : port.quote(record.itemPathSourceOriginKey)) + ';';\n"
		+ '\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * DISCRIMINATOR (renders the pre-slice glue cascade with the slice
	 * reverted). The migration-site shape -- sole-arg call, 13 operands,
	 * over-wide leading literal, mid-chain call operand, ternary paren
	 * operands, interpolated-string operands: the chain breaks at its top-level
	 * `+` seams with the operator LEADING each continuation, and every
	 * operand's own delimited group stays intact. Before the width gate the
	 * committed forward glue cascaded -- the head line ran ~166 columns and
	 * every later paren / call operand opened at its own column.
	 */
	public function testManyOperandChainBreaksAtOperatorSeams(): Void {
		Assert.equals(
			"class Sample {\n\n\tfunction run() {\n\t\tdatalinkPort.execute(\n\t\t\t'INSERT INTO items (itempath,bucket,link_key,bucket_link_key,verbid,itempath_sourcekey,itempath_sourceoriginkey,stampedat) VALUES ('\n\t\t\t+ datalinkPort.quote(record.itemPath) + ',' + (record.bucket ? '1' : '0') + ','\n\t\t\t+ (!record.bucket && record.linkKey != -1 ? Std.string(record.linkKey) : 'NULL') + ','\n\t\t\t+ (record.bucket && record.linkKey != -1 ? Std.string(record.linkKey) : 'NULL')\n\t\t\t+ ',${datalinkPort.quote(RemoteCatalog.remoteActionToLabel(record.verbId))},'\n\t\t\t+ (record.itemPathSourceKey == null ? 'NULL' : datalinkPort.quote(record.itemPathSourceKey)) + ','\n\t\t\t+ (\n\t\t\t\trecord.itemPathSourceOriginKey == null\n\t\t\t\t\t? (record.itemPathSourceKey == null ? 'NULL' : datalinkPort.quote(record.itemPathSourceKey))\n\t\t\t\t\t: datalinkPort.quote(record.itemPathSourceOriginKey)\n\t\t\t) + ',${record.stampedAt});'\n\t\t);\n\t}\n\n}",
			triviaWrite(MANY_OPERAND_SRC, CFG)
		);
	}

	/**
	 * CONTROL (passes with the slice reverted -- byte-identical before and
	 * after; the discriminator is its many-operand sibling). Glue is still the
	 * answer when the operand's own rendering forces it AND the glued head
	 * fits: a short head plus a mid-chain paren too wide for any continuation
	 * line renders `head + (` / inner / `) + tail`. The width gate is a gate,
	 * not a ban.
	 */
	public function testMidChainOpeningParenKeepsTheGlueWhenTheHeadFits(): Void {
		Assert.equals(
			"class Sample {\n\n\tfunction run() {\n\t\tport.execute('rows=' + (\n\t\t\trecord.itemPathSourceOriginKey == null\n\t\t\t\t? (record.itemPathSourceKey == null ? 'NULL' : port.quote(record.itemPathSourceKey))\n\t\t\t\t: port.quote(record.itemPathSourceOriginKey)\n\t\t) + ';');\n\t}\n\n}",
			triviaWrite(SHORT_HEAD_SRC, CFG)
		);
	}

	/**
	 * Exact boundary, glue side -- CONTROL (passes with the slice reverted; the
	 * break-side sibling one column over is the discriminator). The glued first
	 * line lands on column 140 = `maxLineLength` and still glues. Together the
	 * pair fixes the `IfNaturalFirstLineFitsOpenDelim(width, ...)` calibration
	 * `CollapsePass.commitChainGlue` shares with `BinaryChainEmit`'s
	 * `glueProbe` to a single column.
	 */
	public function testGlueBoundaryAtExactlyTheLimitStillGlues(): Void {
		Assert.equals(
			"class Sample {\n\n\tfunction run() {\n\t\tquery = 'SELECT itempath, bucket, link_key, tags FROM items WHERE bucket = 1 AND link_key <> -1 ORDER BY stampedat DESC OFFSET ' + (\n\t\t\trecord.itemPathSourceOriginKey == null\n\t\t\t\t? (record.itemPathSourceKey == null ? 'NULL' : port.quote(record.itemPathSourceKey))\n\t\t\t\t: port.quote(record.itemPathSourceOriginKey)\n\t\t) + ';';\n\t}\n\n}",
			triviaWrite(BOUNDARY_GLUE_SRC, CFG)
		);
	}

	/**
	 * Exact boundary, break side -- DISCRIMINATOR (glues at 141 columns with
	 * the slice reverted). One more literal column puts the glued first line at
	 * 141 and the chain breaks at its operator seams instead.
	 */
	public function testGlueBoundaryOneColumnOverBreaks(): Void {
		Assert.equals(
			"class Sample {\n\n\tfunction run() {\n\t\tquery = 'SELECT itempath, bucket, link_key, tagid FROM items WHERE bucket = 1 AND link_key <> -1 ORDER BY stampedat DESC OFFSET '\n\t\t\t+ (\n\t\t\t\trecord.itemPathSourceOriginKey == null\n\t\t\t\t\t? (record.itemPathSourceKey == null ? 'NULL' : port.quote(record.itemPathSourceKey))\n\t\t\t\t\t: port.quote(record.itemPathSourceOriginKey)\n\t\t\t) + ';';\n\t}\n\n}",
			triviaWrite(BOUNDARY_BREAK_SRC, CFG)
		);
	}

	private inline function triviaWrite(src: String, cfg: String): String {
		return HxWriteFixture.triviaWrite(src, cfg);
	}

}
