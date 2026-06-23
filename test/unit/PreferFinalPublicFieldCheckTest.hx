package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFinalPublicField;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-final-public-field` check: a PUBLIC `var` field assigned only at its
 * declaration and never reassigned across the project is flagged `Info` and `var`
 * rewritten to `final`. A private field (that is `prefer-final-field`'s job), a
 * field written internally (`x =` / `this.x =` / `++`) or externally (`c.x =`), an
 * unresolved-receiver write, a no-init field, a property, and a field whose type
 * has a subtype are all left alone.
 */
class PreferFinalPublicFieldCheckTest extends Test {

	public function testPublicInitOnlyFlagged(): Void {
		final vs: Array<Violation> = violations('class C { public var x:Int = 0; }');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-final-public-field', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** A private field is the `prefer-final-field` check's job, not this one. */
	public function testPrivateNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int = 0; }').length);
	}

	/** A no-modifier field defaults to private — not this check's concern. */
	public function testDefaultVisibilityNotFlagged(): Void {
		Assert.equals(0, violations('class C { var x:Int = 0; }').length);
	}

	public function testWrittenViaThisNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int = 0; function s():Void { this.x = 5; } }').length);
	}

	public function testWrittenBareNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int = 0; function s():Void { x = 5; } }').length);
	}

	public function testIncrementNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int = 0; function i():Void { x++; } }').length);
	}

	public function testNoInitNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int; public function new() { x = 1; } }').length);
	}

	/** A read (`return x`) and a comparison (`x == 1`) are not writes — still flagged. */
	public function testReadAndComparisonStillFlagged(): Void {
		Assert.equals(1, violations('class C { public var x:Int = 0; function r():Bool { return x == 1; } }').length);
	}

	/** A property (`var x(...)`) has a `(` in its head — skipped. */
	public function testPropertyNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x(default, null):Int = 0; }').length);
	}

	/** A typed external write (`c.x = 9` where `c:C`) is resolved to C — left alone. */
	public function testExternalWriteNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; }' },
			{ file: 'W.hx', source: 'class W { public function poke(c:C):Void { c.x = 9; } }' }
		];
		Assert.equals(0, new PreferFinalPublicField().run(files, new HaxeQueryPlugin()).length);
	}

	/** A typed external write to a DIFFERENT type's same-named field does not count. */
	public function testExternalWriteOnOtherTypeStillFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D { public var x:Int = 0; public function poke(d:D):Void { d.x = 9; } }' }
		];
		final vs: Array<Violation> = new PreferFinalPublicField().run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals('C.hx', vs[0].file);
	}

	/** An unresolved receiver write (`makeC().x = 7`) bails the field name — left alone. */
	public function testUnresolvedReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C { public var x:Int = 0; function p():Void { makeC().x = 7; } function makeC():C { return new C(); } }').length
		);
	}

	/** A subtype could write the inherited field, attributing to the subtype — left alone. */
	public function testSubtypeNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D extends C {}' }
		];
		Assert.equals(0, new PreferFinalPublicField().run(files, new HaxeQueryPlugin()).length);
	}

	public function testFixVarToFinal(): Void {
		final fixed: String = fixedSource('class C { public var x:Int = 0; }');
		Assert.isTrue(fixed.indexOf('public final x:Int = 0') >= 0);
		Assert.equals(-1, fixed.indexOf('var x'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-final-public-field'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-final-public-field'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public var x = ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferFinalPublicField().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: PreferFinalPublicField = new PreferFinalPublicField();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	/** A field whose interface declares it as `var` must stay `var` — `final` breaks the contract. */
	public function testInterfaceVarFieldNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'I.hx', source: 'interface I { public var x:Int; }' },
			{ file: 'C.hx', source: 'class C implements I { public var x:Int = 0; }' }
		];
		Assert.equals(0, new PreferFinalPublicField().run(files, new HaxeQueryPlugin()).length);
	}

	/** A field written inside a `macro {}` reification (emitted runtime code, unresolved receiver) is bailed, not flagged. */
	public function testMacroEmittedWriteNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int = 0; function g():Dynamic { return macro foo.x = 1; } }').length);
	}

}
