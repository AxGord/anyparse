package unit;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * omega-methodchain-cuddled-links: `wrapping.methodChainCuddledLinks`
 * (default `false`) lets a dot-broken method-chain link start ON the previous
 * link's dedented closing-delimiter line (`})`) instead of on a fresh indented
 * line of its own, reproducing the compact fluent-callback shape
 * `…(null, {…}).applied(… -> {…}).fault(… -> {…})`. The cuddled link joins the
 * run it rides on, so its lambda body indents from the statement head rather
 * than gaining one extra level per link.
 *
 * The gate is structural, never width-driven: the preceding link must end in a
 * FORCED hardline whose whole tail is close delimiters. With the knob absent /
 * `false` the writer is byte-identical to the pre-knob exploded layout.
 */
@:nullSafety(Strict)
final class HxMethodChainCuddledLinkTest extends Test {

	/** The knob, as a `wrapping` fragment. Every ON config below carries it; every OFF config omits it. */
	private static final KNOB: String = '"methodChainCuddledLinks": true, ';

	/** The forced-`onePerLine` chain cascade, as a `wrapping` fragment (see `ONE_PER_LINE_ON` for why the stock rules are replaced). */
	private static final ONE_PER_LINE: String = '"methodChain": {"defaultWrap": "onePerLine",'
		+ ' "rules": [{"conditions": [{"cond": "itemCount >= n", "value": 1}], "type": "onePerLine"}]}, ';

	/** TM's `callParameter` cascade, as a `wrapping` fragment (see `BOUNDARY_ON`). */
	private static final CALL_PARAM: String = '"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"},'
		+ ' {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}, ';

	/** TM-shaped config (tab indent, maxLineLength 140, ifBody/functionBody fitLine, cuddled object braces) with the knob OFF. */
	private static final OFF: String = config('');

	/** Same config with `wrapping.methodChainCuddledLinks` turned on. */
	private static final ON: String = config(KNOB);

	/**
	 * Knob on with the chain cascade forced to `onePerLine` — the only shape whose FIRST gap's predecessor is the receiver itself. The
	 * cascade's own rules are replaced by one unconditional (`itemCount >= 1`) rule, since the stock rules would answer `noWrap` for a
	 * chain this narrow and never reach the shaper under test.
	 */
	private static final ONE_PER_LINE_ON: String = config(KNOB + ONE_PER_LINE);

	/** The same forced-`onePerLine` cascade with the knob OFF — the inertness half of the receiver-cuddle fixture. */
	private static final ONE_PER_LINE_OFF: String = config(ONE_PER_LINE);

	/**
	 * Knob on plus TM's `callParameter` cascade, whose `fillLineWithLeadingBreak` default makes a >100-char sole argument wrap once the
	 * rendered line exceeds `maxLineLength`. The boundary fixtures need that cascade to show the args wrapping under a cuddled head.
	 */
	private static final BOUNDARY_ON: String = config(KNOB + CALL_PARAM);

	/**
	 * The real-world fluent shape this slice targets, anonymised (length-preserving rename of every identifier and string literal) from a
	 * crash-reporter call site. Pre-knob layout: each `.link` on its own indented line, bodies one level deeper again.
	 */
	private static final FLUENT_EXPLODED: String = 'class SignalReporter {\n\tprivate function signalHandle(keeper:EventDumper):Void {\n'
		+ '\t\tSVC.unit.sendMessage.postLocked(null, {\n\t\t\tOwnerName: title,\n\t\t\tRankCode: 4,\n\t\t\tNoteDetail: \'osTextAndInfo\',\n'
		+ '\t\t\tStampTime: Date.now().toString(),\n\t\t})\n\t\t\t.applied((output:svc.types.OutcomeBase12) -> {\n'
		+ '\t\t\t\tif (!output.Handled) trace(\': sendMessage: \', SVC.collectFaultText2(output));\n\t\t\t})\n'
		+ '\t\t\t.fault((incoming:svc.types.FaultResponse) -> {\n\t\t\t\ttrace(\': sendMessage: \', SVC.collectFaultText(incoming));\n'
		+ '\t\t\t});\n\t}\n}';

