package unit;

import utest.Assert;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Idempotency round-trip tests for the macro-generated writer.
 *
 * Invariant: `fastWrite(parse(fastWrite(parse(s)))) == fastWrite(parse(s))`.
 * The first write normalises formatting; the second write must produce
 * identical output, proving the generated writer emits parseable, stable text.
 */
class HaxeWriterRoundTripTest extends HxTestHelpers {

	private function testEmptyModule(): Void {
		roundTrip('', 'empty');
	}

	private function testEmptyClass(): Void {
		roundTrip('class Foo {}');
	}

	private function testClassWithVar(): Void {
		roundTrip('class Foo { var x:Int; }');
	}

	private function testClassWithVarInit(): Void {
		roundTrip('class Foo { var x:Int = 42; }');
	}

	private function testClassWithFunction(): Void {
		roundTrip('class Foo { function bar():Void {} }');
	}

	private function testFunctionWithParams(): Void {
		roundTrip('class Foo { function bar(x:Int, y:Float):Void {} }');
	}

	private function testFunctionWithBody(): Void {
		roundTrip('class Foo { function f():Void { var x:Int = 1; return x; } }');
	}

	private function testModifiers(): Void {
		roundTrip('class Foo { public static var x:Int; }');
	}

	private function testMultiDecl(): Void {
		roundTrip('class A {} class B {}');
	}

	private function testExprAtoms(): Void {
		roundTrip('class F { var x:Int = 42; var y:Float = 3.14; var b:Bool = true; }');
	}

	private function testExprArithmetic(): Void {
		roundTrip('class F { var x:Int = 1 + 2 * 3; }');
	}

	private function testExprPrefix(): Void {
		roundTrip('class F { var x:Int = -1; var y:Bool = !true; }');
	}

	private function testExprPostfix(): Void {
		roundTrip('class F { function f():Void { var x:Int = a.b; var y:Int = a[0]; var z:Int = f(1, 2); } }');
	}

	private function testExprAssignment(): Void {
		roundTrip('class F { function f():Void { var x:Int = a = b = 1; } }');
	}

	private function testExprComparison(): Void {
		roundTrip('class F { var x:Bool = a == b; }');
	}

	private function testExprLogical(): Void {
		roundTrip('class F { var x:Bool = a && b || c; }');
	}

	private function testExprBitwise(): Void {
		roundTrip('class F { var x:Int = a | b & c; }');
	}

	private function testExprShift(): Void {
		roundTrip('class F { var x:Int = a << 2; }');
	}

	private function testExprTernary(): Void {
		roundTrip('class F { var x:Int = a ? b : c; }');
	}

	private function testExprNullCoal(): Void {
		roundTrip('class F { var x:Int = a ?? b; }');
	}

	private function testExprParens(): Void {
		roundTrip('class F { var x:Int = (a + b) * c; }');
	}

	private function testExprNew(): Void {
		roundTrip('class F { function f():Void { var x:Int = new Foo(1, 2); } }');
	}

	private function testExprArray(): Void {
		roundTrip('class F { function f():Void { var x:Int = [1, 2, 3]; } }');
	}

	private function testExprArrow(): Void {
		roundTrip('class F { var x:Int = a => b; }');
	}

	private function testFnDeclNoReturnType(): Void {
		roundTrip('class F { function main() {} }');
	}

	private function testFnDeclNoReturnTypeWithBody(): Void {
		roundTrip('class F { function main() { return 1; } }');
	}

	private function testObjectLitEmpty(): Void {
		roundTrip('class F { var x:Dynamic = {}; }');
	}

	private function testObjectLitSingle(): Void {
		roundTrip('class F { var x:Dynamic = {a: 1}; }');
	}

	private function testObjectLitMultiple(): Void {
		roundTrip('class F { var x:Dynamic = {a: 1, b: 2}; }');
	}

	private function testObjectLitNested(): Void {
		roundTrip('class F { var x:Dynamic = {outer: {inner: 1}}; }');
	}

	private function testExprParenLambda(): Void {
		roundTrip('class F { function f():Void { var x:Int = (a:Int) => a + 1; } }');
	}

	private function testIfStmt(): Void {
		roundTrip('class F { function f():Void { if (x) return 1; } }');
	}

	private function testIfElseStmt(): Void {
		roundTrip('class F { function f():Void { if (x) return 1; else return 2; } }');
	}

	private function testIfExprInInit(): Void {
		roundTrip('class F { function f():Void { var y:Int = if (c) 1 else 2; } }', 'if-expr as var init');
	}

	private function testIfExprInCall(): Void {
		roundTrip('class F { function f():Void { trace(if (c) 1 else 2); } }', 'if-expr as call arg');
	}

