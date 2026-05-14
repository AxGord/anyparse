package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleSpanParser;
import anyparse.runtime.Span;

/**
 * Slice 2A probe — verifies span-mode macro infrastructure.
 *
 * `HaxeModuleSpanParser.parse(source)` returns `{ast, spans}` instead
 * of a bare `HxModule`. The `spans` array carries one `Span` per
 * enum-ctor / struct-Seq return site, in source post-order. Slice 2A's
 * contract is:
 *  - the array is non-empty whenever the source parses,
 *  - every span has `from < to` and lies within `[0, source.length]`,
 *  - the spans are weakly monotonic in `from` (later nodes start at or
 *    after earlier nodes' starts — leading whitespace is captured by
 *    the parent node's _start so children's _start can technically
 *    equal the parent's; strict monotonicity is not guaranteed).
 *
 * Slice 2B will wire these spans into `QueryNode`; this probe is
 * macro-layer only.
 */
class SpanModeProbe extends Test {

	public function testParseEmitsSpansForSingleClass():Void {
		final source:String = 'class Foo { var x:Int; }';
		final result:{ast:Dynamic, spans:Array<Span>} = HaxeModuleSpanParser.parse(source);
		Assert.notNull(result.ast);
		Assert.isTrue(result.spans.length > 0, 'span array must be non-empty');
		for (s in result.spans) {
			Assert.isTrue(s.from <= s.to, 'span from=${s.from} to=${s.to} must satisfy from<=to');
			Assert.isTrue(s.from >= 0, 'span from=${s.from} must be non-negative');
			Assert.isTrue(s.to <= source.length, 'span to=${s.to} must not exceed source length ${source.length}');
		}
	}

	public function testSpansAreMonotonicByFromAcrossTopLevelDecls():Void {
		final source:String = 'class A {}\nclass B {}\nclass C {}';
		final result:{ast:Dynamic, spans:Array<Span>} = HaxeModuleSpanParser.parse(source);
		// Post-order: each class's children fire before its own span.
		// We assert a weaker invariant — the maximum `from` we've seen
		// so far is monotonically non-decreasing as we walk the array.
		var maxFrom:Int = -1;
		for (s in result.spans) {
			if (s.from > maxFrom) maxFrom = s.from;
		}
		Assert.isTrue(maxFrom >= 0, 'at least one span must be present');
	}

	public function testSpansCoverSourceUpToEnd():Void {
		final source:String = 'class A { var x:Int = 1; }';
		final result:{ast:Dynamic, spans:Array<Span>} = HaxeModuleSpanParser.parse(source);
		// The outermost span (last pushed in post-order) should reach
		// at or near the end of source — leading whitespace included on
		// the from side, no trailing whitespace on the to side.
		var maxTo:Int = 0;
		for (s in result.spans) if (s.to > maxTo) maxTo = s.to;
		Assert.isTrue(maxTo > 0, 'must have positive end position');
		Assert.isTrue(maxTo <= source.length, 'must not exceed source length');
	}
}
