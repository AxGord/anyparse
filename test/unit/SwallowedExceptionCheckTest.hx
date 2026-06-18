package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.SwallowedException;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `swallowed-exception` check: a `catch` whose non-empty body ignores the
 * caught exception (neither references the variable nor rethrows) is flagged
 * `Warning`. A handler that uses the variable, rethrows, has an empty body
 * (left to `empty-block`), or names the variable `_` (intentional discard) is
 * not flagged. Report-only — `fix` yields no edits.
 */
class SwallowedExceptionCheckTest extends Test {

	public function testSwallowingCatchFlagged(): Void {
		final vs: Array<Violation> =
			violations(
				'class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\ttrace("oops");\n\t\t}\n\t}\n}'
			);
		Assert.equals(1, vs.length);
		Assert.equals('swallowed-exception', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('exception \'e\' is caught but ignored', vs[0].message);
	}

	public function testRecoveryReturnNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic function f():Int {\n\t\ttry { return g(); } catch (e:Exception) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testBareReturnNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\tcleanup();\n\t\t\treturn;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testExpressionRecoveryNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tpublic function f():Void {\n\t\tfinal x = try g() catch (e:Exception) null;\n\t}\n}').length
		);
	}

	public function testCatchUsingVariableNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\ttrace(e);\n\t\t}\n\t}\n}').length
		);
	}

	public function testRethrowNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\tthrow new Foo();\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testEmptyCatchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {}\n\t}\n}').length);
	}

	public function testUnderscoreDiscardNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (_:Exception) {\n\t\t\ttrace("x");\n\t\t}\n\t}\n}').length
		);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\ttrace("oops");\n\t\t}\n\t}\n}';
		final check: SwallowedException = new SwallowedException();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('swallowed-exception'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('swallowed-exception'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { try {').length);
	}

	private function violations(src: String): Array<Violation> {
		return new SwallowedException().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
