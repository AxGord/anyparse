package unit.check;

import anyparse.check.PreferFinalPublicField;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The structural-conformance gate asked as a PROOF rather than as a name test
 * (`StructuralTypes.memberCouldUnify`).
 *
 * The gate refuses `var` -> `final` when the owner could be unified with an anonymous structure
 * declaring the candidate mutably, and it decided that by MEMBER NAME SET over
 * `!MemberLookup.lacksMemberClosure`. Both halves of that were wrong in the same direction.
 *
 * The absence walk fails closed toward "cannot prove absent", so its negation read an
 * UNRESOLVABLE supertype as declaring every member: a class extending a type outside the
 * resolution scope conformed to any structure that merely named the candidate. And a member set
 * is not a unification — measured against the compiler on Haxe 4.3.7, a structural `var x:Float`
 * rejects a class declaring `var x:Int`, `var x:Base` rejects `var x:Sub` (a mutable structure
 * field is INVARIANT, a subtype is not enough), and `var x:C` for an abstract `C` with a
 * `@:from Int` rejects `var x:Int` (an implicit cast does not bridge one either).
 *
 * Three spellings measured the OTHER way and are therefore open, each with a fixture below: a
 * plain `typedef MyInt = Int` alias IS accepted by a structural `x:MyInt` against `var x:Int`,
 * and so is `Null<Int>` against `Int` in both directions. A type PARAMETER, `Dynamic` and an
 * anonymous-structure nominal are open by construction.
 *
 * Every structure here uses the SHORTHAND field form `x:Int`, and not by taste: the index records
 * no `typeSource` for the explicit `var x:Int;` form (`declaredTypeSources` keys the shorthand and
 * the optional `?x:Int` but not the `var`), so the refutation half is blind to it and the pin
 * survives — the conservative direction, and the residual this slice leaves open. Real structures
 * are written shorthand: all four the Pony fork withheld findings against are
 * (`{app:String, debug:Bool}`, `{d:EventDispatcher, n:String}`, `{min:Time, max:Time}`).
 */
@:nullSafety(Strict)
class StructuralConformanceProofTest extends Test {

	/** The one-member structure most fixtures here pin against. */
	private static final S_INT: SourceFile = { file: 'S.hx', source: 'typedef S = { x:Int }' };

	/** A two-member structure the owner cannot satisfy on its own. */
	private static final S_INT_Y: SourceFile = { file: 'S.hx', source: 'typedef S = { x:Int, y:Int }' };

	/** The owner: one public field, initialized, never written again. */
	private static final C_INT: SourceFile = { file: 'C.hx', source: 'class C { public var x:Int = 0; }' };

	/** The same owner declaring the member under a type no structural `x:Int` accepts. */
	private static final C_STRING: SourceFile = { file: 'C.hx', source: 'class C { public var x:String = ""; }' };

	/** The same owner under a supertype the scope cannot resolve — the wildcard's shape. */
	private static final C_OUTSIDE: SourceFile = { file: 'C.hx', source: 'class C extends Outside { public var x:Int = 0; }' };

	/** A plain alias of the owner's declared type, in its own module. */
	private static final ALIAS: SourceFile = { file: 'A.hx', source: 'typedef MyInt = Int;' };

	/** The alias-typed structure. */
	private static final S_ALIAS: SourceFile = { file: 'S.hx', source: 'typedef S = { x:MyInt }' };

	/** The `Null<Int>`-typed structure. */
	private static final S_NULLABLE: SourceFile = { file: 'S.hx', source: 'typedef S = { x:Null<Int> }' };

	/** The structure whose member is typed as its own declaration's type parameter. */
	private static final S_PARAM: SourceFile = { file: 'S.hx', source: 'typedef S<T> = { x:T }' };

	/** The `Dynamic`-typed structure. */
	private static final S_DYNAMIC: SourceFile = { file: 'S.hx', source: 'typedef S = { x:Dynamic }' };

	/** An anonymous structure in its own module — a nominal that is a STRUCTURE, not a name. */
	private static final SHAPE: SourceFile = { file: 'Shape.hx', source: 'typedef Shape = { a:Int }' };

	/** The structure whose member is typed by that anonymous-structure typedef. */
	private static final S_SHAPE: SourceFile = { file: 'S.hx', source: 'typedef S = { x:Shape }' };

