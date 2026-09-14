package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import utest.Assert;

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
 * The fixtures pin the silent-on-flat invariant (a fitting chain is
 * byte-identical to pre-slice output), the break of an overflowing chain
 * and of two parenthesised subchains independently, the tight `Interval`
 * staying flat at any column, the assignment break landing inside the RHS,
 * a right-assoc `??` chain staying glued past the width (fork parity), the
 * asymmetric `is` path composing with the Group wrap, and round-trip
 * idempotency of a long-chain assignment.
 */
class HxBinopGroupWrapSliceTest extends HxTestHelpers {

	public function testShortChainStaysFlat(): Void {
		final src: String = 'class C { var x:Bool = a || b || c; }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('a || b || c') != -1, 'short chain stayed flat in: <$out>');
		Assert.isTrue(out.indexOf('a ||\n') == -1, 'short chain unexpectedly broke in: <$out>');
	}

	public function testLongChainBreaks(): Void {
		final src: String = 'class C { static function m():Void {'
			+ ' dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('|| bbbbbbbbbbbb') != -1, 'expected `|| bbb` segment in: <$out>');
		Assert.isTrue(out.indexOf('||\n') == -1, 'op should stay attached to next operand, not lead the next line in: <$out>');
		// Continuation indent at the inner `||` site: class body (1 tab)
		// + fn body (1 tab) + Nest cols (1 tab) = 3 tabs.
		Assert.isTrue(out.indexOf('\n\t\t\t|| ') != -1, 'expected continuation `\\n\\t\\t\\t|| ` in: <$out>');
	}

	public function testNestedChainBreaksOuter(): Void {
		// Outer && chain wide enough to break; inner subchains are short
		// enough that each parenthesised sub-Group stays flat — the
		// nested-Group invariant.
		final src: String =
			'class C { static function m():Void { dirty = (aaaaaaaa || bbbbbbbb) && (cccccccc || dddddddd) && (eeeeeeee || ffffffff); } }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('(aaaaaaaa || bbbbbbbb)') != -1, 'inner Or chain stayed flat in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t&& ') != -1, 'expected outer `\\n\\t\\t\\t&& ` continuation in: <$out>');
	}

	public function testTightIntervalStaysFlat(): Void {
		// `Interval` carries `@:fmt(tight)` → no Group wrap, no Line.
		// The pair `0...1000000000` MUST stay glued even at narrow line
		// widths.
		final src: String = 'class C { static function m():Void { for (i in 0...1000000000) trace(i); } }';
		final out: String = writeWithLineWidth(src, 40);
		Assert.isTrue(out.indexOf('0...1000000000') != -1, 'tight interval stayed flat in: <$out>');
	}

	public function testAssignmentBreakLandsInsideRhs(): Void {
		// Assignment `=` is prec=0 → flat emission preserved. The RHS
		// `||` chain is non-assign and DOES wrap, so the break lands at
		// each `||`, not at `=`. Expected shape (or close): `dirty = aaaa
		// \n\t|| bbbb\n\t|| cccc...`.
		final src: String = 'class C { static function m():Void {'
			+ ' dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('=\n') == -1, '`=` should stay on the lead line, not be followed by hardline in: <$out>');
		Assert.isTrue(out.indexOf('dirty = aaaaaaaaaaaa') != -1, '`dirty = aaaa…` lead-line shape preserved in: <$out>');
	}

	public function testRightAssocNullCoalChainStaysGlued(): Void {
		// `??` (prec=2, right-assoc) routes through the chain engine under a
		// NoWrap cascade -- it no longer takes the per-binary Group path, so a
		// comment-free bare-operand chain stays glued past the width (fork
		// parity), never breaking at the operator.
		final src: String = 'class C { static function m():Void {'
			+ ' var v:Int = aaaaaaaaaaaa ?? bbbbbbbbbbbb ?? cccccccccccc ?? dddddddddddd ?? eeeeeeeeeeee; } }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('aaaaaaaaaaaa ?? bbbbbbbbbbbb') != -1, 'operands stay glued in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t?? ') == -1, 'no leading `??` operator break in: <$out>');
	}

	public function testIsAsymmetricStaysGlued(): Void {
		// `Is(left:HxExpr, right:HxType)` uses the asymmetric writer
		// path — the right operand goes through the HxType writer. The
		// new Group wrap must compose with the asymmetric path without
		// breaking the `expr is Type` operand pair (the chain breaks
		// happen at outer `&&`, not between `is` and its right type).
		final src: String =
			'class C { static function m():Void { if (xxxxxxxxxxxx is SomeReallyLongType && yyyyyyyyyyyy is OtherLongType) trace(0); } }';
		final out: String = writeWithLineWidth(src, 80);
		Assert.isTrue(out.indexOf('xxxxxxxxxxxx is SomeReallyLongType') != -1, '`is` operand pair stayed glued in: <$out>');
	}

	public function testIdempotencyRoundTripLongChain(): Void {
		final src: String = 'class C { static function m():Void {'
			+ ' dirty = aaaaaaaaaaaa || bbbbbbbbbbbb || cccccccccccc || dddddddddddd || eeeeeeeeeeee; } }';
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

}
