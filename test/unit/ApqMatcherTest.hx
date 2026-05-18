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

	public function testVarDeclPatternMatchesEveryPosition():Void {
		// S2 red-green: a Haxe `var` decl surfaces as three
		// position-specific kinds — module `VarDecl`, class-field
		// `VarMember`, local `VarStmt` (all wrap the same `HxVarDecl`).
		// `var $v = 0` parses via the Decl attempt to `VarDecl`; the
		// plugin-supplied search-only kind-equivalence must let it match
		// the field and the local too. The QueryNode tree keeps the
		// precise kinds (ast/--select/refs/meta unchanged) — only the
		// Matcher consults the equivalence.
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final source:String = 'class X {
			var field = 0;
			static function f() { var local = 0; }
		}';
		final pattern:Pattern = plugin.parsePattern("var $v = 0");
		final tree:QueryNode = plugin.parseFile(source);
		final matches:Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(2, matches.length, 'field + local var must both match — got ${matches.length}');
		final names:Array<String> = [for (m in matches) {
			final v = m.bindings.get('v');
			v == null ? '<none>' : (v.name ?? '<noname>');
		}];
		Assert.isTrue(names.contains('field'), '$$v must bind class-field var — got ${names.join(",")}');
		Assert.isTrue(names.contains('local'), '$$v must bind local var — got ${names.join(",")}');
	}

	public function testVarEquivalenceIsScoped():Void {
		// S2 negative control: the var-decl equivalence must NOT
		// over-collapse. `var $v = 0` must not match a `final`
		// declaration (different keyword/semantics, deliberately a
		// separate family) nor a function declaration.
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final source:String = 'class X {
			final c = 0;
			static function g() { return 0; }
		}';
		final pattern:Pattern = plugin.parsePattern("var $v = 0");
		final tree:QueryNode = plugin.parseFile(source);
		final matches:Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(0, matches.length, 'var pattern must not match final/fn — got ${matches.length}');
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

	public function testKindFilterRestrictsByKind():Void {
		// Same verified multi-kind input as testVarDeclPatternMatchesEveryPosition:
		// `var $v = 0` matches the class-field (VarMember) and the local
		// (VarStmt). The --kind filter must narrow Matcher.search to the
		// requested AST kind only, without touching pattern semantics.
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final source:String = 'class X {
			var field = 0;
			static function f() { var local = 0; }
		}';
		final pattern:Pattern = plugin.parsePattern("var $v = 0");
		final tree:QueryNode = plugin.parseFile(source);
		Assert.equals(2, Matcher.search(pattern, tree).length, 'no filter — both match');
		final onlyStmt:Array<Match> = Matcher.search(pattern, tree, 'VarStmt');
		Assert.equals(1, onlyStmt.length, '--kind VarStmt — only the local var');
		final localName:Null<QueryNode> = onlyStmt[0].bindings.get('v');
		Assert.equals('local', localName == null ? '<none>' : (localName.name ?? '<noname>'));
		Assert.equals(1, Matcher.search(pattern, tree, 'VarMember').length, '--kind VarMember — only the field');
		Assert.equals(0, Matcher.search(pattern, tree, 'NoSuchKind').length, 'unknown kind — no matches');
	}

	public function testAnnotationPatternMatches():Void {
		// MetaArgs cascade branch — previously untested. `@:foo($_)`
		// must match each `@:foo(...)` annotation regardless of its
		// single argument.
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final source:String = 'class X {
			@:foo("a") var p:Int;
			@:foo(1) var q:Int;
		}';
		final pattern:Pattern = plugin.parsePattern("@:foo($_)");
		final tree:QueryNode = plugin.parseFile(source);
		final matches:Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(2, matches.length, 'both @:foo(...) sites must match — got ${matches.length}');
	}

	public function testIsDegeneratePredicate():Void {
		// A leaf pattern (bare ident / lone metavar) has no structure;
		// a pattern with children does. Drives the CLI nudge.
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isTrue(plugin.parsePattern("Anon").isDegenerate(), 'bare identifier is degenerate');
		Assert.isTrue(plugin.parsePattern("$x").isDegenerate(), 'lone metavar is degenerate');
		Assert.isFalse(plugin.parsePattern("throw new $E($_)").isDegenerate(), 'throw-new has structure');
		Assert.isFalse(plugin.parsePattern("return $x").isDegenerate(), 'return-stmt has structure');
	}
}
