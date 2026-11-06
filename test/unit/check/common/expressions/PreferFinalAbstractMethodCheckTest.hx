package unit.check.common.expressions;

import anyparse.check.common.expressions.PreferFinal;
import anyparse.check.common.members.PreferFinalField;
import anyparse.check.common.members.PreferFinalPublicField;
import anyparse.query.CachingGrammarPlugin;

/**
 * A `var` of an `abstract` type mutated through a method that reassigns `this`
 * (`abstract Step(Int) { function next():Void this = this + 1; }` used only via
 * `_s.next()`) must NOT be rewritten to `final` — the finalized code fails to
 * compile ("Cannot modify abstract value of final field"). No visible assignment
 * to the binding exists, so the `prefer-final` / `prefer-final-field` writer scan
 * missed the mutation; a method call on an abstract-typed (or unprovable-type)
 * binding is the missing write signal.
 *
 * Control tests pin that the rule stays useful: a plain never-reassigned binding,
 * a field of a resolved CLASS type, and a field of a stdlib value type
 * (`String` / `Array` — their methods do not mutate `this`) are still flagged.
 */
class PreferFinalAbstractMethodCheckTest extends Test {

	private static inline final ABSTRACT: String =
		'abstract Step(Int) { public function nw(v:Int) this = v; public function next():Void this = this + 1; } ';

	/** A ctor-only-writing abstract (openfl `ByteArray` pattern) — `read` returns `this`, only `new` writes it. Final-safe. */
	private static inline final CTOR_ONLY: String =
		'abstract Buf(Int) { public inline function new(v:Int) this = v; public function read():Int return this; } ';

	/** An abstract that REBINDS `this` in a non-ctor member (`bump`) — a `@:forward` to it inherits the rebind. */
	private static inline final REBIND_INNER: String =
		'abstract Inner(Int) { public inline function new(v:Int) this = v; public inline function bump():Void this = this + 1; } ';

	/** A `@:genericBuild` class: each instantiation is built by the macro, here standing for a bit set that `add` rebinds. */
	private static inline final GENERIC: String = '@:genericBuild(M.build()) class Gen<E> {} ';

	// --- Field case (prefer-final-field) ---

	/** Abstract-typed field used only via a mutating method call — must NOT be flagged. */
	public function testAbstractFieldMethodCallNotFlagged(): Void {
		final vs: Array<Violation> =
			fieldViolations('${ABSTRACT}class C { private var _s:Step = new Step(0); function r():Void _s.next(); }');
		Assert.equals(0, vs.length);
	}

	/** Control: a plain never-reassigned field still earns the final suggestion. */
	@:pin('control')
	@:killer('M-PFF-CALLSCAN-ALWAYS')
	public function testPlainFieldStillFlagged(): Void {
		Assert.equals(1, fieldViolations('class C { private var _x:Int = 0; }').length);
	}

	/** Control: a field of a resolved CLASS type keeps the suggestion — a class method does not reassign the field. */
	@:pin('control')
	@:killer('M-PFF-REBIND-UNRESOLVED')
	public function testClassTypedFieldMethodCallStillFlagged(): Void {
		final vs: Array<Violation> = fieldViolations(
			'class D { public function nw() {} public function go():Void {} } class C {'
			+ ' private var _d:D = new D(); function r():Void _d.go(); }'
		);
		Assert.equals(1, vs.length);
	}

	/** Control: a stdlib `Array` field keeps the suggestion — `push` mutates contents, not the `final` binding. */
	@:pin('control')
	@:killer('M-PFF-STDLIB-SAFE-NONE')
	public function testStdlibArrayFieldMethodCallStillFlagged(): Void {
		Assert.equals(1, fieldViolations('class C { private var _a:Array<Int> = []; function r():Void _a.push(1); }').length);
	}

	/** Control: a stdlib `String` field keeps the suggestion — String is immutable. */
	@:pin('control')
	@:killer('M-PFF-STDLIB-SAFE-NONE')
	public function testStdlibStringFieldMethodCallStillFlagged(): Void {
		Assert.equals(1, fieldViolations('class C { private var _t:String = "x"; function r():String return _t.toUpperCase(); }').length);
	}

	/** A field of an UNRESOLVED non-stdlib type with a method call is suppressed conservatively (cannot prove non-abstract). */
	public function testUnknownTypeFieldMethodCallNotFlagged(): Void {
		Assert.equals(0, fieldViolations('class C { private var _e:Ext = make(); function r():Void _e.mutate(); }').length);
	}

