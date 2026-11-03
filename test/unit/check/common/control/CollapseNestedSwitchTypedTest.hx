package unit.check.common.control;

import anyparse.check.Check;
import anyparse.check.common.control.CollapseNestedSwitch;
import anyparse.query.CanonicalEdit;
import anyparse.query.Cli;
import anyparse.query.StdResolver;
#if (sys || nodejs)
import sys.io.File;
#end
import unit.cli.CliFixture;

using StringTools;

/**
 * The typed proofs of `collapse-nested-switch`: a binder at a slot whose constructor sits in another file or
 * holds a type parameter is a proven capture when the subject's declared type rules a constant out, and an inner
 * switch with no catch-all collapses when every constructor of the subject's enum has an unguarded, whole arm.
 */
class CollapseNestedSwitchTypedTest extends Test {

	private static inline final LIB_EITHER: String = 'package lib;\nenum Either<L, R> {\n\tLeft(v: L);\n\tRight(v: R);\n}\n';
	private static inline final LIB_KIND: String = 'package lib;\nenum abstract Kind(Int) {\n\tvar x;\n}\n';
	private static inline final COVERED: String = 'case Left(r): 2;\n\t\t\t\t\tcase Right(y): 3;';
	private static inline final CATCH_ALL: String = 'case Left(r): 2;\n\t\t\t\t\tcase _: 3;';
	private static inline final OUTER_OK: String = 'Either<Array<String>, Array<Int>>';
	private static inline final INNER_OK: String = 'Either<Array<String>, { c: Int }>';

	/** A slot typed by a type argument of an enum from another file: its capture needs the typed proof alone. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-SLOT')
	public function testTypeParameterSlotOfAnotherFileIsACapture(): Void {
		Assert.equals(1, found(site(OUTER_OK, INNER_OK, CATCH_ALL)).length);
	}

	/** Coverage alone: the capture is proven in the file, the inner switch has no catch-all and no harmless tail. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-COVERAGE')
	public function testEveryConstructorMatchedCollapses(): Void {
		final src: String = local('switch b {\n\t\t\t\t\tcase Q: 2;\n\t\t\t\t\tcase A(u, _): 3;\n\t\t\t\t}');
		Assert.equals(1, found(src).length);
		final out: String = fixed(src);
		Assert.stringContains('case P(Q): 2;', out);
		Assert.stringContains('case P(A(u, _)): 3;', out);
	}

	/** The user's site: both proofs together, the emitted run compiling as the exhaustive deep match. */
	public function testGenericEnumFromAnotherFileCollapsesIntoExtractor(): Void {
		final src: String = site(OUTER_OK, INNER_OK);
		Assert.equals(1, found(src).length);
		final out: String = fixed(src);
		Assert.stringContains('case Right(b(q, _) => Left(r)): 2;', out);
		Assert.stringContains('case Right(b(q, _) => Right(y)): 3;', out);
		Assert.equals(0, found(out).length, 'the rewritten run is a fixed point');
	}

	/** A switch on a capture takes its type from the slot the capture sits in, however deep. */
	public function testBareInnerSubjectIsTypedByItsSlot(): Void {
		final src: String = 'package app;\nimport lib.Either;\nenum PE {\n\tP(e: Either<Int, QE>);\n}\nenum QE {\n\tQ;\n\tA;\n}\n'
			+ 'class C {\n\tfunction f(s: PE): Int {\n\t\treturn switch s {\n\t\t\tcase P(Left(_)): 1;\n\t\t\tcase '
			+ 'P(Right(b)):\n\t\t\t\tswitch b {\n\t\t\t\t\tcase Q: 2;\n\t\t\t\t\tcase A: 3;\n\t\t\t\t}\n\t\t};\n\t}\n}\n';
		Assert.stringContains('case P(Right(Q)): 2;', fixed(src));
	}

	/** A parenthesised subject carries the type of what it wraps. */
	public function testParenthesisedSubjectIsTyped(): Void {
		Assert.equals(1, found(site(OUTER_OK, INNER_OK).replace('switch a()', 'switch (a())')).length);
	}

