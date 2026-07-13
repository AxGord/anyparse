package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-binop-wraprules — `||` / `&&` (haxe-formatter `opBoolChain`)
 * and `+` / `-` (haxe-formatter `opAddSubChain`) binary-op chains
 * dispatch to a chain-level emit (`BinaryChainEmit`) that gathers the
 * full same-class subtree into a flat `(items, ops)` pair, runs the
 * `WrapRules` cascade once, and emits one of four shapes:
 *  - `NoWrap` (all inline, ` op ` between);
 *  - `OnePerLineAfterFirst` (BeforeLast op placement — `\n+indent op `
 *    prefixes each continuation line);
 *  - `OnePerLine` (After op placement — each line ends with ` op`
 *    except the last);
 *  - `FillLine` (Wadler `fillSep` — soft-line packing).
 *
 * Defaults: single rule `ExceedsMaxLineLength → OnePerLineAfterFirst`
 * over `defaultMode: NoWrap` for both `opBoolChainWrap` and
 * `opAddSubChainWrap`. Drives the `\n\t\t\t|| ...` continuation shape
 * for haxe-formatter default-config fixtures (issue_187 default,
 * issue_179 long throw).
 *
 * Cases:
 *  - `testShortBoolChainStaysFlat`: short `||` chain fits → `NoWrap`
 *    inline (`a || b || c`).
 *  - `testLongBoolChainBreaksOPLAfterFirst`: long `||` chain exceeds
 *    line width → `OPLAfterFirst` shape: items[0] flat, continuations
 *    `\n+indent || items[i]` (BeforeLast op placement).
 *  - `testMixedBoolOpsCollapseIntoOneChain`: `a || b && c` gathered as
 *    ONE chain at outermost prec — items=[a,b,c], ops=['||','&&']. All
 *    operators land at same indent on break.
 *  - `testLongAddSubChainBreaksOPLAfterFirst`: long `+` string concat
 *    chain breaks identically — `\n+indent + items[i]` continuation.
 *  - `testCustomConfigOnePerLine`: `hxformat.json` overriding
 *    `opBoolChain.defaultWrap: onePerLine` switches the cascade default
 *    → `OnePerLine` shape (After op placement, every operand on its
 *    own indented line).
 *  - `testNonChainOpFallsBackToG1`: `<<` is not in the chain class set
 *    → falls through to existing G.1 per-binary Group emission. Smoke
 *    that the chain-class guard is correct.
 *  - `testNullCoalShortChainStaysFlat`: a short `??` chain that fits stays
 *    inline (NoWrap) -- the null-coalescing analog of the `||` short-chain
 *    case. (Overflow-glued `??` is covered by `HxBinopGroupWrapSliceTest`.)
 *  - `testIdempotencyLongBoolChain`: round-trip stable after the new
 *    chain emission shape.
 */
class HxBinaryChainWrapSliceTest extends HxTestHelpers {

	/**
	 * Shared input for the two cond-chain paren-open/head-glue guard tests
	 * (`testParenOpensForOpBoolChainOperandInCondition` and
	 * `testCondChainHeadGluesToOpeningParen`): a 7-operand `||` subchain as the
	 * last operand of a condition `&&` chain, plus a non-NoWrap wrapping config.
	 */
	private static final CONDITION_CHAIN_SRC: String = 'class C { static function m():Void { if (alphaCondVal && betaCondVal && (cccccccccccc || dddddddddddd || eeeeeeeeeeee || ffffffffffff || gggggggggggg || hhhhhhhhhhhh || iiiiiiiiiiii)) return; } }';

	private static final CONDITION_CHAIN_CFG: String = '{ "wrapping": { "conditionWrapping": { "defaultWrap": "fillLineWithLeadingBreak", "rules": [{ "conditions": [{ "cond": "exceedsMaxLineLength", "value": 0 }], "type": "noWrap" }] }, "expressionWrapping": { "defaultWrap": "fillLineWithLeadingBreak", "rules": [{ "conditions": [{ "cond": "exceedsMaxLineLength", "value": 0 }], "type": "noWrap" }] }, "opBoolChain": { "defaultWrap": "noWrap", "rules": [{ "conditions": [{ "cond": "exceedsMaxLineLength", "value": 1 }], "type": "fillLine", "location": "beforeLast" }] } } }';

	public function testShortBoolChainStaysFlat(): Void {
		final src: String = 'class C { var x:Bool = a || b || c; }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('a || b || c') != -1, 'short chain stayed flat in: <$out>');
		Assert.isTrue(out.indexOf('a ||\n') == -1, 'short chain unexpectedly broke in: <$out>');
	}

