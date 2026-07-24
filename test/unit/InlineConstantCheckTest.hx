package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.InlineConstant;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `inline-constant` check: a non-public `static final` constant of a basic scalar
 * type (Int / Float / Bool, NOT String) whose initializer is a compile-time literal is
 * flagged `Info` and rewritten to `static inline final` (the `:Type` annotation kept).
 * A String constant, a public / non-static / already-inline / `var` field, a non-literal
 * initializer, a reflected name, a `@:keep` field, and an enum-abstract / `#if` member
 * are all left alone.
 */
class InlineConstantCheckTest extends Test {

	public function testIntFlagged(): Void {
		final vs: Array<Violation> = violations('class C { static final A:Int = 5; }');
		Assert.equals(1, vs.length);
		Assert.equals('inline-constant', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFloatFlagged(): Void {
		Assert.equals(1, violations('class C { static final A:Float = 1.5; }').length);
	}

	public function testBoolFlagged(): Void {
		Assert.equals(1, violations('class C { static final A:Bool = true; }').length);
	}

	public function testHexFlagged(): Void {
		Assert.equals(1, violations('class C { static final A:Int = 0xFF; }').length);
	}

	/** A negation wrapping a numeric literal (`-5`) is still a compile-time constant. */
	public function testNegativeFlagged(): Void {
		Assert.equals(1, violations('class C { static final A:Int = -5; }').length);
	}

	/** A typeless scalar constant is inlinable too — the literal kind gates it, not the annotation. */
	public function testTypelessFlagged(): Void {
		Assert.equals(1, violations('class C { static final A = 5; }').length);
	}

	/** An explicit `private` is the default visibility — still a candidate. */
	public function testPrivateExplicitFlagged(): Void {
		Assert.equals(1, violations('class C { private static final _a:Int = 5; }').length);
	}

	/** String constants are excluded by policy (hxcpp per-use-site literal duplication). */
	public function testStringNotFlagged(): Void {
		Assert.equals(0, violations('class C { static final A:String = "x"; }').length);
	}

	public function testPublicNotFlagged(): Void {
		Assert.equals(0, violations('class C { public static final A:Int = 5; }').length);
	}

	/** An instance `final` cannot be inline (inline requires static). */
	public function testNonStaticNotFlagged(): Void {
		Assert.equals(0, violations('class C { final a:Int = 5; }').length);
	}

	public function testAlreadyInlineNotFlagged(): Void {
		Assert.equals(0, violations('class C { static inline final A:Int = 5; }').length);
	}

	/** A mutable `var` is not a `final` constant. */
	public function testVarNotFlagged(): Void {
		Assert.equals(0, violations('class C { static var a:Int = 5; }').length);
	}

	/** An arithmetic initializer is not a bare literal — left alone (conservative constant test). */
	public function testExprInitNotFlagged(): Void {
		Assert.equals(0, violations('class C { static final A:Int = 1 + 2; }').length);
	}

	public function testCallInitNotFlagged(): Void {
		Assert.equals(0, violations('class C { static final A:Int = f(); }').length);
	}

	/** `null` is not a basic scalar literal — left alone. */
	public function testNullNotFlagged(): Void {
		Assert.equals(0, violations('class C { static final A:C = null; }').length);
	}

	/** A `@:keep` field is explicitly retained (reflection / tooling) — never inlined. */
	public function testKeepNotFlagged(): Void {
		Assert.equals(0, violations('class C { @:keep static final A:Int = 5; }').length);
	}

	/** A constant whose name appears as a string literal may be read by reflection — left alone. */
	public function testReflectedNameNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { static final MYCONST:Int = 5; function f():Void { Reflect.field(this, "MYCONST"); } }').length
		);
	}

	/** The reflection scan is whole-scope: a name stringified in ANOTHER file keeps the constant non-inline. */
	public function testReflectedNameCrossFileNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { static final MYCONST:Int = 5; }' },
			{ file: 'D.hx', source: 'class D { function f():Void { Reflect.field(C, "MYCONST"); } }' }
		];
		Assert.equals(0, new InlineConstant().run(files, new HaxeQueryPlugin()).length);
	}

	/** A `#if`-guarded member is nested in a `Conditional` (not a direct container child) — never scanned; its plain sibling still is. */
	public function testConditionalMemberExcluded(): Void {
		final vs: Array<Violation> = violations('class C { static final A:Int = 5; #if debug static final B:Int = 6; #end }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf("'A'") >= 0);
	}

	/** An enum-abstract value lives under `EnumAbstractDecl` (not a visibility container) — handled by prefer-enum-abstract. */
	public function testEnumAbstractMemberNotFlagged(): Void {
		Assert.equals(0, violations('enum abstract E(Int) { final A = 1; var B = 2; }').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('inline-constant'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('inline-constant'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { static final A:Int = ').length);
	}

	/** The fix inserts `inline` and PRESERVES the `:Int` annotation: `static inline final A:Int = 5`. */
	public function testFixInsertsInlineKeepsType(): Void {
		final fixed: String = fixedSource('class C { static final A:Int = 5; }');
		Assert.isTrue(fixed.indexOf('static inline final A:Int = 5') >= 0);
	}

	/** The insertion preserves canonical modifier order: `private static final` -> `private static inline final`. */
	public function testFixCanonicalOrder(): Void {
		final fixed: String = fixedSource('class C { private static final _x:Int = 5; }');
		Assert.isTrue(fixed.indexOf('private static inline final _x:Int = 5') >= 0);
	}

	/** No fix on a String constant (none is flagged). */
	public function testNoFixForString(): Void {
		final fixed: String = fixedSource('class C { static final A:String = "x"; }');
		Assert.equals(-1, fixed.indexOf('inline'));
	}

	private function violations(src: String): Array<Violation> {
		return new InlineConstant().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: InlineConstant = new InlineConstant();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
