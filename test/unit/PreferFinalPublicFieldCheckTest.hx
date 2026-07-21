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

	/** The `var → final` swap is an in-place keyword rewrite, so it preserves canonical modifier order: `public static var` → `public static final`. */
	public function testFixPreservesModifierOrder(): Void {
		final fixed: String = fixedSource('class C { public static var x:Int = 0; }');
		Assert.isTrue(fixed.indexOf('public static final x:Int = 0') >= 0);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-final-public-field'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-final-public-field'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public var x = ').length);
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

	/**
	 * (a) An unresolvable-chain write with a String-literal RHS cannot target a field
	 * of a plain project class — the candidate stays flagged.
	 */
	public function testUnresolvedChainStringRhsClassTypedFlagged(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'Marker.hx', source: 'class Marker {}' },
			{ file: 'A.hx', source: 'class A { public var title:Marker = new Marker(); }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.title = "x"; } }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/** (b) The same unresolvable chain write poisons a String-typed candidate — the RHS could target it. */
	public function testUnresolvedChainStringRhsStringTypedNotFlagged(): Void {
		Assert.equals(0, multi([
			{ file: 'A.hx', source: 'class A { public var title:String = "a"; }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.title = "x"; } }' }
		]).length);
	}

	/**
	 * (c) A chain write `h.inner.title` whose every step resolves in the file set is
	 * attributed to the final receiver type: `Inner.title` is written (skipped) and an
	 * unrelated same-named field is no longer poisoned.
	 */
	public function testResolvedChainAttributesToStepType(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'Holder.hx', source: 'class Holder { public var inner:Inner; }' },
			{ file: 'Inner.hx', source: 'class Inner { public var title:String = "t"; }' },
			{ file: 'W.hx', source: 'class W { public function poke(h:Holder):Void { h.inner.title = "x"; } }' },
			{ file: 'A.hx', source: 'class A { public var title:String = "a"; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/** (d) An index-access write `tabs['k'].x` on a `Map<String, Tab>` container is attributed to the element type `Tab`. */
	public function testIndexAccessAttributesToElementType(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'Tab.hx', source: 'class Tab { public var x:Int = 0; }' },
			{ file: 'U.hx', source: 'class U { public function f(tabs:Map<String, Tab>):Void { tabs["k"].x = 5; } }' },
			{ file: 'A.hx', source: 'class A { public var x:Int = 0; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/** (e) A compound `+=` through an unresolvable receiver poisons regardless of its literal RHS. */
	public function testCompoundAssignUnresolvedPoisonsRegardlessOfRhs(): Void {
		Assert.equals(0, multi([
			{ file: 'Marker.hx', source: 'class Marker {}' },
			{ file: 'A.hx', source: 'class A { public var count:Marker = new Marker(); }' },
			{ file: 'P.hx', source: 'class P { public function f(h:Holder):Void { h.inner.count += 1; } }' }
		]).length);
	}

	/** (f) A `Dynamic`-typed receiver never resolves — its write poisons the field name. */
	public function testDynamicReceiverPoisons(): Void {
		Assert.equals(0, multi([
			{ file: 'Marker.hx', source: 'class Marker {}' },
			{ file: 'A.hx', source: 'class A { public var x:Marker = new Marker(); }' },
			{ file: 'D.hx', source: 'class D { public function f(d:Dynamic):Void { d.x = g(); } function g():Int { return 1; } }' }
		]).length);
	}

	/** (g) An abstract-typed candidate stays poisoned by a String-literal unresolved write — `@:from` can carry the literal into it. */
	public function testAbstractTypedCandidateStringRhsPoisoned(): Void {
		Assert.equals(0, multi([
			{ file: 'Abs.hx', source: 'abstract Abs(String) from String {}' },
			{ file: 'A.hx', source: 'class A { public var title:Abs = "a"; }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.title = "x"; } }' }
		]).length);
	}

	/** (h) A bare-ident container declared in the SUPERCLASS (the `tabButtons` shape) resolves through the supertype chain. */
	public function testInheritedContainerIndexAccessAttributes(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'Base.hx', source: 'class Base { public var tabs:Map<String, Tab>; }' },
			{ file: 'Sub.hx', source: 'class Sub extends Base { public function f():Void { tabs["k"].x = 5; } }' },
			{ file: 'Tab.hx', source: 'class Tab { public var x:Int = 0; }' },
			{ file: 'A.hx', source: 'class A { public var x:Int = 0; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/** A capitalized bare root naming an indexed type is a static access — `Reg.app.title` attributes to `App`. */
	public function testStaticChainRootAttributes(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'Reg.hx', source: 'class Reg { public static var app:App; }' },
			{ file: 'App.hx', source: 'class App { public var title:String = "t"; }' },
			{ file: 'Z.hx', source: 'class Z { public function f():Void { Reg.app.title = "x"; } }' },
			{ file: 'A.hx', source: 'class A { public var title:String = "a"; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/** A `Null<Inner>`-wrapped chain step unwraps to its nominal before the member walk. */
	public function testNullWrappedStepResolves(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'Holder2.hx', source: 'class Holder2 { public var inner:Null<Inner2>; }' },
			{ file: 'Inner2.hx', source: 'class Inner2 { public var title:String = "t"; }' },
			{ file: 'W2.hx', source: 'class W2 { public function poke(h:Holder2):Void { h.inner.title = "x"; } }' },
			{ file: 'A.hx', source: 'class A { public var title:String = "a"; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/**
	 * A case-pattern variable is invisible to the scope resolver and SHADOWS a
	 * same-named inherited field — the supertype-member fallback must not fire, so
	 * the write stays unresolved and keeps poisoning.
	 */
	public function testPatternVariableDoesNotResolveViaSupertypeMember(): Void {
		Assert.equals(0, multi([
			{ file: 'Base3.hx', source: 'class Base3 { public var item:Tab3; }' },
			{
				file: 'Sub3.hx',
				source: 'class Sub3 extends Base3 { public function f(o:Dynamic):Void { switch o { case Some(item): item.x = g(); case _: } } function g():Int { return 0; } }'
			},
			{ file: 'Tab3.hx', source: 'class Tab3 { public var x:Int = 0; }' },
			{ file: 'A3.hx', source: 'class A3 { public var x:Int = 0; }' }
		]).length);
	}

	/**
	 * A bare write to an INHERITED field (`title = …` in a subclass of its declarer)
	 * attributes to the declaring supertype instead of poisoning the name — even
	 * with an untypable call RHS.
	 */
	public function testBareInheritedWriteAttributesToDeclaringSupertype(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'BaseP.hx', source: 'class BaseP { public var title:String; }' },
			{
				file: 'SubP.hx',
				source: 'class SubP extends BaseP { public function f():Void { title = g(); } function g():String { return "t"; } }'
			},
			{ file: 'A.hx', source: 'class A { public var title:String = "a"; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/**
	 * T1: a receiver typed by a method TYPE PARAMETER (`s:T`) must not record under
	 * the nonexistent owner 'T' — the write stays unresolved and poisons `w`.
	 */
	public function testTypeParamReceiverPoisons(): Void {
		Assert.equals(0, multi([
			{
				file: 'T1.hx',
				source: 'class Widget { public var w:Int = 0; } class Helper { public static function reset<T:Widget>(s:T):Void { s.w = 5; } }'
			}
		]).length);
	}

	/**
	 * T2: a case-pattern variable SHADOWS a same-named typed parameter — every
	 * ident-receiver resolution of that name in the file must bail, bound or not.
	 */
	public function testPatternVarShadowingBoundParamPoisons(): Void {
		Assert.equals(0, multi([
			{
				file: 'T2.hx',
				source: 'class Boxed { public var count:Int = 0; } class Other { public var count2:Int = 0; } enum Wrap { Leaf(b:Boxed); } class User { public function go(v:Wrap, outer:Other):Void { outer.count2 = 1; switch v { case Leaf(outer): outer.count = 5; case _: } } }'
			}
		]).length);
	}

	/**
	 * T3: a write through a nominal TYPEDEF alias (`h:Handle`, `typedef Handle =
	 * Widget2`) must not record under 'Handle' — the aliased type's field would be
	 * freed. The owner gate rejects typedef owners into the unresolved bail.
	 */
	public function testTypedefAliasReceiverPoisons(): Void {
		Assert.equals(0, multi([
			{
				file: 'T3.hx',
				source: 'typedef Handle = Widget2; class Widget2 { public var visible:Bool = true; } class C2 { public function f(h:Handle):Void { h.visible = false; } }'
			}
		]).length);
	}

	/**
	 * T4: a `case var item:` CAPTURE binder shadows an inherited field — the
	 * unbound-ident arm must not resolve `item` as `Base4.item`; only the truly
	 * unwritten `sx2` is flagged.
	 */
	public function testCaptureVarShadowingInheritedFieldPoisons(): Void {
		final vs: Array<Violation> = multi([
			{
				file: 'T4.hx',
				source: 'class Other4 { public var sx2:Int = 1; } class Sprite4 { public var sx:Int = 0; } class Base4 { public var item:Other4 = new Other4(); } class D4 extends Base4 { public function pick(v:Sprite4):Void { switch v { case var item: item.sx = 5; } } }'
			}
		]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('sx2') >= 0);
	}

	/**
	 * T5: a chain step through a generic member (`item:Null<T>`) resolves to the
	 * TYPE PARAMETER name — the owner gate must refuse 'T' and keep `px` poisoned.
	 */
	public function testTypeParamMemberChainPoisons(): Void {
		Assert.equals(0, multi([
			{
				file: 'T5.hx',
				source: 'class Cont<T> { public var item:Null<T>; } class P5 { public var px:Int = 0; } class U5 { public function go(c:Cont<P5>):Void { c.item.px = 9; } }'
			}
		]).length);
	}

	/** T6: a compound write through a `Dynamic` receiver poisons regardless of candidate type. */
	public function testDynamicCompoundStaysPoisoned(): Void {
		Assert.equals(0, multi([
			{ file: 'T6.hx', source: 'class C6 { public var n:Int = 0; } class U6 { public function f(d:Dynamic):Void { d.n += 1; } }' }
		]).length);
	}

	/** T7: the INTENDED freeing — a String-literal write through `Dynamic` cannot target a plain-class-typed field. */
	public function testDynamicStringRhsPlainClassFreed(): Void {
		Assert.equals(1, multi([
			{
				file: 'T7.hx',
				source: 'class Plain7 {} class C7 { public var p:Plain7 = new Plain7(); } class U7 { public function f(d:Dynamic):Void { d.p = "s"; } }'
			}
		]).length);
	}

	/** A candidate typed by a `final class` is still a plain class — the SymbolIndex normalises the kind to ClassDecl. */
	public function testFinalClassCandidateFreed(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'FMarker.hx', source: 'final class FMarker {}' },
			{ file: 'A.hx', source: 'class A { public var m:FMarker = new FMarker(); }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.m = "x"; } }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/** An index-access write on a `haxe.ds.Vector<TabV>` container attributes to the element type. */
	public function testVectorIndexAccessAttributes(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'TabV.hx', source: 'class TabV { public var x:Int = 0; }' },
			{ file: 'UV.hx', source: 'class UV { public function f(v:haxe.ds.Vector<TabV>):Void { v[0].x = 5; } }' },
			{ file: 'A.hx', source: 'class A { public var x:Int = 0; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/** A candidate whose declared type resolves to NO indexed decl (external/unknown) stays poisoned. */
	public function testUnknownCandidateTypeStaysPoisoned(): Void {
		Assert.equals(0, multi([
			{ file: 'A.hx', source: 'class A { public var title:ExtT = null; }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.title = "x"; } }' }
		]).length);
	}

	/** A candidate whose declared type's simple name is declared TWICE stays poisoned (ambiguous). */
	public function testAmbiguousCandidateTypeStaysPoisoned(): Void {
		Assert.equals(0, multi([
			{ file: 'a/DupM.hx', source: 'class DupM {}' },
			{ file: 'b/DupM.hx', source: 'class DupM {}' },
			{ file: 'A.hx', source: 'class A { public var title:DupM = null; }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.title = "x"; } }' }
		]).length);
	}

	/** A candidate with NO type annotation has no provable type — stays poisoned. */
	public function testUntypedCandidateFieldStaysPoisoned(): Void {
		Assert.equals(0, multi([
			{ file: 'A.hx', source: 'class A { public var title = makeM(); static function makeM():Dynamic { return null; } }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.title = "x"; } }' }
		]).length);
	}

	/**
	 * A write inside an `untyped` expression escapes the type system — its literal
	 * RHS must NOT be trusted, so the write poisons like an opaque one.
	 */
	public function testUntypedWriteStaysPoisoned(): Void {
		Assert.equals(0, multi([
			{ file: 'PlainQ.hx', source: 'class PlainQ {}' },
			{ file: 'A.hx', source: 'class A { public var q:PlainQ = new PlainQ(); }' },
			{ file: 'U.hx', source: 'class U { public function f():Void { untyped z.q = "s"; } }' }
		]).length);
	}

	/**
	 * The candidate's OWN file imports a same-simple-named module from elsewhere —
	 * the annotation refers to the IMPORT, not the indexed project class, so the
	 * candidate stays poisoned; without the import it is freed.
	 */
	public function testImportShadowedCandidateTypePoisons(): Void {
		final shadowed: Array<{ file: String, source: String }> = [
			{ file: 'ShadowM.hx', source: 'class ShadowM {}' },
			{ file: 'A.hx', source: 'import ext.pack.ShadowM; class A { public var m:ShadowM = null; }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.m = "x"; } }' }
		];
		Assert.equals(0, multi(shadowed).length);
		final unshadowed: Array<{ file: String, source: String }> = [
			{ file: 'ShadowM.hx', source: 'class ShadowM {}' },
			{ file: 'A.hx', source: 'class A { public var m:ShadowM = null; }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.m = "x"; } }' }
		];
		Assert.equals(1, multi(unshadowed).length);
	}

	/**
	 * The candidate's declared type names its OWNER's type parameter (`Cell<Data>`,
	 * `v:Null<Data>`) — even when a same-named project class exists, the field's
	 * runtime type is the instantiation argument, so the candidate stays poisoned.
	 */
	public function testOwnerTypeParamCandidatePoisons(): Void {
		Assert.equals(0, multi([
			{ file: 'Cell.hx', source: 'class Cell<Data> { public var v:Null<Data> = null; }' },
			{ file: 'Data.hx', source: 'class Data {}' },
			{ file: 'W6.hx', source: 'class W6 { public function f(h:HH):Void { h.q.v = 5; } }' }
		]).length);
	}

	/**
	 * An `abstract class` is a real nominal class the index must know: a chain
	 * write resolving to one is RECORDED (the tabButtons regression — an unindexed
	 * abstract-class owner must not fall to the unresolved bail), so the unrelated
	 * same-named candidate stays flagged.
	 */
	public function testAbstractClassChainOwnerRecorded(): Void {
		final vs: Array<Violation> = multi([
			{
				file: 'Btn.hx',
				source: 'abstract class Btn { public var title(get, set):String; function get_title():String { return "x"; } function set_title(v:String):String { return v; } }'
			},
			{ file: 'BaseT.hx', source: 'class BaseT { public var tabs:Map<String, Btn>; }' },
			{
				file: 'SubT.hx',
				source: 'class SubT extends BaseT { public function f():Void { tabs["k"].title = g(); } function g():String { return "t"; } }'
			},
			{ file: 'A.hx', source: 'class A { public var title:String = "a"; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
	}

	/** An `abstract class` has plain-class assignment semantics — a builtin-RHS unresolved write cannot target a field it types. */
	public function testAbstractClassCandidateFreed(): Void {
		final vs: Array<Violation> = multi([
			{ file: 'AM.hx', source: 'abstract class AM {}' },
			{ file: 'A.hx', source: 'class A { public var m:AM = null; }' },
			{ file: 'B.hx', source: 'class B { public function poke(h:Holder):Void { h.inner.m = "x"; } }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('A.hx', vs[0].file);
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


	private function multi(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new PreferFinalPublicField().run(files, new HaxeQueryPlugin());
	}

}
