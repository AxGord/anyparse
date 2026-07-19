package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.MissingVisibility;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `missing-visibility` check: a class / abstract member without an explicit
 * `public` / `private` modifier is flagged `Warning`, and `--fix` inserts `private`
 * (the Haxe default) at the canonical position. Interface members (implicitly
 * public) and enum-abstract values are exempt; a modifier run carrying a visibility
 * keyword — even behind meta or other modifiers — is not flagged.
 */
class MissingVisibilityCheckTest extends Test {

	public function testBareFieldFlagged(): Void {
		final vs: Array<Violation> = violations('class C { var a:Int; }');
		Assert.equals(1, vs.length);
		Assert.equals('missing-visibility', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testPublicMemberNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var a:Int; }').length);
	}

	public function testPrivateMemberNotFlagged(): Void {
		Assert.equals(0, violations('class C { private function f():Void {} }').length);
	}

	public function testStaticWithoutVisibilityFlagged(): Void {
		// static / inline modifiers present, but no public / private.
		Assert.equals(1, violations('class C { static inline function f():Void {} }').length);
	}

	public function testConstructorWithoutVisibilityFlagged(): Void {
		Assert.equals(1, violations('class C { function new() {} }').length);
	}

	public function testInterfaceMembersNotFlagged(): Void {
		Assert.equals(0, violations('interface I { var a:Int; function f():Void; }').length);
	}

	public function testEnumAbstractValuesNotFlagged(): Void {
		Assert.equals(0, violations('enum abstract E(Int) { final X = 0; final Y = 1; }').length);
	}

	public function testMetaBeforeVisibilityNotFlagged(): Void {
		Assert.equals(0, violations('class C { @:keep public function f():Void {} }').length);
	}

	public function testMetaWithoutVisibilityFlagged(): Void {
		Assert.equals(1, violations('class C { @:keep function f():Void {} }').length);
	}

	public function testFinalClassMemberFlagged(): Void {
		Assert.equals(1, violations('final class C { function f():Void {} }').length);
	}

	public function testAbstractMemberFlagged(): Void {
		Assert.equals(1, violations('abstract A(Int) { function g():Void {} }').length);
	}

	public function testMultipleMembersOnlyUntypedFlagged(): Void {
		// public a + private f are fine; b + g lack visibility.
		Assert.equals(2, violations('class C { public var a:Int; var b:Int; private function f():Void {} function g():Void {} }').length);
	}

	public function testFixInsertsPrivate(): Void {
		final fixed: String = fixedSource('class C { static inline function f():Void {} }');
		Assert.isTrue(fixed.indexOf('private static inline function f') >= 0);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('missing-visibility'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('missing-visibility'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** An override inherits supertype visibility; it is still reported but the autofix must NOT force `private`. */
	public function testFixSkipsOverride(): Void {
		Assert.equals(1, violations('class C { override function f():Void {} }').length);
		Assert.equals(-1, fixedSource('class C { override function f():Void {} }').indexOf('private'));
	}

	/** An override of an indexed PUBLIC supertype member gets `public` — the base member's own keyword. */
	public function testFixOverridePublicFromIndexedSupertype(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [{ file: 'B.hx', source: 'class B { public function f():Void {} }' }]);
		Assert.isTrue(fixed.indexOf('override public function f') >= 0);
	}

	/** An override of an indexed PRIVATE supertype member gets `private`. */
	public function testFixOverridePrivateFromIndexedSupertype(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [{ file: 'B.hx', source: 'class B { private function f():Void {} }' }]);
		Assert.isTrue(fixed.indexOf('override private function f') >= 0);
	}

	/** The resolved keyword lands at the canonical slot: after `override`, before `inline`. */
	public function testFixOverrideInlineKeywordPosition(): Void {
		final sub: String = 'class C extends B { override inline function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [{ file: 'B.hx', source: 'class B { public function f():Void {} }' }]);
		Assert.isTrue(fixed.indexOf('override public inline function f') >= 0);
	}

	/** A mid-chain unmarked override defers to ITS supertype: C → B (unmarked override) → A (public). */
	public function testFixOverrideResolvesThroughUnmarkedOverrideChain(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [
			{ file: 'A.hx', source: 'class A { public function f():Void {} }' },
			{ file: 'B.hx', source: 'class B extends A { override function f():Void {} }' }
		]);
		Assert.isTrue(fixed.indexOf('override public function f') >= 0);
	}

