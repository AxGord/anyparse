package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferInterpolation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-interpolation` check: a single-argument `Std.string(x)` is flagged `Info`
 * and rewritten to string interpolation — `'$x'` for a simple identifier whose declared
 * type is provably not itself nullable, `'${expr}'` for any other interpolation-safe
 * expression. A non-`Std` receiver, a wrong arity, and an argument whose source carries a
 * quote (which `'${ … }'` cannot wrap safely) are left alone. A nested
 * `Std.string(Std.string(x))` is flagged once (outermost only).
 *
 * `Std.string` accepts a nullable value; the interpolation form does not under
 * `@:nullSafety(Strict)` (field access never narrows), so a bare field-access argument
 * (`Std.string(o.f)`) is left alone unconditionally — see the `testFieldAccess*` /
 * `testUnannotatedLocalNotFlagged` / `testNullTypedLocalNotFlagged` /
 * `testDynamicTypedLocalNotFlagged` / `test*ParamNotFlagged` gate tests below.
 */
class PreferInterpolationCheckTest extends Test {

	public function testSimpleIdentFlagged(): Void {
		final vs: Array<Violation> = violations(body('var name: Int = 1;\n\t\tvar y = Std.string(name);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-interpolation', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this Std.string() call can be string interpolation', vs[0].message);
	}

	public function testFieldAccessNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Std.string(o.f)')).length);
	}

	public function testNonStdReceiverNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Foo.string(x)')).length);
	}

	public function testWrongArityNotFlagged(): Void {
		Assert.equals(0, violations(wrap('Std.string(a, b)')).length);
	}

	public function testQuoteArgNotFlagged(): Void {
		Assert.equals(0, violations(wrap("Std.string(c == 'a')")).length);
	}

	public function testNestedFlaggedOnce(): Void {
		Assert.equals(1, violations(wrap('Std.string(Std.string(x))')).length);
	}

	public function testFixSimpleIdent(): Void {
		Assert.equals("'$name'", fixText(body('var name: Int = 1;\n\t\tvar y = Std.string(name);')));
	}

	public function testFixFieldAccessNoEdit(): Void {
		Assert.equals('<0 edits>', fixText(wrap('Std.string(o.f)')));
	}

	public function testFixNested(): Void {
		Assert.equals("'${Std.string(x)}'", fixText(wrap('Std.string(Std.string(x))')));
	}

	public function testFieldAccessInNullCheckedBranchNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(obj: Holder):Void {\n\t\tif (obj.field != null) {\n\t\t\tvar s: String = Std.string(obj.field);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNullTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var n: Null<Int> = null;\n\t\tvar s: String = Std.string(n);')).length);
	}

	public function testDynamicTypedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var d: Dynamic = 1;\n\t\tvar s: String = Std.string(d);')).length);
	}

	public function testOptionalParamNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(?p: Int):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDefaultNullParamNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(p: Int = null):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testUnannotatedLocalNotFlagged(): Void {
		Assert.equals(0, violations(body('var u = make();\n\t\tvar s: String = Std.string(u);')).length);
	}

	public function testNonNullLocalStillFlagged(): Void {
		final vs: Array<Violation> = violations(body('var localNonNull: Int = 1;\n\t\tvar s: String = Std.string(localNonNull);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-interpolation', vs[0].rule);
	}

	public function testFixNonNullLocal(): Void {
		Assert.equals("'$localNonNull'", fixText(body('var localNonNull: Int = 1;\n\t\tvar s: String = Std.string(localNonNull);')));
	}

	public function testNonNullParamStillFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(p: Int):Void {\n\t\tvar s: String = Std.string(p);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testStringTypedLocalStillFlagged(): Void {
		Assert.equals(1, violations(body('var s: String = "a";\n\t\tvar r: String = Std.string(s);')).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-interpolation'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-interpolation'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testConcatHtmlViewRepro(): Void {
		Assert.equals(1, violations(wrap("'<xml>' + xhtml + '</xml>'")).length);
		Assert.equals("'<xml>$xhtml</xml>'", fixText(wrap("'<xml>' + xhtml + '</xml>'")));
	}

	public function testConcatEvalOrderPreserved(): Void {
		Assert.equals("'${a + b}x'", fixText(wrap("a + b + 'x'")));
	}

	public function testConcatIdentBeforeIdentCharBraced(): Void {
		Assert.equals("'a${xhtml}more'", fixText(wrap("'a' + xhtml + 'more'")));
	}

	public function testConcatNumericOperands(): Void {
		Assert.equals("'s${3}${4}'", fixText(wrap("'s' + 3 + 4")));
	}

	public function testConcatSingleIdentPrefixBeforeIdentChar(): Void {
		Assert.equals("'${a}x'", fixText(wrap("a + 'x'")));
	}

	public function testConcatSingleIdentPrefixBeforeNonIdent(): Void {
		Assert.equals("'$a.b'", fixText(wrap("a + '.b'")));
	}

	public function testConcatDollarInSingleLiteral(): Void {
		Assert.equals("'$$$v'", fixText(wrap("'$' + v")));
	}

	public function testConcatDoubleQuotedDollar(): Void {
		Assert.equals("'a$$b$x'", fixText(wrap("\"a$b\" + x")));
	}

	public function testConcatDoubleQuotedEscapedQuote(): Void {
		Assert.equals("'a\"b$x'", fixText(wrap('\"a\\\"b\" + x')));
	}

	public function testConcatParenSubChain(): Void {
		Assert.equals("'a${(b + 'c')}'", fixText(wrap("'a' + (b + 'c')")));
	}

	public function testConcatStdStringOperand(): Void {
		Assert.equals("'a${x}b'", fixText(wrap("'a' + Std.string(x) + 'b'")));
	}

	public function testConcatPureLiteralNotFlagged(): Void {
		Assert.equals(0, violations(wrap("'a' + 'b'")).length);
	}

	public function testConcatNumericOnlyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('a + b')).length);
	}

	public function testConcatInterpolatedOperandSkipped(): Void {
		Assert.equals(0, violations(wrap("'x${y}' + z")).length);
	}

	public function testConcatCommentBetweenOperandsSkipped(): Void {
		Assert.equals(0, violations(wrap("'a' + /* c */ b")).length);
	}

	public function testConcatOperandWithBackslashStringNotFolded(): Void {
		// `'\\'` nested inside a `${}` block mis-lexes in the REAL Haxe compiler
		// ("Unterminated string" - escapes in nested same-quote strings are not
		// processed by the interp-block scanner), even though anyparse's own
		// parser accepts it. Any operand whose source carries a backslash is a
		// safe miss.
		final src: String = "class C { function f(a:String, b:String):String { return a + '/' + b.replace('\\\\', '/'); } }";
		// The backslash-carrying operand must never enter a `${}` - the surviving
		// legal rewrite folds only the clean leading sub-chain (`a + '/'`), leaving
		// `+ b.replace('\\', '/')` outside the string.
		Assert.equals("'$a/'", fixText(src));
	}

	public function testConcatInsideInterpolationBlockNotFolded(): Void {
		// A `+` chain that itself sits INSIDE a `${...}` interpolation block must
		// not fold - the result would nest an interpolated string inside an
		// interpolation block (fragile in the real compiler's interp scanner).
		final src: String = "class C { function f(t:String):String { return 'x${t.split('a').join(q() + \"n\")}y'; } }";
		Assert.equals(0, violations(src).length);
	}

	private function wrap(expr: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x = ' + expr + ';\n\t}\n}';
	}

	/** A class fixture whose method body is `stmts` — for gate tests that declare their own typed locals. */
	private function body(stmts: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + stmts + '\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferInterpolation().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixText(src: String): String {
		final check: PreferInterpolation = new PreferInterpolation();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length == 1 ? edits[0].text : '<' + edits.length + ' edits>';
	}

}