	public function testLongBoolChainBreaksOPLAfterFirst(): Void {
		final src: String = 'class C { static function m():Void { dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
		final out: String = writeWithLineWidth(src, 80);
		// items[0] == 'aaaaaaaaaaaa' stays glued to `dirty = `.
		Assert.isTrue(out.indexOf('dirty = aaaaaaaaaaaa') != -1, 'expected `dirty = aaaa…` lead-line shape in: <$out>');
		// Continuations carry the op as PREFIX on the new line at fn-body
		// indent (3 tabs: class > main > expr).
		Assert.isTrue(out.indexOf('\n\t\t\t|| bbbbbbbbbbbb') != -1, 'expected `\\n\\t\\t\\t|| bbb` continuation in: <$out>');
		// No `||\n` (op should not trail at end of line — that would be
		// After-placement, which only fires for OnePerLine / FillLine).
		Assert.isTrue(out.indexOf('||\n') == -1, 'op should not trail at end of line for default cascade in: <$out>');
	}

	public function testMixedBoolOpsCollapseIntoOneChain(): Void {
		// `a || b && c || d` — AST is `Or(Or(a, And(b, c)), d)`. The
		// chain extractor walks Or and And ctors uniformly, gathering
		// items=[a, b, c, d] and ops=['||','&&','||']. A break should
		// land all four operators at the same indent depth, not split
		// the chain at the `&&` boundary.
		final src: String = 'class C { static function m():Void { dirty = aaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbb && cccccccccccccccc || dddddddddddddddd; } }';
		final out: String = writeWithLineWidth(src, 80);
		// All four operators continuation-led at same indent (3 tabs).
		Assert.isTrue(
			out.indexOf('\n\t\t\t|| bbbbbbbbbbbbbbbb') != -1 || out.indexOf('\n\t\t\t&& bbbbbbbbbbbbbbbb') != -1,
			'first continuation present in: <$out>'
		);
	}

	public function testLongAddSubChainBreaksOPLAfterFirst(): Void {
		// Mirror of issue_179: long string concat chain.
		final src: String = "class C { static function m():Void { trace(\"can't insert node\" + key + \" with size of \" + width + \"; \" + height + \" in atlas \" + name); } }";
		final out: String = writeWithLineWidth(src, 80);
		// Continuation `\n + ` (BeforeLast `+ ` placement). Indent
		// depth is class > fn-body > Nest cols = 3 tabs; the chain is
		// the single arg of `trace(...)`, the args list itself stays
		// inline so no extra arg-list nest applies.
		Assert.isTrue(out.indexOf('\n\t\t\t+ ') != -1, 'expected `+ ` continuation in: <$out>');
	}

	public function testCustomConfigOnePerLine(): Void {
		// User-supplied `opBoolChain.defaultWrap: onePerLine` flips the
		// cascade default to `OnePerLine` (After op placement). Because
		// the rules array stays unset (preserved from baseline), the
		// `ExceedsMaxLineLength → OnePerLineAfterFirst` rule still fires
		// when exceeds; baseline behaviour for short flat chains is
		// unchanged. Test a short chain to verify the loader wired the
		// `defaultWrap` swap (short chain uses defaultMode, not the
		// rule branch).
		final src: String = 'class C { var x:Bool = a || b || c; }';
		// Empty `rules: []` so the cascade falls through directly to
		// `defaultMode: OnePerLine` regardless of exceeds — without it,
		// the baseline `ExceedsMaxLineLength → OnePerLineAfterFirst`
		// rule still fires in the break-mode arm of the cascade and
		// the After-op shape never surfaces.
		final cfg: String = '{ "wrapping": { "opBoolChain": { "defaultWrap": "onePerLine", "rules": [] } } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.lineWidth = 80;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		// Default flips to OnePerLine even on a short chain — every
		// item lands on its own line.
		Assert.isTrue(out.indexOf('a ||\n') != -1, 'expected `a ||\\n` After op placement in: <$out>');
	}

	public function testNonChainOpFallsBackToG1(): Void {
		// `<<` is shift, not a chain class. Long chain still breaks, but
		// through the G.1 per-binary Group path (each `<<` Group decides
		// independently), not the BinaryChainEmit cascade.
		final src: String = 'class C { static function m():Void { var v:Int = aaaaaaaaaaaa << bbbbbbbbbbbb << cccccccccccc << dddddddddddd << eeeeeeeeeeee; } }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('<< bbbbbbbbbbbb') != -1, 'expected `<< bbb` segment in: <$out>');
		// G.1 emits op-before-operand on continuation, same shape as G.4
		// OPLAfterFirst, so the existing assertion shape still applies.
		Assert.isTrue(out.indexOf('\n\t\t\t<< ') != -1, 'expected G.1 fallback continuation in: <$out>');
	}

