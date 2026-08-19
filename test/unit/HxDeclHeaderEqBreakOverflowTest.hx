package unit;

import utest.Assert;
import utest.Test;

/**
 * ω-N-break-after-eq, decl-header arm: a `var` / `final` declaration whose RHS
 * ALREADY wraps its own call arguments past the open paren, yet whose remaining
 * HEADER line (everything up to and including that open paren) still exceeds
 * `maxLineLength`, breaks after the `=` as a last resort. The existing arms
 * probe the GLUED natural first line, which resolves such a RHS flat and cannot
 * tell an over-wide header from an over-wide one-liner; this arm measures the
 * RHS head — the token run before its first break opportunity — so the break
 * fires only when no amount of RHS-internal wrapping can bring the header back
 * under the limit.
 *
 * Guards: a header EXACTLY on the limit stays glued (strict `>`), and a short
 * header whose full flat line overflows keeps the `=` glued and lets the call
 * arguments wrap (the pre-existing layout).
 *
 * Config is the real `hxformat.json` of the project this shape was found in
 * (tab / tabWidth 4, maxLineLength 140, `callParameter`
 * `fillLineWithLeadingBreak`). Identifiers are synthetic, length-matched to
 * that shape.
 */
@:nullSafety(Strict)
final class HxDeclHeaderEqBreakOverflowTest extends Test {

	private static final CONFIG: String = '{"indentation": {'
		+ '"character": "tab", "tabWidth": 4, "trailingWhitespace": false, "alignInlineSwitchCaseBody": true}, "emptyLines": {'
		+ '"maxAnywhereInFile": 1, "afterBlocks": "remove", "afterLeftCurly": "remove", "beforeRightCurly": "remove", "classEmptyLines": {'
		+ '"beginType": 1, "endType": 1}, "interfaceEmptyLines": {"beginType": 1, "endType": 1}, "abstractEmptyLines": {"beginType": 1, '
		+ '"endType": 1}, "uniformStatementBlanks": "collapse"}, "wrapping": {"comprehensionCuddledOpen": true, "functionSignature": {'
		+ '"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "totalItemLength <= n", "value": 100}, {"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}], "type": '
		+ '"noWrap"}]}, "maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": ['
		+ '{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {'
		+ '"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": ['
		+ '{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, '
		+ '{"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": '
		+ '"noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}, '
		+ '"expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", '
		+ '"value": 0}], "type": "noWrap"}]}, "opAddSubChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": '
		+ '"exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": '
		+ '"fillLine", "location": "beforeLast"}]}, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "whitespace": {'
		+ '"addLineCommentSpace": false, "normalizeLineCommentIndent": true, "commaPolicy": "after", "ifPolicy": '
		+ '"around", "forPolicy": "around", "whilePolicy": "around", "switchPolicy": "around", "catchPolicy": '
		+ '"around", "arrowFunctionsPolicy": "around", "functionTypeHaxe3Policy": "none", "functionTypeHaxe4Policy": '
		+ '"none", "binopPolicy": "around", "intervalPolicy": "around", "openingBracketPolicy": "none", '
		+ '"closingBracketPolicy": "none", "bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", '
		+ '"closingPolicy": "before", "arrowBodyOpenPad": true, "arrowBodyReflow": true}, "anonTypeBraces": {'
		+ '"openingPolicy": "after", "closingPolicy": "before"}, "typedefBraces": {"openingPolicy": "after", '
		+ '"closingPolicy": "before"}, "blockBraces": {"openingPolicy": "around", "closingPolicy": "before"}, '
		+ '"unknownBraces": {"openingPolicy": "after", "closingPolicy": "before"}, "singleStatementBraces": '
		+ '"remove"}, "parenConfig": {"callParens": {"openingPolicy": "none", "closingPolicy": "none"}, '
		+ '"funcParamParens": {"openingPolicy": "none", "closingPolicy": "none"}, "conditionParens": {'
		+ '"openingPolicy": "before", "closingPolicy": "after"}, "anonFuncParamParens": {"openingPolicy": "none", '
		+ '"closingPolicy": "none"}, "forLoopParens": {"openingPolicy": "before", "closingPolicy": "after"}, '
		+ '"expressionParens": {"openingPolicy": "none", "closingPolicy": "none"}, "switchSubjectParens": "remove"}}, '
		+ '"lineEnds": {"emptyCurly": "noBreak"}, "sameLine": {"ifBody": "fitLine", "forBody": "fitLine", '
		+ '"whileBody": "fitLine", "functionBody": "fitLine", "expressionIf": "next", "comprehensionFor": "fitLine"}}';