	/** An enum abstract whose value the binder spells compares; another spelling captures. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-MEMBER-NAME')
	public function testSlotTypeDeclaringTheNameRefused(): Void {
		final outer: String = 'Either<Array<String>, lib.Kind>';
		Assert.equals(0, found(site(outer, INNER_OK, CATCH_ALL, 'lib.Kind')).length);
		Assert.equals(1, found(site(outer, INNER_OK, CATCH_ALL, 'lib.Kind', 'w')).length);
	}

	/** A typedef may stand for an enum abstract, a structure typedef cannot. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-ALIAS')
	public function testSlotTypeNamedThroughATypedefRefused(): Void {
		final types: String = 'package lib;\ntypedef Alias = Kind;\ntypedef Shape = { c: Int };\n';
		Assert.equals(0, found(site('Either<Array<String>, lib.Types.Alias>', INNER_OK, CATCH_ALL, 'lib.Types.Alias'), types).length);
		Assert.equals(1, found(site('Either<Array<String>, lib.Types.Shape>', INNER_OK, CATCH_ALL, 'lib.Types.Shape'), types).length);
	}

	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-ALL-CTORS')
	public function testConstructorLeftOutRefused(): Void {
		Assert.equals(0, found(site(OUTER_OK, INNER_OK, 'case Left(r): 2;')).length);
	}

	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-GUARD')
	public function testGuardedArmCoversNothing(): Void {
		Assert.equals(0, found(site(OUTER_OK, INNER_OK, 'case Left(r) if (q > 0): 2;\n\t\t\t\t\tcase Right(y): 3;')).length);
	}

	/** A nullable subject holds a value no constructor arm matches. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-NULLABLE')
	public function testNullableInnerSubjectRefused(): Void {
		Assert.equals(0, found(site(OUTER_OK, 'Null<$INNER_OK>')).length);
	}

	/** A constructor's optional parameter holds null, which no constructor arm matches, whether the enum is generic or not. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-OPTIONAL-SLOT')
	public function testOptionalConstructorParameterRefusedInCoverage(): Void {
		final generic: String = 'enum Opt<R> {\n\tSome(?v: R);\n\tNone;\n}\n';
		final plain: String = 'enum Opt {\n\tSome(?v: QE);\n\tNone;\n}\n';
		Assert.equals(0, found(optional(generic, 'Opt<QE>', 'case Q: 1;\n\t\t\t\t\tcase A: 2;')).length);
		Assert.equals(0, found(optional(plain, 'Opt', 'case Q: 1;\n\t\t\t\t\tcase A: 2;')).length);
	}

	/** A capture at an optional slot takes the null too, so only coverage refuses it: a catch-all still collapses. */
	public function testOptionalConstructorParameterStaysACapture(): Void {
		final generic: String = 'enum Opt<R> {\n\tSome(?v: R);\n\tNone;\n}\n';
		Assert.equals(1, found(optional(generic, 'Opt<QE>', 'case Q: 1;\n\t\t\t\t\tcase _: 2;')).length);
	}

