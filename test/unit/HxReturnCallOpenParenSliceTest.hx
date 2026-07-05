package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-rhs-call-open: a `return <value>;` whose value is a SINGLE call that
 * overflows keeps `return` glued and OPENS the call's own paren (leading-
 * breaks its argument list), instead of breaking after the `return` keyword
 * and leaving the call flat on the next line. Mirrors the fork, which marks
 * `return`+value same-line and defers the overflow to its wrapping pass —
 * that pass wraps the call paren when the call is wrappable.
 *
 * The `return` body is a FitLine natural-first-line probe
 * (`IfNaturalFirstLineExceeds`). When the value's outer call arg-list is a
 * single complex argument (a nested binary chain / call), its break shape is
 * itself an `IfNaturalFirstLineFitsOpenDelim` probe. The natural-width walk
 * used to descend that probe's GLUED flat side unconditionally, measuring the
 * value's full flat width and wrongly breaking `return`; it now mirrors
 * render — resolving the open-delim glue-vs-open decision so a value that WILL
 * open its paren caps the natural first line at that `(` and stays glued.
 *
 * The resolve is gated to the RHS probe (`resolveOpenDelim`) so a NESTED open-
 * delim measured for a sibling expr-paren-open decision (a bare `list.add(new
 * Wrapper(new Inner(...)))` statement, which must open the OUTER `.add(` paren,
 * not the inner one) is left descending flat — byte-inert.
 */
@:nullSafety(Strict)
final class HxReturnCallOpenParenSliceTest extends Test {

	private static final CONFIG: String = '{"wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, "expressionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}, "opBoolChain": {"defaultWrap": "noWrap", "rules": [{"conditions": [{"cond": "itemCount <= n", "value": 3}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "totalItemLength <= n", "value": 120}, {"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"}]}}}';

	public function new(): Void {
		super();
	}

	// The fix: a single-argument call value (its sole arg is a nested binary
	// chain) opens the OUTER call paren instead of breaking after `return`.
	public function testReturnSingleArgCallOpensParen(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn check(\n\t\t\tstore.validate("name.txt", false, ACTION_UPLOADED, 12345, 1, extraPaddingArgumentValue, morePaddingArgumentsHereNow) == false\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	// Regression guard: a multi-argument call value keeps its already-correct
	// open-paren wrap (`return`stays glued).
	public function testReturnMultiArgCallOpensParen(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn lookupByIdentifierWithAModeratelyLongMethodName(\n\t\t\tfirstArgumentValue, secondArgumentValue, thirdArgumentValue, fourthArgumentValue\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	// Guard: a value whose call is NoWrap-pinned (single short arg <= 100, no
	// wrappable paren) still breaks after `return` — the fix must not over-glue.
	public function testReturnNoWrapCallBreaksKeyword(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\treturn\n\t\t\tstoreLookupByModeratelyLongishMethodName(theSingleShortArgumentValueThatStaysFlatWhenBrokenToNextLineAfterReturnKeywordHerezz);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	// Narrowing guard: a bare expression statement whose value is a single-arg
	// call opens the OUTER paren (not a nested inner one) — the RHS-only resolve
	// gate must leave this expr-paren-open decision untouched.
	public function testBareNestedCallOpensOuterParen(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tcontainer.append(\n\t\t\tnew Wrapper(new Inner(widthValueHere, heightValueHere, 0x6E6F70, 0xF3F3F3, 0xacacac, 0x000000, firstFlagValueHere))\n\t\t);\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	// Guard: a binary-chain RHS (not a call) keeps its `&&`/`||` chain wrap and
	// stays glued to `=` — the fix does not turn a chain RHS into a paren-open.
	public function testBinaryChainRhsKeepsChainWrap(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal ready:Bool = someModeratelyLongOperandName && anotherModeratelyLongOperandName\n\t\t\t|| yetAnotherLongOperandExpressionToOverflowLineNow;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONFIG);
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
