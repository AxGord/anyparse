package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.CatchDynamic;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `catch-dynamic` check: a `catch` clause whose declared exception type is
 * `Dynamic` (or `Any`) is flagged `Warning` (prefer `catch (exception:Exception)`).
 * A typed catch of any other name (`Exception`, a custom class, `String`) and an
 * untyped `catch (e)` are not flagged. Report-only — `fix` yields no edits.
 */
class CatchDynamicCheckTest extends Test {

	public function testDynamicFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Dynamic) {}\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('catch-dynamic', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('catch type \'Dynamic\' is a raw catch-all — prefer catch (exception:Exception)', vs[0].message);
	}

	public function testDynamicSpanIsParameterRegion(): Void {
		final src: String = 'class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Dynamic) {}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('(e:Dynamic)', src.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testAnyFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Any) {}\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('catch type \'Any\' is a raw catch-all — prefer catch (exception:Exception)', vs[0].message);
	}

	public function testExceptionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Exception) {}\n\t}\n}').length);
	}

	public function testCustomTypeNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:MyError) {}\n\t}\n}').length);
	}

	public function testStringNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:String) {}\n\t}\n}').length);
	}

	public function testUntypedCatchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e) {}\n\t}\n}').length);
	}

	public function testMixedCatchesFlagsOnlyDynamic(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Dynamic) {} catch (x:Exception) {}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('catch type \'Dynamic\' is a raw catch-all — prefer catch (exception:Exception)', vs[0].message);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tpublic function f():Void {\n\t\ttry g() catch (e:Dynamic) {}\n\t}\n}';
		final check: CatchDynamic = new CatchDynamic();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('catch-dynamic'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('catch-dynamic'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { try {').length);
	}

	private function violations(src: String): Array<Violation> {
		return new CatchDynamic().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
