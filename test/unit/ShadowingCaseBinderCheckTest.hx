package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.ShadowingCaseBinder;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

/**
 * The `shadowing-case-binder` check: a bare case-pattern binder that takes a name already
 * declared in scope and never reads it — the shape Haxe turns into a silent catch-all where the
 * author meant a comparison.
 *
 * The premise was verified against the compiler outside this suite: a `case closeAction:` arm
 * over a field of that name fired for every one of three distinct subject values, with no
 * warning. Every refusal fixture below is a MINIMAL PAIR of the firing one.
 */
class ShadowingCaseBinderCheckTest extends Test {

	public function testFieldShadowFlagged(): Void {
		final vs: Array<Violation> = violations(withField('closeAction'));
		Assert.equals(1, vs.length);
		Assert.equals('shadowing-case-binder', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.stringContains('shadows the field', vs[0].message);
		Assert.stringContains('matches EVERY value', vs[0].message);
	}

	/** A name nothing declares is an ordinary capture — `unused-case-binder`'s business, not this rule's. */
	public function testFreeNameRefused(): Void {
		Assert.equals(0, violations(withField('freeName')).length);
	}

	/** A binder the arm READS is a deliberate capture, whatever it shadows. */
	public function testReadBinderRefused(): Void {
		final src: String = 'class C {\n\tvar closeAction: String;\n\n\tfunction f(v: Dynamic): Void {\n\t\tswitch v {'
			+ '\n\t\t\tcase closeAction: r(closeAction);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A parameter of the enclosing function is shadowed just as a field is. */
	public function testParameterShadowFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f(v: Dynamic, mode: String): Void {\n\t\tswitch v {\n\t\t\tcase mode: r();\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('shadows the parameter', vs[0].message);
	}

	/** So is a local declared before the arm. */
	public function testLocalShadowFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(v: Dynamic): Void {\n\t\tfinal mode: String = "x";\n\t\tr(mode);\n\t\tswitch v {'
			+ '\n\t\t\tcase mode: r();\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('shadows the local', vs[0].message);
	}

	/** A local declared AFTER the arm is not in scope there, so nothing is shadowed. */
	public function testLaterLocalRefused(): Void {
		final src: String = 'class C {\n\tfunction f(v: Dynamic): Void {\n\t\tswitch v {\n\t\t\tcase mode: r();\n\t\t}'
			+ '\n\t\tfinal mode: String = "x";\n\t\tr(mode);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A member of a SUPERTYPE is in scope too — resolved through the symbol index the check builds. */
	public function testInheritedFieldShadowFlagged(): Void {
		final src: String = 'class B {\n\tvar closeAction: String;\n}\n\nclass C extends B {\n\tfunction f(v: Dynamic): Void {'
			+ '\n\t\tswitch v {\n\t\t\tcase closeAction: r();\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('shadows the inherited field', vs[0].message);
	}

	/**
	 * A `static inline` field of that name RESOLVES as a pattern constant, so the arm compares
	 * rather than captures and there is no mistake to report.
	 */
	public function testDeclaredConstantRefused(): Void {
		final src: String = 'class C {\n\tstatic inline final mode: String = "x";\n\n\tfunction f(v: Dynamic): Void {\n\t\tswitch v {'
			+ '\n\t\t\tcase mode: r();\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** An uppercase name is a constructor reference by the spelling assumption — never a binder. */
	public function testUppercaseNameRefused(): Void {
		final src: String =
			'class C {\n\tvar Mode: String;\n\n\tfunction f(v: Dynamic): Void {\n\t\tswitch v {\n\t\t\tcase Mode: r();\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/**
	 * A NESTED binder is NOT flagged, though it carries the same misconception. Inside a constructor
	 * pattern a capture is the ordinary reading, and the real-tree instance of this shape (heaps'
	 * `HlslOut`, `case TArray(e, …)` copy-pasted from the arm above) wants `unused-case-binder`'s
	 * "spell it `_`" instead — which a finding here would suppress, since both read one predicate.
	 */
	public function testNestedBinderRefused(): Void {
		final src: String = 'class C {\n\tvar closeAction: String;\n\n\tfunction f(v: Dynamic): Void {\n\t\tswitch v {'
			+ '\n\t\t\tcase Node(closeAction): r();\n\t\t\tcase _: r();\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** Report-only: which of an `==` test, a guard or a free name was meant is the author's call. */
	public function testNoFix(): Void {
		final check: ShadowingCaseBinder = new ShadowingCaseBinder();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final src: String = withField('closeAction');
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin).length);
	}

	public function testRegisteredAsBuiltin(): Void {
		Assert.notNull(Linter.byId('shadowing-case-binder'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('shadowing-case-binder'));
	}

	/** A class declaring `closeAction`, switching on `v` with a lone `case $name:` arm. */
	private function withField(name: String): String {
		return 'class C {\n\tvar closeAction: String;\n\n\tfunction f(v: Dynamic): Void {\n\t\tswitch v {\n\t\t\tcase $name: r();\n\t\t}'
			+ '\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new ShadowingCaseBinder().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