	public function testNullCoalShortChainStaysFlat(): Void {
		// Guard: a short `??` chain that fits stays inline (NoWrap), matching
		// `testShortBoolChainStaysFlat` for `||`.
		final src: String = 'class C { var x = aaaa ?? bbbb ?? cccc; }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('aaaa ?? bbbb ?? cccc') != -1, 'short `??` chain stayed flat in: <$out>');
		Assert.isTrue(out.indexOf('aaaa ??\n') == -1, 'short `??` chain unexpectedly broke in: <$out>');
	}

	public function testAssignTrailingSpaceDropsBeforeRhsBreak(): Void {
		// Slice ω-assign-rhs-optspace: when the RHS chain wraps with a
		// leading hardline (e.g. `opBoolChain.defaultWrap: onePerLine`
		// forces every operand onto its own line including the first),
		// the trailing space after `=` must drop so we emit `dirty =\n`
		// rather than `dirty = \n` — matching haxe-formatter's
		// issue_187_oneline expected output. The split lead emits the
		// trailing space as `OptSpace`, which the renderer drops on
		// break-mode hardline collision.
		final src: String = 'class C { static function m():Void { dirty = a || b || c; } }';
		final cfg: String = '{ "wrapping": { "opBoolChain": { "defaultWrap": "onePerLine", "rules": [] } } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.lineWidth = 80;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('dirty =\n') != -1, 'expected `dirty =\\n` (no trailing space before break-mode hardline) in: <$out>');
		Assert.isTrue(out.indexOf('dirty = \n') == -1, 'unexpected trailing space before hardline in: <$out>');
	}

	public function testAssignFlatKeepsAroundSpace(): Void {
		// Smoke: when the RHS of an assignment expression fits flat, the
		// trailing OptSpace after `=` flushes via the next Text — the
		// output is still ` = ` with the space intact (no behavioural
		// change for flat assignments). Routed through the binary-op
		// Pratt path (`Assign(IdentExpr, IntLit)` inside a function
		// body), not `HxVarDecl @:lead('=')`, so it actually exercises
		// the new split-OptSpace branch.
		final src: String = 'class C { static function m():Void { dirty = 1; } }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('dirty = 1') != -1, 'expected flat `dirty = 1` with around-space intact in: <$out>');
	}

