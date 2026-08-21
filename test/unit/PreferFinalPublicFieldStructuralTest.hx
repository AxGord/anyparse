package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFinalPublicField;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using Lambda;

/**
 * The structural-conformance gate of `prefer-final-public-field`
 * (`SymbolIndex.structuralConformanceForbidsFinal`). Haxe unifies a class instance with an
 * anonymous structure by MEMBER SET, and a `final` field satisfies neither a structural
 * `var x:T` (`Inconsistent setter for field x : ctor should be default`) nor a structural
 * `function x():T` (`Cannot unify final and non-final fields`). That unification is a READ
 * position, so none of the check's write gates can see it — these fixtures are what pin the
 * gate that can.
 *
 * Split out of `PreferFinalPublicFieldCheckTest` only because that class had reached the
 * member cap; the fixtures below belong to the same check.
 */
class PreferFinalPublicFieldStructuralTest extends Test {

	/**
	 * The base case: a structural typedef declaring the same member as a MUTABLE field pins it.
	 */
	public function testStructuralTypedefMemberNotFlagged(): Void {
		Assert.equals(
			0, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { var x:Int; }' },
				{ file: 'C.hx', source: 'class C { public var x:Int = 0; }' }
			]).length
		);
	}

	/**
	 * The SHORTHAND anon-structure field form `x:Int` declares a mutable member too — the
	 * grammar projects it as a different node kind than the explicit `var`.
	 */
	public function testShorthandStructuralTypedefMemberNotFlagged(): Void {
		Assert.equals(
			0, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { x:Int, tag:String }' },
				{ file: 'C.hx', source: 'class C { public var x:Int = 0; public var tag:String = ""; }' }
			]).length
		);
	}

	/**
	 * A structural METHOD member in its PINNING direction — the one kind this gate has and
	 * `prefer-read-only-field`'s does not.
	 */
	public function testStructuralMethodMemberNotFlagged(): Void {
		Assert.equals(
			0, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { function x():Bool; }' },
				{ file: 'C.hx', source: 'class C { public var x:Void->Bool; public function new(p:Void->Bool) { x = p; } }' }
			]).length
		);
	}

	/**
	 * The builtin arm: a class declaring `hasNext` AND `next` is the language's structural
	 * `Iterator`, which no project file declares, so no anon-typedef walk could find it.
	 */
	public function testIteratorShapeMemberNotFlagged(): Void {
		Assert.equals(
			0,
			ownerViolations([
				{
					file: 'C.hx',
					source: 'class C { public var hasNext:Void->Bool; public function new() { hasNext = null; } '
					+ 'public function next():Int return 1; }'
				}
			]).length
		);
	}

	/**
	 * The SUBTYPE arm: `C` alone does not satisfy `S`, its subclass does — and the subclass
	 * INHERITS the field, so `final` on `C.x` is `Inconsistent setter for field x : ctor should
	 * be default` at the subclass's own unification site.
	 */
	public function testSubtypeStructuralConformanceNotFlagged(): Void {
		Assert.equals(
			0, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { var x:Int; var y:Int; }' },
				{ file: 'C.hx', source: 'class C { public var x:Int = 0; }' },
				{ file: 'D.hx', source: 'class D extends C { public var y:Int = 0; }' }
			]).length
		);
	}

	/**
	 * An owner whose SIMPLE name two packages both declare must not un-gate the rewrite: a
	 * package-blind resolution answers "declares nothing" for it, and that is the unsafe
	 * direction. `a.C` conforms and is skipped; `b.C` does not and keeps its finding.
	 */
	public function testAmbiguousOwnerNameStillPinned(): Void {
		final vs: Array<Violation> = run([
			{ file: 'S.hx', source: 'typedef S = { var x:Int; }' },
			{ file: 'a/C.hx', source: 'package a;\nclass C { public var x:Int = 0; }' },
			{ file: 'b/C.hx', source: 'package b;\nclass C { public var y:Int = 0; }' }
		]);
		Assert.equals(1, vs.length);
		Assert.equals('b/C.hx', vs[0].file);
	}

	/**
	 * A structure declaring the member `final` wants a `final` field — no obstacle. A mutable
	 * field already fails to unify with it, so the rewrite can only repair that.
	 */
	public function testFinalStructuralTypedefMemberStillFlagged(): Void {
		Assert.equals(
			1, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { final x:Int; }' },
				{ file: 'C.hx', source: 'class C { public var x:Int = 0; }' }
			]).length
		);
	}

	/** A structure the class does NOT satisfy (it lacks `y`) leaves the field flagged. */
	public function testUnsatisfiedStructuralTypedefStillFlagged(): Void {
		Assert.equals(
			1, ownerViolations([
				{ file: 'S.hx', source: 'typedef S = { var x:Int; var y:Int; }' },
				{ file: 'C.hx', source: 'class C { public var x:Int = 0; }' }
			]).length
		);
	}

	private function run(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new PreferFinalPublicField().run(files, new HaxeQueryPlugin());
	}

	/** Only the violations against the owner `C.hx` — a sibling fixture can carry findings of its own. */
	private function ownerViolations(files: Array<{ file: String, source: String }>): Array<Violation> {
		return run(files).filter(v -> v.file == 'C.hx');
	}

}
