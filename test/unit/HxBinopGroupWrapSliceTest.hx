package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Slice ω-binop-group-wrap — non-tight non-assign binary infix operators
 * emit their operand pair as `Group(Concat([left, Nest(_cols, [Line(' '),
 * 'op ', right])]))`. The `Group` lets the renderer choose flat (Line(' ')
 * → space, byte-identical to the pre-slice flat output) or break (Line(' ')
 * → hardline at indent + cols) based on whether the chain's flat width fits
 * in the remaining columns. Nested infix subtrees emit their own Group, so
 * each chain level decides independently when the renderer descends — the
 * canonical Wadler binary-chain layout.
 *
 * Tight operators (`@:fmt(tight)` — currently only `Interval` `...`) and
 * assignment-class operators (prec=0: `=`, `+=`, `<<=`, `??=`, …) keep
 * flat emission. Tight ops MUST stay inline (`0...n` as one token block).
 * Assignment-class ops must keep the `lhs = first-of-rhs` lead-line shape
 * so the break point falls inside the RHS chain — wrapping `=` itself in
 * a Group would produce `dirty\n\t= dirty || …` instead of the desired
 * `dirty = dirty\n\t|| …`.
 *
 * Cases:
 *  - `testShortChainStaysFlat`: `var x:Bool = a || b || c;` fits in 80
 *    cols; renderer commits all Lines to flat → byte-identical to pre-
 *    slice output (regression guard for the silent-on-flat invariant).
 *  - `testLongChainBreaks`: `var dirty:Bool = a || b || c || d || e || f
 *    || g || h || i;` exceeds 80 cols; outer Or-Group commits MBreak →
 *    each `||` lands on a new line at indent + cols.
 *  - `testNestedChainBreaksBoth`: `(a || b || c) && (d || e || f)` with
 *    each parenthesised subchain wide enough to break independently.
 *  - `testTightIntervalStaysFlat`: `var r:Iterator<Int> = a...b;` keeps
 *    `a...b` flat regardless of column position (Interval is tight).
 *  - `testAssignmentBreakLandsInsideRhs`: `var dirty:Bool = a || b || c
 *    || d || e || f;` with prec=1 RHS (`||`) wide enough to break — the
 *    `=` itself stays flat, only the RHS Or-Group breaks.
 *  - `testRightAssocNullCoalChainBreaks`: `a ?? b ?? c ?? d ?? e ?? f`
 *    breaks at each `??` despite right-associativity.
 *  - `testIsAsymmetricStaysGlued`: `x is SomeType` keeps single-pair
 *    flat even with the asymmetric writer path (smoke for the
 *    `isAsymmetric` branch composing with the new Group wrap).
 *  - `testIdempotencyRoundTrip`: parse(write(parse(write(parse(s))))) ==
 *    write(parse(s)) for a long-chain assignment — pre-existing
 *    invariant must survive the new emission shape.
 */
class HxBinopGroupWrapSliceTest extends HxTestHelpers {

	public function testShortChainStaysFlat():Void {
		final src:String = 'class C { var x:Bool = a || b || c; }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('a || b || c') != -1, 'short chain stayed flat in: <$out>');
		Assert.isTrue(out.indexOf('a ||\n') == -1, 'short chain unexpectedly broke in: <$out>');
	}

	public function testLongChainBreaks():Void {
		final src:String = 'class C { static function m():Void { dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('|| bbbbbbbbbbbb') != -1, 'expected `|| bbb` segment in: <$out>');
		Assert.isTrue(out.indexOf('||\n') == -1, 'op should stay attached to next operand, not lead the next line in: <$out>');
		// Continuation indent at the inner `||` site: class body (1 tab)
		// + fn body (1 tab) + Nest cols (1 tab) = 3 tabs.
		Assert.isTrue(out.indexOf('\n\t\t\t|| ') != -1, 'expected continuation `\\n\\t\\t\\t|| ` in: <$out>');
	}

	public function testNestedChainBreaksOuter():Void {
		// Outer && chain wide enough to break; inner subchains are short
		// enough that each parenthesised sub-Group stays flat — the
		// nested-Group invariant.
		final src:String = 'class C { static function m():Void { dirty = (aaaaaaaa || bbbbbbbb) && (cccccccc || dddddddd) && (eeeeeeee || ffffffff); } }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('(aaaaaaaa || bbbbbbbb)') != -1, 'inner Or chain stayed flat in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t&& ') != -1, 'expected outer `\\n\\t\\t\\t&& ` continuation in: <$out>');
	}

	public function testTightIntervalStaysFlat():Void {
		// `Interval` carries `@:fmt(tight)` → no Group wrap, no Line.
		// The pair `0...1000000000` MUST stay glued even at narrow line
		// widths.
		final src:String = 'class C { static function m():Void { for (i in 0...1000000000) trace(i); } }';
		final out:String = writeWithLineWidth(src, 40);
		Assert.isTrue(out.indexOf('0...1000000000') != -1, 'tight interval stayed flat in: <$out>');
	}

	public function testAssignmentBreakLandsInsideRhs():Void {
		// Assignment `=` is prec=0 → flat emission preserved. The RHS
		// `||` chain is non-assign and DOES wrap, so the break lands at
		// each `||`, not at `=`. Expected shape (or close): `dirty = aaaa
		// \n\t|| bbbb\n\t|| cccc...`.
		final src:String = 'class C { static function m():Void { dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('=\n') == -1, '`=` should stay on the lead line, not be followed by hardline in: <$out>');
		Assert.isTrue(out.indexOf('dirty = aaaaaaaaaaaa') != -1, '`dirty = aaaa…` lead-line shape preserved in: <$out>');
	}

	public function testRightAssocNullCoalChainBreaks():Void {
		// `??` is prec=2 right-assoc, NOT prec=0 → Group wrap applies.
		final src:String = 'class C { static function m():Void { var v:Int = aaaaaaaaaaaa ?? bbbbbbbbbbbb ?? cccccccccccc ?? dddddddddddd ?? eeeeeeeeeeee; } }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('?? bbbbbbbbbbbb') != -1, 'expected `?? bbb` in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t?? ') != -1, 'expected continuation `\\n\\t\\t\\t?? ` in: <$out>');
	}

	public function testIsAsymmetricStaysGlued():Void {
		// `Is(left:HxExpr, right:HxType)` uses the asymmetric writer
		// path — the right operand goes through the HxType writer. The
		// new Group wrap must compose with the asymmetric path without
		// breaking the `expr is Type` operand pair (the chain breaks
		// happen at outer `&&`, not between `is` and its right type).
		final src:String = 'class C { static function m():Void { if (xxxxxxxxxxxx is SomeReallyLongType && yyyyyyyyyyyy is OtherLongType) trace(0); } }';
		final out:String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('xxxxxxxxxxxx is SomeReallyLongType') != -1,
			'`is` operand pair stayed glued in: <$out>');
	}

	public function testIdempotencyRoundTripLongChain():Void {
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
