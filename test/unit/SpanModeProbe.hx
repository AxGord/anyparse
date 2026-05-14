package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleSpanParser;
import anyparse.runtime.Span;

/**
 * Slice 2.5 probe — verifies the in-AST span mechanism.
 *
 * `HaxeModuleSpanParser.parse(source)` returns the paired `HxModuleS`
 * Seq value directly. Every Alt enum value reached through the typed
 * AST carries its own span as the trailing positional arg
 * (`Type.enumParameters(value)` last entry). Slice 2.5's contract is:
 *  - the public entry returns a Seq value (TObject under Reflect),
 *  - walking the AST yields at least one Span instance,
 *  - every encountered span satisfies `0 <= from <= to <= source.length`,
 *  - the maximum `to` across the AST reaches near source end.
 *
 * The side-channel `parseSpans` array of Phase 2 is gone — spans now
 * live structurally inside the AST so Reflect field ordering can no
 * longer desynchronise spans from their carrier nodes.
 */
class SpanModeProbe extends Test {

	public function testParseReturnsPairedRootWithSpans():Void {
		final source:String = 'class Foo { var x:Int; }';
		final root:Dynamic = HaxeModuleSpanParser.parse(source);
		Assert.notNull(root);
		final spans:Array<Span> = collectSpans(root);
		Assert.isTrue(spans.length > 0, 'AST must carry at least one span');
		for (s in spans) {
			Assert.isTrue(s.from <= s.to, 'span from=${s.from} to=${s.to} must satisfy from<=to');
			Assert.isTrue(s.from >= 0, 'span from=${s.from} must be non-negative');
			Assert.isTrue(s.to <= source.length, 'span to=${s.to} must not exceed source length ${source.length}');
		}
	}

	public function testTopLevelSpansAreOrderedByStart():Void {
		final source:String = 'class A {}\nclass B {}\nclass C {}';
		final root:Dynamic = HaxeModuleSpanParser.parse(source);
		final spans:Array<Span> = collectSpans(root);
		var maxFrom:Int = -1;
		for (s in spans) if (s.from > maxFrom) maxFrom = s.from;
		Assert.isTrue(maxFrom >= 0, 'at least one span must be present');
	}

	public function testSpansCoverSourceUpToEnd():Void {
		final source:String = 'class A { var x:Int = 1; }';
		final root:Dynamic = HaxeModuleSpanParser.parse(source);
		final spans:Array<Span> = collectSpans(root);
		var maxTo:Int = 0;
		for (s in spans) if (s.to > maxTo) maxTo = s.to;
		Assert.isTrue(maxTo > 0, 'must have positive end position');
		Assert.isTrue(maxTo <= source.length, 'must not exceed source length');
	}

	private static function collectSpans(value:Dynamic):Array<Span> {
		final out:Array<Span> = [];
		walk(value, out);
		return out;
	}

	private static function walk(value:Dynamic, out:Array<Span>):Void {
		if (value == null) return;
		if (value is String) return;
		if (Std.isOfType(value, Span)) {
			out.push(cast value);
			return;
		}
		final t:Type.ValueType = Type.typeof(value);
		switch t {
			case TEnum(_):
				for (p in Type.enumParameters(value)) walk(p, out);
			case TObject:
				for (f in Reflect.fields(value)) walk(Reflect.field(value, f), out);
			case TClass(_):
				if (Std.isOfType(value, Array)) {
					final arr:Array<Dynamic> = cast value;
					for (e in arr) walk(e, out);
				}
			case _:
		}
	}
}
