package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferInline;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * The `prefer-inline` check: a single-expression method (an arrow body or a block with one
 * `return` / expression statement) markable `inline`, per the user's rule. `Severity.Info`,
 * `--fix` inserts `inline ` before the `function` keyword. Soundness misses: a method
 * referenced as a value anywhere (bare / `.bind` / argument), an `override` / subtype-overridden
 * method, an interface-declared method, a `dynamic` / `macro` / constructor / `@:keep` /
 * `Reflect`-string-accessed method, and a self-recursive body.
 */
class PreferInlineCheckTest extends Test {

	public function testArrowGetterFlagged(): Void {
		final vs: Array<Violation> = violations(cls('function get_date():String return _field.text;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-inline', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testDelegationWrapperFlagged(): Void {
		Assert.equals(1, violations(cls('public function stop():Void _other.stop();')).length);
	}

	public function testBlockSingleReturnFlagged(): Void {
		Assert.equals(1, violations(cls('function three():Int { return 3; }')).length);
	}

	public function testBlockSingleExprStmtFlagged(): Void {
		Assert.equals(1, violations(cls('function ping():Void { _other.ping(); }')).length);
	}

	public function testFinalClassFlagged(): Void {
		Assert.equals(1, violations('final class C {\n\tfunction one():Int return 1;\n}').length);
	}

	public function testMultiStatementNotFlagged(): Void {
		Assert.equals(0, violations(cls('function two():Int { step(); return 3; }')).length);
	}

	public function testEmptyBodyNotFlagged(): Void {
		Assert.equals(0, violations(cls('function noop():Void {}')).length);
	}

	public function testAlreadyInlineNotFlagged(): Void {
		Assert.equals(0, violations(cls('inline function one():Int return 1;')).length);
	}

	public function testDynamicNotFlagged(): Void {
		Assert.equals(0, violations(cls('dynamic function one():Int return 1;')).length);
	}

	public function testMacroNotFlagged(): Void {
		Assert.equals(0, violations(cls('macro static function one():Int return 1;')).length);
	}

	public function testOverrideNotFlagged(): Void {
		Assert.equals(0, violations(cls('override function one():Int return 1;')).length);
	}

	public function testConstructorNotFlagged(): Void {
		Assert.equals(0, violations(cls('function new() init();')).length);
	}

	public function testKeepNotFlagged(): Void {
		Assert.equals(0, violations(cls('@:keep function one():Int return 1;')).length);
	}

	public function testSelfRecursiveNotFlagged(): Void {
		Assert.equals(0, violations(cls('function fac(n:Int):Int return n <= 1 ? 1 : n * fac(n - 1);')).length);
	}

	public function testThisRecursiveNotFlagged(): Void {
		Assert.equals(0, violations(cls('function loop():Void this.loop();')).length);
	}

	public function testMethodValueReferenceSkipsTarget(): Void {
		final vs: Array<Violation> = violations(cls('function target():Int return 1;\n\tfunction caller():Void use(target);'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('caller') >= 0);
	}

	public function testBindReferenceSkips(): Void {
		final vs: Array<Violation> = violations(cls('function handler():Void act();\n\tfunction wire():Void listen(handler.bind());'));
		Assert.isFalse(hasMethod(vs, 'handler'));
	}

	public function testReflectStringSkips(): Void {
		final vs: Array<Violation> = violations(cls('function foo():Int return 1;\n\tfunction r():Void Reflect.callMethod(o, "foo", []);'));
		Assert.isFalse(hasMethod(vs, 'foo'));
	}

	public function testSubtypeOverrideSkips(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'B.hx', source: 'class B {\n\tfunction f():Int return 1;\n}' },
			{ file: 'S.hx', source: 'class S extends B {\n\toverride function f():Int return 2;\n}' }
		];
		Assert.equals(0, new PreferInline().run(files, new HaxeQueryPlugin()).length);
	}

	public function testInterfaceImplSkips(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'I.hx', source: 'interface I {\n\tfunction f():Int;\n}' },
			{ file: 'C.hx', source: 'class C implements I {\n\tfunction f():Int return 1;\n}' }
		];
		Assert.equals(0, new PreferInline().run(files, new HaxeQueryPlugin()).length);
	}

	public function testFixInsertsInline(): Void {
		final src: String = cls('public function one():Int return 1;');
		final check: PreferInline = new PreferInline();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('inline function one') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function cls(members: String): String {
		return 'class C {\n\t$members\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferInline().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function hasMethod(vs: Array<Violation>, name: String): Bool {
		for (v in vs) if (v.message.indexOf('\'$name\'') >= 0) return true;
		return false;
	}

}