	/** A simple-name collision whose bases DISAGREE on visibility stays report-only. */
	public function testFixOverrideCollisionDisagreementStaysReportOnly(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [
			{ file: 'a/B.hx', source: 'class B { public function f():Void {} }' },
			{ file: 'b/B.hx', source: 'class B { private function f():Void {} }' }
		]);
		Assert.equals(-1, fixed.indexOf('override public'));
		Assert.equals(-1, fixed.indexOf('override private'));
	}

	/** An UNMARKED non-override base member is not provably private (public-default containers exist) — report-only. */
	public function testFixOverrideUnmarkedBaseStaysReportOnly(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, [{ file: 'B.hx', source: 'class B { function f():Void {} }' }]);
		Assert.equals(-1, fixed.indexOf('override public'));
		Assert.equals(-1, fixed.indexOf('override private'));
	}

	/** An override whose supertype is NOT in the index stays report-only. */
	public function testFixOverrideUnindexedSupertypeStaysReportOnly(): Void {
		final sub: String = 'class C extends B { override function f():Void {} }';
		final fixed: String = fixedSourceIndexed(sub, []);
		Assert.equals(-1, fixed.indexOf('override public'));
		Assert.equals(-1, fixed.indexOf('override private'));
	}

	/** An extern class defaults its members to public; the autofix must NOT force `private`. */
	public function testFixSkipsExternClass(): Void {
		Assert.equals(1, violations('extern class C { function f():Void; }').length);
		Assert.equals(-1, fixedSource('extern class C { function f():Void; }').indexOf('private'));
	}

	/** A `@:publicFields` class defaults its members to public; the autofix must NOT force `private`. */
	public function testFixSkipsPublicFieldsClass(): Void {
		Assert.equals(1, violations('@:publicFields class D { function g():Void {} }').length);
		Assert.equals(-1, fixedSource('@:publicFields class D { function g():Void {} }').indexOf('private'));
	}

	/** `final class` wraps the class in a decl node; the extern / public-default skip must still reach the members. */
	public function testFixSkipsExternFinalClass(): Void {
		Assert.equals(1, violations('extern final class C { function f():Void; }').length);
		Assert.equals(-1, fixedSource('extern final class C { function f():Void; }').indexOf('private'));
	}

	/** A `@:publicFields final class` (the project's house form) must also stay report-only, not get `private`. */
	public function testFixSkipsPublicFieldsFinalClass(): Void {
		Assert.equals(1, violations('@:publicFields final class D { function g():Void {} }').length);
		Assert.equals(-1, fixedSource('@:publicFields final class D { function g():Void {} }').indexOf('private'));
	}

	/** A plain `final class` still defaults members to private, so the autofix DOES insert `private`. */
	public function testFixInsertsPrivateInFinalClass(): Void {
		Assert.isTrue(fixedSource('final class F { function g():Void {} }').indexOf('private function g') >= 0);
	}

	private function violations(src: String): Array<Violation> {
		return new MissingVisibility().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: MissingVisibility = new MissingVisibility();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		return applyEdits(src, edits);
	}

	/** `fixedSource` with a `SymbolIndex` built over `others` + the fixed file itself — the production `--fix` shape. */
	private function fixedSourceIndexed(src: String, others: Array<{ file: String, source: String }>): String {
		final check: MissingVisibility = new MissingVisibility();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = others.concat([{ file: 'C.hx', source: src }]);
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final edits: Array<{ span: Span, text: String }> =
			check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin, index);
		return applyEdits(src, edits);
	}

	private static function applyEdits(src: String, edits: Array<{ span: Span, text: String }>): String {
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
