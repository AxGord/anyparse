package unit.check;

import anyparse.check.AvoidDynamic;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.Violation;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import unit.CheckFixture.FixRun;
import utest.Assert;
import utest.Test;

/**
 * The `avoid-dynamic` PARAMETER arm: a `Dynamic` parameter of a type-member function whose
 * every read is either an ascription `(p : T)` to ONE conversion-free type or a null
 * comparison is retyped to that `T` in the signature, and each ascription is unwrapped to its
 * operand. A `Null<Dynamic>` keeps its wrapper, a bare `Dynamic` gains one when a read
 * compares it with null, and `?p` keeps its `?`.
 *
 * Every gate is pinned AGAINST A CONTROL that differs only in what the gate looks at — a skip
 * assertion alone is satisfied by a fixer that never fires, so `assertBlocked` demands the
 * control fire in the same breath.
 */
@:nullSafety(Strict)
class AvoidDynamicParamAscriptionFixTest extends Test {

	/** In-file decl making `Foo` a provably conversion-free plain nominal for the index gate. */
	private static final FOO: String = '\nclass Foo {}\n';

	private static final FOO_BAR: String = '\nclass Foo {}\nclass Bar {}\n';

	/** The minimal firing shape every gate fixture is a one-change variant of. */
	private static final CONTROL: String = 'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO';

	// ---- FIRES ----

	public function testBareDynamicParamTakesTheAscribedType(): Void {
		final out: String = fixedSource(CONTROL);
		Assert.isTrue(out.indexOf('function f(p:Foo):Void') != -1, 'the signature carries the ascribed type');
		Assert.isTrue(out.indexOf('trace(p);') != -1, 'the ascription is unwrapped to its operand');
	}

	public function testNullWrappedParamKeepsItsWrapper(): Void {
		final out: String = fixedSource('class C {\n\tfunction f(p:Null<Dynamic>):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO');
		Assert.isTrue(out.indexOf('function f(p:Null<Foo>):Void') != -1, 'only the wrapped argument is rewritten');
		Assert.isTrue(out.indexOf('trace(p);') != -1);
	}

	public function testOptionalParamKeepsItsQuestionMark(): Void {
		final out: String = fixedSource('class C {\n\tfunction f(?p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO');
		Assert.isTrue(out.indexOf('function f(?p:Foo):Void') != -1, 'the optional marker survives');
		Assert.isTrue(out.indexOf('trace(p);') != -1, 'the ascription is unwrapped to its operand');
	}

