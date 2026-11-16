package unit.check.haxe.types;

import anyparse.check.Check;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.check.haxe.types.PreferIntersectionType;

/**
 * The `prefer-intersection-type` check: a typedef whose type is a structure of nothing but `> T` extensions is flagged
 * `Info` and rewritten to the intersection `A & B` (one extension: a plain alias). A structure with an own field or an
 * annotation, one holding a comment, and every structure that is not a typedef's whole type are left alone.
 */
class PreferIntersectionTypeTest extends Test {

	private static inline final DECLS: String = 'typedef A = {a:Int}\ntypedef B = {b:Int}\ntypedef D = {d:Int}\n';

	/** Two and three extensions, written on one line and over several, become the intersection of their types. */
	@:pin('control')
	@:killer('M-PIT-JOIN-FIRST')
	@:killer('M-PIT-LEAD-KEPT')
	public function testExtensionsBecomeAnIntersection(): Void {
		final src: String = '${DECLS}typedef C = { > A, > B, };\ntypedef E = {\n\t> A,\n\t> B,\n\t> D,\n};\n';
		final found: Array<Violation> = CheckFixture.violations(new PreferIntersectionType(), src);
		Assert.equals(2, found.length);
		Assert.equals(Severity.Info, found[0].severity);
		Assert.equals('this structure only extends other types: write it as an intersection (A & B)', found[0].message);
		final fixed: String = fixedSource(src);
		Assert.stringContains('typedef C = A & B;', fixed);
		Assert.stringContains('typedef E = A & B & D;', fixed);
	}

	/** One extension is a plain alias; type arguments and a qualified path are carried over as written. */
	@:pin('control')
	@:killer('M-PIT-LEAD-KEPT')
	public function testASingleExtensionIsAnAlias(): Void {
		final fixed: String = fixedSource('${DECLS}typedef C = { > A, };\ntypedef G<T> = { > Base<T>, > pkg.Other, };\n');
		Assert.stringContains('typedef C = A;', fixed);
		Assert.stringContains('typedef G<T> = Base<T> & pkg.Other;', fixed);
	}

	/** `typedef C = { … }` needs no terminator, `typedef C = A & B;` does. */
	@:pin('control')
	@:killer('M-PIT-NO-TERMINATOR')
	public function testATypedefWrittenWithoutItsSemicolonGainsOne(): Void {
		Assert.stringContains('typedef C = A & B;\n', fixedSource('${DECLS}typedef C = {\n\t> A,\n\t> B,\n}\n'));
	}

	/** An own field, an annotated field and a field after the clauses keep the structure: an intersection holds none. */
	@:pin('control')
	@:killer('M-PIT-ANY-MEMBER')
	public function testAnOwnFieldKeepsTheStructure(): Void {
		final src: String =
			'${DECLS}typedef C = { > A, x:Int, };\ntypedef E = { > A, @:optional var y:Int, };\ntypedef F = { z:Int, > A, };\n';
		Assert.equals(0, CheckFixture.violations(new PreferIntersectionType(), src).length);
	}

	/** A comment anywhere in the body has no place in the intersection. */
	@:pin('control')
	@:killer('M-PIT-COMMENT-IGNORED')
	public function testACommentInTheBodyIsLeftAlone(): Void {
		final src: String = '${DECLS}typedef C = {\n\t> A, // the base\n\t> B,\n};\ntypedef E = { /* all */ > A, };\n';
		Assert.equals(0, CheckFixture.violations(new PreferIntersectionType(), src).length);
	}

	/**
	 * Only a typedef's whole type is rewritten: a field, a parameter, a return type and a type parameter's constraint
	 * have no spelling for the intersection, and a structure followed by more of the type is not the whole of it.
	 */
	@:pin('control')
	@:killer('M-PIT-ANY-STRUCTURE')
	@:killer('M-PIT-TAIL-IGNORED')
	public function testAStructureThatIsNotTheTypedefsWholeTypeIsLeftAlone(): Void {
		final src: String = '${DECLS}class K {\n\tvar f:{ > A, > B, };\n\tfunction g(x:{ > A, }):{ > B, } {\n\t\treturn null;\n\t}\n}\n'
			+ 'typedef H<T:{ > A, }> = Array<T>;\ntypedef I = { > A, } & B;\n';
		Assert.equals(0, CheckFixture.violations(new PreferIntersectionType(), src).length);
	}

	/** A structure that ends the typedef's type after an intersection clause reads the same joined onto it. */
	public function testAStructureAfterAClauseJoinsIt(): Void {
		Assert.stringContains('typedef C = A & B & D;', fixedSource('${DECLS}typedef C = A & { > B, > D, };\n'));
	}

	/** The fix reaches a fixed point, and its output is what the writer prints. */
	@:pin('guard')
	public function testTheFixIsIdempotentAndCanonical(): Void {
		final fixed: String = fixedSource('${DECLS}typedef C = {\n\t> A,\n\t> B,\n}\n');
		Assert.equals(0, CheckFixture.violations(new PreferIntersectionType(), fixed).length);
		Assert.equals(fixed, fixedSource(fixed));
		Assert.equals(fixed, new HaxeQueryPlugin().writeRoundTrip(fixed, '{}') ?? '');
	}

	public function testRegisteredUnderTypes(): Void {
		final check: Null<Check> = Linter.byId('prefer-intersection-type');
		Assert.notNull(check);
		if (check != null) Assert.equals(RuleCategory.Types, check.category());
	}

	/** `src` as `C.hx` after the check's fix. */
	private static function fixedSource(src: String): String {
		return CheckFixture.fixedSource(new PreferIntersectionType(), src);
	}

}