	/** The same chain compacted: every link rides the previous link's `})` line, and every body sits one level below the statement head. */
	private static final FLUENT_CUDDLED: String = 'class SignalReporter {\n\tprivate function signalHandle(keeper:EventDumper):Void {\n'
		+ '\t\tSVC.unit.sendMessage.postLocked(null, {\n\t\t\tOwnerName: title,\n\t\t\tRankCode: 4,\n\t\t\tNoteDetail: \'osTextAndInfo\',\n'
		+ '\t\t\tStampTime: Date.now().toString(),\n\t\t}).applied((output:svc.types.OutcomeBase12) -> {\n\t\t\tif (!output.Handled) '
		+ 'trace(\': sendMessage: \', SVC.collectFaultText2(output));\n\t\t}).fault((incoming:svc.types.FaultResponse) -> {\n'
		+ '\t\t\ttrace(\': sendMessage: \', SVC.collectFaultText(incoming));\n\t\t});\n\t}\n}';

	/** A dot-broken chain whose links carry only plain args and expression-bodied arrows — nothing in it forces a hardline. */
	private static final PLAIN_ARGS_EXPLODED: String = 'class PlainChain {\n\tprivate function f():Void {\n'
		+ '\t\tvalueSource.map(v -> v + 1)\n\t\t\t.filter(v -> v > 2)\n\t\t\t.sort(cmp)\n'
		+ '\t\t\t.join(sepValue)\n\t\t\t.trim()\n\t\t\t.toLowerCase()\n\t\t\t.substr(0, 10)\n' + '\t\t\t.split(\',\')\n\t\t\t.concat(o);\n'
		+ '\t}\n' + '}';

	/** A chain whose first two links end multi-line and whose last three carry plain args. Pre-knob: every link on its own line. */
	private static final MIXED_EXPLODED: String = 'class MixedChain {\n\tprivate function f():Void {\n\t\tremoteClient.first(null, {\n'
		+ '\t\t\talphaField: alphaValue,\n\t\t\tbetaField: betaValue,\n\t\t})\n\t\t\t.second((r:ResponsePayload) '
		+ '-> {\n\t\t\t\thandleResult(r);\n\t\t\t})\n\t\t\t.third(plainArgumentValue)\n'
		+ '\t\t\t.fourth(anotherPlainArgumentValue)\n\t\t\t.fifth(yetAnotherPlainArgumentValue);\n\t}\n}';

	/** Same chain with only the two post-multiline-close gaps cuddled; `.fourth` / `.fifth` keep their own indented lines. */
	private static final MIXED_CUDDLED: String = 'class MixedChain {\n\tprivate function f():Void {\n\t\tremoteClient.first(null, {\n'
		+ '\t\t\talphaField: alphaValue,\n\t\t\tbetaField: betaValue,\n\t\t}).second((r:ResponsePayload) -> {\n'
		+ '\t\t\thandleResult(r);\n\t\t}).third(plainArgumentValue)\n\t\t\t.fourth(anotherPlainArgumentValue)\n'
		+ '\t\t\t.fifth(yetAnotherPlainArgumentValue);\n\t}\n}';

	/** A dot-broken chain whose ONLY block-arg link is the last one — no gap follows it, so nothing can cuddle. */
	private static final TERMINAL_BLOCK: String = 'class TailBlockChain {\n\tprivate function f():Void {\n'
		+ '\t\tremoteClient.third(plainArgumentValue)\n\t\t\t.fourth(anotherPlainArgumentValue)\n'
		+ '\t\t\t.fifth(yetAnotherPlainArgumentValue)\n' + '\t\t\t.second((r:ResponsePayload) -> {\n' + '\t\t\t\thandleResult(r);\n'
		+ '\t\t\t});\n' + '\t}\n' + '}';

	/** Two dot-broken chains, the inner one living inside the outer one's lambda body. Pre-knob: both exploded. */
	private static final NESTED_EXPLODED: String = 'class NestedChain {\n\tprivate function f():Void {\n'
		+ '\t\touterService.beginRequest(null, {\n\t\t\talphaField: alphaValue,\n\t\t\tbetaField: '
		+ 'betaValue,\n\t\t})\n\t\t\t.completed((outerResult:svc.types.OutcomeBase12) -> {\n'
		+ '\t\t\t\tinnerService.beginRequest(null, {\n\t\t\t\t\tgammaField: gammaValue,\n'
		+ '\t\t\t\t\tdeltaField: deltaValue,\n\t\t\t\t})\n' + '\t\t\t\t\t.completed((innerResult:svc.types.OutcomeBase12) -> {\n'
		+ '\t\t\t\t\t\thandleInnerSuccess(innerResult);\n\t\t\t\t\t})\n' + '\t\t\t\t\t.failed((innerError:svc.types.FaultResponse) -> {\n'
		+ '\t\t\t\t\t\treportInnerFailure(innerError);\n\t\t\t\t\t});\n\t\t\t})\n'
		+ '\t\t\t.failed((outerError:svc.types.FaultResponse) -> {\n' + '\t\t\t\treportOuterFailure(outerError);\n\t\t\t});\n\t}\n}';