	public function testParenWrapBreakOnLeadingHardline(): Void {
		// ω-paren-wrap-break: when a `@:wrap('(', ')')` ctor's inner Doc
		// opens with a hardline (here: `opBoolChain.defaultWrap=onePerLine`
		// forces every operand onto its own line, including the first),
		// the close `)` lands on its own line at the outer indent —
		// matches haxe-formatter's `return !(\n…\n);` shape on the first
		// sub-case of issue_187_oneline. Gated at runtime via
		// `WrapList.startsWithHardline` so the default OPLAfterFirst
		// cascade (no leading hardline, items[0] glued to `((`) keeps the
		// close glued to the last item.
		final src: String = 'class Main {\n\tpublic static function main() {\n\t\treturn !(\n\t\t\ta.y + b.h <= c.y || d.y >= e.y + f.h ||\n\t\t\tg.x + h.w <= i.x || j.x >= k.x + l.w\n\t\t);\n\t}\n}';
		final cfg: String = '{ "wrapping": { "opBoolChain": { "defaultWrap": "onePerLine", "rules": [] } } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.lineWidth = 80;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('\n\t\t);') != -1, 'expected close `)` on own line at outer indent in: <$out>');
		Assert.isTrue(out.indexOf('l.w);') == -1, 'close should not be glued to last item in: <$out>');
	}

	public function testParenWrapKeepsCloseGluedOnOPLAfterFirst(): Void {
		// Default opBoolChain cascade is OPLAfterFirst (items[0] inline,
		// rest on own lines). Inner Doc has NO leading hardline, so
		// `WrapList.startsWithHardline` returns false and the wrap stays
		// in the pre-slice `lead + inner + trail` flat shape — close `)`
		// glued to last item. Mirrors the expected default-config layout
		// of issue_187_multi_line_wrapped_assignment.
		final src: String = 'class C { static function m():Void { var v:Bool = (aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee); } }';
		final out: String = writeWithLineWidth(src, 80);
		// Close paren must be glued to the last operand `eeee...);`.
		Assert.isTrue(out.indexOf('eeeeeeeeeeee);') != -1, 'expected close `)` glued to last item for OPLAfterFirst inner in: <$out>');
		Assert.isTrue(
			out.indexOf('\n\t);') == -1 && out.indexOf('\n\t\t);') == -1,
			'close should not land on its own line for OPLAfterFirst inner in: <$out>'
		);
	}

	public function testOnePerLineGluesItemsZeroToOpenDelim(): Void {
		// ω-onePerLine-glueAtOpenDelim — when a chain in OnePerLine mode is
		// wrapped directly inside `(`/`[`/`{`, the leading hardline of the
		// chain shape (`Doc.OptHardlineSkipAtOpenDelim` since this slice)
		// drops at render time so items[0] glues to the open delim.
		// Mirrors haxe-formatter's `((items[0] ||\n\titems[1]))` shape on
		// the inner paren-wrapped sub-chains of issue_187_oneline (3rd/4th
		// `dirty=` statements). Without the drop, anyparse would emit
		// `(\n\titems[0] ||...` and diverge from fork.
		//
		// `var v:Bool = (a || b || c)` puts the OnePerLine chain directly
		// inside ParenExpr (`@:wrap('(', ')')` on `HxExpr.ParenExpr`).
		// `defaultWrap: onePerLine` + empty rules forces OnePerLine
		// regardless of fit, so the shape exercises the leading-hardline
		// drop path even on a short chain.
		final src: String = 'class C { static function m():Void { var v:Bool = (a || b || c); } }';
		final cfg: String = '{ "wrapping": { "opBoolChain": { "defaultWrap": "onePerLine", "rules": [] } } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.lineWidth = 80;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('(a ||') != -1, 'expected items[0] glued to `(` (no `\\n+indent` between) in: <$out>');
		Assert.isTrue(out.indexOf('(\n') == -1, 'unexpected `(\\n` after open paren — leading hardline should drop in: <$out>');
		// Sanity: the chain still breaks (continuations on own lines).
		Assert.isTrue(out.indexOf('\n') != -1, 'expected at least one break in chain: <$out>');
	}

	public function testOnePerLineKeepsLeadingBreakAfterAssign(): Void {
		// Sister of testOnePerLineGluesItemsZeroToOpenDelim — verifies
		// the OPPOSITE context (chain after `=` assignment) still emits
		// the leading `\n+indent`. The new ctor's drop predicate fires
		// only when last byte is `(`/`[`/`{` — `=` (with OptSpace
		// trailing-space dropped on hardline) leaves the previous byte
		// neither hardline nor open delim, so the leading `\n` emits.
		// Matches haxe-formatter's `dirty =\n\titems[0]...` shape on the
		// 1st `dirty=` statement of issue_187_oneline.
		final src: String = 'class C { static function m():Void { dirty = a || b || c; } }';
		final cfg: String = '{ "wrapping": { "opBoolChain": { "defaultWrap": "onePerLine", "rules": [] } } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.lineWidth = 80;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('=\n') != -1, 'expected `=\\n` (leading break still emits after assignment) in: <$out>');
	}

	public function testIdempotencyLongBoolChain(): Void {
		final src: String = 'class C { static function m():Void { dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.lineWidth = 80;
		final w1: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		final w2: String = HxModuleWriter.write(HaxeModuleParser.parse(w1), opts);
		Assert.equals(w1, w2, 'idempotency failed for long-chain assignment: <$w1>');
	}

	private inline function writeWithLineWidth(src: String, width: Int): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.lineWidth = width;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

	public function testPlainAddChainFillsNoHeadBreak(): Void {
		// ω-opadd-plain-fillline regression: a plain assignment `+` chain
		// under an `opAddSubChain.fillLine` cascade FILLS its head line to
		// the budget (multiple operands) — it must NOT collapse to the
		// former head-break shape (head operand alone on line 1, the whole
		// tail glued flat on the continuation). The direct head-break was a
		// re-measure workaround that diverged from the reference formatter,
		// which fillLine-packs a bare-value add-chain.
		final src: String = 'class C { static function m():Void { total = alphaaaa + betaaaaa + gammaaaa + deltaaaa + epsiloon; } }';
		final cfg: String = '{ "wrapping": { "opAddSubChain": { "defaultWrap": "noWrap", "rules": [ {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"} ] } } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.lineWidth = 60;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		// Head line packs at least the first two operands (FillLine), so the
		// head operand is NOT left alone on its own line.
		Assert.isTrue(out.indexOf('total = alphaaaa + betaaaaa') != -1, 'expected FillLine head with >=2 operands in: <$out>');
		Assert.isTrue(out.indexOf('total = alphaaaa\n') == -1, 'unexpected head-break (head operand alone) in: <$out>');
	}

	public function testCompareLeftAddChainKeepsHeadBreak(): Void {
		// Guard the ONE legitimate head-break context (fork
		// `opbool_reeval_strips_opadd_breaks`): an add-chain that is the LEFT
		// operand of a never-wrap compare (`> upperLimit`) nested in an
		// `onePerLineAfterFirst` opBool. This path is committed by leg 2
		// (`CollapsePass.compareOpGluedToHeadBreak`), which survives the
		// direct head-break removal — the wide call head stays alone on its
		// continuation line and the `+ ... > upperLimit` tail glues flat one
		// indent deeper.
		final src: String = 'class Main { static function main() { if (conditionAlpha && computeValue(longParameterA, longParameterB, longParameterC) + additionalValue + extraOffset > upperLimit) { doWork(); } } }';
		final cfg: String = '{ "wrapping": { "opBoolChain": { "defaultWrap": "noWrap", "rules": [ {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "onePerLineAfterFirst", "location": "beforeLast"} ] }, "opAddSubChain": { "defaultWrap": "noWrap", "rules": [ {"conditions": [{"cond": "exceedsMaxLineLength", "value": 1}], "type": "fillLine", "location": "beforeLast"} ] }, "callParameter": { "defaultWrap": "fillLineWithLeadingBreak", "rules": [ {"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"} ] } } }';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.lineWidth = 100;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		// The wide call head is alone on its continuation line...
		Assert.isTrue(
			out.indexOf('&& computeValue(longParameterA, longParameterB, longParameterC)\n') != -1,
			'expected call head on its own line in: <$out>'
		);
		// ...and the add-tail + compare glue flat (single line) one indent deeper.
		Assert.isTrue(out.indexOf('+ additionalValue + extraOffset > upperLimit') != -1, 'expected glued add-tail + compare in: <$out>');
	}

	public function testParenOpensForOpBoolChainOperandInCondition(): Void {
		// A parenthesized opBool subchain that is an OPERAND of a condition's
		// `&&`/`||` chain OPENS (`&& (\n ... \n)`) when its content cannot fit
		// on one line, rather than staying glued with the `(` fused to the
		// first operand. Mirrors the opAddSub-in-condition path: config-gated
		// on `expressionWrapping` being non-NoWrap (so the default corpus
		// config stays byte-inert) AND the paren sitting inside a condition
		// (`_parenInCondition`). A small group that still fits keeps glued.
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONDITION_CHAIN_CFG);
		opts.lineWidth = 80;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(CONDITION_CHAIN_SRC), opts);
		// Open head: `(` ends the `&&` line, the first operand drops below.
		Assert.isTrue(out.indexOf('&& (\n') != -1, 'expected paren to OPEN (`&& (` alone) in: <$out>');
		// Close `)` lands on its own line, not glued to the last operand.
		Assert.isTrue(out.indexOf('iiiiiiiiiiii\n') != -1, 'expected close `)` NOT glued to last operand in: <$out>');
	}

	public function testCondChainHeadGluesToOpeningParen(): Void {
		// When a condition's `&&` chain has an opening paren as its LAST operand,
		// the chain head glues up to the open `(` (`a && b && (`) instead of
		// breaking the soft-line before the last operator (`a && b` / `&& (`).
		// The cond-forced fillLine chain is a single-shape `Fill` with no 2-state
		// pivot for the If*-based forward-glue to commit, so a dedicated Fill
		// forward-glue (last operand opens -> render the packed operands glued)
		// mirrors `collapseChainBreaksAfter` for this shape.
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(CONDITION_CHAIN_CFG);
		opts.lineWidth = 80;
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(CONDITION_CHAIN_SRC), opts);
		// Head stays on the open-paren line: `... betaCondVal && (` then a break.
		Assert.isTrue(out.indexOf('betaCondVal && (\n') != -1, 'expected chain head glued to `(` in: <$out>');
		// NOT broken before the last operator (a broken shape ends a line with betaCondVal).
		Assert.isTrue(out.indexOf('betaCondVal\n') == -1, 'chain head should not break before `&& (` in: <$out>');
	}

}