	private function testIfExprInObjectField(): Void {
		roundTrip('class F { function f():Void { var o:Dynamic = {label: if (c) 1 else 2}; } }', 'if-expr as object-literal value');
	}

	private function testIfExprNoElse(): Void {
		roundTrip('class F { function f():Void { var y:Int = if (c) 1; } }', 'if-expr without else');
	}

	private function testIfExprElseIfChain(): Void {
		roundTrip('class F { function f():Void { var y:Int = if (a) 1 else if (b) 2 else 3; } }', 'if-expr else-if chain');
	}

	private function testIfExprInReturn(): Void {
		roundTrip('class F { function f():Int { return if (c) 1 else 2; } }', 'if-expr as return value');
	}

	private function testSwitchExprInReturn(): Void {
		roundTrip('class F { function f():String { return switch (x) { case 1: "a"; case _: "b"; }; } }', 'switch-expr as return value');
	}

	private function testSwitchExprInInit(): Void {
		roundTrip('class F { function f():Void { var y:String = switch (x) { case 1: "a"; case _: "b"; }; } }', 'switch-expr as var init');
	}

	private function testSwitchExprInCall(): Void {
		roundTrip('class F { function f():Void { trace(switch (x) { case 1: "a"; case _: "b"; }); } }', 'switch-expr as call arg');
	}

	private function testSwitchExprInObjectField(): Void {
		roundTrip(
			'class F { function f():Void { var o:Dynamic = {label: switch (x) { case 1: "a"; case _: "b"; }}; } }',
			'switch-expr as object-literal value'
		);
	}

	private function testWhileStmt(): Void {
		roundTrip('class F { function f():Void { while (x) return 1; } }');
	}

	private function testForStmt(): Void {
		roundTrip('class F { function f():Void { for (i in items) return i; } }');
	}

	private function testBlockStmt(): Void {
		roundTrip('class F { function f():Void { { var x:Int = 1; } } }');
	}

	private function testVoidReturn(): Void {
		roundTrip('class F { function f():Void { return; } }');
	}

	private function testThrowStmt(): Void {
		roundTrip('class F { function f():Void { throw x; } }');
	}

	private function testDoWhileStmt(): Void {
		roundTrip('class F { function f():Void { do return 1; while (x); } }');
	}

	private function testTryCatch(): Void {
		roundTrip('class F { function f():Void { try return 1; catch (e:Error) return 2; } }');
	}

	private function testSwitchStmt(): Void {
		roundTrip('class F { function f():Void { switch (x) { case 1: return 1; default: return 2; } } }');
	}

	private function testTypedef(): Void {
		roundTrip('typedef Foo = Bar;');
	}

	private function testEnum(): Void {
		roundTrip('enum Foo { A; B; }');
	}

	private function testEnumParamCtor(): Void {
		roundTrip('enum Foo { A(x:Int, y:Float); B; }');
	}

	private function testInterface(): Void {
		roundTrip('interface Foo { function bar():Void {} }');
	}

	private function testAbstract(): Void {
		roundTrip('abstract Foo(Int) from Int to Int { function bar():Void {} }');
	}

	private function testDoubleString(): Void {
		roundTrip('class F { var x:String = "hello"; }');
	}