	/** An enum abstract holds values it does not declare, so naming every declared one leaves a hole. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-ENUM-ABSTRACT')
	public function testEnumAbstractSubjectIsNotCovered(): Void {
		Assert.equals(0, found(site(OUTER_OK, 'lib.Kind', 'case x: 2;', null, 'w')).length);
	}

	/** An argument that may compare leaves the rest of its constructor to fall through. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-WHOLE-ARG')
	public function testInnerArgumentThatMayCompareRefused(): Void {
		final inner: String = 'Either<Array<String>, lib.Kind>';
		Assert.equals(0, found(site(OUTER_OK, inner, 'case Left(r): 2;\n\t\t\t\t\tcase Right(x): 3;')).length);
		Assert.equals(0, found(site(OUTER_OK, INNER_OK, 'case Left(r): 2;\n\t\t\t\t\tcase Right({ c: 1 }): 3;')).length);
	}

	/** A written type reaching here from another file has no reading scope, so a shared name proves nothing. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-UNSCOPED')
	public function testNameTwoDeclarationsShareRefused(): Void {
		final other: Array<{ file: String, source: String }> = [
			{ file: 'other/Either.hx', source: 'package other;\nenum Either<L, R> {\n\tLeft(v: L);\n\tRight(v: R);\n}\n' }
		];
		Assert.equals(0, found(site(OUTER_OK, INNER_OK), '', other).length);
	}

	/** A parameter mentioning the enum's type parameter leaves its own arguments unbound. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-ARGS-UNREAD')
	public function testArgumentsOfAParameterMentioningATypeParameterRefused(): Void {
		final src: String = 'package app;\nimport lib.Either;\nimport lib.Box;\nclass C {\n'
			+ '\tstatic function b(x: Dynamic): Either<Int, Int> { return null; }\n\tfunction f(s: Box<Int>): Int {\n'
			+ '\t\treturn switch s {\n\t\t\tcase B(Left(_)): 1;\n\t\t\tcase B(Right(t)):\n\t\t\t\tswitch b(t) {\n'
			+ '\t\t\t\t\tcase Left(_): 2;\n\t\t\t\t\tcase _: 3;\n\t\t\t\t}\n\t\t};\n\t}\n}\n';
		final box: String = 'package lib;\nclass T {}\nenum Box<T> {\n\tB(v: Either<T, T>);\n}\n';
		Assert.equals(0, found(src, '', [{ file: 'lib/Box.hx', source: box }]).length);
	}

	/** A slot typed by a function's own type parameter holds whatever the call instantiates, whatever else shares the name. */
	public function testFunctionTypeParameterSlotRefused(): Void {
		final src: String = 'package app;\nimport lib.Either;\nclass C {\n\tstatic function a<T>(): Either<Array<String>, T> {'
			+ ' return null; }\n\tstatic function b(q: Int, x: Dynamic): $INNER_OK { return null; }\n'
			+ '\tfunction f(q: Int): Int {\n\t\treturn switch a() {\n\t\t\tcase Left(r): 1;\n\t\t\tcase Right(x):\n'
			+ '\t\t\t\tswitch b(q, x) {\n\t\t\t\t\t$CATCH_ALL\n\t\t\t\t}\n\t\t};\n\t}\n}\n';
		Assert.equals(0, found(src, '', [{ file: 'lib/T.hx', source: 'package lib;\nclass T {}\n' }]).length);
	}

	/** A slot typed by the enclosing class's type parameter, whatever else shares the name. */
	public function testClassTypeParameterSlotRefused(): Void {
		final src: String = 'package app;\nimport lib.Either;\nclass C<T> {\n\tfunction a(): Either<Array<String>, T> { return null; }\n'
			+ '\tfunction b(q: Int, x: Dynamic): $INNER_OK { return null; }\n\tfunction f(q: Int): Int {\n\t\treturn switch a() {\n'
			+ '\t\t\tcase Left(r): 1;\n\t\t\tcase Right(x):\n\t\t\t\tswitch b(q, x) {\n\t\t\t\t\t$CATCH_ALL\n\t\t\t\t}\n\t\t};\n\t}\n}\n';
		Assert.equals(0, found(src, '', [{ file: 'lib/T.hx', source: 'package lib;\nclass T {}\n' }]).length);
	}

	/** A slot typed by the constructor's own type parameter, whatever else shares the name in the enum's file. */
	@:pin('control')
	@:killer('M-COLLAPSE-TYPED-CTOR-PARAM')
	public function testConstructorTypeParameterSlotRefused(): Void {
		final src: String = 'package app;\nimport lib.Either;\nimport lib.Own;\nclass C {\n\tstatic function b(q: Int, x: Dynamic): '
			+ '$INNER_OK { return null; }\n\tfunction f(s: Own, q: Int): Int {\n\t\treturn switch s {\n\t\t\tcase O(x):\n'
			+ '\t\t\t\tswitch b(q, x) {\n\t\t\t\t\t$CATCH_ALL\n\t\t\t\t}\n\t\t};\n\t}\n}\n';
		final own: String = 'package lib;\nclass T {}\nenum Own {\n\tO<T>(v: T);\n}\n';
		Assert.equals(0, found(src, '', [{ file: 'lib/Own.hx', source: own }]).length);
	}

