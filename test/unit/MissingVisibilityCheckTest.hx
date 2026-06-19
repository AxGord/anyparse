package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.MissingVisibility;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `missing-visibility` check: a class / abstract member without an explicit
 * `public` / `private` modifier is flagged `Warning`. Interface members (implicitly
 * public) and enum-abstract values are exempt; a modifier run carrying a visibility
 * keyword — even behind meta or other modifiers — is not flagged.
 */
class MissingVisibilityCheckTest extends Test {

	public function testBareFieldFlagged(): Void {
		final vs: Array<Violation> = violations('class C { var a:Int; }');
		Assert.equals(1, vs.length);
		Assert.equals('missing-visibility', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testPublicMemberNotFlagged(): Void {
		Assert.equals(0, violations('class C { public var a:Int; }').length);
	}

	public function testPrivateMemberNotFlagged(): Void {
		Assert.equals(0, violations('class C { private function f():Void {} }').length);
	}

	public function testStaticWithoutVisibilityFlagged(): Void {
		// static / inline modifiers present, but no public / private.
		Assert.equals(1, violations('class C { static inline function f():Void {} }').length);
	}

	public function testConstructorWithoutVisibilityFlagged(): Void {
		Assert.equals(1, violations('class C { function new() {} }').length);
	}

	public function testInterfaceMembersNotFlagged(): Void {
		Assert.equals(0, violations('interface I { var a:Int; function f():Void; }').length);
	}

	public function testEnumAbstractValuesNotFlagged(): Void {
		Assert.equals(0, violations('enum abstract E(Int) { final X = 0; final Y = 1; }').length);
	}

	public function testMetaBeforeVisibilityNotFlagged(): Void {
		Assert.equals(0, violations('class C { @:keep public function f():Void {} }').length);
	}

	public function testMetaWithoutVisibilityFlagged(): Void {
		Assert.equals(1, violations('class C { @:keep function f():Void {} }').length);
	}

	public function testFinalClassMemberFlagged(): Void {
		Assert.equals(1, violations('final class C { function f():Void {} }').length);
	}

	public function testAbstractMemberFlagged(): Void {
		Assert.equals(1, violations('abstract A(Int) { function g():Void {} }').length);
	}

	public function testMultipleMembersOnlyUntypedFlagged(): Void {
		// public a + private f are fine; b + g lack visibility.
		Assert.equals(2, violations('class C { public var a:Int; var b:Int; private function f():Void {} function g():Void {} }').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('missing-visibility'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('missing-visibility'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new MissingVisibility().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
