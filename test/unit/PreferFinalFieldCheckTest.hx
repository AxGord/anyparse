package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFinalField;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-final-field` check: a private `var` field is flagged `Info` and `var`
 * rewritten to `final` when it is assigned only at its declaration, OR has no
 * initializer and its sole write is exactly one unconditional top-level constructor
 * statement. A public field, a field written elsewhere (`=` / `this.x =` / `++`), a
 * no-init field written more than once / conditionally / outside the constructor, a
 * property, and a field of a non-confined type are left alone.
 */
class PreferFinalFieldCheckTest extends Test {

	public function testPrivateInitOnlyFlagged(): Void {
		final vs: Array<Violation> = violations('class C { private var _x:Int = 0; }');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-final-field', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** A no-modifier field defaults to private — still a candidate. */
	public function testDefaultVisibilityFlagged(): Void {
		Assert.equals(1, violations('class C { var _x:Int = 0; }').length);
	}

	public function testPublicNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int = 0; }').length);
	}

	public function testWrittenInCtorNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int = 0; public function new() { _x = 1; } }').length);
	}

	public function testWrittenViaThisNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int = 0; function s():Void { this._x = 5; } }').length);
	}

	public function testIncrementNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int = 0; function i():Void { _x++; } }').length);
	}

	/** A no-init private var whose sole write is one top-level constructor statement is now flagged (var → final). */
	public function testNoInitSingleCtorWriteFlagged(): Void {
		final vs: Array<Violation> = violations('class C { private var _x:Int; public function new() { _x = 1; } }');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-final-field', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** A no-init field written twice in the constructor is not single-assignment — left alone. */
	public function testNoInitWrittenTwiceNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new() { _x = 1; _x = 2; } }').length);
	}

	/** A read (`return _x`) and a comparison (`_x == 1`) are not writes — still flagged. */
	public function testReadAndComparisonStillFlagged(): Void {
		Assert.equals(1, violations('class C { private var _x:Int = 0; function r():Bool { return _x == 1; } }').length);
	}

	/** A property (`var x(...)`) has a `(` in its head — skipped. */
	public function testPropertyNotFlagged(): Void {
		Assert.equals(0, violations('class C { var x(default, null):Int = 0; }').length);
	}

	/** A subtype that WRITES the inherited private field — left alone. */
	public function testSubtypeWriteNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D extends C { function s():Void { _x = 5; } }' }
		];
		Assert.equals(0, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * `@:access(<subtype>)` grants a third file write access to a private field declared in
	 * the SUPERtype — verified against the compiler: with the metadata `s.p = 5` on `s:Sub`
	 * compiles, without it the field is inaccessible. Neither scanning the subtype's body
	 * nor asking for grants on the OWNER sees it, so the subtype gate has to carry it.
	 */
	public function testAccessGrantOnSubtypeNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D extends C {}' },
			{ file: 'W.hx', source: '@:access(D) class W { public function poke(d:D):Void { d._x = 9; } }' }
		];
		Assert.equals(0, ownerViolations(files).length);
	}

	/** A subtype that merely EXTENDS without touching the field does not block the finalization. */
	public function testEmptySubtypeStillFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D extends C {}' }
		];
		Assert.equals(1, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/** A subtype that only READS the inherited private field does not block it either — a read survives `final`. */
	public function testSubtypeReadStillFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D extends C { function r():Int { return _x; } }' }
		];
		Assert.equals(1, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/** A TRANSITIVE subtype's write blocks the finalization too. */
	public function testTransitiveSubtypeWriteNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D extends C {}' },
			{ file: 'E.hx', source: 'class E extends D { function s():Void { _x = 5; } }' }
		];
		Assert.equals(0, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * The index keys types by SIMPLE name, so a second `C` extending the owner's `C` makes
	 * the two hierarchies indistinguishable — the write in it must still block.
	 */
	public function testSameSimpleNameSubtypeNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'a/C.hx', source: 'package a;\nclass C { private var _x:Int = 0; }' },
			{ file: 'b/C.hx', source: 'package b;\nclass C extends a.C { function s():Void { _x = 5; } }' }
		];
		Assert.equals(0, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * A subtype whose member table merely CARRIES the field's name — here from a nested
	 * anonymous-structure annotation, which the index collects as a member — is ambiguous,
	 * not proof of shadowing. Skipping such a subtype would hide the real write next to it.
	 */
	public function testSubtypeDeclaringSameNameNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D extends C { public var _cfg:{ var _x:Int; } = { _x: 1 }; function s():Void { _x = 5; } }' }
		];
		Assert.equals(0, ownerViolations(files).length);
	}

	/** A `@:build` macro on a subtype can inject a write no text scan can see — left alone. */
	public function testBuildMacroSubtypeNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'D.hx', source: '@:build(M.gen()) class D extends C {}' }
		];
		Assert.equals(0, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/** The no-initializer (constructor-assigned) case gets the same precise subtype gate. */
	public function testNoInitEmptySubtypeStillFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int; public function new() { _x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C {}' }
		];
		Assert.equals(1, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/** The no-initializer case is still blocked by a subtype write. */
	public function testNoInitSubtypeWriteNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int; public function new() { _x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C { function s():Void { _x = 2; } }' }
		];
		Assert.equals(0, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	public function testFixVarToFinal(): Void {
		final fixed: String = fixedSource('class C { private var _x:Int = 0; }');
		Assert.isTrue(fixed.indexOf('private final _x:Int = 0') >= 0);
		Assert.equals(-1, fixed.indexOf('var _x'));
	}

	/** The `var → final` swap is an in-place keyword rewrite, so it preserves canonical modifier order: `private static var` → `private static final`. */
	public function testFixPreservesModifierOrder(): Void {
		final fixed: String = fixedSource('class C { private static var _x:Int = 0; }');
		Assert.isTrue(fixed.indexOf('private static final _x:Int = 0') >= 0);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-final-field'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-final-field'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { var _x = ').length);
	}

	/** A write whose name is separated from `=` by a comment is still detected — not flagged. */
	public function testCommentInterruptedWriteNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int = 0; function s():Void { _x /* c */ = 5; } }').length);
	}

	/** An `@:access` grant in another file makes the type non-confined — left alone. */
	public function testAccessGrantNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'W.hx', source: '@:access(C) class W { public function poke(c:C):Void { c._x = 9; } }' }
		];
		Assert.equals(0, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * An `@:access` grantee that only READS the private field does not block the
	 * finalization — a read survives `final`, exactly as for a subtype. The grant is
	 * file-scoped, so the whole grantee file is scanned, not one declaration span.
	 */
	public function testAccessGrantReadStillFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'R.hx', source: '@:access(C) class R { public function peek(c:C):Int { return c._x; } }' }
		];
		Assert.equals(1, ownerViolations(files).length);
	}

	/** A `@:build` macro in an `@:access` grantee can inject a write — left alone. */
	public function testAccessGrantBuildMacroNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'R.hx', source: '@:access(C) @:build(M.gen()) class R {}' }
		];
		Assert.equals(0, ownerViolations(files).length);
	}

	/** A prefix `++`/`--` separated from the field by a comment is still detected — not flagged. */
	public function testPrefixIncrementWithCommentNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _d:Int = 4; function f():Void { ++ /* c */ _d; } }').length);
	}

	/** A no-init field assigned only conditionally (not a top-level constructor statement) — left alone. */
	public function testNoInitConditionalNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new(c:Bool) { if (c) _x = 1; } }').length);
	}

	/** A no-init field assigned only in a non-constructor method — left alone (no single constructor init). */
	public function testNoInitMethodWriteNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; function s():Void { _x = 1; } }').length);
	}

	/** A constructor assignment to a shadowing parameter (not the field) — left alone. */
	public function testNoInitShadowingParamNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new(_x:Int) { _x = 5; } }').length);
	}

	/** A no-init field written in the constructor AND another method is reassigned — left alone. */
	public function testNoInitAlsoWrittenElsewhereNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { private var _x:Int; public function new() { _x = 1; } function s():Void { _x = 2; } }').length
		);
	}

	/** The no-init fix swaps var → final and leaves the single constructor assignment intact. */
	public function testNoInitFixVarToFinal(): Void {
		final fixed: String = fixedSource('class C { private var _x:Int; public function new() { _x = 1; } }');
		Assert.isTrue(fixed.indexOf('private final _x:Int') >= 0);
		Assert.isTrue(fixed.indexOf('_x = 1') >= 0);
	}

	public function testNoInitStaticCtorWriteNotFlagged(): Void {
		// A STATIC field cannot become final off a ctor assignment - `static final`
		// requires a declaration initializer ("Static final variable must be
		// initialized"), so the no-init case must skip statics.
		final vs: Array<Violation> = violations('class C { private static var _i:C; public function new() { _i = this; } }');
		Assert.equals(0, vs.length);
	}

	/**
	 * A field whose name an IMPLEMENTED interface declares as a `var` is pinned to that
	 * interface's read+write property access — `var → final` would break parity
	 * ("different property access than in I"). The implementing field carries no explicit
	 * `public`, so it routes through this (non-exported) check. Must be skipped.
	 */
	public function testInterfaceVarFieldNotFinalized(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'I.hx', source: 'interface I {\n\tvar needsResync:Bool;\n}' },
			{ file: 'C.hx', source: 'class C implements I {\n\tvar needsResync:Bool = false;\n}' }
		];
		Assert.equals(0, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/** An implemented interface that is not in scope MAY declare the field as a mutable member — skipped conservatively. */
	public function testUnresolvableInterfaceSkips(): Void {
		final vs: Array<Violation> = new PreferFinalField().run([
			{ file: 'C.hx', source: 'class C implements ExternalIface {\n\tvar needsResync:Bool = false;\n}' }
		], new HaxeQueryPlugin());
		Assert.equals(0, vs.length);
	}

	/** Control: a field an implemented interface does NOT declare still converts. */
	public function testNonInterfaceFieldStillConverts(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'I.hx', source: 'interface I {\n\tvar needsResync:Bool;\n}' },
			{ file: 'C.hx', source: 'class C implements I {\n\tvar _other:Int = 0;\n}' }
		];
		Assert.equals(1, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * The conditional-default fold on a PRIVATE field: a declaration default whose only
	 * other write is one `if (p != null) _x = p;` constructor statement folds into
	 * `final` plus a `??` assignment.
	 */
	public function testCtorConditionalDefaultPrivateFlagged(): Void {
		final vs: Array<Violation> =
			violations('class C { private var _n:Int = 5; public function new(?n:Int) { if (n != null) _n = n; } }');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-final-field', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('null-guarded constructor') >= 0);
	}

	/** The private fold is the same two edits. */
	public function testCtorConditionalDefaultPrivateFixed(): Void {
		final fixed: String = fixedSource('class C { private var _n:Int = 5; public function new(?n:Int) { if (n != null) _n = n; } }');
		Assert.isTrue(fixed.indexOf('private final _n:Int;') >= 0);
		Assert.isTrue(fixed.indexOf('_n = n ?? 5;') >= 0);
	}

	/** A second write in a method breaks single-assignment — skipped. */
	public function testCtorConditionalDefaultPrivateMethodWriteNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { private var _n:Int = 5; public function new(?n:Int) { if (n != null) _n = n; } function s():Void { _n = 1; } }'
			).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferFinalField().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Only the violations reported against the owner `C.hx` — a subtype fixture can carry findings of its own. */
	private function ownerViolations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new PreferFinalField().run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'C.hx');
	}

	private function fixedSource(src: String): String {
		final check: PreferFinalField = new PreferFinalField();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