	/** The real std's `haxe.ds.Either`, through the resolution index a lint run builds. */
	public function testStdEitherCollapsesThroughTheRun(): Void {
		#if (sys || nodejs)
		if (StdResolver.stdDir() == null) {
			Assert.pass('no Haxe std on this machine');
			return;
		}
		final code: String = 'package;\n\nimport haxe.ds.Either;\n\nclass C {\n\n'
			+ '\tstatic function a():Either<Array<String>, Array<Int>> {\n\t\treturn Left([]);\n\t}\n\n\tstatic function '
			+ 'b(q:Int, x:Array<Int>):Either<Array<String>, {c:Int}> {\n\t\treturn Left([]);\n\t}\n\n\tfunction '
			+ 'f(q:Int):Int {\n\t\treturn switch a() {\n\t\t\tcase Left(r): 1;\n\t\t\tcase Right(x):\n\t\t\t\tswitch b(q, '
			+ 'x) {\n\t\t\t\t\tcase Left(s): 2;\n\t\t\t\t\tcase Right(y): 3;\n\t\t\t\t}\n\t\t};\n\t}\n\n}\n';
		final proj: String = CliFixture.writeDir('collapsetypedstd', [{ name: 'C.hx', source: code }]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--rule', 'collapse-nested-switch', '$proj/C.hx']), 'the fix run succeeds');
		final out: String = File.getContent('$proj/C.hx');
		Assert.stringContains('case Right(b(q, _) => Left(s)): 2;', out);
		Assert.stringContains('case Right(b(q, _) => Right(y)): 3;', out);
		CliFixture.removeDir(proj);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** One file: `a()` over `outer`, then in its `Right` arm a switch on `b(q, binder)` of type `inner`. */
	private function site(outer: String, inner: String, arms: String = COVERED, ?param: String, binder: String = 'x'): String {
		final held: String = param ?? 'Array<Int>';
		return
			'package app;\nimport lib.Either;\nclass C {\n\tstatic function a(): $outer { return null; }\n\tstatic function b(q: Int, x: '
				+ '$held): $inner { return null; }\n\tfunction f(q: Int): Int {\n\t\treturn switch a() {\n\t\t\tcase Left(r): 1;\n'
				+ '\t\t\tcase Right($binder):\n\t\t\t\tswitch b(q, $binder) {\n\t\t\t\t\t$arms\n\t\t\t\t}\n\t\t};\n\t}\n}\n';
	}

	/** One file with its enums, the outer arm's slot declared there so its capture needs no typed proof. */
	private function local(inner: String): String {
		return 'package app;\nenum PE {\n\tP(b: QE);\n}\nenum QE {\n\tQ;\n\tA(u: Int, v: Int);\n}\n'
			+ 'class C {\n\tfunction f(s: PE): Int {\n\t\treturn switch s {\n\t\t\tcase P(b):\n\t\t\t\t$inner\n\t\t};\n\t}\n}\n';
	}

	/** One file: `f` switches on the optional slot of `Some`, bare, its enum `decl` declared beside `QE`. */
	private function optional(decl: String, subject: String, arms: String): String {
		return 'package app;\n${decl}enum QE {\n\tQ;\n\tA;\n}\nclass C {\n\tfunction f(s: $subject): Int {\n\t\treturn switch s {\n'
			+ '\t\t\tcase None: 0;\n\t\t\tcase Some(b):\n\t\t\t\tswitch b {\n\t\t\t\t\t$arms\n\t\t\t\t}\n\t\t};\n\t}\n}\n';
	}

	private function files(
		src: String, types: String, more: Array<{ file: String, source: String }>
	): Array<{ file: String, source: String }> {
		final set: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'lib/Either.hx', source: LIB_EITHER },
			{ file: 'lib/Kind.hx', source: LIB_KIND },
			{ file: 'lib/Types.hx', source: types == '' ? 'package lib;\n' : types }
		];
		return set.concat(more);
	}

	private function found(src: String, types: String = '', ?more: Array<{ file: String, source: String }>): Array<Violation> {
		return CheckFixture.violationsIn(new CollapseNestedSwitch(), files(src, types, more ?? [])).filter(v -> v.file == 'app/C.hx');
	}

	private function fixed(src: String): String {
		return switch CanonicalEdit.canonicalize(
			src, CheckFixture.fixRun(new CollapseNestedSwitch(), files(src, '', []), 'app/C.hx').edits, true, new HaxeQueryPlugin()
		) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