	/** Both chains compacted, each against its OWN base indent — the inner one at the outer lambda body's level. */
	private static final NESTED_CUDDLED: String = 'class NestedChain {\n\tprivate function f():Void {\n'
		+ '\t\touterService.beginRequest(null, {\n\t\t\talphaField: alphaValue,\n'
		+ '\t\t\tbetaField: betaValue,\n\t\t}).completed((outerResult:svc.types.OutcomeBase12) -> {\n'
		+ '\t\t\tinnerService.beginRequest(null, {\n\t\t\t\tgammaField: gammaValue,\n' + '\t\t\t\tdeltaField: deltaValue,\n'
		+ '\t\t\t}).completed((innerResult:svc.types.OutcomeBase12) -> {\n' + '\t\t\t\thandleInnerSuccess(innerResult);\n'
		+ '\t\t\t}).failed((innerError:svc.types.FaultResponse) -> {\n' + '\t\t\t\treportInnerFailure(innerError);\n\t\t\t});\n'
		+ '\t\t}).failed((outerError:svc.types.FaultResponse) -> {\n' + '\t\t\treportOuterFailure(outerError);\n\t\t});\n\t}\n}';

	/**
	 * A chain that BREAKS before it cuddles: `.second` / `.third` carry plain args, `.fourth` is the block-arg link, `.fifth` rides its
	 * `})`. The only fixture whose cuddle lands inside an already-open `Nest` run rather than in the leading run at base indent.
	 */
	private static final BREAK_THEN_CUDDLE_EXPLODED: String = 'class BreakThenCuddle {\n\tprivate function f():Void {\n'
		+ '\t\tremoteClient.first(plainArgumentValue)\n\t\t\t.second(anotherPlainArgumentValue)\n'
		+ '\t\t\t.third(yetAnotherPlainArgumentValue)\n' + '\t\t\t.fourth((r:ResponsePayload) -> {\n' + '\t\t\t\thandleResult(r);\n'
		+ '\t\t\t})\n' + '\t\t\t.fifth(oneMorePlainArgumentValue);\n' + '\t}\n' + '}';

	/** Same chain with `.fifth` riding `.fourth`'s `})` INSIDE the broken run, so both stay at base + 1 and the body at base + 2. */
	private static final BREAK_THEN_CUDDLE_CUDDLED: String = 'class BreakThenCuddle {\n\tprivate function f():Void {\n'
		+ '\t\tremoteClient.first(plainArgumentValue)\n\t\t\t.second(anotherPlainArgumentValue)\n'
		+ '\t\t\t.third(yetAnotherPlainArgumentValue)\n' + '\t\t\t.fourth((r:ResponsePayload) -> {\n' + '\t\t\t\thandleResult(r);\n'
		+ '\t\t\t}).fifth(oneMorePlainArgumentValue);\n' + '\t}\n' + '}';

	/**
	 * Under a forced-`onePerLine` cascade, a chain whose RECEIVER is a call with a broken object-literal argument — the only shape whose
	 * first gap has no link before it. The receiver must be a CALL: since ω-methodchain-all-or-nothing's isDotAfterPClose refinement, a
	 * receiver that is not one (a bare ident, a field path, the array literal this fixture used to carry) keeps its first link glued, and
	 * the first gap then has a link before it like every other gap.
	 */
	private static final RECEIVER_EXPLODED: String = 'class OnePerLineChain {\n\tprivate function f():Void {\n\t\tbuildSource({\n'
		+ '\t\t\talphaField: alphaValue,\n\t\t\tbetaField: betaValue,\n\t\t})\n'
		+ '\t\t\t.second(anotherPlainArgumentValue)\n\t\t\t.third(yetAnotherPlainArgumentValue);\n' + '\t}\n}';

