package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Matcher;
import anyparse.query.Matcher.Match;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;

/**
 * Slice 2D probe — verifies the structural matcher against patterns
 * built by `HaxeQueryPlugin.parsePattern` and inputs from
 * `HaxeQueryPlugin.parseFile`.
 *
 * Covers:
 *  - Q6-style `throw new $E($_)` matches every throw-new site.
 *  - `$x` reuse: structurally-identical subtrees on both sides.
 *  - `$_` wildcard independence: distinct `$_` slots in one pattern do
 *    not cross-constrain.
 *  - Literal-only patterns match exact ctor + name shapes.
 */
class ApqMatcherTest extends Test {

	public function testThrowNewMatchesEveryThrowNewSite():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final source:String = 'class X {
			static function a() { throw new IoError("oops"); }
			static function b() { throw new RangeError(42); }
			static function c() { var n:Int = 0; return n; }
		}';
		final pattern:Pattern = plugin.parsePattern("throw new $E($_)");
		final tree:QueryNode = plugin.parseFile(source);
		final matches:Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(2, matches.length, 'two throw-new sites expected — got ${matches.length}');
		final names:Array<String> = [for (m in matches) {
			final e = m.bindings.get('E');
			e == null ? '<none>' : (e.name ?? '<noname>');
		}];
		Assert.isTrue(names.contains('IoError'), '$$E must bind to IoError — got ${names.join(",")}');
		Assert.isTrue(names.contains('RangeError'), '$$E must bind to RangeError');
	}

	public function testSelfIncrementReuseEnforcesStructuralIdentity():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		// Pattern: `$x = $x + 1`. Should match `n = n + 1` but NOT
		// `n = m + 1` (different `x` on each side).
		final source:String = 'class X {
			static function a() { var n:Int = 0; n = n + 1; }
			static function b() { var n:Int = 0; var m:Int = 0; n = m + 1; }
		}';
		final pattern:Pattern = plugin.parsePattern("$x = $x + 1");
		final tree:QueryNode = plugin.parseFile(source);
		final matches:Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'only self-increment counts — got ${matches.length}');
	}

	public function testWildcardIndependence():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		// Pattern uses two independent wildcards.
		final source:String = 'class X { static function a() { throw new IoError(1, 2); } }';
		final pattern:Pattern = plugin.parsePattern("throw new $E($_, $_)");
		final tree:QueryNode = plugin.parseFile(source);
		final matches:Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'two-arg throw-new expected to match');
	}

	public function testLiteralOnlyPatternMatchesExactShape():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final source:String = 'class X {
			static function a() { return null; }
			static function b() { return 0; }
		}';
		final pattern:Pattern = plugin.parsePattern('return null');
		final tree:QueryNode = plugin.parseFile(source);
		final matches:Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'literal `return null` must match exactly once');
	}

	/**
	 * Slice 2.5 regression — the Phase 2 side-channel mechanism mis-attributed
	 * spans for inner bindings reached through deeply-nested Seq/Alt hops
	 * (Reflect-fields hash-keyed ordering on neko disagreed with parser
	 * push order). The in-AST `_span` mechanism makes the attribution
	 * structural: each enum value carries its own span as the trailing
	 * `Type.enumParameters` arg, so `$x` binding to an `IdentLit("n")`
	 * inside `if ($x != null) return $x` must carry the source span
	 * covering `n`, not some unrelated type slot.
	 */
	public function testInnerBindingSpanCoversSourceText():Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final source:String = 'class X { static function f() { if (n != null) return n; } }';
		final pattern:Pattern = plugin.parsePattern("if ($x != null) return $x");
		final tree:QueryNode = plugin.parseFile(source);
		final matches:Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'pattern must match exactly once');
		final m:Match = matches[0];
		final bound:Null<QueryNode> = m.bindings.get('x');
		Assert.notNull(bound, '$$x binding must be present');
		if (bound == null) return;
		final span = bound.span;
		Assert.notNull(span, '$$x binding must carry a span');
		if (span == null) return;
		final slice:String = source.substring(span.from, span.to);
		Assert.equals('n', StringTools.trim(slice), 'source slice for $$x must be "n", got "$slice"');
	}
}
