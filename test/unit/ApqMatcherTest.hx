package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Engine;
import anyparse.query.Matcher;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.runtime.Span;

using StringTools;

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

	public function testThrowNewMatchesEveryThrowNewSite(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
			static function a() { throw new IoError("oops"); }
			static function b() { throw new RangeError(42); }
			static function c() { var n:Int = 0; return n; }
		}';
		final pattern: Pattern = plugin.parsePattern("throw new $E($_)");
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(2, matches.length, 'two throw-new sites expected — got ${matches.length}');
		final names: Array<String> = [
			for (m in matches) {
				final e: Null<QueryNode> = m.bindings.get('E');
				e == null ? '<none>' : (e.name ?? '<noname>');
			}
		];
		Assert.isTrue(names.contains('IoError'), '$$E must bind to IoError — got ${names.join(',')}');
		Assert.isTrue(names.contains('RangeError'), '$$E must bind to RangeError');
	}

	public function testSelfIncrementReuseEnforcesStructuralIdentity(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		// Pattern: `$x = $x + 1`. Should match `n = n + 1` but NOT
		// `n = m + 1` (different `x` on each side).
		final source: String = 'class X {
			static function a() { var n:Int = 0; n = n + 1; }
			static function b() { var n:Int = 0; var m:Int = 0; n = m + 1; }
		}';
		final pattern: Pattern = plugin.parsePattern("$x = $x + 1");
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'only self-increment counts — got ${matches.length}');
	}

	public function testWildcardIndependence(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		// Pattern uses two independent wildcards.
		final source: String = 'class X { static function a() { throw new IoError(1, 2); } }';
		final pattern: Pattern = plugin.parsePattern("throw new $E($_, $_)");
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'two-arg throw-new expected to match');
	}

	public function testLiteralOnlyPatternMatchesExactShape(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
			static function a() { return null; }
			static function b() { return 0; }
		}';
		final pattern: Pattern = plugin.parsePattern('return null');
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'literal `return null` must match exactly once');
	}

	public function testVarDeclPatternMatchesEveryPosition(): Void {
		// S2 red-green: a Haxe `var` decl surfaces as three
		// position-specific kinds — module `VarDecl`, class-field
		// `VarMember`, local `VarStmt` (all wrap the same `HxVarDecl`).
		// `var $v = 0` parses via the Decl attempt to `VarDecl`; the
		// plugin-supplied search-only kind-equivalence must let it match
		// the field and the local too. The QueryNode tree keeps the
		// precise kinds (ast/--select/refs/meta unchanged) — only the
		// Matcher consults the equivalence.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
			var field = 0;
			static function f() { var local = 0; }
		}';
		final pattern: Pattern = plugin.parsePattern("var $v = 0");
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(2, matches.length, 'field + local var must both match — got ${matches.length}');
		final names: Array<String> = [
			for (m in matches) {
				final v: Null<QueryNode> = m.bindings.get('v');
				v == null ? '<none>' : (v.name ?? '<noname>');
			}
		];
		Assert.isTrue(names.contains('field'), '$$v must bind class-field var — got ${names.join(',')}');
		Assert.isTrue(names.contains('local'), '$$v must bind local var — got ${names.join(',')}');
	}

	public function testFnDeclPatternMatchesEveryPosition(): Void {
		// B0 red-green: a Haxe `function` declaration surfaces as five
		// position/modifier-specific kinds — module `FnDecl`, member `FnMember`,
		// local `LocalFnStmt`, plus two that swallow a modifier keyword into their
		// own span, `final function` (`FinalModifiedMember`) and a local `inline
		// function` (`LocalInlineFnStmt`). A pattern parses via the Decl attempt to
		// `FnDecl`, so before the search-only equivalence it matched nothing in
		// ordinary code — `search --explain` reported the root kind as absent from
		// every scanned file. The three modifier-free positions must match; `sealed`
		// and `localInline` are in-fixture negatives, deliberately out of the group
		// because the same relation drives `Rewrite` and matching them there deletes
		// the modifier (RewriteSliceTest.testModifierBearingFunctionKindsAreNotRewritten).
		// `host` is a third negative: same kind, different child shape (no parameter).
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'function mod(?p:Bool = true):Void {}
class X {
	public function member(?p:Bool = true):Void {}
	final function sealed(?p:Bool = true):Void {}
	static function host():Void {
		function local(?p:Bool = true):Void {}
		inline function localInline(?p:Bool = true):Void {}
	}
}';
		final pattern: Pattern = plugin.parsePattern("function $n(?$p:Bool = true):Void {}");
		final tree: QueryNode = plugin.parseFile(source);
		final names: Array<String> = boundNames(Matcher.search(pattern, tree), 'n');
		names.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		Assert.equals(
			'local,member,mod', names.join(','), 'every modifier-free function declaration position must match — got ${names.join(',')}'
		);
	}

	public function testFnEquivalenceIsScoped(): Void {
		// Positive + negative in ONE input, so a disabled equivalence flips the
		// assertion instead of leaving it vacuously true. The function group must
		// reach the member and nothing else here: a `var` / `final` binding is a
		// different family, an anonymous `function (…)` (`FnExpr`) has no name to
		// bind, and a named function EXPRESSION (`NamedFnExpr`) is expression
		// position, outside the declaration-only criterion.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
	var v = 0;
	final c = 0;
	public function member(?p:Bool = true):Void {}
	static function host():Void {
		var f = function (?p:Bool = true):Void {};
		var g = function named(?p:Bool = true):Void {};
	}
}';
		final pattern: Pattern = plugin.parsePattern("function $n(?$p:Bool = true):Void {}");
		final tree: QueryNode = plugin.parseFile(source);
		final names: Array<String> = boundNames(Matcher.search(pattern, tree), 'n');
		Assert.equals('member', names.join(','), 'only the declared member matches — got ${names.join(',')}');
	}

	public function testFinalDeclPatternMatchesEveryPosition(): Void {
		// The `final` twin of the function case, with one extra wrinkle: the
		// module-level spelling is `FinalDecl(VarForm …)`, a nameless wrapper the
		// matcher can never unify with the flat `FinalMember` / `FinalStmt`. The
		// pattern is re-rooted onto the named `VarForm`, which is what the group
		// is keyed on.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'final mod:T = new X();
class Y {
	final member:T = new X();
	static function host():Void { final local:T = new X(); }
}';
		final pattern: Pattern = plugin.parsePattern("final $n:$t = new $x();");
		final tree: QueryNode = plugin.parseFile(source);
		final names: Array<String> = boundNames(Matcher.search(pattern, tree), 'n');
		names.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
		Assert.equals('local,member,mod', names.join(','), 'every final-binding position must match — got ${names.join(',')}');
	}

	public function testFinalEquivalenceIsScoped(): Void {
		// Positive + negative in one input. `var v = 0;` differs from
		// `final c = 0;` by the keyword alone, so a group that over-collapsed the
		// two families would match both; a `final function` belongs to the
		// function group, not this one.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
	var v = 0;
	final c = 0;
	final function sealed():Void {}
	static function host():Void { var lv = 0; }
}';
		final pattern: Pattern = plugin.parsePattern("final $n = 0");
		final tree: QueryNode = plugin.parseFile(source);
		final names: Array<String> = boundNames(Matcher.search(pattern, tree), 'n');
		Assert.equals('c', names.join(','), 'only the final binding matches — got ${names.join(',')}');
	}

	public function testVarEquivalenceIsScoped(): Void {
		// S2 negative control, widened for B0: the var-decl equivalence must not
		// over-collapse into the function or `final` families that now have groups
		// of their own. Positive and negatives share one input — `var v = 0` and
		// `final c = 0` differ by the keyword alone — so a broken group flips this
		// in either direction instead of passing vacuously.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
	var v = 0;
	final c = 0;
	final function sealed():Void {}
	static function g() { return 0; }
	static function host():Void {
		final lc = 0;
		inline function localInline():Void {}
	}
}';
		final pattern: Pattern = plugin.parsePattern("var $v = 0");
		final tree: QueryNode = plugin.parseFile(source);
		final names: Array<String> = boundNames(Matcher.search(pattern, tree), 'v');
		Assert.equals('v', names.join(','), 'var pattern must match only the var — got ${names.join(',')}');
	}

	public function testSearchEquivalenceDoesNotLeakIntoSelect(): Void {
		// The safety argument for the whole mechanism: the relation is carried on
		// the `Pattern` and read only by the search `Matcher`, so `--select` (and
		// with it `ast` / `refs` / `--on`) keeps the precise per-position kinds.
		// The `1` assertions make this discriminating — a tree that had been
		// collapsed would move them, not just the `0`s.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
	final c = 0;
	public function member():Void { function local():Void {} }
}';
		final tree: QueryNode = plugin.parseFile(source);
		final eq: KindEquivalence = plugin.selectKindEquivalence();
		Assert.equals(0, Engine.select(tree, Selector.parse('FnDecl'), eq).length, '--select FnDecl must not reach a FnMember');
		Assert.equals(0, Engine.select(tree, Selector.parse('FinalDecl'), eq).length, '--select FinalDecl must not reach a FinalMember');
		Assert.equals(0, Engine.select(tree, Selector.parse('VarForm'), eq).length, 'no module-level final here');
		Assert.equals(1, Engine.select(tree, Selector.parse('FnMember'), eq).length, 'the member keeps its own kind');
		Assert.equals(1, Engine.select(tree, Selector.parse('LocalFnStmt'), eq).length, 'the local fn keeps its own kind');
		Assert.equals(1, Engine.select(tree, Selector.parse('FinalMember'), eq).length, 'the final field keeps its own kind');
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
	public function testInnerBindingSpanCoversSourceText(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X { static function f() { if (n != null) return n; } }';
		final pattern: Pattern = plugin.parsePattern("if ($x != null) return $x");
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'pattern must match exactly once');
		final m: Match = matches[0];
		final bound: Null<QueryNode> = m.bindings['x'];
		Assert.notNull(bound, '$$x binding must be present');
		if (bound == null) return;
		final span: Null<Span> = bound.span;
		Assert.notNull(span, '$$x binding must carry a span');
		if (span == null) return;
		final slice: String = source.substring(span.from, span.to);
		Assert.equals('n', slice.trim(), 'source slice for $$x must be "n", got "$slice"');
	}

	public function testKindFilterRestrictsByKind(): Void {
		// Same verified multi-kind input as testVarDeclPatternMatchesEveryPosition:
		// `var $v = 0` matches the class-field (VarMember) and the local
		// (VarStmt). The --kind filter must narrow Matcher.search to the
		// requested AST kind only, without touching pattern semantics.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
			var field = 0;
			static function f() { var local = 0; }
		}';
		final pattern: Pattern = plugin.parsePattern("var $v = 0");
		final tree: QueryNode = plugin.parseFile(source);
		Assert.equals(2, Matcher.search(pattern, tree).length, 'no filter — both match');
		final onlyStmt: Array<Match> = Matcher.search(pattern, tree, 'VarStmt');
		Assert.equals(1, onlyStmt.length, '--kind VarStmt — only the local var');
		final localName: Null<QueryNode> = onlyStmt[0].bindings.get('v');
		Assert.equals('local', localName == null ? '<none>' : (localName.name ?? '<noname>'));
		Assert.equals(1, Matcher.search(pattern, tree, 'VarMember').length, '--kind VarMember — only the field');
		Assert.equals(0, Matcher.search(pattern, tree, 'NoSuchKind').length, 'unknown kind — no matches');
	}

	public function testAnnotationPatternMatches(): Void {
		// MetaArgs cascade branch — previously untested. `@:foo($_)`
		// must match each `@:foo(...)` annotation regardless of its
		// single argument.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
			@:foo("a") var p:Int;
			@:foo(1) var q:Int;
		}';
		final pattern: Pattern = plugin.parsePattern("@:foo($_)");
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(2, matches.length, 'both @:foo(...) sites must match — got ${matches.length}');
	}

	public function testIsDegeneratePredicate(): Void {
		// A leaf pattern (bare ident / lone metavar) has no structure;
		// a pattern with children does. Drives the CLI nudge.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isTrue(plugin.parsePattern('Anon').isDegenerate(), 'bare identifier is degenerate');
		Assert.isTrue(plugin.parsePattern("$x").isDegenerate(), 'lone metavar is degenerate');
		Assert.isFalse(plugin.parsePattern("throw new $E($_)").isDegenerate(), 'throw-new has structure');
		Assert.isFalse(plugin.parsePattern("return $x").isDegenerate(), 'return-stmt has structure');
	}

	/**
	 * A modifier-bearing declaration fragment must not become a degenerate
	 * `(Static)` pattern that matches every static modifier — the Decl
	 * extraction is completeness-gated (a partial extraction is rejected).
	 */
	public function testModifierDeclFragmentNotDegenerate(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
			static final A:Array<String> = [];
			static final B:Array<String> = [];
		}';
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = try {
			final pattern: Pattern = plugin.parsePattern('static final A:Array<String> = []');
			Matcher.search(pattern, tree);
		} catch (exception: haxe.Exception) [];
		// Either the pattern is refused outright or it matches nothing —
		// two silent matches on the bare modifiers is the corruption regression.
		Assert.equals(0, matches.length);
	}

	/**
	 * A statement fragment missing only its `;` terminator parses via the
	 * automatic `;`-appended retry and matches the local declaration.
	 */
	public function testMissingSemicolonStatementRetry(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
			static function f() { var a:Array<String> = []; trace(a); }
		}';
		final tree: QueryNode = plugin.parseFile(source);
		final pattern: Pattern = plugin.parsePattern('var a:Array<String> = []');
		Assert.equals(1, Matcher.search(pattern, tree).length);
	}

	/**
	 * A single-binder `for` pattern no longer matches a KEY-VALUE loop. While the value binder had
	 * no node the two shapes were indistinguishable, so `for ($v in $m)` matched `for (k => v in m)`
	 * and bound `$v` to the KEY — a silently wrong capture for every `search`/`rewrite` consumer.
	 * The binder is an extra child now, so the arities differ and only the matching shape hits.
	 */
	public function testSingleBinderForPatternSkipsKeyValueLoop(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {\n\tstatic function f(m:Map<Int,Int>, xs:Array<Int>) {\n\t\tfor (a in xs) trace(a);\n'
			+ '\t\tfor (k => b in m) trace(b);\n\t}\n}';
		final tree: QueryNode = plugin.parseFile(source);
		final plain: Array<Match> = Matcher.search(plugin.parsePattern("for ($v in $m) $body"), tree);
		Assert.equals(1, plain.length, 'only the single-binder loop matches — got ${plain.length}');
		final bound: Null<QueryNode> = plain[0].bindings.get('v');
		Assert.notNull(bound);
		if (bound != null) Assert.equals('a', bound.name);
		final keyValue: Array<Match> = Matcher.search(plugin.parsePattern("for ($k => $v in $m) $body"), tree);
		Assert.equals(1, keyValue.length, 'the key-value pattern matches exactly the key-value loop');
	}

	public function testArgumentlessNewDeclarationMatchesOnlyNewInitializers(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final source: String = 'class X {
		static function a() { final p = new Point(); final q = 42; final r = compute(); }
	}';
		final pattern: Pattern = plugin.parsePattern("final $n = new $x();");
		final tree: QueryNode = plugin.parseFile(source);
		final matches: Array<Match> = Matcher.search(pattern, tree);
		Assert.equals(1, matches.length, 'only the new-initialised final may match - got ${matches.length}');
	}

	/** The names each match bound to the given metavariable, in match order. */
	private static function boundNames(matches: Array<Match>, metavar: String): Array<String> {
		return [
			for (m in matches) {
				final n: Null<QueryNode> = m.bindings.get(metavar);
				n == null ? '<none>' : (n.name ?? '<noname>');
			}
		];
	}

}
