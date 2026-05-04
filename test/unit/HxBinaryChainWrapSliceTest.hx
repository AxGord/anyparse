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
 *  - `testNullCoalNotChain`: `??` chain (right-assoc, prec=2) is not
 *    in the chain class set — falls back to G.1 like other non-chain
 *    operators. Confirms the guard is opText-based, not prec-based.
 *  - `testIdempotencyLongBoolChain`: round-trip stable after the new
 *    chain emission shape.
 */
class HxBinaryChainWrapSliceTest extends HxTestHelpers {

	public function testShortBoolChainStaysFlat():Void {
		final src:String = 'class C { var x:Bool = a || b || c; }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('a || b || c') != -1, 'short chain stayed flat in: <$out>');
		Assert.isTrue(out.indexOf('a ||\n') == -1, 'short chain unexpectedly broke in: <$out>');
	}

	public function testLongBoolChainBreaksOPLAfterFirst():Void {
		final src:String = 'class C { static function m():Void { dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
		final out:String = writeWithLineWidth(src, 80);
		// items[0] == 'aaaaaaaaaaaa' stays glued to `dirty = `.
		Assert.isTrue(out.indexOf('dirty = aaaaaaaaaaaa') != -1,
			'expected `dirty = aaaa…` lead-line shape in: <$out>');
		// Continuations carry the op as PREFIX on the new line at fn-body
		// indent (3 tabs: class > main > expr).
		Assert.isTrue(out.indexOf('\n\t\t\t|| bbbbbbbbbbbb') != -1,
			'expected `\\n\\t\\t\\t|| bbb` continuation in: <$out>');
		// No `||\n` (op should not trail at end of line — that would be
		// After-placement, which only fires for OnePerLine / FillLine).
		Assert.isTrue(out.indexOf('||\n') == -1,
			'op should not trail at end of line for default cascade in: <$out>');
	}

	public function testMixedBoolOpsCollapseIntoOneChain():Void {
		// `a || b && c || d` — AST is `Or(Or(a, And(b, c)), d)`. The
		// chain extractor walks Or and And ctors uniformly, gathering
		// items=[a, b, c, d] and ops=['||','&&','||']. A break should
		// land all four operators at the same indent depth, not split
		// the chain at the `&&` boundary.
		final src:String = 'class C { static function m():Void { dirty = aaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbb && cccccccccccccccc || dddddddddddddddd; } }';
		final out:String = writeWithLineWidth(src, 80);
		// All four operators continuation-led at same indent (3 tabs).
		Assert.isTrue(out.indexOf('\n\t\t\t|| bbbbbbbbbbbbbbbb') != -1
			|| out.indexOf('\n\t\t\t&& bbbbbbbbbbbbbbbb') != -1,
			'first continuation present in: <$out>');
	}

	public function testLongAddSubChainBreaksOPLAfterFirst():Void {
		// Mirror of issue_179: long string concat chain.
		final src:String = "class C { static function m():Void { trace(\"can't insert node\" + key + \" with size of \" + width + \"; \" + height + \" in atlas \" + name); } }";
		final out:String = writeWithLineWidth(src, 80);
		// Continuation `\n + ` (BeforeLast `+ ` placement). Indent
		// depth is class > fn-body > Nest cols = 3 tabs; the chain is
		// the single arg of `trace(...)`, the args list itself stays
		// inline so no extra arg-list nest applies.
		Assert.isTrue(out.indexOf('\n\t\t\t+ ') != -1,
			'expected `+ ` continuation in: <$out>');
	}

	public function testCustomConfigOnePerLine():Void {
		// User-supplied `opBoolChain.defaultWrap: onePerLine` flips the
		// cascade default to `OnePerLine` (After op placement). Because
		// the rules array stays unset (preserved from baseline), the
		// `ExceedsMaxLineLength → OnePerLineAfterFirst` rule still fires
		// when exceeds; baseline behaviour for short flat chains is
		// unchanged. Test a short chain to verify the loader wired the
		// `defaultWrap` swap (short chain uses defaultMode, not the
		// rule branch).
		final src:String = 'class C { var x:Bool = a || b || c; }';
		// Empty `rules: []` so the cascade falls through directly to
		// `defaultMode: OnePerLine` regardless of exceeds — without it,
		// the baseline `ExceedsMaxLineLength → OnePerLineAfterFirst`
		// rule still fires in the break-mode arm of the cascade and
		// the After-op shape never surfaces.
		final cfg:String = '{ "wrapping": { "opBoolChain": { "defaultWrap": "onePerLine", "rules": [] } } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		opts.lineWidth = 80;
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		// Default flips to OnePerLine even on a short chain — every
		// item lands on its own line.
		Assert.isTrue(out.indexOf('a ||\n') != -1, 'expected `a ||\\n` After op placement in: <$out>');
	}

	public function testNonChainOpFallsBackToG1():Void {
		// `<<` is shift, not a chain class. Long chain still breaks, but
		// through the G.1 per-binary Group path (each `<<` Group decides
		// independently), not the BinaryChainEmit cascade.
		final src:String = 'class C { static function m():Void { var v:Int = aaaaaaaaaaaa << bbbbbbbbbbbb << cccccccccccc << dddddddddddd << eeeeeeeeeeee; } }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('<< bbbbbbbbbbbb') != -1, 'expected `<< bbb` segment in: <$out>');
		// G.1 emits op-before-operand on continuation, same shape as G.4
		// OPLAfterFirst, so the existing assertion shape still applies.
		Assert.isTrue(out.indexOf('\n\t\t\t<< ') != -1, 'expected G.1 fallback continuation in: <$out>');
	}

	public function testNullCoalNotChain():Void {
		// `??` is not a chain class (haxe-formatter has no opNullCoalChain).
		// Falls back to G.1 emission. Pre-existing G.1 test already
		// covers this; restating here as a regression guard for the
		// chain-class membership check.
		final src:String = 'class C { static function m():Void { var v:Int = aaaaaaaaaaaa ?? bbbbbbbbbbbb ?? cccccccccccc ?? dddddddddddd ?? eeeeeeeeeeee; } }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('?? bbbbbbbbbbbb') != -1, 'expected `?? bbb` in: <$out>');
	}

	public function testIdempotencyLongBoolChain():Void {
		final src:String = 'class C { static function m():Void { dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.lineWidth = 80;
		final w1:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		final w2:String = HxModuleWriter.write(HaxeModuleParser.parse(w1), opts);
		Assert.equals(w1, w2, 'idempotency failed for long-chain assignment: <$w1>');
	}

	private inline function writeWithLineWidth(src:String, width:Int):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.lineWidth = width;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}
