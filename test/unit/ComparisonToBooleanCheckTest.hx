package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.ComparisonToBoolean;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `comparison-to-boolean` check: a comparison against a boolean literal
 * (`x == true`, `x != false`, `true == x`) is flagged `Info` when the operand is
 * provably non-null Bool. A bare identifier goes through the declared-type gate:
 * flagged only when its declared type proves non-null Bool; a `Null<Bool>` /
 * optional-param / unannotated identifier stays silent (its `== true` may be
 * load-bearing under strict null-safety). An operand whose nullness the check
 * cannot rule out — a `?.` access, a call / `Map.get` result, a
 * possibly-`@:optional` field — is SKIPPED too. `fix` rewrites only a
 * boolean-operator operand. Comparisons inside macro reification are skipped.
 */
class ComparisonToBooleanCheckTest extends Test {

	public function testEqTrueFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = x == true;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('comparison-to-boolean', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('comparison against a boolean literal', vs[0].message);
	}

	public function testNeqFalseFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = x != false;\n\t}\n}').length);
	}

	public function testLiteralOnLeftFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = true == x;\n\t}\n}').length);
	}

	/**
	 * A `Null<Bool>` local's `== true` is load-bearing under strict null-safety
	 * (three-state check) — the declared-type gate keeps it silent.
	 */
	public function testNullableBoolIdentSkipped(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tfinal x:Null<Bool> = g();\n\t\tvar b = x == true;\n\t}\n}').length
		);
	}

	/** An unannotated / unresolvable identifier cannot be verified non-null — silent. */
	public function testUnannotatedIdentSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = x == true;\n\t}\n}').length);
	}

	/** An optional `?x:Bool` param is nullable despite the Bool annotation — silent. */
	public function testOptionalBoolParamSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(?x:Bool):Void {\n\t\tvar b = x == true;\n\t}\n}').length);
	}

	/** A declared non-null `Bool` local is a genuine redundancy — flagged. */
	public function testDeclaredBoolLocalFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tfinal x:Bool = a > c;\n\t\tvar b = x == true;\n\t}\n}').length);
	}

	public function testBooleanExprOperandFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tvar b = (a > c) == true;\n\t}\n}').length);
	}

	public function testNullSafeOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = obj?.ready() == true;\n\t}\n}').length);
	}

	public function testNullSafeFieldSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = obj?.flag == false;\n\t}\n}').length);
	}

	public function testNoBooleanLiteralNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = x == c;\n\t}\n}').length);
	}

	public function testBothBooleanLiteralsNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = true == true;\n\t}\n}').length);
	}

	public function testFixRewritesComparisonOperand(): Void {
		Assert.equals(wrap('var b = x < y;'), applyFix(wrap('var b = x < y == true;')));
	}

	public function testFixRewritesParenAndOperand(): Void {
		Assert.equals(wrap('var b = (a && c);'), applyFix(wrap('var b = (a && c) != false;')));
	}

	public function testFixRewritesNotOperand(): Void {
		Assert.equals(wrap('var b = !flag;'), applyFix(wrap('var b = !flag == true;')));
	}

	public function testFixLiteralOnLeftBoolOp(): Void {
		Assert.equals(wrap('var b = (a && c);'), applyFix(wrap('var b = true == (a && c);')));
	}

	public function testFixLeavesBareIdentifier(): Void {
		// An unannotated / unresolvable identifier cannot be proven non-null Bool, so it is
		// neither reported nor stripped — unlike a declared-Bool ident, which fix now rewrites.
		final src: String = wrap('var b = x == true;');
		Assert.equals(src, applyFix(src));
	}

	public function testFixParenthesizedNegation(): Void {
		Assert.equals(wrap('var b = !(a > c);'), applyFix(wrap('var b = (a > c) == false;')));
	}

	public function testFixWrapsBareComparisonNegation(): Void {
		// `a < c` is neither a bare identifier nor parenthesized, so `!` must wrap it.
		Assert.equals(wrap('var b = !(a < c);'), applyFix(wrap('var b = a < c == false;')));
	}

	public function testFixLeavesNullableOperand(): Void {
		final src: String = wrap('var b = obj.flag == true;');
		Assert.equals(src, applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('comparison-to-boolean'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('comparison-to-boolean'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testCallOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = map.get(k) == true;\n\t}\n}').length);
	}

	public function testFieldAccessOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar b = obj.flag == true;\n\t}\n}').length);
	}

	public function testMacroReificationSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar e = macro x == true;\n\t}\n}').length);
	}

	/**
	 * An array element (`ps[i]`) is neither a boolean-operator result nor a bare identifier with a
	 * declared non-null Bool type, so it is not provably non-null Bool — its `== true` may be
	 * load-bearing (a `Null<Bool>` / `Dynamic` element under strict null-safety). It stays silent,
	 * matching `fix`, which refuses to strip a non-boolean-operator operand.
	 */
	public function testArrayAccessOperandSkipped(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(ps:Array<Dynamic>):Void {\n\t\tvar b = ps[5] == true;\n\t}\n}').length);
	}

	/** A declared non-null Bool local is provably Bool — `== true` collapses to the operand. */
	public function testFixStripsDeclaredBoolLocal(): Void {
		Assert.equals(wrap('final x:Bool = a > c;\n\t\tvar b = x;'), applyFix(wrap('final x:Bool = a > c;\n\t\tvar b = x == true;')));
	}

	/**
	 * A non-null Bool parameter: `!= true` collapses to its negation.
	 */
	public function testFixNegatesDeclaredBoolParam(): Void {
		Assert.equals(
			'class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = !x;\n\t}\n}',
			applyFix('class C {\n\tfunction f(x:Bool):Void {\n\t\tvar b = x != true;\n\t}\n}')
		);
	}

	/** A `(get, set):Bool` property resolves to a non-null Bool field — `== false` collapses to `!flag`. */
	public function testFixStripsBoolProperty(): Void {
		Assert.equals(
			'class C {\n\tpublic var flag(get, set):Bool;\n\tfunction f():Void {\n\t\tvar b = !flag;\n\t}\n}',
			applyFix('class C {\n\tpublic var flag(get, set):Bool;\n\tfunction f():Void {\n\t\tvar b = flag == false;\n\t}\n}')
		);
	}

	private function violations(src: String): Array<Violation> {
		return new ComparisonToBoolean().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Wrap a single statement body in a minimal class+function so it parses. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	private function applyFix(src: String): String {
		final check: ComparisonToBoolean = new ComparisonToBoolean();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