	/** A method REFERENCE (no call) on an abstract-typed field does not mutate — still flagged. */
	@:pin('control')
	@:killer('M-PFF-CALLSCAN-ALWAYS')
	public function testAbstractFieldNoCallStillFlagged(): Void {
		Assert.equals(
			1, fieldViolations('${ABSTRACT}class C { private var _s:Step = new Step(0); function r():Step->Void return null; }').length
		);
	}

	// --- Local case (prefer-final) ---

	/** Abstract-typed local used only via a mutating method call — must NOT be flagged. */
	public function testAbstractLocalMethodCallNotFlagged(): Void {
		final vs: Array<Violation> =
			localViolations('${ABSTRACT}class C { function r():Void { var s:Step = new Step(0); s.next(); trace(s); } }');
		Assert.equals(0, vs.length);
	}

	/** Control: a plain never-reassigned local still earns the final suggestion. */
	@:pin('control')
	@:killer('M-PFF-CALLSCAN-ALWAYS')
	public function testPlainLocalStillFlagged(): Void {
		Assert.equals(1, localViolations('class C { function r():Void { var n:Int = 5; trace(n); } }').length);
	}

	/** Ctor-only abstract field used via a non-mutating method call — the `this =` lives only in `new`, so it IS flagged. */
	@:pin('control')
	@:killer('M-PFF-REBIND-UNRESOLVED')
	public function testCtorOnlyAbstractFieldFlagged(): Void {
		Assert.equals(
			1, fieldViolations('${CTOR_ONLY}class C { private var _b:Buf = new Buf(0); function r():Int return _b.read(); }').length
		);
	}

	/** Ctor-only abstract local used via a non-mutating method call — flagged, mirroring the field case. */
	@:pin('control')
	@:killer('M-PFF-REBIND-UNRESOLVED')
	public function testCtorOnlyAbstractLocalFlagged(): Void {
		Assert.equals(
			1, localViolations('${CTOR_ONLY}class C { function r():Void { var b:Buf = new Buf(0); b.read(); trace(b); } }').length
		);
	}

	/** A non-ctor `this =` reachable only through `#if` is scanned conservatively (all branches) — the abstract rebinds, so NOT flagged. */
	public function testConditionalThisWriteAbstractNotFlagged(): Void {
		final vs: Array<Violation> = fieldViolations(
			'abstract Buf(Int) { public inline function new(v:Int) this = v; public inline function f():Void { #if x this = 1; #end } } '
			+ 'class C { private var _b:Buf = new Buf(0); function r():Void _b.f(); }'
		);
		Assert.equals(0, vs.length);
	}

	/** A `@:build` on a ctor-only abstract bails conservative — macro-generated members are invisible, so NOT flagged. */
	public function testBuildMetaAbstractNotFlagged(): Void {
		Assert.equals(
			0,
			fieldViolations(
				'@:build(M.build()) ${CTOR_ONLY}class C { private var _b:Buf = new Buf(0); function r():Int return _b.read(); }'
			).length
		);
	}

	/**
	 * `@:forward` to a CLASS underlying — a forwarded call mutates the
	 * object, never the binding — so the ctor-only abstract field IS flagged.
	 */
	@:pin('control')
	@:killer('M-PFF-REBIND-UNRESOLVED')
	public function testForwardToClassAbstractFieldFlagged(): Void {
		final vs: Array<Violation> = fieldViolations(
			'@:forward abstract W(Impl) { public inline function new(v:Impl) this = v; } class Impl { public function new() {} public '
			+ 'function go():Void {} } class C { private var _w:W = make(); function r():Void _w.go(); function make():W return null; }'
		);
		Assert.equals(1, vs.length);
	}

	/**
	 * `@:forward` to an abstract underlying that itself rebinds `this` in
	 * a non-ctor method — the forward inherits the rebind, so NOT flagged.
	 */
	public function testForwardToRebindingAbstractNotFlagged(): Void {
		final vs: Array<Violation> = fieldViolations(
			'$REBIND_INNER@:forward abstract W2(Inner) { public inline function new(v:Inner) this = v; } class C {'
			+ ' private var _w:W2 = make(); function r():Void _w.bump(); function make():W2 return null; }'
		);
		Assert.equals(0, vs.length);
	}

	/** `@:forward` to an underlying not declared in scope — the forwarded call cannot be proven safe, so NOT flagged (conservative). */
	public function testForwardToUnresolvedUnderlyingNotFlagged(): Void {
		final vs: Array<Violation> = fieldViolations(
			'@:forward abstract W3(Ext) {} class C {'
			+ ' private var _w:W3 = make(); function r():Void _w.go(); function make():W3 return null; }'
		);
		Assert.equals(0, vs.length);
	}