	public function testTwoIdenticalAscriptionsAreBothUnwrapped(): Void {
		final out: String = fixedSource(
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t\ttrace((p : Foo));\n\t}\n}$FOO'
		);
		Assert.isTrue(out.indexOf('function f(p:Foo):Void') != -1);
		Assert.equals(-1, out.indexOf(' : Foo)'), 'no ascription is left behind');
	}

	public function testNullComparisonWrapsTheNarrowedType(): Void {
		final out: String = fixedSource('class C {\n\tfunction f(p:Dynamic):Void {\n\t\tif (p != null) trace((p : Foo));\n\t}\n}$FOO');
		Assert.isTrue(out.indexOf('function f(p:Null<Foo>):Void') != -1, 'a null-compared parameter stays nullable');
		Assert.isTrue(out.indexOf('if (p != null) trace(p);') != -1);
	}

	public function testStaticMethodNeedsNoOverrideFamilyProof(): Void {
		final out: String = fixedSource('class C {\n\tstatic function f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO');
		Assert.isTrue(out.indexOf('static function f(p:Foo):Void') != -1);
	}

	public function testInFileAbstractWithoutImplicitConversionPasses(): Void {
		final src: String = 'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Wrapped));\n\t}\n}\n'
			+ 'abstract Wrapped(Int) from Int to Int {\n\tpublic function new(v:Int) {\n\t\tthis = v;\n\t}\n}\n';
		Assert.isTrue(fixedSource(src).indexOf('function f(p:Wrapped):Void') != -1, 'a header-only from/to generates no code');
	}

	// ---- SKIPS, each against the control it differs from by one change ----

	public function testTwoDifferentAscribedTypesSkip(): Void {
		assertBlocked(
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t\ttrace((p : Bar));\n\t}\n}$FOO_BAR',
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t\ttrace((p : Foo));\n\t}\n}$FOO_BAR'
		);
	}

	public function testNonAscriptionReadSkips(): Void {
		assertBlocked('class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t\ttrace(p);\n\t}\n}$FOO', CONTROL);
	}

	public function testWriteSkips(): Void {
		assertBlocked('class C {\n\tfunction f(p:Dynamic):Void {\n\t\tp = null;\n\t\ttrace((p : Foo));\n\t}\n}$FOO', CONTROL);
	}

	public function testOverrideMethodSkips(): Void {
		assertBlocked('class C {\n\toverride function f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO', CONTROL);
	}

	public function testABodylessMethodSkips(): Void {
		// The NoBody gate is what decides, and it is the only one that can: a bodyless member has
		// no ascription to be pinned by either, and Haxe admits none outside an interface or an
		// `abstract` method — both signatures their implementors already match.
		assertBlocked('interface I {\n\tfunction f(p:Dynamic):Void;\n}$FOO', CONTROL);
	}

	public function testLambdaParameterSkips(): Void {
		assertBlocked(
			'class C {\n\tfunction f():Void {\n\t\tfinal g = (p:Dynamic) -> trace((p : Foo));\n\t\tg(null);\n\t}\n}$FOO', CONTROL
		);
	}

	public function testMethodOverriddenInASubtypeSkips(): Void {
		final base: String = CONTROL;
		Assert.equals(
			0, crossFileEdits(base, 'class D extends C {\n\toverride function f(p:Dynamic):Void {}\n}\n').length,
			'a subtype redeclaring the method makes the signature a family contract'
		);
		Assert.isTrue(crossFileEdits(base, 'class D {\n\tfunction g():Void {}\n}\n').length > 0, 'the same base alone still fires');
	}

	public function testAbstractCarryingAnImplicitConversionSkips(): Void {
		assertBlocked(
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Wrapped));\n\t}\n}\n'
			+ 'abstract Wrapped(Int) {\n\t@:from static function ofInt(v:Int):Wrapped {\n\t\treturn cast v;\n\t}\n}\n',
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Wrapped));\n\t}\n}\n'
			+ 'abstract Wrapped(Int) {\n\tstatic function ofInt(v:Int):Wrapped {\n\t\treturn cast v;\n\t}\n}\n'
		);
	}

	public function testTypedefAliasSkips(): Void {
		assertBlocked(
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Alias));\n\t}\n}\ntypedef Alias = Foo;$FOO',
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}\ntypedef Alias = Foo;$FOO'
		);
	}

	public function testUnresolvableAscribedTypeSkips(): Void {
		assertBlocked('class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Missing));\n\t}\n}$FOO', CONTROL);
	}

	public function testCommentInADeletedRegionSkips(): Void {
		assertBlocked('class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p /* keep */ : Foo));\n\t}\n}$FOO', CONTROL);
	}

	public function testAnAlreadyNullableAscriptionIsNotWrappedTwice(): Void {
		final out: String = fixedSource(
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\tif (p != null) trace((p : Null<Foo>));\n\t}\n}$FOO'
		);
		Assert.isTrue(out.indexOf('function f(p:Null<Foo>):Void') != -1, 'the ascription already admits null');
		Assert.equals(-1, out.indexOf('Null<Null<'), 'no double wrapper');
	}

	public function testANullWrappedParamWithANullableAscriptionKeepsOneWrapper(): Void {
		final out: String = fixedSource('class C {\n\tfunction f(p:Null<Dynamic>):Void {\n\t\ttrace((p : Null<Foo>));\n\t}\n}$FOO');
		Assert.isTrue(out.indexOf('function f(p:Null<Foo>):Void') != -1, 'the written wrapper is replaced, not nested');
		Assert.equals(-1, out.indexOf('Null<Null<'), 'no double wrapper');
	}

	public function testAnImplicitConversionOwnerSkips(): Void {
		// `@:from static function of(p:Dynamic)` IS a conversion: every assignment in the program is
		// one of its call sites, so narrowing its parameter narrows what the conversion accepts.
		assertBlocked(
			'abstract W(Int) {\n\t@:from static function of(p:Dynamic):W {\n\t\ttrace((p : Foo));\n\t\treturn cast 0;\n\t}\n}$FOO',
			'abstract W(Int) {\n\tstatic function of(p:Dynamic):W {\n\t\ttrace((p : Foo));\n\t\treturn cast 0;\n\t}\n}$FOO'
		);
	}

	public function testAMemberASupertypeDeclaresSkips(): Void {
		// The override family proves nothing about a slot the owner FILLS: an interface or a base
		// class declaring the name pins the signature from above, where no subtype scan looks.
		assertBlocked(
			'interface I {\n\tfunction f(p:Dynamic):Void;\n}\n\nclass C implements I {\n\tpublic function f(p:Dynamic):Void {\n'
			+ '\t\ttrace((p : Foo));\n\t}\n}$FOO',
			'interface I {\n\tfunction g(p:Dynamic):Void;\n}\n\nclass C implements I {\n\tpublic function f(p:Dynamic):Void {\n'
			+ '\t\ttrace((p : Foo));\n\t}\n}$FOO'
		);
	}

	public function testAnUnresolvableSupertypeSkips(): Void {
		assertBlocked(
			'class C extends Elsewhere {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO',
			'class C extends Base {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}\n\nclass Base {}$FOO'
		);
	}

	public function testAMethodTypeParameterSkips(): Void {
		// A method's type-parameter NAMES are not projected, so `T` the parameter and `T` the type
		// are indistinguishable — the whole generic method is refused.
		assertBlocked(
			'class C {\n\tstatic function f<T>(p:Dynamic):Void {\n\t\ttrace((p : T));\n\t}\n}\n\nclass T {}\n',
			'class C {\n\tstatic function f(p:Dynamic):Void {\n\t\ttrace((p : T));\n\t}\n}\n\nclass T {}\n'
		);
	}

	public function testAnEnclosingTypeParameterSkips(): Void {
		assertBlocked(
			'class C<T> {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : T));\n\t}\n}\n\nclass T {}\n',
			'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : T));\n\t}\n}\n\nclass T {}\n'
		);
	}

	public function testAnUnresolvableSupertypeTwoLinksUpSkips(): Void {
		// The member walk is transitive, so the resolvability proof has to be: a reachable base
		// whose OWN interface left the index leaves the closure unproven just the same.
		final base: String = 'class C extends Base {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO';
		Assert.equals(0, crossFileEdits(base, 'class Base implements IGone {}\n').length, 'the closure is not reachable');
		Assert.isTrue(crossFileEdits(base, 'class Base {}\n').length > 0, 'the same owner fires over a reachable closure');
	}

	public function testAQualifiedAscriptionNeedsThatPathIndexed(): Void {
		// A written `pk.Foo` must resolve as a PATH: a plain `Foo` in scope names a different type.
		final base: String = 'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : pk.Foo));\n\t}\n}\n';
		Assert.equals(0, crossFileEdits(base, 'class Foo {}\n', 'Foo.hx').length, 'a plain Foo does not vouch for pk.Foo');
		Assert.isTrue(crossFileEdits(base, 'package pk;\n\nclass Foo {}\n', 'pk/Foo.hx').length > 0, 'the written path itself resolves');
	}

	public function testACommentInsideTheWrittenTypeSkips(): Void {
		assertBlocked(
			'class C {\n\tfunction f(p:Null</* keep */ Dynamic>):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO',
			'class C {\n\tfunction f(p:Null<Dynamic>):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO'
		);
	}

	public function testAnOperatorOverloadOwnerSkips(): Void {
		// `@:op` is dispatched by the compiler on the operand's static type, exactly as `@:from` is
		// on an assignment's: either way the parameter's type IS the dispatch key.
		assertBlocked(
			'abstract W(Int) {\n\t@:op(A + B) static function add(p:Dynamic, b:Int):W {\n\t\ttrace((p : Foo));\n'
			+ '\t\treturn cast 0;\n\t}\n}$FOO',
			'abstract W(Int) {\n\tstatic function add(p:Dynamic, b:Int):W {\n\t\ttrace((p : Foo));\n\t\treturn cast 0;\n\t}\n}$FOO'
		);
	}

	public function testAMemberASupertypeDeclaresThroughATypedefSkips(): Void {
		// A `typedef` written in `implements` records NO supertype edge of its own, so the closure
		// walk has to follow its alias target or the interface above it is invisible.
		assertBlocked(
			'interface I {\n\tfunction f(p:Dynamic):Void;\n}\n\ntypedef Alias = I;\n\nclass C implements Alias {\n'
			+ '\tpublic function f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO',
			'interface I {\n\tfunction g(p:Dynamic):Void;\n}\n\ntypedef Alias = I;\n\nclass C implements Alias {\n'
			+ '\tpublic function f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO'
		);
	}

	public function testAnArrayAccessOwnerSkips(): Void {
		assertBlocked(
			'abstract W(Int) {\n\t@:arrayAccess static function at(p:Dynamic, i:Int):W {\n\t\ttrace((p : Foo));\n'
			+ '\t\treturn cast 0;\n\t}\n}$FOO',
			'abstract W(Int) {\n\tstatic function at(p:Dynamic, i:Int):W {\n\t\ttrace((p : Foo));\n\t\treturn cast 0;\n\t}\n}$FOO'
		);
	}

	public function testAResolveOwnerSkips(): Void {
		assertBlocked(
			'abstract W(Int) {\n\t@:resolve static function of(p:Dynamic):W {\n\t\ttrace((p : Foo));\n\t\treturn cast 0;\n\t}\n}$FOO',
			'abstract W(Int) {\n\tstatic function of(p:Dynamic):W {\n\t\ttrace((p : Foo));\n\t\treturn cast 0;\n\t}\n}$FOO'
		);
	}

	public function testDynamicFunctionSkips(): Void {
		assertBlocked('class C {\n\tdynamic function f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO', CONTROL);
	}

	public function testMacroFunctionSkips(): Void {
		assertBlocked('class C {\n\tmacro function f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t}\n}$FOO', CONTROL);
	}

	public function testNamedLocalFunctionParameterSkips(): Void {
		// The only shape the owner-KIND filter alone decides: a lambda is already stopped by its
		// declaring node carrying no name.
		assertBlocked(
			'class C {\n\tfunction f():Void {\n\t\tfunction inner(p:Dynamic):Void {\n\t\t\ttrace((p : Foo));\n\t\t}\n'
			+ '\t\tinner(null);\n\t}\n}$FOO',
			CONTROL
		);
	}

	public function testRestParameterSkips(): Void {
		assertBlocked(
			'class C {\n\tfunction f(...r:Dynamic):Void {\n\t\ttrace((r : Foo));\n\t}\n}$FOO',
			'class C {\n\tfunction f(r:Dynamic):Void {\n\t\ttrace((r : Foo));\n\t}\n}$FOO'
		);
	}

	public function testAscriptionToATopTypeSkips(): Void {
		// The sibling file declares `Any` the way the std does, so the index RESOLVES it and the
		// top-type gate is the only thing left to refuse — a fixture that leaves `Any` unresolvable
		// would be turned away by the conversion-free gate instead and prove nothing about this one.
		final any: String = 'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Any));\n\t}\n}\n';
		final std: String = 'abstract Any(Dynamic) {}\n';
		Assert.equals(0, crossFileEdits(any, std).length, 'the sanctioned top type is no narrowing');
		Assert.isTrue(crossFileEdits(CONTROL, std).length > 0, 'the control fixture fires against the same index');
		assertBlocked('class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Dynamic));\n\t}\n}$FOO', CONTROL);
	}

	// ---- Grouping and the decline ledger ----

	public function testTheTypeEditAndEveryUnwrapShareOneGroup(): Void {
		final src: String = 'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace((p : Foo));\n\t\ttrace((p : Foo));\n\t}\n}$FOO';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: AvoidDynamic = new AvoidDynamic();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final grouped: Array<GroupedEdit> = check.fixGrouped(src, vs, plugin);
		Assert.equals(3, grouped.length, 'the signature type plus both unwraps');
		final first: Null<Int> = grouped[0].group;
		Assert.notNull(first, 'a parameter rewrite is one atomic unit');
		Assert.same([first, first, first], [for (e in grouped) e.group]);
	}

	public function testDeclineReasonNamesTheParameterRefusal(): Void {
		final src: String = 'class C {\n\tfunction f(p:Dynamic):Void {\n\t\ttrace(p);\n\t}\n}$FOO';
		final run: FixRun = fixed(src);
		Assert.equals(0, run.edits.length);
		Assert.same([
			'a parameter, but its reads are not all ascriptions to one conversion-free type, or its method can be overridden'
		], [for (v in run.violations) v.declineReason ?? '-']);
	}

	public function testARestParameterIsNotTheArmsSubjectAtAll(): Void {
		final src: String = 'class C {\n\tfunction f(...r:Dynamic):Void {\n\t\ttrace((r : Foo));\n\t}\n}$FOO';
		final run: FixRun = fixed(src);
		Assert.equals(0, run.edits.length);
		Assert.same([
			'the fix narrows a LOCAL variable from its uses, or a type-MEMBER function PARAMETER from its ascriptions; this '
			+ '`Dynamic` is a field, a return type, a type argument, a rest parameter, or a lambda / local-function parameter'
		], [for (v in run.violations) v.declineReason ?? '-']);
	}

	// ---- helpers ----

	/** A gate fixture is pinned by the PAIR: `control` must fire, `blocked` must not. */
	private function assertBlocked(blocked: String, control: String): Void {
		Assert.isTrue(edits(control).length > 0, 'the control fixture fires');
		Assert.equals(0, edits(blocked).length, 'the gate refuses the fixture it guards');
	}

	private function edits(src: String): Array<FixEdit> {
		return fixed(src).edits;
	}

	private function fixedSource(src: String): String {
		return CheckFixture.applyEdits(src, edits(src));
	}

	/** Run the check over `src` and fix its findings, handing back BOTH halves (the decline reasons ride the violations). */
	private function fixed(src: String): FixRun {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: AvoidDynamic = new AvoidDynamic();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		return { violations: vs, edits: check.fix(src, vs, plugin) };
	}

	/** The edits for `base` alone, resolved against an index that ALSO holds `sub` — the override-family gate's scope. */
	private function crossFileEdits(base: String, sub: String, subFile: String = 'D.hx'): Array<FixEdit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: AvoidDynamic = new AvoidDynamic();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: base }, { file: subFile, source: sub }];
		final vs: Array<Violation> = check.run(files, plugin).filter(v -> v.file == 'C.hx');
		return check.fix(base, vs, plugin, SymbolIndex.build(files, plugin));
	}

}
