package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DoubleNegation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `double-negation` check: a not-node directly wrapping another (`!!x`) is flagged `Info`; `fix` strips it when the
 * operand is provably non-null. A single `!`, or a `!` wrapping a non-`!`
 * expression, is not.
 */
class DoubleNegationCheckTest extends Test {

	public function testDoubleNegationFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tvar b = !!x;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('double-negation', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('redundant double negation', vs[0].message);
	}

	public function testSingleNegationNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = !x;\n\t}\n}').length);
	}

	public function testNotOfNonNotNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = !(a && c);\n\t}\n}').length);
	}

	public function testTripleNegationFlaggedOnce(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = !!!x;\n\t}\n}').length);
	}

	public function testFixStripsDoubleNegation(): Void {
		Assert.equals(wrap('var b = x;'), applyFix(wrap('var b = !!x;')));
	}

	public function testFixStripsParenOperand(): Void {
		Assert.equals(wrap('var b = (a && c);'), applyFix(wrap('var b = !!(a && c);')));
	}

	public function testFixTripleNegationToSingle(): Void {
		// An odd-length chain keeps a leading `!`, so the result is always a definite Bool.
		Assert.equals(wrap('var b = !x;'), applyFix(wrap('var b = !!!x;')));
	}

	public function testFixLeavesNullableCallOperand(): Void {
		// `!!foo()` coerces a possibly-null call result; bare `foo()` would not — left alone.
		final src: String = wrap('var b = !!foo();');
		Assert.equals(src, applyFix(src));
	}

	public function testFixLeavesNullableFieldOperand(): Void {
		final src: String = wrap('var b = !!obj.flag;');
		Assert.equals(src, applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('double-negation'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('double-negation'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testMacroReificationSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar e = macro !!x;\n\t}\n}').length);
	}

	private function violations(src: String): Array<Violation> {
		return new DoubleNegation().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Wrap a single statement body in a minimal class+function so it parses. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + body + '\n\t}\n}';
	}

	private function applyFix(src: String): String {
		final check: DoubleNegation = new DoubleNegation();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