	/**
	 * The original resolution-scope bug: a report-only index cannot see a library type, so a method call
	 * on a library-typed local is treated as an unprovable mutation and the local is NOT flagged. With a
	 * `CachingGrammarPlugin` resolution scope that unions the library source, `Window` resolves to a class
	 * and the local IS flagged; the bare-plugin control (no scope) still misses it.
	 */
	@:pin('control')
	@:killer('M-SCOPE-LIBRARY-DROPPED')
	public function testResolutionScopeResolvesLibraryType(): Void {
		final report: Array<{ file: String, source: String }> = [
			{
				file: 'C.hx',
				source: 'class C { function r():Void { var w:Window = get(); w.move(1, 2); trace(w); } function get():Window return null; }'
			}
		];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				projectRoots: [],
				library: new LibrarySources([
					{ file: 'Window.hx', source: 'class Window { public function move(x:Int, y:Int):Void {} }' }
				])
			}
		});
		Assert.equals(1, CheckFixture.violationsIn(new PreferFinal(), report, scoped).length);
		Assert.equals(0, CheckFixture.violationsIn(new PreferFinal(), report).length);
	}

	/**
	 * A module-level modifier between `@:forward` and the decl (`@:forward private
	 * abstract`) must not drop the meta — forwards to a rebinding underlying, so NOT flagged.
	 */
	public function testForwardMetaBeforeModifierPreserved(): Void {
		final vs: Array<Violation> = fieldViolations(
			'$REBIND_INNER@:forward private abstract Wp(Inner) { public inline function new(v:Inner) this = v; } class C {'
			+ ' private var _w:Wp = make(); function r():Void _w.bump(); function make():Wp return null; }'
		);
		Assert.equals(0, vs.length);
	}

	/**
	 * `@:build` before a modifier (`@:build(...) private abstract`) must not
	 * drop the meta — the ctor-only abstract bails conservative, so NOT flagged.
	 */
	public function testBuildMetaBeforeModifierPreserved(): Void {
		Assert.equals(
			0,
			fieldViolations(
				'@:build(M.build()) private abstract Bp(Int) { public inline function new(v:Int) this = v; public function read():Int '
				+ 'return this; } class C { private var _b:Bp = new Bp(0); function r():Int return _b.read(); }'
			).length
		);
	}

	/**
	 * A `#if`-guarded meta+decl (`#if x @:forward abstract Wg(Inner) ... #end`, openfl `Vector`
	 * pattern) lifts the meta out of the region — forwards to a rebinding underlying, so NOT flagged.
	 */
	public function testGuardedForwardMetaLifted(): Void {
		final vs: Array<Violation> = fieldViolations(
			'$REBIND_INNER#if x @:forward abstract Wg(Inner) { public inline function new(v:Inner) this = v; } #end class C {'
			+ ' private var _w:Wg = make(); function r():Void _w.bump(); function make():Wg return null; }'
		);
		Assert.equals(0, vs.length);
	}

	/**
	 * Control: a `private` ctor-only abstract with NO meta is still flagged —
	 * preserving the meta run across a modifier must not over-suppress a meta-less decl.
	 */
	@:pin('control')
	@:killer('M-PFF-REBIND-UNRESOLVED')
	public function testPrivateCtorOnlyNoMetaStillFlagged(): Void {
		Assert.equals(
			1,
			fieldViolations(
				'private abstract Bp2(Int) { public inline function new(v:Int) this = v; public function read():Int return this; } '
				+ 'class C { private var _b:Bp2 = new Bp2(0); function r():Int return _b.read(); }'
			).length
		);
	}

	/**
	 * lime's `@:forward abstract Bytes(HaxeBytes)` shape: the underlying is spelled with the
	 * DECLARING file's import alias (`import haxe.io.Bytes as HaxeBytes`), which a simple-name
	 * index can never resolve. "Underlying not found" is therefore no evidence either way, so the
	 * walk must answer UNKNOWN and let the caller's stdlib whitelist decide -- `Bytes` is
	 * final-safe, so the field IS flagged. Answering "rebinds" made ADDING the library to the
	 * resolution scope silence a field that was flagged without it.
	 *
	 * Discriminated against `testForwardToUnresolvedUnderlyingNotFlagged` above, whose abstract
	 * (`W3`) is NOT on the whitelist: same unresolved underlying, still conservatively kept.
	 */
	@:pin('control')
	@:killer('M-PFF-STDLIB-SAFE-NONE')
	public function testForwardToAliasedUnderlyingWhitelistedNameFlagged(): Void {
		final vs: Array<Violation> = fieldViolations(
			'@:forward abstract Bytes(HaxeBytes) { public inline function new(v:HaxeBytes) this = v; } class C {'
			+ ' private var _b:Bytes = make(); function r():Void _b.blit(); function make():Bytes return null; }'
		);
		Assert.equals(1, vs.length);
	}

	/** The local mirror of the aliased-underlying case -- same unknown-not-unsafe resolution, same verdict. */
	@:pin('control')
	@:killer('M-PFF-STDLIB-SAFE-NONE')
	public function testForwardToAliasedUnderlyingWhitelistedNameLocalFlagged(): Void {
		final vs: Array<Violation> = localViolations(
			'@:forward abstract Bytes(HaxeBytes) { public inline function new(v:HaxeBytes) this = v; } class C { function r():Void {'
			+ ' var b:Bytes = make(); b.blit(); trace(b); } function make():Bytes return null; }'
		);
		Assert.equals(1, vs.length);
	}

	/** A `@:genericBuild` class is instantiated as an abstract of the macro's making: a method call on a local of it may rebind it. */
	public function testGenericBuildLocalMethodCallNotFlagged(): Void {
		Assert.equals(
			0, localViolations('${GENERIC}class C { function r():Void { var s:Gen<Int> = new Gen<Int>(); s.add(1); trace(s); } }').length
		);
	}

	/** The field mirror of the generic-build local case. */
	public function testGenericBuildFieldMethodCallNotFlagged(): Void {
		Assert.equals(
			0, fieldViolations('${GENERIC}class C { private var _s:Gen<Int> = new Gen<Int>(); function r():Void _s.add(1); }').length
		);
	}

	/** A PUBLIC field of a generic-build type is called on from any file, so it stays a `var`. */
	public function testGenericBuildPublicFieldNotFlagged(): Void {
		Assert.equals(0, publicViolations('${GENERIC}class C { public var s:Gen<Int> = new Gen<Int>(); }').length);
	}

	/** A PUBLIC field of a resolved abstract that rebinds `this` stays a `var`: `c.s.next()` from any file would reassign it. */
	public function testRebindingAbstractPublicFieldNotFlagged(): Void {
		Assert.equals(0, publicViolations('${ABSTRACT}class C { public var s:Step = new Step(0); }').length);
	}

	/** Control: only `@:genericBuild` can make a class an abstract; `@:build` alone keeps the suggestion. */
	@:pin('control')
	@:killer('M-PFF-GENERICBUILD-ANY-BUILD')
	public function testBuildOnlyClassLocalStillFlagged(): Void {
		Assert.equals(
			1,
			localViolations(
				'@:build(M.build()) class Plain { public function new() {} public function go():Void {} } class C { function r():Void {'
				+ ' var p:Plain = new Plain(); p.go(); trace(p); } }'
			).length
		);
	}

	/** Control: a PUBLIC field of a ctor-only abstract cannot be rebound by a call, so it is still flagged. */
	@:pin('control')
	@:killer('M-PFF-PUBLIC-FIELD-ANY-TYPE')
	public function testCtorOnlyAbstractPublicFieldStillFlagged(): Void {
		Assert.equals(1, publicViolations('${CTOR_ONLY}class C { public var b:Buf = new Buf(0); }').length);
	}

	/** Control: a generic-build receiver that is never called on rebinds nothing, so it is still flagged. */
	@:pin('control')
	@:killer('M-PFF-CALLSCAN-ALWAYS')
	public function testGenericBuildLocalNeverCalledStillFlagged(): Void {
		Assert.equals(1, localViolations('${GENERIC}class C { function r():Void { var s:Gen<Int> = new Gen<Int>(); trace(s); } }').length);
	}

	/** A comment that merely names `@:genericBuild` makes no type of the file macro-made: the plain class keeps its `final` suggestion. */
	public function testProseNamingGenericBuildMarksNothing(): Void {
		final plain: String =
			'// A comment that names @:genericBuild only in prose.\nclass Plain { public function new() {} public function go():Void {} } ';
		Assert.equals(1, localViolations('${plain}class C { function r():Void { var p:Plain = new Plain(); p.go(); trace(p); } }').length);
		Assert.equals(1, publicViolations('${plain}class C { public var p:Plain = new Plain(); }').length);
	}

	private function fieldViolations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferFinalField(), src);
	}

	private function localViolations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferFinal(), src);
	}

	private function publicViolations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferFinalPublicField(), src);
	}

}