	/**
	 * The supertype half. An unresolvable supertype supplies no member, so a class extending one
	 * conforms to nothing it does not declare itself. Three findings on the Pony fork stood on
	 * this one line.
	 */
	@:pin('control')
	@:killer('M-STRUCT-DECLARES-LOOSE')
	public function testUnresolvableSupertypeSuppliesNoMember(): Void {
		// Leading assertion — the same structure over a supertype-less owner reports, so the
		// fixture reaches this gate rather than some earlier one.
		Assert.equals(1, owner([S_INT_Y, C_INT]), 'an owner missing y does not conform');
		Assert.equals(1, owner([S_INT_Y, C_OUTSIDE]), 'an unresolvable supertype does not supply y');
	}

	/**
	 * The type half. The structure's member and the owner's are both named `x` and cannot unify,
	 * so the structure pins nothing.
	 */
	@:pin('control')
	@:killer('M-STRUCT-NOMINAL-OPEN')
	public function testDifferentDeclaredTypeDoesNotPin(): Void {
		// Leading assertion — the SAME type still pins, so the refutation is what moves the other.
		Assert.equals(0, owner([S_INT, C_INT]), 'the same declared type pins');
		Assert.equals(1, owner([S_INT, C_STRING]), 'a different declared type cannot unify');
	}

	/**
	 * A plain `typedef` alias is FOLLOWED, not compared as a name: `{x:MyInt}` with
	 * `typedef MyInt = Int` does accept a class declaring `var x:Int`, so refuting on the two
	 * spellings would drop a pin the compiler needs. Guards behaviour the base commit already had,
	 * where neither side refuted anything.
	 */
	@:pin('control')
	@:killer('M-STRUCT-ALIAS-OPAQUE')
	public function testAliasedStructureMemberTypeStillPins(): Void {
		// Leading assertion — the refutation is live on this structure for a genuinely other type.
		Assert.equals(1, owner([ALIAS, S_ALIAS, C_STRING]), 'MyInt does not accept String');
		Assert.equals(0, owner([ALIAS, S_ALIAS, C_INT]), 'MyInt is Int and still pins');
	}

	/**
	 * `Null<T>` is transparent for this question in both directions, so the wrapper is stripped and
	 * its argument answered instead. Guards behaviour the base commit already had.
	 */
	@:pin('control')
	@:killer('M-STRUCT-NULL-OPAQUE')
	public function testNullWrappedStructureMemberTypeStillPins(): Void {
		// Leading assertion — the refutation is live on this structure for a genuinely other type.
		Assert.equals(1, owner([S_NULLABLE, C_STRING]), 'Null<Int> does not accept String');
		Assert.equals(0, owner([S_NULLABLE, C_INT]), 'Null<Int> is Int and still pins');
	}

	/**
	 * A structure member typed as one of its own declaration's type PARAMETERS binds to whatever
	 * the unification site supplies, so it refutes nothing. Guards behaviour the base commit
	 * already had.
	 */
	@:pin('control')
	@:killer('M-STRUCT-TYPEPARAM-CLOSED')
	public function testTypeParameterStructureMemberStillPins(): Void {
		// Leading assertion — the non-generic structure of the same shape pins too.
		Assert.equals(0, owner([S_INT, C_INT]), 'the non-generic structure pins');
		Assert.equals(0, owner([S_PARAM, C_INT]), 'a type parameter binds to Int');
	}

	/** `Dynamic` unifies with everything. Guards behaviour the base commit already had. */
	@:pin('control')
	@:killer('M-STRUCT-DYNAMIC-CLOSED')
	public function testDynamicStructureMemberStillPins(): Void {
		// Leading assertion — the Int structure of the same shape pins too.
		Assert.equals(0, owner([S_INT, C_INT]), 'the Int structure pins');
		Assert.equals(0, owner([S_DYNAMIC, C_INT]), 'Dynamic accepts Int');
	}

	/**
	 * A nominal naming an ANONYMOUS-STRUCTURE typedef is a structure rather than a name, and a
	 * class can unify with one — so it is not a spelling two written types may be refuted on.
	 * Conservative in the direction that keeps the pin, and it keeps one here that a full
	 * unification would not need. Guards behaviour the base commit already had.
	 */
	@:pin('control')
	@:killer('M-STRUCT-ANON-CLOSED')
	public function testAnonStructureNominalStillPins(): Void {
		// Leading assertion — the plain-class nominal in the same slot still pins.
		Assert.equals(0, owner([S_INT, C_INT]), 'a plain nominal pins');
		Assert.equals(0, owner([SHAPE, S_SHAPE, C_INT]), 'an anonymous-structure nominal refutes nothing');
	}

	/** How many findings the rule reports against the owner file `C.hx`. */
	private function owner(files: Array<SourceFile>): Int {
		return new PreferFinalPublicField().run(files, new HaxeQueryPlugin()).count(v -> v.file == 'C.hx');
	}

}

/** One source a fixture hands the rule. */
private typedef SourceFile = {
	var file: String;
	var source: String;
};