	public function new(): Void {
		super();
	}

	/** Header line is 145 columns even with the call args wrapped -> break after `=`. */
	public function testOverflowingHeaderBreaksAfterEq(): Void {
		final wrapped: String = 'class M {\n\n'
			+ '\tprivate static final recordsIncrementalRemoteRefreshCachePrime:RecordIncrementalRemoteRefreshCache = new '
			+ 'RecordIncrementalRemoteRefreshCache(\n\t\t\'Primes\'\n\t);\n\n}';
		final glued: String = 'class M {\n\n'
			+ '\tprivate static final recordsIncrementalRemoteRefreshCachePrime:RecordIncrementalRemoteRefreshCache = new '
			+ 'RecordIncrementalRemoteRefreshCache(\'Primes\');\n\n}';
		final broken: String = 'class M {\n\n'
			+ '\tprivate static final recordsIncrementalRemoteRefreshCachePrime:RecordIncrementalRemoteRefreshCache =\n'
			+ '\t\tnew RecordIncrementalRemoteRefreshCache(\'Primes\');\n\n}';
		Assert.equals(broken, triviaWrite(wrapped));
		Assert.equals(broken, triviaWrite(glued));
		Assert.equals(broken, triviaWrite(broken));
	}

	/** GUARD: header EXACTLY 140 columns -> stays glued, only the call args wrap. */
	public function testHeaderAtLimitStaysGlued(): Void {
		final src: String = 'class M {\n\n\tprivate static final recordsIncrementalRemoteRefreshPrime:RecordIncrementalRemoteRefreshCache '
			+ '= new RecordIncrementalRemoteRefreshCache(\n\t\t\'Primes\'\n\t);\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** GUARD: 51-column header, 144-column flat line -> the call args wrap, `=` stays glued. */
	public function testShortHeaderKeepsEqGlued(): Void {
		final src: String = 'class M {\n\n\tprivate final _badge:BadgeView = new BadgeView(\n'
			+ '\t\tlabel(\'TransparencyLevel\', 207), Typography.getFormatBadgeText(), 64, 20, Colors.PANEL_GREY\n\t);\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/** GUARD: a `+` chain's head ends at an OPERAND, not an open delimiter — the chain wraps its own later lines, `=` stays glued. */
	public function testOperatorChainHeadKeepsEqGlued(): Void {
		final src: String = 'class C {\n\n\tfunction f() {\n\t\tfinal request:String = \'SELECT filepath, folder, cloud_id, '
			+ 'folder_cloud_id, action, filepath_movedfrom, filepath_movedfromorigin, tstamp \'\n'
			+ '\t\t\t+ \'FROM files WHERE SUBSTR(filepath, 0, 12) = quoted ORDER by filepath\';\n\t}\n\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * A `+` chain whose FIRST operand is a call DOES end at an open delimiter, so the
	 * arm fires: the 145-column head is a real over-wide line and every break point the
	 * chain owns sits past it. Companion to the operand-headed chain above — the two
	 * together pin what `endsAtOpenDelim` does and does not exclude.
	 */
	public function testCallLedChainHeadBreaksAfterEq(): Void {
		final src: String = 'class C {\n\n\tfunction f() {\n\t\tfinal request:String = '
			+ 'buildIncrementalCloudUpdatesRequestForMovedFromPrefixWithQuotedSeparatorAndOrderedFilepathTailSegmentForCloudSync(\'SELECT '
			+ 'filepath, folder, cloud_id, action, tstamp \')\n\t\t\t+ \'FROM files WHERE prefix ORDER by filepath\';\n\t}\n\n}';
		final broken: String = 'class C {\n\n\tfunction f() {\n\t\tfinal request:String =\n'
			+ '\t\t\tbuildIncrementalCloudUpdatesRequestForMovedFromPrefixWithQuotedSeparatorAndOrderedFilepathTailSegmentForCloudSync(\n'
			+ '\t\t\t\t\t\'SELECT filepath, folder, cloud_id, action, tstamp \'\n'
			+ '\t\t\t\t) + \'FROM files WHERE prefix ORDER by filepath\';\n\t}\n\n}';
		Assert.equals(broken, triviaWrite(src));
		Assert.equals(broken, triviaWrite(broken));
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