	private function testDoubleStringMultilineLiteralPreserved(): Void {
		// ω-doublestring-rawstring: literal embedded newlines inside a
		// double-quoted string must survive round-trip verbatim (Haxe
		// allows multiline strings). Previously decoded + re-escaped
		// via `escapeChar` which converted literal `\n` → `\n` escape,
		// collapsing the multiline source to inline-escaped form.
		// Source has actual newlines between the quotes — no `\n` escape.
		final src: String = 'class F { var x:String = "a\n\nb"; }';
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('"a\n\nb"') != -1, 'expected literal multiline string preserved in: <' + out + '>');
		Assert.isTrue(out.indexOf('\\n') == -1, 'did not expect re-escaped \\n in: <' + out + '>');
	}

	private function testSingleString(): Void {
		roundTrip("class F { var x:String = 'hello'; }");
	}

	private function testSingleStringInterp(): Void {
		roundTrip("class F { var x:String = 'hello $name'; }");
	}

	private function testSingleStringBlock(): Void {
		roundTrip("class F { var x:String = 'val=${a + b}'; }");
	}

	private function testSingleStringDollar(): Void {
		roundTrip("class F { var x:String = 'costs $$5'; }");
	}

	private function testSingleStringEscapedDollarRoundTrip(): Void {
		// `\$` inside `'...'` is a valid Haxe escape preventing interpolation;
		// previously `unescapeChar` threw on the escape with no current
		// fixture exercising it. Defensive completeness — paired with
		// `escapeSingleQuoteChar`'s `'$' → '\\$'` emission.
		final src: String = "class F { var x:String = 'val=\\$name'; }";
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf("'val=\\$name'") != -1, 'expected backslash-dollar-name preserved in: ' + out);
	}

	private function testSingleStringWithDoubleQuotePreservedBare(): Void {
		// ω-singlequote-escape: bare `"` inside `'...'` must NOT be escaped
		// on output. Haxe single-quoted strings don't escape `"`.
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse("class F { var x:String = 'a \"b\" c'; }"));
		Assert.isTrue(out.indexOf("'a \"b\" c'") != -1, 'expected bare `"b"` inside single-quoted string in: <$out>');
		Assert.isTrue(out.indexOf('\\\"') == -1, 'did not expect backslash-escaped `\\"` in: <$out>');
	}

	private function testDoubleStringWithDoubleQuoteEscaped(): Void {
		// Sister: inside `"..."`, embedded `"` MUST be escaped as `\"`.
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class F { var x:String = "a \\"b\\" c"; }'));
		Assert.isTrue(out.indexOf('"a \\"b\\" c"') != -1, 'expected `\\"` inside double-quoted string in: <$out>');
	}

	private function testMixedDecls(): Void {
		roundTrip('class A {} typedef B = C; enum D { X; } interface E {} abstract F(Int) {}');
	}

	private function testParamDefault(): Void {
		roundTrip('class F { function f(x:Int = 0):Void {} }');
	}

	private function testNestedExpr(): Void {
		roundTrip('class F { var x:Int = (a + b) * (c - d); }');
	}

	private function testCompoundAssign(): Void {
		roundTrip('class F { function f():Void { var x:Int = a += b *= 2; } }');
	}

	private function testIfBlock(): Void {
		roundTrip('class F { function f():Void { if (x) { return 1; } } }');
	}

	private function testFunctionNameAdjacentToParen(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function main():Void {} }'));
		Assert.isTrue(out.indexOf('main()') != -1, 'expected `main()` (no space) in: <$out>');
		Assert.isTrue(out.indexOf('main ()') == -1, 'did not expect space before `()` in: <$out>');
	}

	private function testFunctionWithParamsAdjacentToParen(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function bar(x:Int):Void {} }'));
		Assert.isTrue(out.indexOf('bar(x') != -1, 'expected `bar(x` (no space) in: <$out>');
		Assert.isTrue(out.indexOf('bar (') == -1, 'did not expect space before `(` in: <$out>');
	}

	private function testFunctionReturnTypeTightColon(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function f():Int { return 1; } }'));
		Assert.isTrue(out.indexOf('f():Int') != -1, 'expected `f():Int` (tight colon) in: <$out>');
		Assert.isTrue(out.indexOf(' : Int') == -1, 'did not expect spaced ` : Int` in: <$out>');
	}

	private function testFatArrowKeyTypeSpacedColon(): Void {
		// `(a:Int) => a + 1` is a check-type map key + prec-0 infix `=>`, NOT a
		// lambda: `ParenLambdaExpr` is the last paren atom, so a single-expression
		// key routes through `ECheckTypeExpr` + infix `=>`. haxe-formatter therefore
		// spaces the `:` (`(a : Int)`, via the typeCheckColon policy) and the `=>`.
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function f():Void { var x:Int = (a:Int) => a + 1; } }'));
		Assert.isTrue(out.indexOf('(a : Int) => a + 1') != -1, 'expected spaced `(a : Int) => a + 1` in: <$out>');
		Assert.isTrue(out.indexOf('(a:Int)') == -1, 'did not expect tight `(a:Int)` in: <$out>');
	}

	private function testNoLeadingSpaceBeforeMemberWithoutModifiers(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class F { function test() {} }'));
		Assert.isTrue(out.indexOf('\tfunction') != -1, 'expected `\\tfunction` (no leading space after indent) in: <$out>');
		Assert.isTrue(out.indexOf('\t function') == -1, 'did not expect `\\t function` (extra space) in: <$out>');
	}

	private function testNoLeadingSpaceBeforeVarWithoutModifiers(): Void {
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse('class F { var x:Int; }'));
		Assert.isTrue(out.indexOf('\tvar') != -1, 'expected `\\tvar` (no leading space after indent) in: <$out>');
		Assert.isTrue(out.indexOf('\t var') == -1, 'did not expect `\\t var` (extra space) in: <$out>');
	}

	private function testIfBodyPolicySame(): Void {
		final out: String = writeWithIfBody('class F { function f() { if (x) doA(); } }', BodyPolicy.Same, 120);
		Assert.isTrue(out.indexOf('if (x) doA();') != -1, 'expected `if (x) doA();` (same line) in: <$out>');
	}

	private function testIfBodyPolicyNextAlwaysBreaks(): Void {
		final out: String = writeWithIfBody('class F { function f() { if (x) doA(); } }', BodyPolicy.Next, 120);
		Assert.isTrue(out.indexOf('if (x)\n\t\t\tdoA();') != -1, 'expected `if (x)\\n\\t\\t\\tdoA();` (next line + indent) in: <$out>');
	}

	private function testIfBodyPolicyFitLineStaysFlatWhenFits(): Void {
		final out: String = writeWithIfBody('class F { function f() { if (x) doA(); } }', BodyPolicy.FitLine, 120);
		Assert.isTrue(out.indexOf('if (x) doA();') != -1, 'expected `if (x) doA();` (fits flat) in: <$out>');
	}

	private function testIfBodyPolicyFitLineBreaksWhenTooLong(): Void {
		final out: String = writeWithIfBody('class F { function f() { if (x) doSomethingVeryLong(); } }', BodyPolicy.FitLine, 20);
		Assert.isTrue(out.indexOf('if (x)\n\t\t\tdoSomethingVeryLong();') != -1, 'expected broken body in: <$out>');
	}

	private function testForBodyPolicyNextAlwaysBreaks(): Void {
		final out: String = writeWithForBody('class F { function f() { for (i in xs) doA(); } }', BodyPolicy.Next, 120);
		Assert.isTrue(out.indexOf('for (i in xs)\n\t\t\tdoA();') != -1, 'expected for-body next line in: <$out>');
	}

	private function testWhileBodyPolicyFitLineBreaksWhenTooLong(): Void {
		final out: String = writeWithWhileBody('class F { function f() { while (x) doSomethingVeryLong(); } }', BodyPolicy.FitLine, 20);
		Assert.isTrue(out.indexOf('while (x)\n\t\t\tdoSomethingVeryLong();') != -1, 'expected while-body break in: <$out>');
	}

	private function testElseBodyPolicyNextBreaksOnlyElseBody(): Void {
		final out: String = writeWithOpts(
			'class F { function f() { if (x) doA(); else doB(); } }', BodyPolicy.Same, BodyPolicy.Next, BodyPolicy.Same, BodyPolicy.Same,
			BodyPolicy.Same, 120
		);
		Assert.isTrue(out.indexOf('if (x) doA();') != -1, 'expected then-body flat in: <$out>');
		Assert.isTrue(out.indexOf('else\n\t\t\tdoB();') != -1, 'expected else-body next line in: <$out>');
	}

	private function testDoBodyPolicySame(): Void {
		final out: String = writeWithDoBody('class F { function f() { do doA(); while (x); } }', BodyPolicy.Same, 120);
		Assert.isTrue(out.indexOf('do doA(); while (x);') != -1, 'expected `do doA(); while (x);` (same line) in: <$out>');
	}

	private function testDoBodyPolicyNextAlwaysBreaks(): Void {
		final out: String = writeWithDoBody('class F { function f() { do doA(); while (x); } }', BodyPolicy.Next, 120);
		Assert.isTrue(
			out.indexOf('do\n\t\t\tdoA(); while (x);') != -1, 'expected `do\\n\\t\\t\\tdoA(); while (x);` (next line + indent) in: <$out>'
		);
	}

	private function testDoBodyPolicyFitLineBreaksWhenTooLong(): Void {
		final out: String = writeWithDoBody('class F { function f() { do doSomethingVeryLong(); while (x); } }', BodyPolicy.FitLine, 20);
		Assert.isTrue(out.indexOf('do\n\t\t\tdoSomethingVeryLong(); while (x);') != -1, 'expected broken do-body in: <$out>');
	}

	private inline function writeWithIfBody(src: String, policy: BodyPolicy, lineWidth: Int): String {
		return writeWithOpts(src, policy, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, lineWidth);
	}

	private inline function writeWithForBody(src: String, policy: BodyPolicy, lineWidth: Int): String {
		return writeWithOpts(src, BodyPolicy.Same, BodyPolicy.Same, policy, BodyPolicy.Same, BodyPolicy.Same, lineWidth);
	}

	private inline function writeWithWhileBody(src: String, policy: BodyPolicy, lineWidth: Int): String {
		return writeWithOpts(src, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, policy, BodyPolicy.Same, lineWidth);
	}

	private inline function writeWithDoBody(src: String, policy: BodyPolicy, lineWidth: Int): String {
		return writeWithOpts(src, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, BodyPolicy.Same, policy, lineWidth);
	}

	private function writeWithOpts(
		src: String, ifBody: BodyPolicy, elseBody: BodyPolicy, forBody: BodyPolicy, whileBody: BodyPolicy, doBody: BodyPolicy,
		lineWidth: Int
	): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.lineWidth = lineWidth;
		opts.ifBody = ifBody;
		opts.elseBody = elseBody;
		opts.forBody = forBody;
		opts.whileBody = whileBody;
		opts.doBody = doBody;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

}