	/** Same chain with `.second` riding the receiver's `})` at BASE indent (no run open yet), `.third` still breaking to base + 1. */
	private static final RECEIVER_CUDDLED: String = 'class OnePerLineChain {\n\tprivate function f():Void {\n\t\tbuildSource({\n'
		+ '\t\t\talphaField: alphaValue,\n\t\t\tbetaField: betaValue,\n\t\t}).second(anotherPlainArgumentValue)\n'
		+ '\t\t\t.third(yetAnotherPlainArgumentValue);\n' + '\t}\n' + '}';

	/** A chain carrying a trailing line comment after its first link — routed through `shapeKeep` by the comment-forced break mask. */
	private static final COMMENT_CHAIN: String = 'class CommentChain {\n\tprivate function f():Void {\n'
		+ '\t\tremoteClient.beginRequest(null, {\n\t\t\t\talphaField: alphaValue,\n'
		+ '\t\t\t\tbetaField: betaValue,\n\t\t\t}) // keep the request payload above\n'
		+ '\t\t\t.completed((r:ResponsePayload) -> {\n\t\t\t\thandleResult(r);\n\t\t\t})\n'
		+ '\t\t\t.failed((e:ErrorPayload) -> {\n\t\t\t\treportFailure(e);\n\t\t\t});\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** Acceptance: the fluent callback chain collapses onto its own closing lines, bodies at statement indent + 1 rather than + N. */
	public function testFluentCallbackChainCuddles(): Void {
		Assert.equals(FLUENT_CUDDLED, triviaWrite(FLUENT_EXPLODED, ON));
	}

	/** Knob absent (`false`): the same chain keeps the exploded one-link-per-line layout — byte-inert default. */
	public function testKnobOffKeepsExplodedChain(): Void {
		Assert.equals(FLUENT_EXPLODED, triviaWrite(FLUENT_EXPLODED, OFF));
	}

	/**
	 * The cuddled layout is a fixed point: the compact output fed back in reproduces itself byte for byte, so a chain does not oscillate
	 * between the two shapes across writes. Stated against the literal expected output rather than against a previous write, so a shaper
	 * that stopped cuddling would fail here too instead of agreeing with itself.
	 */
	public function testCuddledChainIsIdempotent(): Void {
		Assert.equals(FLUENT_CUDDLED, triviaWrite(FLUENT_CUDDLED, ON));
	}

	/**
	 * A dot-broken chain of plain-arg links keeps the pre-knob layout even with the knob on: no link ends in a forced hardline, so the
	 * structural gate answers false everywhere. Width alone never cuddles.
	 */
	public function testPlainArgChainKeepsExplodedLayout(): Void {
		Assert.equals(PLAIN_ARGS_EXPLODED, triviaWrite(PLAIN_ARGS_EXPLODED, ON));
	}

	/**
	 * Mixed chain: `.second` cuddles onto the object literal's `})`, `.third` onto the lambda's `})`, while `.fourth` / `.fifth` follow
	 * plain-arg links and still break onto their own indented lines. The cuddled links' bodies sit at the leading run's indent, one level
	 * below the statement head — not one level per link.
	 */
	public function testMixedChainCuddlesOnlyAfterMultilineClose(): Void {
		Assert.equals(MIXED_CUDDLED, triviaWrite(MIXED_EXPLODED, ON));
	}

	/** A chain whose LAST link is the block-arg one is unaffected: the gate asks about each gap's PREDECESSOR, and nothing follows it. */
	public function testTerminalBlockLinkUnaffected(): Void {
		Assert.equals(TERMINAL_BLOCK, triviaWrite(TERMINAL_BLOCK, ON));
	}

	/** An inner chain inside an outer chain's lambda body cuddles independently, against its own base indent. */
	public function testNestedChainsCuddleAtTheirOwnIndent(): Void {
		Assert.equals(NESTED_CUDDLED, triviaWrite(NESTED_EXPLODED, ON));
	}

	/**
	 * A cuddle landing inside an already-open broken run: `.fifth` rides `.fourth`'s `})` at base + 1, NOT at base. This is the only
	 * fixture reaching `cuddledRuns`' append-to-open-run branch — every other one cuddles into the leading run.
	 */
	public function testCuddleInsideBrokenRunKeepsRunIndent(): Void {
		Assert.equals(BREAK_THEN_CUDDLE_CUDDLED, triviaWrite(BREAK_THEN_CUDDLE_EXPLODED, ON));
	}

