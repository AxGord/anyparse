package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ExplicitLocalType;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * The `explicit-local-type` check: a local `var` / `final` with no `:Type`
 * annotation is flagged (statement-position locals only; a typed local, a macro-
 * reification local, and non-local bindings are exempt). Default OFF — dropped from
 * the default set unless `apqlint.json` opts in (`enabled:true`) or an explicit rule
 * selection bypasses enablement. The autofix annotates ONLY a structurally-pinned
 * initializer type (literal / neg-numeric / written-generic `new` / homogeneous
 * array literal / string-literal-receiver method return), re-stating the compiler's
 * own inference; every inference-resolved shape (empty / heterogeneous array, bare
 * `new`, `new Map()`, `null`, `.map()`, a field read) stays report-only.
 */
class ExplicitLocalTypeCheckTest extends Test {

	// --- detection ---

	public function testUntypedVarFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('var a = 5;'));
		Assert.equals(1, vs.length);
		Assert.equals('explicit-local-type', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testUntypedFinalFlagged(): Void {
		Assert.equals(1, violations(wrap('final a = 5;')).length);
	}

	public function testTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var a:Int = 5;')).length);
	}

	public function testTypedFinalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('final a:String = "x";')).length);
	}

	public function testParameterNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(p):Void {}\n}').length);
	}

	public function testNoInitUntypedFlaggedNoFix(): Void {
		final src: String = wrap('var a;');
		Assert.equals(1, violations(src).length);
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	public function testMacroLocalSkipped(): Void {
		final src: String = 'class C {\n\tmacro static function f() {\n\t\treturn macro {\n\t\t\tvar inside = 5;\n\t\t};\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	// --- fix: structurally-pinned shapes annotated ---

	public function testFixString(): Void {
		assertFixContains("final s = 'hello';", ':String');
	}

	public function testFixInt(): Void {
		assertFixContains('var a = 5;', ':Int');
	}

	public function testFixFloat(): Void {
		assertFixContains('var d = 1.5;', ':Float');
	}

	public function testFixBool(): Void {
		assertFixContains('final b = true;', ':Bool');
	}

	public function testFixNegInt(): Void {
		assertFixContains('var e = -3;', ':Int');
	}

	public function testFixHomogeneousIntArray(): Void {
		assertFixContains('final arr = [1, 2, 3];', ':Array<Int>');
	}

	public function testFixHomogeneousStringArray(): Void {
		assertFixContains("var strs = ['a', 'b'];", ':Array<String>');
	}

	public function testFixNewWithWrittenGenerics(): Void {
		assertFixContains('final m = new Map<String, Int>();', ':Map<String, Int>');
	}


	// --- fix: inference-resolved shapes stay report-only ---

	public function testSkipEmptyArray(): Void {
		assertNoFix('final empty = [];');
	}

	public function testSkipHeterogeneousArray(): Void {
		assertNoFix("var hetero = [1, 'x'];");
	}

	public function testSkipBareNew(): Void {
		assertNoFix('final bare = new Map();');
	}

	public function testSkipNullInit(): Void {
		assertNoFix('final nul = null;');
	}

	public function testSkipGenericMethodCall(): Void {
		assertNoFix("final mapped = ['a'].map(z -> z);");
	}

	public function testSkipStringMethodCall(): Void {
		// a method call is inference / receiver-type dependent — report-only, no fix.
		assertNoFix("final parts = 'a,b'.split(',');");
	}

	public function testIdempotentOnTyped(): Void {
		final src: String = wrap('var a:Int = 5;');
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	// --- enablement gate ---

	public function testDefaultOffSuppressed(): Void {
		Assert.equals(0, runGated(wrap('var a = 5;'), '{}', true).length);
	}

	public function testOptInEnabled(): Void {
		final json: String = '{"rules":{"explicit-local-type":{"enabled":true}}}';
		Assert.equals(1, runGated(wrap('var a = 5;'), json, true).length);
	}

	public function testExplicitSelectionBypassesGate(): Void {
		// applyEnablement=false is the --rule path: a DefaultOff rule runs regardless.
		Assert.equals(1, runGated(wrap('var a = 5;'), '{}', false).length);
	}

	public function testNoqaSuppression(): Void {
		final json: String = '{"rules":{"explicit-local-type":{"enabled":true}}}';
		Assert.equals(0, runGated(wrap('var a = 5; // noqa'), json, true).length);
	}

	// --- registry / robustness ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('explicit-local-type'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('explicit-local-type'));
		Assert.equals(91, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { var a = 5;').length);
	}

	// --- helpers ---

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + body + '\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new ExplicitLocalType().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function runGated(source: String, json: String, applyEnablement: Bool): Array<Violation> {
		final resolver: (String) -> LintConfig = function(file: String): LintConfig return LintConfig.parse(json);
		return Linter.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin(), [new ExplicitLocalType()], resolver, applyEnablement);
	}

	private function assertFixContains(body: String, expected: String): Void {
		final check: ExplicitLocalType = new ExplicitLocalType();
		final src: String = wrap(body);
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length >= 1);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(expected) >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertNoFix(body: String): Void {
		final src: String = wrap(body);
		Assert.equals(0, new ExplicitLocalType().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

}
