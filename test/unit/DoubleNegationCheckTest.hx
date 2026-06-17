package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DoubleNegation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `double-negation` check: a not-node directly wrapping another (`!!x`) is flagged
 * `Info`, report-only. A single `!`, or a `!` wrapping a non-`!` expression, is not.
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

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar b = !!x;\n\t}\n}';
		final check: DoubleNegation = new DoubleNegation();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('double-negation'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('double-negation'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new DoubleNegation().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
