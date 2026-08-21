package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferReadOnlyField;
import anyparse.check.PreferFinalPublicField;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `prefer-read-only-field` check: a PUBLIC `var` field written only inside its
 * declaring class is flagged `Info` and rewritten to `var X(default, null)`. A field
 * written externally, an unresolved-receiver write, a no-write field (that is
 * `prefer-final-public-field`'s job), a private field, a property, and a field whose
 * type has a subtype are all left alone.
 */
class PreferReadOnlyFieldCheckTest extends Test {

	public function testInternalBareWriteFlagged(): Void {
		final vs: Array<Violation> = violations('class C { public var x:Int = 0; function s():Void { x = 5; } }');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-read-only-field', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testInternalThisWriteFlagged(): Void {
		Assert.equals(1, violations('class C { public var x:Int = 0; function s():Void { this.x = 5; } }').length);
	}

	/** No write anywhere is `prefer-final-public-field`'s territory, not this one. */
	public function testNoWriteNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x:Int = 0; }').length);
	}

	/**
	 * A no-init field whose sole write is one unconditional top-level constructor
	 * statement is `final` territory (`prefer-final-public-field`'s constructor arm) — ceded.
	 */
	public function testCtorSoleAssignmentCeded(): Void {
		Assert.equals(0, violations('class C { public var x:Int; public function new(x:Int) { this.x = x; } }').length);
	}

	/** A ctor write PLUS a method write cannot be final — still this rule's candidate. */
	public function testCtorPlusMethodWriteStillFlagged(): Void {
		Assert.equals(
			1, violations('class C { public var x:Int; public function new(a:Int) { x = a; } function s():Void { x = 1; } }').length
		);
	}

	/** An initializer plus a constructor write cannot be final (double init) — still claimed here. */
	public function testInitPlusCtorWriteStillFlagged(): Void {
		Assert.equals(1, violations('class C { public var x:Int = 0; public function new() { x = 1; } }').length);
	}

	/** A typed external write (`c.x = 9` where `c:C`) forbids making it read-only. */
	public function testExternalWriteNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'W.hx', source: 'class W { public function poke(c:C):Void { c.x = 9; } }' }
		];
		Assert.equals(0, new PreferReadOnlyField().run(files, new HaxeQueryPlugin()).length);
	}

	/** An unresolved receiver write (`makeC().x = 7`) bails the field name — left alone. */
	public function testUnresolvedReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { public var x:Int = 0; function s():Void { x = 1; } function p():Void { makeC().x = 7; } function makeC():C {'
				+ ' return new C(); } }'
			).length
		);
	}

	public function testPrivateNotFlagged(): Void {
		Assert.equals(0, violations('class C { private var _x:Int = 0; function s():Void { _x = 1; } }').length);
	}

	/** A property (`var x(...)`) is already accessor-controlled — skipped. */
	public function testPropertyNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var x(default, null):Int = 0; function s():Void { x = 1; } }').length);
	}

	/**
	 * A subtype WRITING the inherited field is the case the subtype gate exists for: the
	 * write index attributes `this.x = 2` there to the SUBTYPE, so asking it about the
	 * OWNER cannot see it, and `(default, null)` would reject it. Left alone. (A BARE
	 * `x = 2` would NOT exercise this gate — the index resolves an unbound inherited write
	 * back to the declaring type, so the terminal write gates already catch it.)
	 */
	public function testSubtypeWriteNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C { function t():Void { this.x = 2; } }' }
		];
		Assert.equals(0, ownerViolations(files).length);
	}

	/** A subtype that merely EXTENDS writes nothing, so it does not block the restriction. */
	public function testEmptySubtypeStillFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C {}' }
		];
		Assert.equals(1, ownerViolations(files).length);
	}

	/** A subtype that only READS survives `(default, null)` — read access stays public. */
	public function testSubtypeReadStillFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C { function r():Int { return x; } }' }
		];
		Assert.equals(1, ownerViolations(files).length);
	}

	/**
	 * A write through a SUBTYPE-TYPED receiver, from a third file that never mentions the
	 * owner: `s.x = 1` on `s:D` is resolved and recorded against `D`, so asking the write
	 * index about `C` misses it, and scanning `D`'s own body misses it too — the write is
	 * not there. Real-world shape: a layout base class whose padding is set on a subclass
	 * instance by a UI builder.
	 */
	public function testExternalWriteViaSubtypeReceiverNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C {}' },
			{ file: 'U.hx', source: 'class U { function f(d:D):Void { d.x = 10; } }' }
		];
		Assert.equals(0, ownerViolations(files).length);
	}

	/**
	 * A file the grammar could not parse can hold ANY write, so no proof of internal-only
	 * access survives it. The subtype gate used to cover this by accident (a subtype in
	 * scope made it bail regardless); with the precise gate the skip has to be checked on
	 * its own, as `prefer-final-field` already does via `privateMemberScanIsSound`.
	 */
	public function testSkipParsedFileNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C {}' },
			{ file: 'U.hx', source: 'class U { function f(d:D):Void { d.x = 10; } (((' }
		];
		Assert.equals(0, ownerViolations(files).length);
	}

	/** A TRANSITIVE subtype's write blocks it too. */
	public function testTransitiveSubtypeWriteNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'D.hx', source: 'class D extends C {}' },
			{ file: 'E.hx', source: 'class E extends D { function t():Void { this.x = 2; } }' }
		];
		Assert.equals(0, ownerViolations(files).length);
	}

	public function testFixInsertsDefaultNull(): Void {
		final fixed: String = fixedSource('class C { public var x:Int = 0; function s():Void { x = 5; } }');
		Assert.isTrue(fixed.indexOf('public var x(default, null):Int = 0') >= 0);
	}

	/** The two public-field checks are disjoint: an internal-write field is read-only, not final. */
	public function testDisjointFromFinalPublic(): Void {
		final src: String = 'class C { public var x:Int = 0; function s():Void { x = 5; } }';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(0, new PreferFinalPublicField().run(files, plugin).length);
		Assert.equals(1, new PreferReadOnlyField().run(files, plugin).length);
	}

	/**
	 * Ctor-arm twin of `testDisjointFromFinalPublic`: over the SAME fixture exactly one
	 * of the two rules fires — the constructor-sole candidate goes to
	 * `prefer-final-public-field`, and this rule's cession leaves it alone.
	 */
	public function testCtorArmDisjointFromFinalPublic(): Void {
		final src: String = 'class C { public var x:Int; public function new(x:Int) { this.x = x; } }';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(1, new PreferFinalPublicField().run(files, plugin).length);
		Assert.equals(0, new PreferReadOnlyField().run(files, plugin).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-read-only-field'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-read-only-field'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public var x = ').length);
	}

	/** A field whose interface declares it as `var` must keep its access — skipped. */
	public function testInterfaceVarFieldNotFlagged(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'I.hx', source: 'interface I { public var x:Int; }' },
			{ file: 'C.hx', source: 'class C implements I { public var x:Int = 0; function s():Void { x = 1; } }' }
		];
		Assert.equals(0, new PreferReadOnlyField().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * An index-access write to ANOTHER type no longer poisons the name: the
	 * internally-written field is flagged, while the element type written through
	 * the container is correctly treated as externally written.
	 */
	public function testUnrelatedIndexWriteNoLongerPoisons(): Void {
		final vs: Array<Violation> = new PreferReadOnlyField().run([
			{ file: 'C.hx', source: 'class C { public var x:Int = 0; function s():Void { x = 1; } }' },
			{ file: 'Tab.hx', source: 'class Tab { public var x:Int = 0; }' },
			{ file: 'U.hx', source: 'class U { public function f(tabs:Map<String, Tab>):Void { tabs["k"].x = 5; } }' }
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals('C.hx', vs[0].file);
	}

	/** A resolved chain write INSIDE the declaring class counts as internal — the field is flagged. */
	public function testInternalChainWriteFlagged(): Void {
		Assert.equals(1, violations('class C { public var v:Int = 0; var next:C; function s():Void { next.next.v = 3; } }').length);
	}

	/**
	 * Conditional-default twin of `testCtorArmDisjointFromFinalPublic`: the fold candidate
	 * goes to `prefer-final-public-field` and this rule cedes it, so exactly one fires.
	 */
	public function testConditionalDefaultArmDisjointFromFinalPublic(): Void {
		final src: String = 'class C { public var mode:Int = 7; public function new(?other:Int) { if (other != null) mode = other; } }';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(1, new PreferFinalPublicField().run(files, plugin).length);
		Assert.equals(0, new PreferReadOnlyField().run(files, plugin).length);
	}

	/**
	 * A public field written inside a member-position `#if` is a field of the class like any other,
	 * and its internal-only write still restricts to `(default, null)`. Both halves were blind: the
	 * container scan never saw the declaration, and the write index dropped every write resolving to
	 * it — which read as "never written" and ceded the field to `prefer-final-public-field`.
	 */
	public function testConditionalMemberFlaggedAndFixedInPlace(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tpublic var x:Int = 0;\n\t#end\n\tpublic function bump():Void {\n\t\tx = 5;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C {\n\t#if cpp\n\tpublic var x(default, null):Int = 0;\n\t#end\n\tpublic function bump():Void {\n\t\tx = 5;\n\t}\n}',
			fixedSource(src)
		);
	}

	/**
	 * A structural typedef declaring the same member as a MUTABLE field pins its write
	 * access too: `(default, null)` against a structural `var` is `Inconsistent setter for
	 * field x : null should be default`.
	 */
	public function testStructuralTypedefMemberNotFlagged(): Void {
		Assert.equals(
			0, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { var x:Int; }' },
				{ file: 'C.hx', source: 'class C { public var x:Int = 0; public function bump():Void { x = 5; } }' }
			]).length
		);
	}

	/**
	 * A structural typedef declaring the member as a METHOD does NOT pin write access — a
	 * `(default, null)` field of function type satisfies it — so the field stays flagged.
	 */
	public function testStructuralMethodMemberStillFlagged(): Void {
		Assert.equals(
			1, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { function x():Bool; }' },
				{ file: 'C.hx', source: 'class C { public var x:Void->Bool = null; public function bump():Void { x = null; } }' }
			]).length
		);
	}

	/**
	 * The cession seam: a no-init field whose sole write is one constructor assignment is
	 * normally ceded to `prefer-final-public-field`, but a structural METHOD member forbids
	 * `final` there while tolerating `(default, null)` here. An unconditional cession would drop
	 * the finding entirely — this is the `Iterator`-shaped field the structural gate was added
	 * for, and `(default, null)` is its correct answer.
	 */
	public function testCededCandidateReclaimedWhenFinalIsPinned(): Void {
		Assert.equals(
			1, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { function x():Bool; }' },
				{ file: 'C.hx', source: 'class C { public var x:Void->Bool; public function new(p:Void->Bool) { x = p; } }' }
			]).length
		);
	}

	/** With no structure in scope the same candidate is ceded as before — `final` is available. */
	public function testCtorSoleAssignmentStillCededWithoutStructure(): Void {
		Assert.equals(
			0,
			ownerViolations([
				{ file: 'C.hx', source: 'class C { public var x:Void->Bool; public function new(p:Void->Bool) { x = p; } }' }
			]).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferReadOnlyField().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Only the violations against the owner `C.hx` — a subtype fixture can carry findings of its own. */
	private function ownerViolations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new PreferReadOnlyField().run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'C.hx');
	}

	private function fixedSource(src: String): String {
		return CheckFixture.fixedSource(new PreferReadOnlyField(), src);
	}

}
