package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.ShadowingLocal;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `shadowing-local` check: a local declaration whose name an enclosing frame already binds.
 *
 * The positive fixtures cover each frame a binding can come from — an enclosing block, a `switch`
 * arm's enclosing block, the same statement list (a redeclaration), a parameter, and a local
 * function's body over its host's local. The negative ones are the discriminators: two SIBLING
 * `switch` arms and two sibling blocks each declaring the same name are mutually invisible, and a
 * subtree scan of the enclosing function — the shape `CasePatternScan.declaresBefore` uses, which
 * is why this check does not reuse it — would report both. A local sharing its name with a FIELD
 * is the ordinary Haxe idiom and is not a finding; neither is a declaration inside a
 * conditional-compilation region, whose arms are mutually exclusive.
 */
class ShadowingLocalCheckTest extends Test {

	public function testEnclosingBlockLocalFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { var q:Int = 1; { var q:Int = 2; } } }').length);
	}

	public function testSwitchArmOverEnclosingLocalFlagged(): Void {
		Assert.equals(1, violations('class C { function f(v:Int) { var q:Int = 0; switch v { case 1: var q:Int = 1; } } }').length);
	}

	public function testSameBlockRedeclarationFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { var q:Int = 1; var q:Int = 2; } }').length);
	}

	public function testParameterFlagged(): Void {
		final found: Array<Violation> = violations('class C { function f(q:Int) { var q:Int = 1; } }');
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.indexOf('parameter') != -1, 'expected a parameter finding, got: ${found[0].message}');
	}

	public function testLocalFunctionBodyOverHostLocalFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { var q:Int = 1; function g() { var q:Int = 2; } } }').length);
	}

	public function testFinalDeclarationFlagged(): Void {
		Assert.equals(1, violations('class C { function f() { final q:Int = 1; { final q:Int = 2; } } }').length);
	}

	public function testSeverityIsWarning(): Void {
		Assert.equals(Severity.Warning, violations('class C { function f() { var q:Int = 1; var q:Int = 2; } }')[0].severity);
	}

	public function testSiblingSwitchArmsNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(v:Int) { switch v { case 1: var q:Int = 1; case 2: var q:Int = 2; } } }').length);
	}

	public function testSiblingBlocksNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { { var q:Int = 1; } { var q:Int = 2; } } }').length);
	}

	public function testFieldNotFlagged(): Void {
		Assert.equals(0, violations('class C { var q:Int = 0; function f() { var q:Int = 1; } }').length);
	}

	public function testSiblingMethodsNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var q:Int = 1; } function g() { var q:Int = 2; } }').length);
	}

	public function testConditionalRegionNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var q:Int = 1; #if debug var q:Int = 2; #end } }').length);
	}

	public function testNullSafetyRebindNotFlagged(): Void {
		// The narrowing re-bind the language's own null-safety guidance prescribes.
		Assert.equals(0, violations('class Foo {} class C { function f(v:Null<Foo>) { if (v == null) return; final v:Foo = v; } }').length);
	}

	public function testNormalisingRebindNotFlagged(): Void {
		// A parameter re-derived once under its own name — Haxe has no `final` parameter to assign into.
		Assert.equals(0, violations('class C { function f(p:String) { final p:String = p.substr(1); } }').length);
	}

	public function testRebindGateNeedsTheSameName(): Void {
		// The gate is a read of the SHADOWED name, not any read at all.
		Assert.equals(1, violations('class C { function f(p:String, o:String) { final p:String = o.substr(1); } }').length);
	}

	public function testRebindGateIgnoresNestedLambdaBinding(): Void {
		// The read is the LAMBDA's own `q`, a third declaration — not the shadowed local.
		Assert.equals(
			1,
			violations('class C { function f(xs:Array<Int>) { var q:Int = 0; { final q:Null<Int> = xs.filter(q -> q > 0)[0]; } } }').length
		);
	}

	public function testDistinctNamesNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { var q:Int = 1; { var r:Int = 2; } } }').length);
	}

	public function testReportOnly(): Void {
		final src: String = 'class C { function f() { var q:Int = 1; var q:Int = 2; } }';
		final check: ShadowingLocal = new ShadowingLocal();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('shadowing-local'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('shadowing-local'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new ShadowingLocal().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var q:Int = ' }], new HaxeQueryPlugin()).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new ShadowingLocal().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
