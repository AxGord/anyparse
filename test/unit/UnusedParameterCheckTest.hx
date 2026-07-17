package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedParameter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `unused-parameter` check: a function parameter never referenced in its
 * body is flagged. Used parameters, `_`-prefixed parameters, body-less
 * (interface / abstract) method declarations, and methods of a type carrying a
 * supertype clause (`extends` / `implements`, a contract candidate) are not
 * flagged. A named local function or a confined private method whose call set is
 * provably complete within the file is `Warning`, and `fix` removes the
 * parameter plus its in-file call arguments. A public / unconfined method
 * stays `Info` — its callers may be cross-file (use the `remove-param` op).
 */
class UnusedParameterCheckTest extends Test {

	public function testUnusedParameterFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('unused-parameter', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('unused parameter \'value\'', vs[0].message);
	}

	public function testUsedParameterNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(value:Int):Void {\n\t\tg(value);\n\t}\n}').length);
	}

	public function testUnderscorePrefixNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(_value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testImplementsContractNotFlagged(): Void {
		Assert.equals(0, violations('class C implements I {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testExtendsContractNotFlagged(): Void {
		Assert.equals(0, violations('class C extends B {\n\tpublic function f(value:Int):Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testInterfaceMethodNotFlagged(): Void {
		Assert.equals(0, violations('interface I {\n\tfunction f(value:Int):Void;\n}').length);
	}

	public function testLocalFunctionParameterFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function m():Void {\n\t\tfunction inner(value:Int):Void {\n\t\t\tg();\n\t\t}\n\t\tinner(1);\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('unused parameter \'value\'', vs[0].message);
		// A named local function called directly is the autofixable subset.
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testParameterUsedInSiblingDefaultNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f(a:Int, b:Int = a):Void {\n\t\tg(b);\n\t}\n}').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unused-parameter'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unused-parameter'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(').length);
	}

	public function testLocalFunctionParameterAutofixed(): Void {
		final src: String = 'class C {\n\tpublic function m():Void {\n\t\tfunction inner(value:Int):Void {\n\t\t\tg();\n\t\t}\n\t\tinner(1);\n\t}\n}';
		Assert.equals(
			'class C {\n\tpublic function m():Void {\n\t\tfunction inner():Void {\n\t\t\tg();\n\t\t}\n\t\tinner();\n\t}\n}', applyFix(src)
		);
	}

	public function testConfinedPrivateMethodParameterAutofixed(): Void {
		final src: String = 'class C {\n\tprivate function h(a:Int, b:Int):Int {\n\t\treturn a;\n\t}\n\n\tfunction u():Int {\n\t\treturn h(1, 2);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(
			'class C {\n\tprivate function h(a:Int):Int {\n\t\treturn a;\n\t}\n\n\tfunction u():Int {\n\t\treturn h(1);\n\t}\n}',
			applyFix(src)
		);
	}

	public function testPublicMethodParameterReportOnly(): Void {
		// A public method's callers may live in other files — the lint cannot prove
		// the call set complete, so it stays `Info` and `fix` leaves it untouched.
		final src: String = 'class C {\n\tpublic function f(x:Int, unused:Int):Int {\n\t\treturn x;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(src, applyFix(src));
	}

	public function testLocalFunctionPassedByValueNotAutofixed(): Void {
		// `inner` is captured as a value (passed to `take`), so its call set cannot
		// be proven complete — the unused parameter stays `Info`, not autofixed.
		final src: String = 'class C {\n\tpublic function m():Void {\n\t\tfunction inner(value:Int):Void {\n\t\t\tg();\n\t\t}\n\t\ttake(inner);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(src, applyFix(src));
	}

	private function violations(src: String): Array<Violation> {
		return new UnusedParameter().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: UnusedParameter = new UnusedParameter();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}


	public function testDynamicFunctionParameterNotFlagged(): Void {
		// `dynamic` marks a reassignable callback slot — an assigner elsewhere relies
		// on the signature, so an unreferenced param in the default body is by
		// design, not dead code. The whole function is skipped, never autofixed.
		final src: String = 'class C {\n\tpublic static dynamic function cb(value:Bool):Void {}\n\n\tpublic static function assign():Void {\n\t\tcb = v -> trace(v);\n\t}\n}';
		Assert.equals(0, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

}
