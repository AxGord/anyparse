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
 * The `prefer-final-field` check: a private `var` field assigned only at its
 * declaration is flagged `Info` and `var` rewritten to `final`. A public field, a
 * field written elsewhere (`=` / `this.x =` / `++`), a no-init field, a property,
 * and a field of a non-confined type are left alone.
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

	public function testNoInitNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int; public function new() { _x = 1; } }').length);
	}

	/** A read (`return _x`) and a comparison (`_x == 1`) are not writes — still flagged. */
	public function testReadAndComparisonStillFlagged(): Void {
		Assert.equals(1, violations('class C { private var _x:Int = 0; function r():Bool { return _x == 1; } }').length);
	}

	/** A property (`var x(...)`) has a `(` in its head — skipped. */
	public function testPropertyNotFlagged(): Void {
		Assert.equals(0, violations('class C { var x(default, null):Int = 0; }').length);
	}

	/** A subtype can write the private field, so the type is not confined — left alone. */
	public function testNonConfinedNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { private var _x:Int = 0; }' },
			{ file: 'D.hx', source: 'class D extends C {}' }
		];
		Assert.equals(0, new PreferFinalField().run(files, new HaxeQueryPlugin()).length);
	}

	public function testFixVarToFinal(): Void {
		final fixed: String = fixedSource('class C { private var _x:Int = 0; }');
		Assert.isTrue(fixed.indexOf('private final _x:Int = 0') >= 0);
		Assert.equals(-1, fixed.indexOf('var _x'));
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

	/** A prefix `++`/`--` separated from the field by a comment is still detected — not flagged. */
	public function testPrefixIncrementWithCommentNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _d:Int = 4; function f():Void { ++ /* c */ _d; } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferFinalField().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
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
