package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedCaseBinder;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `unused-case-binder` check: a case-pattern binder that neither the arm's guard
 * nor its body reads is flagged `Warning`, and the fix spells it `_`.
 *
 * The fixtures come in pairs — the shape that unbinds, and the neighbouring shape that
 * must not. Every gate defends one way the rewrite could change meaning: a read
 * anywhere in the arm (guard, body, interpolation, a nested arm's own label), an
 * or-pattern alternative that still reads the name, a bare identifier that names a
 * declared `enum` / `enum abstract` value rather than a binder, and a whole-pattern
 * identifier outside the switch's LAST arm, where the constant reading and the binder
 * reading stop agreeing.
 */
class UnusedCaseBinderCheckTest extends Test {

	/** The reported message for the canary's unread binder. */
	private static inline final CANARY_MESSAGE: String = 'case binder \'_data\' is never read; replace it with _';

	public function testCanaryFlagged(): Void {
		final vs: Array<Violation> = violations(canary());
		Assert.equals(1, vs.length);
		Assert.equals('unused-case-binder', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(CANARY_MESSAGE, vs[0].message);
	}

	/** The canary's trailing catch-all binder becomes the wildcard, body untouched. */
	public function testCanaryFixed(): Void {
		final out: String = applyFixOnce(canary());
		Assert.stringContains('case _:', out);
		Assert.isFalse(StringTools.contains(out, '_data'), 'the binder is gone');
		Assert.stringContains('t("User", 10150)', out);
	}

	/** A constructor argument nothing reads becomes `_`; its used sibling keeps its name. */
	public function testConstructorArgumentUnbound(): Void {
		final out: String = applyFixOnce(sw('case Node(x, y): use(y);'));
		Assert.stringContains('case Node(_, y):', out);
	}

	/** An array-pattern element nothing reads becomes `_`. */
	public function testArrayElementUnbound(): Void {
		Assert.stringContains('case [_, b]:', applyFixOnce(sw('case [a, b]: use(b);')));
	}

	/** A structure-pattern field's value nothing reads becomes `_`; the field LABEL is not a binder. */
	public function testStructureFieldValueUnbound(): Void {
		final out: String = applyFixOnce(sw('case {name: n, age: k}: use(k);'));
		Assert.stringContains('case {name: _, age: k}:', out);
	}

	/** An unread `=`-capture head is DROPPED rather than spelled `_ =`, leaving the sub-pattern alone. */
	public function testAssignCaptureHeadDropped(): Void {
		final out: String = applyFixOnce(sw('case c = Foo(1): use(1);'));
		Assert.stringContains('case Foo(1):', out);
		Assert.isFalse(StringTools.contains(out, '='), 'the capture head is dropped, not wildcarded');
	}

	/** A `case var q:` capture is a binder by SYNTAX, so it needs no position gate to become `_`. */
	public function testVarCaptureUnbound(): Void {
		final out: String = applyFixOnce(sw('case A: p();\n\t\t\tcase var q: r();'));
		Assert.stringContains('case _:', out);
		Assert.isFalse(StringTools.contains(out, 'var q'), 'the capture is gone');
	}

	/** A GUARD read is a read: the binder stays. */
	public function testGuardReadKeepsBinder(): Void {
		Assert.equals(0, violations(sw('case p if (p > 0): r();')).length);
	}

	/** A BODY read is a read. */
	public function testBodyReadKeepsBinder(): Void {
		Assert.equals(0, violations(sw('case Node(x, y): use(x, y);')).length);
	}

	/** A `'$x'` string-interpolation read is not an identifier node, and still counts. */
	public function testInterpolationReadKeepsBinder(): Void {
		Assert.equals(0, violations(sw("case Node(x, y): use(y, '$x');")).length);
	}

	/** A nested arm RE-BINDING the name is a mention too — the outer binder is left alone. */
	public function testNestedRebindingKeepsBinder(): Void {
		Assert.equals(0, violations(sw('case Node(x, y): switch y {\n\t\t\t\tcase x: use(x);\n\t\t\t}')).length);
	}

	/** An or-pattern binds the same set in every alternative, so ONE finding carries BOTH edits. */
	public function testOrPatternUnboundTogether(): Void {
		final src: String = sw('case A(x), B(x): r();');
		Assert.equals(1, violations(src).length);
		Assert.stringContains('case A(_), B(_):', applyFixOnce(src));
	}

	/** One alternative still reading the name blocks the whole group — a partial unbind would not compile. */
	public function testOrPatternWithReadKeepsBothBinders(): Void {
		Assert.equals(0, violations(sw('case A(x), B(x): use(x);')).length);
	}

	/** A whole-pattern bare identifier outside the LAST arm is refused: under the constant reading it would kill the arms below. */
	public function testWholePatternBinderNotLastRefused(): Void {
		Assert.equals(0, violations(sw('case q: p();\n\t\t\tcase B: r();')).length);
	}

	/** The same identifier in the last arm IS unbound — both readings agree there. */
	public function testWholePatternBinderLastFlagged(): Void {
		Assert.equals(1, violations(sw('case B: r();\n\t\t\tcase q: p();')).length);
	}

	/** A bare identifier naming a declared `enum` value is a CONSTANT, not a binder — never widened to `_`. */
	public function testDeclaredEnumConstantRefused(): Void {
		Assert.equals(0, violations('enum E { alpha; beta; }\n' + sw('case beta: r();\n\t\t\tcase alpha: p();')).length);
	}

	/** The same guard covers an `enum abstract` value, which resolves unqualified in a pattern just as well. */
	public function testDeclaredEnumAbstractValueRefused(): Void {
		final decl: String = 'enum abstract K(String) { var one = "one"; var two = "two"; }\n';
		Assert.equals(0, violations(decl + sw('case two: r();\n\t\t\tcase one: p();')).length);
	}

	/** A capitalised bare identifier is a constructor reference by the family spelling — never a binder. */
	public function testCapitalisedIdentifierNotABinder(): Void {
		Assert.equals(0, violations(sw('case Alpha: r();')).length);
	}

	/** The wildcard itself binds nothing, so there is nothing to report. */
	public function testWildcardNotFlagged(): Void {
		Assert.equals(0, violations(sw('case _: r();')).length);
	}

	/** An arm holding a conditional-compilation region is skipped: its arm run cannot be enumerated. */
	public function testConditionalCompilationArmSkipped(): Void {
		Assert.equals(0, violations(sw('case Node(x, y):\n\t\t\t\t#if debug\n\t\t\t\tuse(y);\n\t\t\t\t#end')).length);
	}

	/** After the fix every flagged name is `_`, which is never a binder — a second pass finds nothing. */
	public function testFixIsIdempotent(): Void {
		Assert.equals(0, violations(applyFixOnce(canary())).length);
	}

	public function testRegisteredAsBuiltin(): Void {
		Assert.notNull(Linter.byId('unused-case-binder'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unused-case-binder'));
	}

	/** The canary: the trailing arm binds `_data` and never reads it. */
	private function canary(): String {
		return 'class C {\n\tfunction f(data: Dynamic): String {\n\t\treturn switch data.role {\n\t\t\tcase "Owner": t("Owner", 10149);'
			+ '\n\t\t\tcase "User": t("User", 10150);\n\t\t\tcase _data: t("User", 10150);\n\t\t}\n\t}\n}';
	}

	/** A statement switch over `v` holding `branches`. */
	private function sw(branches: String): String {
		return 'class C {\n\tfunction f(v: Dynamic): Void {\n\t\tswitch v {\n\t\t\t$branches\n\t\t}\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new UnusedCaseBinder().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final check: UnusedCaseBinder = new UnusedCaseBinder();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer, `reformat` on so the minimal fixture need not be canonical. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, fixEdits(src), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}


	/**
	 * A LEGACY `@:enum abstract` projects as a plain abstract with no marker the scan can
	 * read, so the constant set has to reach EVERY abstract member, not only the modern
	 * `enum abstract` kind. Without that, `case Ace(hearts):` reads as a binder and the
	 * rewrite silently shadows the arm below it.
	 */
	public function testLegacyEnumAbstractValueRefused(): Void {
		final decl: String = '@:enum abstract Suit(Int) { var hearts = 1; var spades = 2; }\n';
		Assert.equals(0, violations(decl + sw('case Ace(hearts): r();\n\t\t\tcase Ace(spades): p();')).length);
	}


	/**
	 * A `static inline` field resolves unqualified in a pattern exactly as an enum value
	 * does, and it is declared by an ORDINARY class — the shape that made the first
	 * version of gate 1 emit code that compiled and behaved differently.
	 */
	public function testStaticInlineConstantRefused(): Void {
		final src: String = 'class C {\n\tstatic inline final one: String = "x";\n\n\tfunction f(v: String): Void {\n\t\tswitch v {'
			+ '\n\t\t\tcase "q": p();\n\t\t\tcase one: r();\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}


	/**
	 * `case A | B:` is Haxe's OTHER or-pattern spelling and projects as a bitwise-or node
	 * the pattern whitelist does not model, so `binders` refuses the arm. That refusal is
	 * the load-bearing property of the whitelist design — pinned here rather than left to
	 * hold by accident.
	 */
	public function testUnmodelledOrPatternRefused(): Void {
		Assert.equals(0, violations(sw('case A(x) | B(x): r();')).length);
	}


	/** A reification subtree may splice in a read no source scan resolves, so an arm inside one is skipped. */
	public function testReificationArmSkipped(): Void {
		final src: String =
			'class C {\n\tmacro function f(): Expr {\n\t\treturn macro switch v {\n\t\t\tcase Node(x, y): use(y);\n\t\t};\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

}
