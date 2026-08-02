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
 * The `inline-constant` check: a `static final` constant of a basic scalar type (Int /
 * Float / Bool, NOT String) whose initializer is a compile-time constant is flagged `Info`
 * and rewritten to `static inline final` (the `:Type` annotation kept). The initializer may be
 * a literal OR a reference — bare or `Other.A`-qualified — that provably resolves to an
 * already-`static inline` constant of such a literal; declaration order is irrelevant. PUBLIC
 * constants are included, gated by the reflection-name and macro-consumption checks. A String
 * constant, a non-static / already-inline / `var` field, a non-literal initializer, constant
 * arithmetic over a proven reference (Phase 2, deferred), a reference to a non-inline / String /
 * `#if`-guarded / non-field / unresolvable target, a deeper `pkg.Other.A` chain, a reflected name,
 * a macro-consumed module, a `@:keep` / `@:rtti` field or class, and an enum-abstract / `#if`
 * member are all left alone. Three fixtures pin the qualified arm's certainty requirements, each
 * of which would otherwise emit code that does not compile in some configuration: unanimity across
 * a multi-candidate simple name, a type declared twice through `#if`, and a reference through an
 * ALIAS import (the one import kind the index does not bring into simple-name scope).
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

	public function testPublicFlagged(): Void {
		// PUBLIC scalar constants are now inlinable too (the blanket public exclusion is
		// lifted), gated only by the reflection and macro-consumption checks.
		final vs: Array<Violation> = violations('class C { public static final A:Int = 5; }');
		Assert.equals(1, vs.length);
		Assert.equals('inline-constant', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('use inline') >= 0);
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

	public function testInlineVarIntFlagged(): Void {
		// A `static inline var` scalar constant is flagged for var -> final (behaviour-neutral:
		// a write to a static inline var is already a compile error - verified).
		final vs: Array<Violation> = violations('class C { public static inline var N:Int = 5; }');
		Assert.equals(1, vs.length);
		Assert.equals('inline-constant', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('use final') >= 0);
	}

	public function testInlineVarStringFlagged(): Void {
		// Unlike the add-inline case (String excluded for hxcpp per-use-site duplication), the
		// var -> final case accepts String: the field is already inline, so nothing about its
		// codegen changes - only the keyword.
		Assert.equals(1, violations('class C { public static inline var EV:String = "evt"; }').length);
	}

	public function testInlineVarSelfNamedEventConstantFlagged(): Void {
		// An event-name constant whose value equals its own name must NOT self-trip the
		// reflection gate (var -> final is reflection-neutral: Reflect.field / Type.getClassFields
		// identical for inline var vs inline final - verified).
		Assert.equals(1, violations('class C { public static inline var ITEM_SELECTED:String = "ITEM_SELECTED"; }').length);
	}

	public function testInlineVarPublicFlagged(): Void {
		// PUBLIC is included: inline var -> inline final changes no ABI (the field stays inline).
		Assert.equals(1, violations('class C { public static inline var N:Int = 5; }').length);
	}

	public function testInlineVarFixVarToFinal(): Void {
		final fixed: String = fixedSource('class C { public static inline var N:Int = 5; }');
		Assert.isTrue(fixed.indexOf('public static inline final N:Int = 5') >= 0);
	}

	public function testInlineVarStringFixVarToFinal(): Void {
		final fixed: String = fixedSource('class C { public static inline var ITEM_SELECTED:String = "ITEM_SELECTED"; }');
		Assert.isTrue(fixed.indexOf('public static inline final ITEM_SELECTED:String') >= 0);
	}

	public function testInlineVarKeepNotFlagged(): Void {
		// A @:keep field is explicitly retained (reflection / tooling) - never rewritten.
		Assert.equals(0, violations('class C { @:keep public static inline var N:Int = 5; }').length);
	}

	public function testInlineVarReflectedElsewhereNotFlagged(): Void {
		// The name read as a reflection key in OTHER code (not its own value) keeps it a var.
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public static inline var MYCONST:Int = 5; }' },
			{ file: 'D.hx', source: 'class D { function f():Void { Reflect.field(C, "MYCONST"); } }' }
		];
		Assert.equals(0, new InlineConstant().run(files, new HaxeQueryPlugin()).length);
	}

	public function testInlineVarExprInitNotFlagged(): Void {
		// An arithmetic initializer is not a bare literal - left alone (conservative constant test).
		Assert.equals(0, violations('class C { public static inline var N:Int = 1 + 2; }').length);
	}

	public function testInlineVarConditionalValueNotFlagged(): Void {
		// An #if-divergent initializer is a ConditionalExpr, not a plain literal - left alone.
		Assert.equals(0, violations('class C { public static inline var N:Int = #if debug 1 #else 2 #end; }').length);
	}

	public function testNonInlineStaticVarNotFlagged(): Void {
		// A plain (non-inline) static var is mutable - writes are allowed, so var -> final is unsound.
		Assert.equals(0, violations('class C { public static var n:Int = 5; }').length);
	}

	/** A PUBLIC String constant stays excluded (hxcpp per-use-site literal duplication) even though public scalars now convert. */
	public function testPublicStringNotFlagged(): Void {
		Assert.equals(0, violations('class C { public static final A:String = "x"; }').length);
	}

	/**
	 * A PUBLIC constant whose name appears as a string literal may be read by reflection; the
	 * name-as-string gate keeps it non-inline. Mandatory for the public arm: on hxcpp adding
	 * inline erases the field's reflective value (`Reflect.field` returns null), unlike var -> final.
	 */
	public function testPublicReflectedNameNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { public static final MYCONST:Int = 5; function f():Void { Reflect.field(C, "MYCONST"); } }').length
		);
	}

	/** A PUBLIC constant whose owning module is referenced in macro-context code (a file importing haxe.macro that mentions the class) is macro-consumed and left alone. */
	public function testMacroContextReferencedModuleNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public static final A:Int = 5; }' },
			{ file: 'Build.hx', source: 'import haxe.macro.Context;\nclass Build { public static function f():Void { C; } }' }
		];
		Assert.equals(0, new InlineConstant().run(files, new HaxeQueryPlugin()).length);
	}

	/** The same class mentioned in a NON-macro file is not macro-consumed — its public constant still converts. */
	public function testNonMacroContextReferenceStillFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public static final A:Int = 5; }' },
			{ file: 'User.hx', source: 'class User { public static function f():Void { C; } }' }
		];
		Assert.equals(1, new InlineConstant().run(files, new HaxeQueryPlugin()).length);
	}

	/** A field-level `@:rtti` pins the constant for runtime type info — never inlined. */
	public function testRttiFieldNotFlagged(): Void {
		Assert.equals(0, violations('class C { @:rtti public static final A:Int = 5; }').length);
	}

	/** A class-level `@:rtti` exposes every member to `haxe.rtti.Rtti` — none inlined. */
	public function testRttiClassNotFlagged(): Void {
		Assert.equals(0, violations('@:rtti class C { public static final A:Int = 5; }').length);
	}

	/** A class-level `@:keep` pins all members — none inlined. */
	public function testKeepClassNotFlagged(): Void {
		Assert.equals(0, violations('@:keep class C { public static final A:Int = 5; }').length);
	}

	/** The fix inserts `inline` on a public constant, preserving canonical order: `public static final` -> `public static inline final`. */
	public function testFixPublicInsertsInline(): Void {
		final fixed: String = fixedSource('class C { public static final A:Int = 5; }');
		Assert.isTrue(fixed.indexOf('public static inline final A:Int = 5') >= 0);
	}

	/** A class-level `@:rtti` on a `final class` (nested in a FinalDecl wrapper) still pins all members. */
	public function testRttiFinalClassNotFlagged(): Void {
		Assert.equals(0, violations('@:rtti final class C { public static final A:Int = 5; }').length);
	}

	/** A class-level `@:keep` on a `final class` pins all members. */
	public function testKeepFinalClassNotFlagged(): Void {
		Assert.equals(0, violations('@:keep final class C { public static final A:Int = 5; }').length);
	}

	/** A plain `final class` with no pin meta still has its public constant flagged (scanning reaches the wrapped container). */
	public function testFinalClassPublicFlagged(): Void {
		Assert.equals(1, violations('final class C { public static final A:Int = 5; }').length);
	}

	/** A bare reference to a same-class `static inline final` scalar folds, so the referencing constant is inlinable too. */
	public function testSameClassInlineRefFlagged(): Void {
		final vs: Array<Violation> = violations('class C { static inline final A:Int = 1; static final B:Int = A; }');
		// One predicate, because utest keeps running after a failed assertion and eager interpolation
		// of `vs[0]` on an empty array would surface a TypeError instead of the intended diagnostic.
		Assert.isTrue(vs.length == 1 && vs[0].message.indexOf("'B'") >= 0, 'expected exactly B flagged, got: $vs');
	}

	/** Declaration ORDER is irrelevant - a forward reference compiles and folds (verified live). */
	public function testForwardInlineRefFlagged(): Void {
		final vs: Array<Violation> = violations('class C { static final B:Int = A; static inline final A:Int = 1; }');
		// One predicate, because utest keeps running after a failed assertion and eager interpolation
		// of `vs[0]` on an empty array would surface a TypeError instead of the intended diagnostic.
		Assert.isTrue(vs.length == 1 && vs[0].message.indexOf("'B'") >= 0, 'expected exactly B flagged, got: $vs');
	}

	/**
	 * A `static inline var` is a valid fold target too. `@:keep` pins the target so its own
	 * var -> final finding cannot blur the count; the reference to it is still proven.
	 */
	public function testInlineVarTargetRefFlagged(): Void {
		final vs: Array<Violation> = violations('class C { @:keep static inline var A:Int = 1; static final B:Int = A; }');
		// One predicate, because utest keeps running after a failed assertion and eager interpolation
		// of `vs[0]` on an empty array would surface a TypeError instead of the intended diagnostic.
		Assert.isTrue(vs.length == 1 && vs[0].message.indexOf("'B'") >= 0, 'expected exactly B flagged, got: $vs');
	}

	/** A qualified `Other.A` resolves through the SymbolIndex against this file's import scope. */
	public function testCrossClassQualifiedRefFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Other.hx', source: 'class Other { public static inline final A:Int = 1; }' },
			{ file: 'C.hx', source: 'class C { static final B:Int = Other.A; }' }
		];
		final vs: Array<Violation> = new InlineConstant().run(files, new HaxeQueryPlugin());
		// One predicate, because utest keeps running after a failed assertion and eager interpolation
		// of `vs[0]` on an empty array would surface a TypeError instead of the intended diagnostic.
		Assert.isTrue(vs.length == 1 && vs[0].message.indexOf("'B'") >= 0, 'expected exactly B flagged, got: $vs');
	}

	/** The fix inserts `inline` on a reference-initialized constant, preserving the initializer. */
	public function testFixInsertsInlineForRefInitializer(): Void {
		final fixed: String = fixedSource('class C { static inline final A:Int = 1; static final B:Int = A; }');
		Assert.isTrue(fixed.indexOf('static inline final B:Int = A') >= 0, 'got: $fixed');
	}

	/**
	 * A NON-inline `static final` target is a COMPILE ERROR to reference from an inline
	 * initializer ("Inline variable initialization must be a constant value" - measured), so the
	 * reference proves nothing. `@:keep` on the target makes the fixture's expected total 0.
	 */
	public function testRefToNonInlineTargetNotFlagged(): Void {
		Assert.equals(0, violations('class C { @:keep static final A:Int = 1; static final B:Int = A; }').length);
	}

	/** The String exclusion applies transitively: the TARGET fails the literal-kinds policy seam. */
	public function testRefToStringConstantNotFlagged(): Void {
		Assert.equals(0, violations('class C { static inline final A:String = "x"; static final B:String = A; }').length);
	}

	/** A `#if`-guarded target is nested in a `Conditional`, never a direct container child - unprovable. */
	public function testRefToConditionalTargetNotFlagged(): Void {
		Assert.equals(0, violations('class C { #if debug static inline final A:Int = 1; #end static final B:Int = A; }').length);
	}

	/** A bare reference that names no member of the owning container proves nothing. */
	public function testUnresolvedBareRefNotFlagged(): Void {
		Assert.equals(0, violations('class C { static final B:Int = A; }').length);
	}

	/** A qualified reference whose type the index does not declare proves nothing. */
	public function testUnresolvedQualifiedRefNotFlagged(): Void {
		Assert.equals(0, violations('class C { static final B:Int = Other.A; }').length);
	}

	/**
	 * Constant arithmetic over a proven reference compiles too, but is deliberately out of scope
	 * (Phase 2): an arithmetic node carries no name and matches neither reference kind.
	 */
	public function testArithmeticOverInlineRefNotFlagged(): Void {
		Assert.equals(0, violations('class C { static inline final A:Int = 1; static final B:Int = A * 2; }').length);
	}

	/**
	 * A same-named `static inline function` proves nothing. The `isField` conjunct names the reason,
	 * but the terminal literal test is what actually rejects it - a non-field member is always a
	 * FUNCTION, whose last child is a body node and never a literal - so `isField` is a shape guard
	 * with no discriminating fixture, not a provable gate.
	 */
	public function testBareRefToFunctionNotFlagged(): Void {
		Assert.equals(0, violations('class C { static inline function A():Int return 1; static final B:Int = A; }').length);
	}

	/**
	 * UNANIMITY: the root-package `Other` is in simple-name scope from every file, so `Other.A`
	 * collects TWO candidates. One conforms and one does not, and a single non-conforming candidate
	 * refuses the whole proof. `@:keep` pins both targets so only `B` could ever be flagged.
	 */
	public function testQualifiedRefAmbiguousCandidatesNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'p/C.hx', source: 'package p;\nclass C { static final B:Int = Other.A; }' },
			{ file: 'p/Other.hx', source: 'package p;\nclass Other { @:keep public static inline final A:Int = 1; }' },
			{ file: 'Other.hx', source: 'class Other { @:keep public static final A:Int = 1; }' }
		];
		Assert.equals(0, new InlineConstant().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * A type declared twice through `#if` is deduped to ONE index candidate, so taking the first
	 * container node would prove the reference from whichever branch is written first and break the
	 * other configuration. `soleContainer` refuses the ambiguity instead.
	 */
	public function testQualifiedRefConditionalTypeNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'Other.hx',
				source: '#if debug\nclass Other { @:keep public static inline final A:Int = 1; }\n'
					+ '#else\nclass Other { @:keep public static final A:Int = 1; }\n#end'
			},
			{ file: 'C.hx', source: 'class C { static final B:Int = Other.A; }' }
		];
		Assert.equals(0, new InlineConstant().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * An ALIAS import is the one import kind `SymbolIndex.simpleRefInScope` does not bring into
	 * simple-name scope, so the candidate set can MISS the real target - here Haxe binds `Alias` to
	 * the non-inline `pkg.Other`, while the index would offer the same-package `q.Alias`. Unanimity
	 * cannot vet a candidate that was never collected, so the alias refuses outright.
	 */
	public function testQualifiedRefThroughImportAliasNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Other.hx', source: 'package pkg;\nclass Other { @:keep public static final A:Int = 1; }' },
			{ file: 'q/Alias.hx', source: 'package q;\nclass Alias { @:keep public static inline final A:Int = 1; }' },
			{ file: 'q/C.hx', source: 'package q;\nimport pkg.Other as Alias;\nclass C { static final B:Int = Alias.A; }' }
		];
		Assert.equals(0, new InlineConstant().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * A deeper `pkg.Other.A` chain (whose receiver is itself a field access) is not attempted. The
	 * import makes `Other` resolvable from `C.hx`, so ONLY the bare-receiver gate can reject this.
	 */
	public function testDeepQualifiedChainNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'Other.hx', source: 'package pkg;\nclass Other { public static inline final A:Int = 1; }' },
			{ file: 'C.hx', source: 'import pkg.Other;\nclass C { static final B:Int = pkg.Other.A; }' }
		];
		Assert.equals(0, new InlineConstant().run(files, new HaxeQueryPlugin()).length);
	}

	/** The reflection-name gate covers a reference-initialized constant exactly as it covers a literal one. */
	public function testRefInitializedReflectedNameNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { static inline final A:Int = 1; static final MYCONST:Int = A; function f():Void { Reflect.field(C, "MYCONST"); } }'
			).length
		);
	}

}
