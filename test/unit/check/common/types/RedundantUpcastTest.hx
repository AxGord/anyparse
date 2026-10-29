package unit.check.common.types;

import anyparse.check.Severity;
import anyparse.check.common.types.RedundantUpcast;

/**
 * The `redundant-upcast` check: a runtime-checked cast `cast(x, T)` where `x`'s declared
 * type is a strict subtype of `T`, so the cast always succeeds and is a no-op. Same-type
 * (redundant-cast), unrelated (impossible-cast), downcast, external, generic, and
 * compile-time `(x : T)` are not flagged.
 */
class RedundantUpcastTest extends Test {

	@:pin('control') @:killer('M-ISSUBTYPE-FALSE')
	public function testUpcastFlagged(): Void {
		Assert.equals(
			1, violations('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = cast(s, Base); } }').length
		);
	}

	public function testInterfaceUpcastFlagged(): Void {
		// `cast(a:A, I)` where A implements I — always succeeds.
		Assert.equals(1, violations('interface I {} class A implements I {} class C { function f(a:A) { var b = cast(a, I); } }').length);
	}

	public function testSameTypeNotFlagged(): Void {
		// `cast(a, A)` — same type; that is redundant-cast's domain (isSubtype is strict).
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, A); } }').length);
	}

	public function testUnrelatedNotFlagged(): Void {
		// `cast(a:A, B)` — unrelated; impossible-cast's domain.
		Assert.equals(0, violations('class A {} class B {} class C { function f(a:A) { var b = cast(a, B); } }').length);
	}

	public function testDowncastNotFlagged(): Void {
		// `cast(b:Base, Sub)` — a downcast may fail at runtime; not redundant.
		Assert.equals(
			0, violations('class Base {} class Sub extends Base {} class C { function f(b:Base) { var x = cast(b, Sub); } }').length
		);
	}

	public function testExternalTypeNotFlagged(): Void {
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, String); } }').length);
	}

	public function testGenericTargetNotFlagged(): Void {
		Assert.equals(0, violations('class A {} class C { function f(a:A) { var b = cast(a, Array<Int>); } }').length);
	}

	public function testCompileTimeCheckNotFlagged(): Void {
		Assert.equals(
			0, violations('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = (s : Base); } }').length
		);
	}

	public function testNonIdentifierOperandNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class Base {} class Sub extends Base {} class C { function f() { var b = cast(make(), Base); } '
				+ 'function make():Sub return null; }'
			).length
		);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> =
			violations('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = cast(s, Base); } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-upcast', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixUnwrapsUpcast(): Void {
		final out: String = applyFix('class Base {} class Sub extends Base {} class C { function f(s:Sub) { var b = cast(s, Base); } }');
		Assert.isTrue(out.indexOf('= s;') != -1, 'expected `= s;`, got: $out');
		Assert.isTrue(out.indexOf('cast(') == -1, 'cast should be gone, got: $out');
	}

	public function testFixLeavesUnrelatedCastAlone(): Void {
		// A non-flagged cast (unrelated types) yields no edits — fix only unwraps proven upcasts.
		final src: String = 'class A {} class B {} class C { function f(a:A) { var b = cast(a, B); } }';
		final check: RedundantUpcast = new RedundantUpcast();
		Assert.equals(0, CheckFixture.edits(check, src).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			CheckFixture.violationsIn(new RedundantUpcast(), [{ file: 'Bad.hx', source: 'class Bad { function f() { var b = cast(a, ' }])
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-upcast'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-upcast'));
	}

	/**
	 * A cast target and the supertype a declared type really extends can share a simple name across packages: only the
	 * declaration the cast names, resolved where it is written, makes the cast an upcast. The second assertion keeps the
	 * namesake in the index, so the first cannot pass by the check going silent on every ambiguous name.
	 */
	@:pin('control') @:killer('M-SUBTYPE-TARGET-SIMPLE-NAME')
	public function testNamesakeSupertypeIsNotTheCastTarget(): Void {
		Assert.equals(0, namesakeUpcasts('Base'), 'a subtype of another package\'s Base is not upcast to this one');
		Assert.equals(1, namesakeUpcasts('pkg.Base'), 'a subtype of this Base still is');
	}

	/**
	 * The operand's type is resolved where it is declared too: a `haxe.io.Eof` local is the std's, not the project's
	 * `my.Eof` that extends `Base`, so `cast(s, Base)` can fail. The twin declaring the project's `Eof` is an upcast.
	 */
	@:pin('control') @:killer('M-SUBTYPE-START-SIMPLE-NAME')
	public function testAnOperandNamedLikeAProjectSubtypeIsNotUpcast(): Void {
		Assert.equals(0, eofUpcasts('haxe.io.Eof'), 'the std Eof is no Base');
		Assert.equals(1, eofUpcasts('Eof'), 'the project Eof is');
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(new RedundantUpcast(), src);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new RedundantUpcast(), src);
	}

	/** `redundant-upcast` findings over two `Base` classes in two packages, `other.Sub` extending `subExtends`. */
	private function namesakeUpcasts(subExtends: String): Int {
		return CheckFixture.violationsIn(new RedundantUpcast(), [
			{ file: 'pkg/Base.hx', source: 'package pkg;\n\nclass Base {}\n' },
			{ file: 'other/Base.hx', source: 'package other;\n\nclass Base {}\n' },
			{ file: 'other/Sub.hx', source: 'package other;\n\nclass Sub extends $subExtends {}\n' },
			{
				file: 'pkg/Main.hx',
				source: 'package pkg;\n\nimport other.Sub;\n\nclass Main {\n\n\tfunction f(s:Sub):Base {\n'
				+ '\t\tfinal b:Base = cast(s, Base);\n\t\treturn b;\n\t}\n\n}\n'
			}
		]).length;
	}

	/** `redundant-upcast` findings over `cast(s, Base)` with `s` declared `operand`, beside `my.Eof extends Base`. */
	private function eofUpcasts(operand: String): Int {
		return CheckFixture.violationsIn(new RedundantUpcast(), [
			{ file: 'my/Base.hx', source: 'package my;\n\nclass Base {}\n' },
			{ file: 'my/Eof.hx', source: 'package my;\n\nclass Eof extends Base {}\n' },
			{
				file: 'my/Main.hx',
				source: 'package my;\n\nclass Main {\n\n\tfunction f(s:$operand):Base {\n\t\tfinal b:Base = cast(s, Base);\n\t\treturn b;\n'
				+ '\t}\n\n}\n'
			}
		]).length;
	}

}
