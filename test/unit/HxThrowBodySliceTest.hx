package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-throw-body — `opt.throwBody:BodyPolicy` driving the separator
 * between `throw` and its value expression at `HxStatement.ThrowStmt`.
 * Exact mirror of ω-return-body: same `bodyPolicyWrap` macro path,
 * same 4-value `BodyPolicy` enum, same `WriterLowering` Case 3
 * extension consuming `@:fmt(bodyPolicy('throwBody'))` on a kw-led
 * single-Ref enum branch.
 *
 * Default is `Same` (slice ω-throw-body-same-default) — `throw value;`
 * always stays flat at the kw boundary, regardless of value length.
 * haxe-formatter has no `throwBody` knob and leaves `throw <expr>`
 * inline, deferring any wrap to the value's own chain/fill rules; the
 * `Same` default matches that upstream byte-for-byte.
 *
 * Unlike `returnBody`, there is NO upstream `sameLine.throwBody` key
 * in haxe-formatter — the JSON loader does not parse one. The runtime
 * knob exists for parity with `returnBody` and for programmatic
 * construction of `HxModuleWriteOptions`. A test verifies the loader
 * leaves the field at its default when the JSON contains no throw key.
 */
@:nullSafety(Strict)
class HxThrowBodySliceTest extends Test {

	/**
	 * Length of the synthetic string literal used by the long-value
	 * tests. Must exceed the default `lineWidth` (~120) so `FitLine`
	 * is forced to break and the `Same`-vs-`FitLine` contrast is
	 * meaningful.
	 */
	private static inline final LONG_VALUE_LEN:Int = 200;

	public function new():Void {
		super();
	}

	public function testDefaultIsSame():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.Same, defaults.throwBody);
	}

	public function testSameKeepsValueFlat():Void {
		final out:String = writeWith('class M { function f():Void { throw 1; } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf('throw 1;') != -1, 'expected `throw 1;` flat in: <$out>');
	}

	/**
	 * Pins the `Same` contract for slice ω-throw-body-same-default:
	 * `Same` is unconditional flat — value length irrelevant. The
	 * single-byte separator between `throw` and its value is always
	 * one space regardless of how the value renders (`lineWidth`
	 * gating belongs to `FitLine`, not `Same`). Long-string-throw is
	 * exactly the corpus shape (issue_179) the default flip targets.
	 */
	public function testSameKeepsLongValueFlat():Void {
		final src:String = 'class M { function f():Void { throw ${makeLongStringLit(LONG_VALUE_LEN)}; } }';
		final out:String = writeWith(src, BodyPolicy.Same);
		Assert.isTrue(out.indexOf('throw "') != -1, 'expected `throw "..."` flat (Same ignores width) in: <$out>');
		Assert.isTrue(out.indexOf('throw\n') == -1, '`Same` must NOT break before long value in: <$out>');
	}

	public function testNextBreaksShortValue():Void {
		final out:String = writeWith('class M { function f():Void { throw 1; } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('throw\n') != -1, 'expected hardline after `throw` in: <$out>');
		Assert.isTrue(out.indexOf('throw 1;') == -1, 'did not expect `throw 1;` flat in: <$out>');
	}

	public function testFitLineFitsShortValueFlat():Void {
		final out:String = writeWith('class M { function f():Void { throw 1; } }', BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf('throw 1;') != -1, 'expected `throw 1;` flat (fits lineWidth) in: <$out>');
	}

	public function testFitLineBreaksLongValue():Void {
		final src:String = 'class M { function f():Void { throw ${makeLongStringLit(LONG_VALUE_LEN)}; } }';
		final out:String = writeWith(src, BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf('throw\n') != -1, 'expected break before long value (>lineWidth) in: <$out>');
	}

	public function testKeepDoesNotForceLayout():Void {
		final out:String = writeWith('class M { function f():Void { throw 1; } }', BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('throw') != -1, 'sanity: `throw` present in: <$out>');
	}

	public function testStringValueRoundTrips():Void {
		final out:String = writeWith('class M { function f():Void { throw "boom"; } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf('throw "boom";') != -1, 'expected `throw "boom";` flat in: <$out>');
	}

	public function testCallExpressionValue():Void {
		final out:String = writeWith('class M { function f():Void { throw new Error("x"); } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf('throw new Error("x");') != -1, 'expected `throw new Error(...)` flat in: <$out>');
	}

	public function testConfigLoaderLeavesThrowBodyAtDefault():Void {
		// haxe-formatter has no `sameLine.throwBody` key — verify the
		// loader does NOT parse it, and the field stays at its default
		// regardless of any value passed in.
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"throwBody": "next"}}'
		);
		Assert.equals(BodyPolicy.Same, opts.throwBody);
	}

	public function testConfigLoaderEmptyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Same, opts.throwBody);
	}

	public function testReturnBodyAndThrowBodyIndependent():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.returnBody = BodyPolicy.Same;
		opts.throwBody = BodyPolicy.Next;
		final src:String = 'class M { function f():Int { throw 1; } }';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
		Assert.isTrue(out.indexOf('throw\n') != -1, 'expected `throw` break (throwBody=Next) in: <$out>');
	}

	private inline function writeWith(src:String, policy:BodyPolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.throwBody = policy;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

	private static inline function makeLongStringLit(len:Int):String {
		final buf:StringBuf = new StringBuf();
		for (i in 0...len) buf.add('-');
		return '"' + buf.toString() + '"';
	}
}
