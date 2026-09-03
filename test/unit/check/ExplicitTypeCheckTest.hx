package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.ExplicitType;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * The `explicit-type` check: a member field with no `:Type`, a function parameter
 * with no `:Type`, or a function with no return type is flagged `Warning`. A
 * constructor (`new`) is exempt from the return-type rule, and enum-abstract values
 * are exempt from the field rule; interface members are checked like any other.
 */
class ExplicitTypeCheckTest extends Test {

	// --- parameter types copied from an implemented / overridden signature ---

	private static inline final IFACE: String =
		'interface I {\n\tpublic function grab(str:String):Int;\n\tpublic function opt(?flag:Bool):Void;\n}';

	public function testTypedFieldNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var a:Int; }').length);
	}

	public function testUntypedFieldWithInitFlagged(): Void {
		final vs: Array<Violation> = violations('class C { public var a = 0; }');
		Assert.equals(1, vs.length);
		Assert.equals('explicit-type', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testUntypedFieldNoInitFlagged(): Void {
		Assert.equals(1, violations('class C { public var b; }').length);
	}

	public function testTypedParamsAndReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C { public function f(a:Int, b:String):Void {} }').length);
	}

	public function testUntypedParamFlagged(): Void {
		Assert.equals(1, violations('class C { public function f(a):Void {} }').length);
	}

	public function testMissingReturnTypeFlagged(): Void {
		Assert.equals(1, violations('class C { public function f() {} }').length);
	}

	public function testParamAndReturnBothFlagged(): Void {
		Assert.equals(2, violations('class C { public function g(a) {} }').length);
	}

	public function testConstructorReturnExempt(): Void {
		Assert.equals(0, violations('class C { public function new() {} }').length);
	}

	public function testConstructorParamStillChecked(): Void {
		Assert.equals(1, violations('class C { public function new(a) {} }').length);
	}

	public function testEnumAbstractValuesExempt(): Void {
		Assert.equals(0, violations('enum abstract E(Int) { final X = 0; final Y = 1; }').length);
	}

	public function testEnumAbstractMethodChecked(): Void {
		// The value is exempt, but the method's missing return type is flagged.
		Assert.equals(1, violations('enum abstract E(Int) { final X = 0; public function f() {} }').length);
	}

	public function testUnprojectedEnumAbstractValuesExempt(): Void {
		// The same exemption for the two spellings that project under a plain abstract — `@:enum` and
		// the `#if` version guard. Annotating such a value with its literal's type is `Int should be E`.
		Assert.equals(0, violations('@:enum abstract E(Int) { final X = 0; final Y = 1; }').length);
		Assert.equals(0, violations('#if (haxe_ver >= 4.2) enum #else @:enum #end abstract E(Int) { final X = 0; final Y = 1; }').length);
	}

	public function testMetaOnlyCondRegionLeavesAbstractFieldChecked(): Void {
		// A leading region carrying only metadata contributes no declaration-prefix keyword, so the
		// abstract stays a plain one and its untyped field is still flagged.
		Assert.equals(1, violations('#if js @:native("E") #end abstract F(Int) { final a = 0; }').length);
	}

	public function testInterfaceTypedMembersNotFlagged(): Void {
		Assert.equals(0, violations('interface I { var a:Int; function f():Void; }').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('explicit-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('explicit-type'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/**
	 * A generic constraint (`<T:C>`) projects like a return type but sits before the
	 * parameters; a constrained-generic method with no return type must still be
	 * flagged. Regression for the position-aware return detection.
	 */
	public function testConstrainedGenericMissingReturnFlagged(): Void {
		Assert.equals(1, violations('class C { public function k<T:Iterator<Int>>(x:T) {} }').length);
	}

	public function testCheckstyleIgnoreEnumAbstractFalseFlags(): Void {
		// checkstyle Type.ignoreEnumAbstractValues=false turns off the exemption,
		// so an untyped enum-abstract value is flagged.
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = tmp != null && tmp.length > 0 ? tmp : '/tmp';
		final dir: String = '$base/anyparse_et_cs_${Sys.time()}';
		sys.FileSystem.createDirectory(dir);
		File.saveContent('$dir/checkstyle.json', '{"checks":[{"type":"Type","props":{"ignoreEnumAbstractValues":false}}]}');
		final path: String = '$dir/EA.hx';
		final src: String = 'enum abstract E(Int) {\n\tvar A = 1;\n}';
		File.saveContent(path, src);
		Assert.isTrue(new ExplicitType().run([{ file: path, source: src }], new HaxeQueryPlugin()).length >= 1);
		CliFixture.removeDir(dir);
	}

	public function testFixNewWithTypeParamsCarried(): Void {
		final out: String = applyFix('class C { public var a = new Map<Int, String>(); }');
		Assert.isTrue(out.indexOf('a:Map<Int, String> =') != -1, 'expected carried type params, got: $out');
	}

	public function testFixBareNewSkipped(): Void {
		// A bare `new Foo()` could be a generic used without params — annotating `:Foo` risks a broken build.
		Assert.equals(0, fixCount('class C { public var a = new Foo(); }'));
	}

	public function testFixNewWithArgsButNoParamsSkipped(): Void {
		Assert.equals(0, fixCount('class C { public var a = new Foo(1, 2); }'));
	}

	public function testFixStringLiteral(): Void {
		final out: String = applyFix('class C { var a = "hi"; }');
		Assert.isTrue(out.indexOf('a:String =') != -1, 'got: $out');
	}

	public function testFixSingleQuoteString(): Void {
		final out: String = applyFix("class C { var a = 'hi'; }");
		Assert.isTrue(out.indexOf('a:String =') != -1, 'got: $out');
	}

	public function testFixBoolLiteral(): Void {
		final out: String = applyFix('class C { var a = true; }');
		Assert.isTrue(out.indexOf('a:Bool =') != -1, 'got: $out');
	}

	public function testFixIntLiteral(): Void {
		final out: String = applyFix('class C { var a = 42; }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
	}

	public function testFixHexLiteral(): Void {
		final out: String = applyFix('class C { var a = 0xFF; }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
	}

	public function testFixFloatLiteral(): Void {
		final out: String = applyFix('class C { var a = 3.14; }');
		Assert.isTrue(out.indexOf('a:Float =') != -1, 'got: $out');
	}

	public function testFixNegativeInt(): Void {
		final out: String = applyFix('class C { var a = -5; }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
	}

	public function testFixNegativeFloat(): Void {
		final out: String = applyFix('class C { var a = -3.5; }');
		Assert.isTrue(out.indexOf('a:Float =') != -1, 'got: $out');
	}

	public function testFixTypedCast(): Void {
		final out: String = applyFix('class C { function f(x:Int) { } var a = cast(x, Foo); }');
		Assert.isTrue(out.indexOf('a:Foo =') != -1, 'got: $out');
	}

	public function testFixCheckType(): Void {
		final out: String = applyFix('class C { var a = (x : Bar); }');
		Assert.isTrue(out.indexOf('a:Bar =') != -1, 'got: $out');
	}

	public function testFixParamDefault(): Void {
		final out: String = applyFix('class C { public function f(p = 5):Void {} }');
		Assert.isTrue(out.indexOf('p:Int =') != -1, 'got: $out');
	}

	public function testFixSkipsCall(): Void {
		Assert.equals(0, fixCount('class C { var a = foo(); }'));
	}

	public function testFixSkipsArrayLiteral(): Void {
		Assert.equals(0, fixCount('class C { var a = [1, 2]; }'));
	}

	public function testFixSkipsTernary(): Void {
		Assert.equals(0, fixCount('class C { var a = c ? 1 : 2; }'));
	}

	public function testFixVoidMethodAnnotated(): Void {
		// A block-bodied method with no return at all returns Void.
		final out: String = applyFix('class C { public function f() {} }');
		Assert.isTrue(out.indexOf('f():Void') != -1, 'got: $out');
	}

	public function testFixVoidMethodWithBareReturn(): Void {
		// A bare `return;` is not a value-return — the method is still Void.
		final out: String = applyFix('class C { public function f() { if (a) return; } }');
		Assert.isTrue(out.indexOf('f():Void') != -1, 'got: $out');
	}

	public function testFixSkipsValueReturn(): Void {
		// `return 5;` is a value-return — its type is unknown without inference, so skip.
		Assert.equals(0, fixCount('class C { public function f() { return 5; } }'));
	}

	public function testFixSkipsValueReturnInExpression(): Void {
		// A `return <expr>` in expression position (`ReturnExpr`, inside a ternary) is still
		// a value-return in the function's own scope — must not be annotated Void.
		Assert.equals(0, fixCount('class C { public function f() { var y = c ? return 5 : 3; } }'));
	}

	public function testFixVoidDespiteLambdaValueReturn(): Void {
		// The lambda's `return x` belongs to the lambda, not to `f` — `f`'s own scope has no
		// value-return, so it is Void. The critical do-not-descend-into-lambdas case.
		final src: String = 'class C { public function f() { arr.map(x -> { return x; }); } }';
		Assert.equals(1, fixCount(src));
		Assert.isTrue(applyFix(src).indexOf('f():Void') != -1, 'got: ${applyFix(src)}');
	}

	public function testFixVoidDespiteNestedLocalFnValueReturn(): Void {
		// The nested local function's `return 7` is its own; `f` is Void. Only `f` is fixed.
		final src: String = 'class C { public function f() { function g() { return 7; } g(); } }';
		Assert.equals(1, fixCount(src));
		Assert.isTrue(applyFix(src).indexOf('f():Void') != -1, 'got: ${applyFix(src)}');
	}

	public function testFixSkipsMacroFunction(): Void {
		// A macro function returns `Expr` implicitly — annotating Void would break it.
		Assert.equals(0, fixCount('class C { macro static function f() {} }'));
	}

	public function testFixSkipsExpressionBodyReturn(): Void {
		// An expression-bodied `function f() return 5;` is a value-return — report-only.
		Assert.equals(0, fixCount('class C { public function f() return 5; }'));
	}

	public function testFixSkipsExpressionBodyBareCall(): Void {
		// An expression-bodied `function f() expr;` has an unknown return type — skip; only a
		// `{ … }` block body is annotated. Guards the block-body restriction.
		Assert.equals(0, fixCount('class C { public function f() trace("x"); }'));
	}

	public function testFixSkipsUntypedParamNoDefault(): Void {
		Assert.equals(0, fixCount('class C { public function f(a):Void {} }'));
	}

	public function testFixSkipsFieldNoInit(): Void {
		Assert.equals(0, fixCount('class C { public var b; }'));
	}

	public function testFixVoidSkipsBlockCommentWithParen(): Void {
		// A block comment containing ')' between the parameter list and the body must
		// not be taken for the parameter close — the finding stays report-only.
		Assert.equals(0, fixCount('class C { public function f() /* twelve (12) */ { trace(1); } }'));
	}

	public function testFixVoidSkipsLineCommentWithParen(): Void {
		// A trailing `//` comment containing ')' forces the body brace onto the next
		// line; the comment's ')' must not be mistaken for the parameter close.
		final src: String = 'class C {\n\tpublic function f() // twelve (12)\n\t{\n\t\ttrace(1);\n\t}\n}';
		Assert.equals(0, fixCount(src));
	}

	public function testFixVoidPlainFunctionAnnotated(): Void {
		// Sanity: with no comment between the parameter list and the body, the plain
		// function is still annotated `: Void`.
		final out: String = applyFix('class C { public function f() { trace(1); } }');
		Assert.isTrue(out.indexOf('f():Void') != -1, 'got: $out');
	}

	public function testFixVoidSkipsThrowOnlyBody(): Void {
		// A throw-only body unifies with any return type (a caller may use the call as
		// a value), so `: Void` would be unsound — report-only.
		Assert.equals(0, fixCount("class C { public function f() { throw 'x'; } }"));
	}

	public function testFixVoidSkipsGuardedThrow(): Void {
		// Deliberately over-conservative: a throw anywhere in the own scope, even
		// behind an `if`, suppresses the fix though `trace(1)` alone would be Void.
		Assert.equals(0, fixCount("class C { public function f() { if (c) throw 'x'; trace(1); } }"));
	}

	public function testFixMultipleNonCastFieldsNoCastTargets(): Void {
		// Several fixable violations, none a cast — the lazy cast-target lookup (a second
		// full parse) is never built, yet every field is annotated from its literal.
		final out: String = applyFix('class C { var a = 0; var b = "hi"; var c = true; }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
		Assert.isTrue(out.indexOf('b:String =') != -1, 'got: $out');
		Assert.isTrue(out.indexOf('c:Bool =') != -1, 'got: $out');
	}

	// --- a PARENTHESIZED initializer / default infers exactly as the bare one ---

	public function testFixParenNegativeIntField(): Void {
		// The field twin of the local-rule case: `(-1)` must annotate like a bare `-1`.
		final out: String = applyFix('class C { var a = (-1); }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
	}

	public function testFixDoubleParenIntField(): Void {
		final out: String = applyFix('class C { var a = ((1)); }');
		Assert.isTrue(out.indexOf('a:Int =') != -1, 'got: $out');
	}

	public function testFixParenStringLiteralField(): Void {
		final out: String = applyFix("class C { var a = ('hi'); }");
		Assert.isTrue(out.indexOf('a:String =') != -1, 'got: $out');
	}

	public function testFixParenBoolLiteralField(): Void {
		final out: String = applyFix('class C { var a = (true); }');
		Assert.isTrue(out.indexOf('a:Bool =') != -1, 'got: $out');
	}

	public function testFixParenTypedCastField(): Void {
		final out: String = applyFix('class C { function f(x:Int) { } var a = (cast(x, Foo)); }');
		Assert.isTrue(out.indexOf('a:Foo =') != -1, 'got: $out');
	}

	public function testFixParenWrappedCheckTypeField(): Void {
		// `(x : Bar)` IS the check-type node; an EXTRA wrap must peel back to it.
		final out: String = applyFix('class C { var a = ((x : Bar)); }');
		Assert.isTrue(out.indexOf('a:Bar =') != -1, 'got: $out');
	}

	public function testFixParenNewWithTypeParamsField(): Void {
		final out: String = applyFix('class C { public var a = (new Map<Int, String>()); }');
		Assert.isTrue(out.indexOf('a:Map<Int, String> =') != -1, 'got: $out');
	}

	public function testFixParenParamDefault(): Void {
		// A parenthesized DEFAULT VALUE annotates like a bare one — the parameter twin.
		final out: String = applyFix('class C { public function f(p = (5)):Void {} }');
		Assert.isTrue(out.indexOf('p:Int =') != -1, 'got: $out');
	}

	public function testFixSkipsParenCall(): Void {
		// Unwrapping exposes the arm, but a call still pins nothing -> report-only.
		Assert.equals(0, fixCount('class C { var a = (foo()); }'));
	}

	public function testFixSkipsParenArrayLiteral(): Void {
		// `explicit-type` has no array-literal arm (that one is local-only) — unchanged.
		Assert.equals(0, fixCount('class C { var a = ([1, 2]); }'));
	}

	public function testFixSkipsParenBareNew(): Void {
		// A bare `new Foo()` could be generic — the paren must not change that verdict.
		Assert.equals(0, fixCount('class C { public var a = (new Foo()); }'));
	}

	/** The implemented interface states the parameter type, so the implementation copies it verbatim. */
	public function testFixParamFromInterface(): Void {
		final out: String = scopedFix('class Impl implements I { public function grab(str):Int return 0; }');
		Assert.isTrue(out.indexOf('grab(str:String)') != -1, 'got: $out');
	}

	/** An overridden SUPERCLASS method is the same lookup — `supertypes` and `interfaces` share one closure. */
	public function testFixParamFromSuperclass(): Void {
		final out: String = scopedFix('class Impl extends B { override public function take(v):Void {} }', [
			{ file: 'B.hx', source: 'class B {\n\tpublic function new() {}\n\tpublic function take(v:Float):Void {}\n}' }
		]);
		Assert.isTrue(out.indexOf('take(v:Float)') != -1, 'got: $out');
	}

	/** The closure is TRANSITIVE: the type comes from the interface the implemented one extends. */
	public function testFixParamFromTransitiveInterface(): Void {
		final out: String = scopedFix('class Impl implements Mid { public function deep(n):Void {} }', [
			{ file: 'Mid.hx', source: 'interface Mid extends Root {}' },
			{ file: 'Root.hx', source: 'interface Root {\n\tpublic function deep(n:Int):Void;\n}' }
		]);
		Assert.isTrue(out.indexOf('deep(n:Int)') != -1, 'got: $out');
	}

	/** An optional parameter matches an optional declaration — the `?` sigil is part of the node kind, and it agrees. */
	public function testFixOptionalParamFromInterface(): Void {
		final out: String = scopedFix('class Impl implements I { public function opt(?flag):Void {} }');
		Assert.isTrue(out.indexOf('opt(?flag:Bool)') != -1, 'got: $out');
	}

	/** A NON-optional implementation of an optional declaration is a signature mismatch — skipped, not "fixed" into one. */
	public function testFixSkipsOptionalitySigilMismatch(): Void {
		final out: String = scopedFix('class Impl implements I { public function opt(flag):Void {} }');
		Assert.equals(-1, out.indexOf(':Bool'), 'got: $out');
	}

	/**
	 * A method no supertype declares has no written type to copy — report-only (its type would
	 * need the compiler oracle). CONTRACT, not a gate revert: there is no datum to find, so no
	 * implementation of the pass could emit here.
	 */
	public function testFixSkipsMethodWithNoDeclaredCounterpart(): Void {
		final out: String = scopedFix('class Impl implements I { public function solo(v):Void {} }');
		Assert.equals(-1, out.indexOf('solo(v:'), 'got: $out');
	}

	/** A constructor is never inherited — a superclass ctor's parameter list says nothing about this one. */
	public function testFixSkipsConstructor(): Void {
		final out: String = scopedFix(
			'class Impl extends B { public function new(v) { super(); } }',
			[{ file: 'B.hx', source: 'class B {\n\tpublic function new(v:Float) {}\n}' }]
		);
		Assert.equals(-1, out.indexOf('new(v:'), 'got: $out');
	}

	/** Two implemented interfaces stating DIFFERENT types for the position: no unambiguous answer, so no edit. */
	public function testFixSkipsConflictingDeclarations(): Void {
		final out: String = scopedFix('class Impl implements A implements B2 { public function both(v):Void {} }', [
			{ file: 'A.hx', source: 'interface A {\n\tpublic function both(v:Int):Void;\n}' },
			{ file: 'B2.hx', source: 'interface B2 {\n\tpublic function both(v:String):Void;\n}' }
		]);
		Assert.equals(-1, out.indexOf('both(v:'), 'got: $out');
	}

	/**
	 * The declaring type states the member but with a SHORTER parameter list — the position is not
	 * what the pass assumes. CONTRACT, not a gate revert: the guard is a bounds check whose removal
	 * cannot compile under strict null-safety, so no build discriminates it; what it pins is that a
	 * mismatched arity yields NO annotation rather than one copied from a clamped position.
	 */
	public function testFixSkipsShorterDeclaredParamList(): Void {
		final out: String = scopedFix('class Impl implements Sh { public function pair(a:Int, b):Void {} }', [
			{ file: 'Sh.hx', source: 'interface Sh {\n\tpublic function pair(a:Int):Void;\n}' }
		]);
		Assert.equals(-1, out.indexOf('b:'), 'got: $out');
	}

	/**
	 * The declaring type leaves the same parameter untyped — nothing to copy. CONTRACT, not a gate
	 * revert: `declaredTypeSources` simply has no entry for the position.
	 */
	public function testFixSkipsUntypedDeclaredParam(): Void {
		final out: String = scopedFix(
			'class Impl implements Un { public function u(v):Void {} }',
			[{ file: 'Un.hx', source: 'interface Un {\n\tpublic function u(v):Void;\n}' }]
		);
		Assert.equals(-1, out.indexOf('u(v:'), 'got: $out');
	}

	/**
	 * The declared type is visible to the INTERFACE (which imports it) but not to this file — the
	 * pass copies a type reference, never an import, so it skips rather than emit a name that does
	 * not resolve here.
	 */
	public function testFixSkipsTypeNotInScopeHere(): Void {
		final out: String = scopedFix('class Impl implements Pk { public function take(p):Void {} }', packaged());
		Assert.equals(-1, out.indexOf('take(p:'), 'got: $out');
	}

	/** The same shape once THIS file imports the type: it resolves here, so the annotation is copied. */
	public function testFixCopiesTypeAlreadyImportedHere(): Void {
		final out: String = scopedFix('import pkg.Payload;\n\nclass Impl implements Pk { public function take(p):Void {} }', packaged());
		Assert.isTrue(out.indexOf('take(p:Payload)') != -1, 'got: $out');
	}

	/**
	 * Without a `SymbolIndex` (a non-resolving fix path) the pass cannot look anything up and stays
	 * silent. CONTRACT, not a gate revert: the null check is what makes the pass type-check at all.
	 */
	public function testFixWithoutIndexSkips(): Void {
		final src: String = '${IFACE}\n\nclass Impl implements I { public function grab(str):Int return 0; }';
		final check: ExplicitType = new ExplicitType();
		final vs: Array<Violation> = check.run([{ file: 'Impl.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * A GENERIC interface states its members with its OWN type parameter, which the implementation
	 * binds to anything — copying `T` verbatim emits a name that resolves to nothing. Refused on
	 * the declaring type's `typeParamArity`, because a type parameter scans exactly like a nominal
	 * and no name-level gate can tell them apart.
	 */
	public function testFixSkipsGenericDeclaringType(): Void {
		final out: String = scopedFix('class Impl implements Gen { public function f(v):Void {} }', [
			{ file: 'Gen.hx', source: 'interface Gen<T> {\n\tpublic function f(v:T):Void;\n}' }
		]);
		Assert.equals(-1, out.indexOf('f(v:'), 'got: $out');
	}

	/**
	 * The nominal resolves on BOTH sides but to DIFFERENT declarations (`a.Payload` in the
	 * interface, `b.Payload` here). Copying it produces an override Haxe rejects with a type
	 * mismatch, so "the name resolves here" is not on its own a sufficient gate.
	 */
	public function testFixSkipsSameNameDifferentPackages(): Void {
		final out: String = scopedFix('import b.Payload;\n\nclass Impl implements Dp { public function take(p):Void {} }', [
			{ file: 'a/Payload.hx', source: 'package a;\n\nclass Payload {\n\tpublic function new() {}\n}' },
			{ file: 'b/Payload.hx', source: 'package b;\n\nclass Payload {\n\tpublic function new() {}\n}' },
			{ file: 'Dp.hx', source: 'import a.Payload;\n\ninterface Dp {\n\tpublic function take(p:Payload):Void;\n}' }
		]);
		Assert.equals(-1, out.indexOf('take(p:'), 'got: $out');
	}

	/**
	 * A LOCAL function in an earlier member carries the same name slot and is reached first in
	 * pre-order, so the declaring-method lookup must test the member KIND — copying the local's
	 * parameter type would annotate the override with an unrelated one.
	 */
	public function testFixIgnoresLocalFunctionOfTheSameName(): Void {
		final out: String = scopedFix('class Impl extends Lb { override public function f(v):Void {} }', [
			{
				file: 'Lb.hx',
				source: 'class Lb {\n\tpublic function new() {}\n'
				+ '\tpublic function a():Void { function f(v:String) { trace(v); } f("x"); }\n\tpublic function f(v:Float):Void {}\n}'
			}
		]);
		Assert.isTrue(out.indexOf('f(v:Float)') != -1, 'got: $out');
	}

	/**
	 * The only import bringing the type into THIS file sits inside `#if` — `ImportInfo.guarded`.
	 * The reference index is branch-blind, so it reads as unconditional; copying a type that rests
	 * on it emits a name that does not resolve in the other configuration.
	 */
	public function testFixSkipsGuardedImport(): Void {
		final out: String = scopedFix(
			'#if js\nimport pkg.Payload;\n#end\n\nclass Impl implements Pk { public function take(p):Void {} }', packaged()
		);
		Assert.equals(-1, out.indexOf('take(p:'), 'got: $out');
	}

	/**
	 * Neither side's index models the type (a standard-library one, and the standard library is
	 * normally outside the resolution scope), but both files carry the IDENTICAL plain import path
	 * — the one shape where an un-indexed name still provably means the same thing on both sides.
	 * PIN of preserved behaviour across the `typeUsableFrom` rewrite, not a gate revert.
	 */
	public function testFixCopiesUnindexedTypeImportedIdenticallyOnBothSides(): Void {
		final out: String = scopedFix('import haxe.io.Bytes;\n\nclass Impl implements By { public function w(b):Void {} }', [
			{ file: 'By.hx', source: 'import haxe.io.Bytes;\n\ninterface By {\n\tpublic function w(b:Bytes):Void;\n}' }
		]);
		Assert.isTrue(out.indexOf('w(b:Bytes)') != -1, 'got: $out');
	}

	/**
	 * The same un-indexed type imported by the DECLARING file only: nothing proves it resolves here,
	 * so it is skipped. PIN of preserved behaviour across the `typeUsableFrom` rewrite.
	 */
	public function testFixSkipsUnindexedTypeImportedOnOneSide(): Void {
		final out: String = scopedFix('class Impl implements By { public function w(b):Void {} }', [
			{ file: 'By.hx', source: 'import haxe.io.Bytes;\n\ninterface By {\n\tpublic function w(b:Bytes):Void;\n}' }
		]);
		Assert.equals(-1, out.indexOf('w(b:'), 'got: $out');
	}

	/**
	 * `String` needs no import in any module, so it copies with nothing indexed at all — the
	 * motivating case, and what `AMBIENT_TYPES` exists for. PIN: it must survive every tightening
	 * of `typeUsableFrom`, since no index models the standard library.
	 */
	public function testFixCopiesAmbientTypeWithNothingIndexed(): Void {
		final out: String = scopedFix('class Impl implements I { public function grab(str):Int return 0; }');
		Assert.isTrue(out.indexOf('grab(str:String)') != -1, 'got: $out');
	}

	/** A `pkg.Payload` the interface imports and the implementation does not. */
	private function packaged(): Array<{ file: String, source: String }> {
		return [
			{ file: 'pkg/Payload.hx', source: 'package pkg;\n\nclass Payload {\n\tpublic function new() {}\n}' },
			{ file: 'Pk.hx', source: 'import pkg.Payload;\n\ninterface Pk {\n\tpublic function take(p:Payload):Void;\n}' }
		];
	}

	/**
	 * Apply `fix` to `impl` (keyed `Impl.hx`) with a `SymbolIndex` built over it plus `decls`
	 * (default: the shared `I` interface) — the resolving path `lint --fix` takes.
	 */
	private function scopedFix(impl: String, ?decls: Array<{ file: String, source: String }>): String {
		final files: Array<{ file: String, source: String }> = [{ file: 'Impl.hx', source: impl }].concat(decls ?? [
			{
				file: 'I.hx',
				source: IFACE
			}
		]);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ExplicitType = new ExplicitType();
		final vs: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'Impl.hx');
		final edits: Array<{ span: Span, text: String }> = check.fix(impl, vs, plugin, SymbolIndex.build(files, plugin));
		edits.sort((a, b) -> b.span.from - a.span.from);
		var result: String = impl;
		for (e in edits) result = result.substring(0, e.span.from) + e.text + result.substring(e.span.to);
		return result;
	}

	private function violations(src: String): Array<Violation> {
		return new ExplicitType().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: ExplicitType = new ExplicitType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		edits.sort((a, b) -> b.span.from - a.span.from);
		var result: String = src;
		for (e in edits) result = result.substring(0, e.span.from) + e.text + result.substring(e.span.to);
		return result;
	}

	private function fixCount(src: String): Int {
		final check: ExplicitType = new ExplicitType();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return check.fix(src, vs, new HaxeQueryPlugin()).length;
	}

}
