package unit;

import utest.Assert;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Interval operator (`...`) whitespace under `opt.intervalPolicy`.
 *
 * haxe-formatter lexes a DECIMAL int literal directly abutting `...`
 * (`0...n`) into a single fused `IntInterval` token that is emitted TIGHT
 * regardless of the policy; every other operand shape is a binary
 * `OpInterval` that honours `whitespace.intervalPolicy` (`around` → spaces
 * on both sides). anyparse collapses both shapes into one `Interval` node
 * and drops the source adjacency, so the writer reproduces the fused-tight
 * form by inspecting the rendered left operand's tail: a trailing decimal
 * digit (the fused char before `...`) → tight, anything else → policy-spaced.
 *
 * Default policy `None` keeps every interval tight, byte-identical to the
 * pre-slice `@:fmt(tight)` emission.
 *
 * Residual: a decimal int operand written WITH a source space (`1 ... n`)
 * is indistinguishable from the fused form after adjacency is dropped, so
 * it stays tight (see `testWriterResidualIntLitWithSpace`).
 */
@:nullSafety(Strict)
class HxIntervalPolicySliceTest extends HxTestHelpers {

	public function testWriterTightFusedIntLitLeft(): Void {
		final out: String = writeWith('class Foo { function f() { for (i in 0...n) g(); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('for (i in 0...n)') != -1, 'expected fused `0...n` in: <$out>');
	}

	public function testWriterTightFusedMultiDigitIntLitLeft(): Void {
		final out: String = writeWith('class Foo { function f() { for (i in 10...items.length) g(); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('for (i in 10...items.length)') != -1, 'expected fused `10...items.length` in: <$out>');
	}

	public function testWriterTightFusedTrailingIntLitInCompoundLeft(): Void {
		// The fused rule is LEXICAL: a decimal digit directly abutting `...`
		// stays tight even when it is only the TAIL of a larger left operand
		// (`i + 1...len` lexes `1...` as one token).
		final out: String = writeWith('class Foo { function f() { for (j in i + 1...moves.length) g(); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('for (j in i + 1...moves.length)') != -1, 'expected fused `i + 1...moves.length` in: <$out>');
	}

	public function testWriterSpacedWhenDigitInsideBrackets(): Void {
		// `arr[0]...n` — the char before `...` is `]`, not a digit, so it is a
		// binary `OpInterval` and is policy-spaced.
		final out: String = writeWith('class Foo { function f() { for (m in arr[0]...n) g(); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('arr[0] ... n') != -1, 'expected spaced `arr[0] ... n` in: <$out>');
	}

	public function testWriterSpacedHexLeft(): Void {
		// Hex literals are not fused (the `x`/hex tail is not a decimal digit
		// abutting `...`); `0xFF...n` is policy-spaced.
		final out: String = writeWith('class Foo { function f() { for (i in 0xFF...n) g(); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('0xFF ... n') != -1, 'expected spaced `0xFF ... n` in: <$out>');
	}

	public function testWriterSpacedIdentOperands(): Void {
		final out: String = writeWith('class Foo { function f() { for (i in a...b) g(); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('for (i in a ... b)') != -1, 'expected spaced `a ... b` in: <$out>');
	}

	public function testWriterSpacedFieldAccessLeft(): Void {
		final out: String = writeWith('class Foo { function f() { for (i in x.y...z) g(); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('for (i in x.y ... z)') != -1, 'expected spaced `x.y ... z` in: <$out>');
	}

	public function testWriterSpacedIntLitRightOnly(): Void {
		// Fusion is about the LEFT operand only: an ident left with an int
		// right (`n...10`) is a binary `OpInterval` and is policy-spaced.
		final out: String = writeWith('class Foo { function f() { final s = n...10; } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('n ... 10') != -1, 'expected spaced `n ... 10` in: <$out>');
	}

	public function testWriterTightWhenPolicyNone(): Void {
		// Default policy keeps EVERY interval tight, including non-int-literal
		// operands that `Both` would space.
		final out: String = writeWith('class Foo { function f() { for (i in a...b) g(); } }', WhitespacePolicy.None);
		Assert.isTrue(out.indexOf('for (i in a...b)') != -1, 'expected tight `a...b` in: <$out>');
		Assert.isTrue(out.indexOf('a ... b') == -1, 'did not expect spaced `a ... b` in: <$out>');
	}

	public function testWriterResidualIntLitWithSpace(): Void {
		// Residual: a decimal int operand written with a source space cannot
		// be told apart from the fused form once adjacency is dropped, so it
		// stays tight even under `Both` (haxe-formatter would space it).
		final out: String = writeWith('class Foo { function f() { for (i in 1 ... n) g(); } }', WhitespacePolicy.Both);
		Assert.isTrue(out.indexOf('for (i in 1...n)') != -1, 'expected residual tight `1...n` in: <$out>');
	}

	public function testIntervalPolicyDefaultIsNone(): Void {
		final defaults: HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(WhitespacePolicy.None, defaults.intervalPolicy);
	}

	public function testIntervalPolicyLoaderMapsAround(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace":{"intervalPolicy":"around"}}');
		Assert.equals(WhitespacePolicy.Both, opts.intervalPolicy);
	}

	public function testIntervalPolicyLoaderMapsNone(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{"whitespace":{"intervalPolicy":"none"}}');
		Assert.equals(WhitespacePolicy.None, opts.intervalPolicy);
	}

	public function testIntervalPolicyLoaderDefaultsToNoneWhenAbsent(): Void {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(WhitespacePolicy.None, opts.intervalPolicy);
	}

	private inline function writeWith(src: String, policy: WhitespacePolicy): String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(policy));
	}

	private inline function makeOpts(policy: WhitespacePolicy): HxModuleWriteOptions {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.intervalPolicy = policy;
		return opts;
	}

}