	/**
	 * `methodChain.defaultWrap: "onePerLine"` breaks before EVERY link, so the first gap's predecessor is the RECEIVER, not a link — the
	 * only route into `cuddledRuns` with `first == 0`. A receiver that itself ended on a dedented `]` is ridden the same way: `.second`
	 * joins it at BASE indent (no `Nest` opened yet), while `.third` follows a plain-arg link and still breaks to base + 1.
	 */
	public function testOnePerLineCuddlesOntoReceiver(): Void {
		Assert.equals(RECEIVER_EXPLODED, triviaWrite(RECEIVER_EXPLODED, ONE_PER_LINE_OFF), 'knob off must keep the receiver break');
		Assert.equals(RECEIVER_CUDDLED, triviaWrite(RECEIVER_EXPLODED, ONE_PER_LINE_ON));
	}

	/**
	 * A chain carrying a trailing `//` comment keeps the pre-knob exploded layout under the knob: the comment-forced break mask routes it
	 * through `shapeKeep`, which this slice does not touch. Cuddling there would let the comment swallow the following `.link`.
	 */
	public function testCommentBearingChainKeepsExplodedLayout(): Void {
		Assert.equals(COMMENT_CHAIN, triviaWrite(COMMENT_CHAIN, ON));
	}

	/** Boundary: a cuddled head line landing EXACTLY on `maxLineLength` (140 columns) stays on one line, args unwrapped. */
	public function testCuddledHeadAtLimitStaysOnOneLine(): Void {
		final expected: String = '${boundaryPrefix()}\t\t}).finalCall(${boundaryIdent(118)})\n\t\t\t.lastProperty;\n\t}\n}';
		Assert.equals(expected, triviaWrite(boundarySource(118), BOUNDARY_ON));
	}

	/**
	 * Boundary: one column past `maxLineLength` the link STILL cuddles — unlike `comprehensionCuddledOpen`, whose head placement is
	 * width-gated, this slice's gate is purely structural. What gives is the cuddled link's own argument list, which wraps by the normal
	 * `callParameter` rules while the `}).finalCall(` head stays on the closing line.
	 */
	public function testCuddledHeadPastLimitStillCuddles(): Void {
		final expected: String = '${boundaryPrefix()}\t\t}).finalCall(\n\t\t\t${boundaryIdent(119)}\n\t\t)\n\t\t\t.lastProperty;\n\t}\n}';
		Assert.equals(expected, triviaWrite(boundarySource(119), BOUNDARY_ON));
	}

	/** Shared head of the boundary fixtures: the object-literal link whose `})` the measured link cuddles onto. */
	private inline function boundaryPrefix(): String {
		return
			'class BoundaryChain {\n\tprivate function f():Void {\n\t\tremoteClient.beginRequest(null, {\n\t\t\talphaField: alphaValue,\n'
				+ '\t\t\tbetaField: betaValue,\n';
	}

	/**
	 * Pre-knob (exploded) boundary source: `.finalCall` on its own indented line with its argument leading-broken below it. The rendered
	 * cuddled head is `<2 tabs = 8 cols>` + `}).finalCall(` (13) + ident + `)` (1), so `identLength = 118` lands exactly on
	 * `maxLineLength` 140 and 119 puts it one column past. The trailing bare `.lastProperty` keeps the chain out of the
	 * `CollapsePass` re-glue path, whose candidate gate requires the LAST segment to be a breakable call.
	 */
	private inline function boundarySource(identLength: Int): String {
		return '${boundaryPrefix()}\t\t})\n\t\t\t.finalCall(\n\t\t\t\t${boundaryIdent(identLength)}\n\t\t\t)\n\t\t\t.lastProperty;\n\t}\n}';
	}

	/** A synthetic identifier of exactly `length` characters. */
	private inline function boundaryIdent(length: Int): String {
		return 'a${''.rpad('b', length - 1)}';
	}

	private inline function triviaWrite(src: String, config: String): String {
		return HxWriteFixture.triviaWrite(src, config);
	}

	/**
	 * The shared TM-shaped config with `extraWrapping` (a JSON fragment, comma-terminated) spliced into its `wrapping` section. Static
	 * because the fixture constants are initialised before any instance exists.
	 */
	private static function config(extraWrapping: String): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {$extraWrapping"maxLineLength": 140},'
			+ ' "sameLine": {"ifBody": "fitLine", "functionBody": "fitLine"},'
			+ ' "whitespace": {"bracesConfig": {"objectLiteralBraces": {"openingPolicy": "after", "closingPolicy": "before"}}}}';
	}

}
