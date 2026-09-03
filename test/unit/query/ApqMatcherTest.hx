package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Engine;
import anyparse.query.Matcher;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

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

	private static final ARITY_SOURCE: String = 'class X {\n\tfunction f() {\n\t\tvar a = new Foo();\n\t\tvar b = new Foo(1);\n'
		+ '\t\tvar c = new Foo(1, 2);\n\t\tvar d = new Foo(1, 2, 3);\n\t\tg();\n\t\tg(1);\n\t\tg(1, 2);\n\t}\n}';

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
		names.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
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
		names.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
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

	/**
	 * THE SLICE'S FAILING-FIRST TEST. `new` of ANY arity is one question, and
	 * before the ellipsis it needed one pattern PER arity: the matcher's child
	 * loop gates on `pChildren.length != iChildren.length`, so `new $T()`,
	 * `new $T($a)` and `new $T($a, $b)` are three disjoint censuses that a reader
	 * writing only the first under-counts by whatever the tail holds. `...`
	 * collapses them into one.
	 */
	public function testEllipsisCollapsesTheThreeArityPatternsForNew(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(ARITY_SOURCE);
		// The split, pinned: each arity pattern sees only its own arity.
		Assert.equals(1, Matcher.search(plugin.parsePattern("new $T()"), tree).length, 'the 0-arg pattern sees only the 0-arg new');
		Assert.equals(1, Matcher.search(plugin.parsePattern("new $T($a)"), tree).length, 'the 1-arg pattern sees only the 1-arg new');
		Assert.equals(1, Matcher.search(plugin.parsePattern("new $T($a, $b)"), tree).length, 'the 2-arg pattern sees only the 2-arg new');
		// One pattern, every arity.
		final star: Array<Match> = Matcher.search(plugin.parsePattern("new $T(...)"), tree);
		Assert.equals(4, star.length, 'one starred pattern must see all four `new` sites - got ${star.length}');
		Assert.equals('Foo,Foo,Foo,Foo', boundNames(star, 'T').join(','));
	}

	/** The same collapse for a call: `$f(...)` is every arity of every call. */
	public function testEllipsisCollapsesArityForACall(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(ARITY_SOURCE);
		Assert.equals(1, Matcher.search(plugin.parsePattern('g()'), tree).length);
		Assert.equals(1, Matcher.search(plugin.parsePattern("g($a)"), tree).length);
		Assert.equals(1, Matcher.search(plugin.parsePattern("g($a, $b)"), tree).length);
		Assert.equals(3, Matcher.search(plugin.parsePattern('g(...)'), tree).length, 'one starred call pattern must see all three arities');
	}

	/** `[...]` is an array literal of any length; `{a: ...}` is not attempted (an object field VALUE is one node, not a run). */
	public function testEllipsisMatchesArrayLiteralOfAnyLength(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(
			'class X {\n\tfunction f() {\n\t\tvar a = [];\n\t\tvar b = [1];\n\t\tvar c = [1, 2, 3];\n\t}\n}'
		);
		Assert.equals(3, Matcher.search(plugin.parsePattern('[...]'), tree).length);
		Assert.equals(1, Matcher.search(plugin.parsePattern("[$x]"), tree).length, 'the single-item pattern still means exactly one item');
	}

	/**
	 * Anchoring. A star splits the pattern's child list into a PREFIX matched
	 * from the left and a SUFFIX matched from the right; the star absorbs the
	 * (possibly empty) run between them. All three shapes therefore work and
	 * mean three different things.
	 */
	public function testEllipsisAnchorsPrefixSuffixAndBoth(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(
			'class X {\n\tfunction f() {\n\t\th(1);\n\t\th(1, 9);\n\t\th(9, 1);\n\t\th(1, 5, 1);\n\t\th(9, 9);\n\t}\n}'
		);
		Assert.equals(3, Matcher.search(plugin.parsePattern('h(1, ...)'), tree).length, 'leading 1: h(1), h(1,9), h(1,5,1)');
		Assert.equals(3, Matcher.search(plugin.parsePattern('h(..., 1)'), tree).length, 'trailing 1: h(1), h(9,1), h(1,5,1)');
		Assert.equals(
			1, Matcher.search(plugin.parsePattern('h(1, ..., 1)'), tree).length,
			'both ends 1: only h(1,5,1) - prefix+suffix must FIT, so the bare h(1) cannot serve one argument to both ends'
		);
	}

	/**
	 * PINNED CONFLATION. `NewExpr` flattens type arguments and value arguments
	 * into one child list (see the `ast` dump in the slice handoff), and the
	 * matcher is language-agnostic by construction - it compares kinds and
	 * positions, never grammar vocabulary. So `new $T(...)` DELIBERATELY matches
	 * `new Foo<Int>()` as well as `new Foo(x)`: both are constructions, which is
	 * the question `new $T(...)` asks. The count is "constructions", not
	 * "constructions carrying arguments". This is not new with the star - the
	 * pre-existing `new $T($a, $b)` already matches `new Map<String,Int>()`.
	 */
	public function testEllipsisDoesNotSeparateTypeArgumentsFromValueArguments(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(
			'class X {\n\tfunction f() {\n\t\tvar a = new Foo<Int>();\n\t\tvar b = new Foo(x);\n\t\tvar c = new Foo<Int>(x);\n\t}\n}'
		);
		Assert.equals(3, Matcher.search(plugin.parsePattern("new $T(...)"), tree).length, 'all three are constructions');
		// The pre-existing conflation, pinned so a future type-aware fix has to move THIS number too.
		Assert.equals(
			2, Matcher.search(plugin.parsePattern("new $T($a)"), tree).length,
			'`new Foo<Int>()` already reads as one-argument today, star or no star'
		);
	}

	/** A star does not bind: nothing lands in `Match.bindings` for it, so no template can name it. */
	public function testEllipsisDoesNotBind(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(ARITY_SOURCE);
		final matches: Array<Match> = Matcher.search(plugin.parsePattern("new $T(...)"), tree);
		Assert.equals(4, matches.length);
		for (m in matches) {
			final keys: Array<String> = [for (k in m.bindings.keys()) k];
			keys.sort(Reflect.compare);
			Assert.equals('T', keys.join(','), 'only the name metavar binds - got ${keys.join(',')}');
		}
	}

	/**
	 * The range operator and the rest/spread `...` are ordinary Haxe and must
	 * keep parsing as themselves: the ellipsis is recognised only where it
	 * stands ALONE in a child slot, which a range and a spread never do.
	 */
	public function testRangeAndSpreadPatternsAreUntouched(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(
			'class Q {\n\tfunction f(arr:Array<Int>, n:Int) {\n\t\tfor (i in 0...n) trace(i);\n\t\tg(...arr);\n\t}\n'
			+ '\tfunction g(...xs:Int) {}\n}'
		);
		Assert.equals(
			1, Matcher.search(plugin.parsePattern("for ($i in 0...$n) $b"), tree).length, 'the range operator still parses as a range'
		);
		Assert.equals(1, Matcher.search(plugin.parsePattern("g(...$a)"), tree).length, 'a spread argument still parses as a spread');
	}

	/**
	 * THE TYPE-PARAMETER GATE. A BARE star cannot separate type arguments from
	 * value arguments (the test above pins that). Writing the type arguments
	 * out CAN, and the gate is the matcher's ordinary kind check: a metavar in
	 * a type-argument slot projects as `Named`, and no expression argument is
	 * ever `Named` — the plugin already declares that partition as
	 * `GrammarPluginShape.typeAnnotationKinds` (`Named` / `Anon` / the
	 * function-type forms), which is what makes the disjointness a property of
	 * the grammar rather than a coincidence of this fixture.
	 *
	 * So `new $T<$K>(...)` is "a construction carrying at least one type
	 * argument, any arity" — a question that needed one pattern per TOTAL child
	 * count before the star, and that must NOT collect `new Foo(x)`. Delete the
	 * kind comparison in `Matcher.unify` and this test goes from 2 to 4.
	 */
	public function testWrittenOutTypeArgumentsSeparateFromValueArguments(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(
			'class X {\n\tfunction f() {\n\t\tnew Foo(x);\n\t\tnew Foo(x, y);\n'
			+ '\t\tnew Map<String, Int>();\n\t\tnew Map<String, Int>(x);\n\t}\n}'
		);
		final typed: Array<Match> = Matcher.search(plugin.parsePattern("new $T<$K>(...)"), tree);
		Assert.equals(2, typed.length, 'only the two `new Map<..>` sites carry a type argument - got ${typed.length}');
		Assert.equals('Map,Map', boundNames(typed, 'T').join(','));
		Assert.equals('String,String', boundNames(typed, 'K').join(','), '$$K must bind the TYPE argument, not the value one');
		Assert.equals(
			2, Matcher.search(plugin.parsePattern("new $T<$K, $V>(...)"), tree).length, 'two written-out type arguments, any value arity'
		);
		Assert.equals(
			4, Matcher.search(plugin.parsePattern("new $T(...)"), tree).length, 'the bare star still sees all four constructions'
		);
	}

	/**
	 * A reused metavariable is enforced by `RefactorSupport.structurallyEqual`, which compares
	 * the PROJECTED shape — so it is only as sharp as the projection. `BoolLit` carried no
	 * value, and `$C ? $A : $A` therefore matched `c ? true : false` and bound `$A = true`;
	 * `apq rewrite … '$A'` then turned that ternary into a bare `true`. Reduced from the shipped
	 * binary, not constructed.
	 */
	public function testBooleanLiteralsAreNotInterchangeable(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(
			'class X {\n\tfunction f(c:Bool) {\n\t\tvar a = c ? true : false;\n\t\tvar b = c ? true : true;\n\t}\n}'
		);
		final reused: Array<Match> = Matcher.search(plugin.parsePattern("$C ? $A : $A"), tree);
		Assert.equals(1, reused.length, 'only `c ? true : true` has two IDENTICAL branches - got ${reused.length}');
		Assert.equals(
			1,
			Matcher.search(
				plugin.parsePattern("$y == true"),
				plugin.parseFile('class X {\n\tfunction f(x:Bool) {\n\t\tif (x == true) g();\n\t\tif (x == false) g();\n\t}\n}')
			)
				.length,
			'a literal `true` in a pattern must not match a literal `false`'
		);
	}

	/**
	 * A type WRITTEN in a pattern must constrain the match. The annotation is a SLOT, not a
	 * child, so `unifyChildren` never saw it and `Pattern`'s node rebuilds dropped it outright:
	 * `final $x:Int = $v` matched `final b:String = 1`, and `apq rewrite` then rewrote the
	 * String-typed declaration. A pattern that writes NO type still constrains nothing.
	 */
	public function testAWrittenTypeAnnotationConstrainsTheMatch(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile('class X {\n\tfunction f() {\n\t\tfinal a:Int = 1;\n\t\tfinal b:String = 1;\n\t}\n}');
		Assert.equals(1, Matcher.search(plugin.parsePattern("final $x:Int = $v"), tree).length, 'only the Int declaration');
		Assert.equals(2, Matcher.search(plugin.parsePattern("final $x = $v"), tree).length, 'an unannotated pattern constrains nothing');
		Assert.equals(
			'Int,String', boundNames(Matcher.search(plugin.parsePattern("final $x:$t = $v"), tree), 't').join(','),
			'a metavariable in the annotation binds the type'
		);
	}

	/**
	 * `(e : T)` and `cast(e, T)` dropped their type from the projection entirely, so every
	 * check-type / typed-cast compared equal to every other: `($y : String)` matched
	 * `(o : Bytes)` and `apq rewrite` collapsed `c ? cast(o, String) : cast(o, Bytes)` onto the
	 * String arm. The type now rides the node's type SLOT, which keeps every consumer's child
	 * indices where they were.
	 */
	public function testCheckTypeAndTypedCastCarryTheirType(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(
			'class X {\n\tfunction f(o:Dynamic) {\n\t\tvar a = (o : String);\n\t\tvar b = (o : Bytes);\n'
			+ '\t\tvar c = cast(o, String);\n\t\tvar d = cast(o, Bytes);\n\t}\n}'
		);
		Assert.equals(1, Matcher.search(plugin.parsePattern("($y : String)"), tree).length, 'the Bytes check-type is a different node');
		Assert.equals(1, Matcher.search(plugin.parsePattern("cast($y, String)"), tree).length, 'the Bytes cast is a different node');
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
