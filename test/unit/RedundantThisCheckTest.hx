package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantThis;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-this` check: a `this.field` access reduces to bare `field`
 * when no local / parameter / loop-var / local-function in the enclosing member
 * shadows the name. Shadowed accesses (the `this.x = x` constructor pattern) and
 * compile-time abstracts (where `this` is the underlying value) are left alone.
 */
class RedundantThisCheckTest extends Test {

	public function testRedundantThisFlagged(): Void {
		Assert.equals(1, violations('class C { var f:Int; function m():Int { return this.f; } }').length);
	}

	public function testFixDropsThis(): Void {
		final out: String = applyFix('class C { var f:Int; function m():Int { return this.f; } }');
		Assert.isTrue(out.indexOf('return f;') != -1, 'expected `return f;`, got: $out');
		Assert.isTrue(out.indexOf('this.f') == -1, 'this. should be gone, got: $out');
	}

	public function testConstructorShadowNotFlagged(): Void {
		// `this.x = x`: the parameter shadows the field, so `this.` is required.
		Assert.equals(0, violations('class C { var x:Int; public function new(x:Int) { this.x = x; } }').length);
	}

	public function testLocalVarShadowNotFlagged(): Void {
		Assert.equals(0, violations('class C { var f:Int; function m() { var f = 1; trace(this.f); } }').length);
	}

	public function testLocalFunctionShadowNotFlagged(): Void {
		Assert.equals(0, violations('class C { var helper:Int; function m() { function helper() {}; trace(this.helper); } }').length);
	}

	public function testMethodCallThisFlagged(): Void {
		Assert.equals(1, violations('class C { function go() {} function m() { this.go(); } }').length);
		final out: String = applyFix('class C { function go() {} function m() { this.go(); } }');
		Assert.isTrue(out.indexOf('go();') != -1 && out.indexOf('this.go') == -1, 'got: $out');
	}

	public function testChainedThisInnerFlagged(): Void {
		// Only the inner `this.a` is a this-access; the outer `.b` is not.
		final out: String = applyFix('class C { var a:Dynamic; function m() { return this.a.b; } }');
		Assert.isTrue(out.indexOf('return a.b;') != -1, 'got: $out');
	}

	public function testAbstractThisNotMatched(): Void {
		// In `abstract A(T)` the `this.x` carries no IdentExpr-this receiver and
		// `this.` is mandatory — never flagged.
		Assert.equals(
			0,
			new RedundantThis().run([{ file: 'A.hx', source: 'abstract A(Int) { function f() return this.x; }' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { var f:Int; function m():Int { return this.f; } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-this', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new RedundantThis().run([{ file: 'Bad.hx', source: 'class Bad { function f() { ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-this'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-this'));
	}

	// Inheritance: a member inherited from a base declared in the SAME file is now
	// flagged — membership resolves through the extends chain via SymbolIndex.
	public function testInheritedFromSameFileBaseFlagged(): Void {
		final src: String = 'class Base { public function inh():Void {} } class S extends Base { function m():Void { this.inh(); } }';
		Assert.equals(1, new RedundantThis().run([{ file: 'S.hx', source: src }], new HaxeQueryPlugin()).length);
	}

	// A member inherited from a base in ANOTHER file in the set is flagged — the index
	// is built over every linted file, not just the one holding the access.
	public function testInheritedFromOtherFileBaseFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'Base.hx', source: 'class Base { public function inh():Void {} }' },
			{ file: 'S.hx', source: 'class S extends Base { function m():Void { this.inh(); } }' }
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals('S.hx', vs[0].file);
	}

	// A base OUTSIDE the linted set leaves the access silent — `inh` cannot be proven a
	// member (inherited member OR `using` extension), so `this.` is kept.
	public function testInheritedFromBaseOutsideSetNotFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'S.hx', source: 'class S extends Base { function m():Void { this.inh(); } }' }
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	// Load-bearing: with the base IN the set, a `using` static-extension call whose name
	// is NOT declared by the type or any ancestor stays silent — dropping `this.` would
	// break compile (`Unknown identifier`).
	public function testUsingExtensionSilentEvenWithBaseInSet(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'Base.hx', source: 'class Base { public function inh():Void {} }' },
			{
				file: 'W.hx',
				source: 'using Type; class W extends Base { function m():Class<Dynamic> { return this.getClass(); } }'
			}
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	// A local binding that shadows an INHERITED member name still wins — the shadow gate
	// runs before the membership check, so `this.inh` (with a local `inh`) is kept.
	public function testShadowedBindingWinsOverInheritedMembership(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'Base.hx', source: 'class Base { public function inh():Void {} }' },
			{ file: 'S.hx', source: 'class S extends Base { function m():Void { var inh = 1; trace(this.inh); } }' }
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	// Vector A — a SECOND unrelated `class S extends Lib` (Lib declares getClass) must NOT
	// make the REAL `S`'s `this.getClass()` (a `using Type` extension) flag. The simple-name
	// union claimed the real S inherits getClass; pinning the enclosing type to its own
	// `(file, name)` declaration keeps it silent. Fails before the ambiguity fix.
	public function testVectorAUnrelatedSameNamedEnclosingNotFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'Lib.hx', source: 'class Lib { public function getClass():Class<Dynamic> return null; }' },
			{ file: 'pa/S.hx', source: 'package pa; class S extends Lib {}' },
			{
				file: 'pr/S.hx',
				source: 'package pr; using Type; class S { function m():Class<Dynamic> { return this.getClass(); } }'
			}
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	// Vector B (qualified) — the real base `b.Widget` is OUT of the set and its simple name
	// collides with an unrelated in-set `a.Widget` that declares getClass. Import-path-precise
	// resolution binds the base to `b.Widget` (external ⇒ no proof), so `a.Widget` never spoofs
	// the membership and `this.getClass()` stays silent. Fails before the ambiguity fix.
	public function testVectorBQualifiedSupertypeCollisionNotFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'a/Widget.hx', source: 'package a; class Widget { public function getClass():Class<Dynamic> return null; }' },
			{
				file: 'pr/S.hx',
				source: 'package pr; using Type; class S extends b.Widget { function m():Class<Dynamic> { return this.getClass(); } }'
			}
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	// Vector B (simple + import) — the base is written `extends Widget` with `import b.Widget`,
	// and both `a.Widget` (declares getClass) and the real `b.Widget` (does not) are in the set.
	// The import binds `Widget` to `b.Widget`, so the collider `a.Widget` is never consulted and
	// `this.getClass()` stays silent. Fails before the ambiguity fix.
	public function testVectorBImportedSupertypeCollisionNotFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'a/Widget.hx', source: 'package a; class Widget { public function getClass():Class<Dynamic> return null; }' },
			{ file: 'b/Widget.hx', source: 'package b; class Widget {}' },
			{
				file: 'pr/S.hx',
				source: 'package pr; import b.Widget; using Type; class S extends Widget { function m():Class<Dynamic> { return this.getClass(); } }'
			}
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	// Positive control (over-conservatism guard): a real cross-PACKAGE inheritance resolved
	// through an explicit `import` — mirroring `class X extends Sprite` with `import ...Sprite` —
	// is still proven, so `this.inh()` is flagged. Guards against the resolver refusing legit
	// inherited members.
	public function testInheritedCrossPackageViaImportFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'lib/Base.hx', source: 'package lib; class Base { public function inh():Void {} }' },
			{ file: 'app/S.hx', source: 'package app; import lib.Base; class S extends Base { function m():Void { this.inh(); } }' }
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals('app/S.hx', vs[0].file);
	}

	// Positive control: a TRANSITIVE inheritance (S extends Mid extends Grand) where the
	// declaring ancestor is reached through a same-package intermediate is proven and flagged.
	public function testInheritedTransitiveFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'g/Grand.hx', source: 'package g; class Grand { public function inh():Void {} }' },
			{ file: 'g/Mid.hx', source: 'package g; class Mid extends Grand {}' },
			{ file: 'app/S.hx', source: 'package app; import g.Mid; class S extends Mid { function m():Void { this.inh(); } }' }
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
	}

	// Wildcard AMBIGUITY → silent. `import a.*; import b.*;` bring both `a.Widget`
	// (declares getClass) and `b.Widget`; `extends Widget` cannot be uniquely resolved, so
	// `this.getClass()` stays silent. Pins the `matches.length == 1` ambiguity gate: under a
	// `>= 1` weakening the resolver would take the FIRST match (a.Widget, listed first) and
	// falsely flag. Must FAIL under that mutation.
	public function testWildcardAmbiguousSupertypeNotFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'a/Widget.hx', source: 'package a; class Widget { public function getClass():Class<Dynamic> return null; }' },
			{ file: 'b/Widget.hx', source: 'package b; class Widget {}' },
			{
				file: 's/S.hx',
				source: 'package s; import a.*; import b.*; using Type; class S extends Widget { function m():Class<Dynamic> { return this.getClass(); } }'
			}
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	// Wildcard POSITIVE → flagged. A single `import pkg.*` brings one `Base` declaring
	// `bump`; `extends Base` resolves unambiguously, so `this.bump()` is flagged. Locks that
	// wildcard resolution still works in the unambiguous case (the ambiguity gate must not
	// refuse all wildcards).
	public function testWildcardUnambiguousInheritedFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'pkg/Base.hx', source: 'package pkg; class Base { public function bump():Void {} }' },
			{ file: 'app/S.hx', source: 'package app; import pkg.*; class S extends Base { function m():Void { this.bump(); } }' }
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
	}

	// Aliased import → silent (CONSERVATIVE MISS, not a resolution). `import a.B as C; class
	// S extends C`, with an unrelated in-set `other.B` declaring `bump`. The resolver does
	// not follow `as` aliases, so `C` resolves to nothing (external) and the collider
	// `other.B` is never consulted (its name is `B`, not `C`) — `this.bump()` stays silent.
	// Fails CLOSED by design.
	public function testAliasedSupertypeNotFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'a/B.hx', source: 'package a; class B {}' },
			{ file: 'other/B.hx', source: 'package other; class B { public function bump():Void {} }' },
			{ file: 'app/S.hx', source: 'package app; import a.B as C; class S extends C { function m():Void { this.bump(); } }' }
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	// Qualified POSITIVE → flagged. `extends pkg.T` where `pkg.T` is IN-set and declares
	// `bump`, resolved by import-path identity — so `this.bump()` is flagged. Pins the
	// `importPathFor == raw` positive branch (the Vector-B-qualified test only exercises the
	// external/negative direction).
	public function testQualifiedInheritedFlagged(): Void {
		final vs: Array<Violation> = new RedundantThis().run([
			{ file: 'pkg/T.hx', source: 'package pkg; class T { public function bump():Void {} }' },
			{ file: 'app/S.hx', source: 'package app; class S extends pkg.T { function m():Void { this.bump(); } }' }
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantThis().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: RedundantThis = new RedundantThis();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		edits.sort((a, b) -> b.span.from - a.span.from);
		var result: String = src;
		for (e in edits) result = result.substring(0, e.span.from) + e.text + result.substring(e.span.to);
		return result;
	}

}
