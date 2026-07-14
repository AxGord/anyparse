package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.MagicNumber;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

/**
 * The `magic-number` check: a numeric literal used in logic (inside a function)
 * whose value is not a small conventional one is flagged `Warning`. The "in
 * logic" gate (member field initializers and enum-abstract values exempt), the
 * named-local-binding exemption, the `{0,1,2}` exempt set with its boundary,
 * negative-magnitude handling, hex / float coverage, and the `apqlint.json`
 * `ignore` option are all pinned. Report-only — `fix` yields no edits.
 */
class MagicNumberCheckTest extends Test {

	public function testFlaggedInComparison(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f(n:Int):Bool { return n > 5000; }\n}');
		Assert.equals(1, vs.length);
		Assert.equals('magic-number', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('5000'));
	}

	public function testFlaggedAsCallArgument(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f() { trace(16); }\n}').length);
	}

	public function testEveryMagicLiteralFlagged(): Void {
		// Two distinct magic args -> two findings (the walk reaches them all).
		Assert.equals(2, violations('class C {\n\tfunction f() { rect(16, 32); }\n}').length);
	}

	public function testSmallValuesExempt(): Void {
		// 0 / 1 / 2 carry no hidden meaning.
		Assert.equals(0, violations('class C {\n\tfunction f(n:Int):Int { return n + 0 + 1 + 2; }\n}').length);
	}

	public function testThreeIsMagic(): Void {
		// Boundary: 3 is outside the {0,1,2} exempt set.
		Assert.equals(1, violations('class C {\n\tfunction f(n:Int):Int { return n + 3; }\n}').length);
	}

	public function testNegativeMagnitudeExempt(): Void {
		// -1 parses as Neg(IntLit 1); magnitude 1 is exempt.
		Assert.equals(0, violations('class C {\n\tfunction f():Int { return -1; }\n}').length);
	}

	public function testNegativeMagicFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int { return -5000; }\n}').length);
	}

	public function testFloatMagicFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Float { return 3.14; }\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('3.14'));
	}

	public function testFloatOneExempt(): Void {
		// 1.0 reduces to the exempt value 1.
		Assert.equals(0, violations('class C {\n\tfunction f():Float { return 1.0; }\n}').length);
	}

	public function testHexMagicFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Int { return 0xCAFE; }\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('0xCAFE'));
	}

	public function testNamedLocalBindingExempt(): Void {
		// `final x = 5000` already names the literal — the extraction the rule asks for.
		Assert.equals(0, violations('class C {\n\tfunction f():Int { final x = 5000; return x; }\n}').length);
	}

	public function testLiteralInBindingExpressionFlagged(): Void {
		// Nested in an initializer expression, the literal is still in logic.
		Assert.equals(1, violations('class C {\n\tfunction f(k:Int):Int { final x = 5000 * k; return x; }\n}').length);
	}

	public function testMemberFieldInitializerExempt(): Void {
		// The member-level literal is outside any function — exempt by construction.
		final src: String = 'class C {\n\tstatic final MAX = 5000;\n\tfunction f(n:Int):Bool { return n > MAX; }\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testEnumAbstractValueExempt(): Void {
		Assert.equals(0, violations('enum abstract E(Int) {\n\tfinal A = 4;\n\tfinal B = 8;\n}').length);
	}

	public function testIgnoreOptionAccessor(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"magic-number":{"ignore":[5000,42]}}}');
		Assert.same([5000.0, 42.0], cfg.numberListOption('magic-number', 'ignore'));
	}

	public function testRespectsIgnoreFromDisk(): Void {
		// End-to-end: an apqlint.json discovered by walking up adds 5000 to the
		// exempt set, so a literal the check would otherwise flag is left alone.
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? tmp : '/tmp';
		final dir: String = '$base/anyparse_mn_cfg_${Sys.time()}';
		sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent('$dir/apqlint.json', '{"rules":{"magic-number":{"ignore":[5000]}}}');
		final path: String = '$dir/Foo.hx';
		final src: String = 'class Foo {\n\tfunction f(k:Int):Int { return 5000 * k; }\n}';
		sys.io.File.saveContent(path, src);
		Assert.equals(0, new MagicNumber().run([{ file: path, source: src }], new HaxeQueryPlugin()).length);
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteFile('$dir/apqlint.json');
		sys.FileSystem.deleteDirectory(dir);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f(n:Int):Bool { return n > 5000; }\n}';
		final check: MagicNumber = new MagicNumber();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { return 5000').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('magic-number'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('magic-number'));
	}

	public function testNumberListOptionEdgeCases(): Void {
		// Non-numeric elements dropped, non-array -> null, empty array -> empty list (not null).
		Assert.same(
			[5000.0, 42.0],
			LintConfig.parse('{"rules":{"magic-number":{"ignore":[5000,"x",42]}}}').numberListOption('magic-number', 'ignore')
		);
		Assert.isNull(LintConfig.parse('{"rules":{"magic-number":{"ignore":5}}}').numberListOption('magic-number', 'ignore'));
		Assert.same([], LintConfig.parse('{"rules":{"magic-number":{"ignore":[]}}}').numberListOption('magic-number', 'ignore'));
	}

	public function testMutableLocalBindingExempt(): Void {
		// `var x = 5000` names the literal just like the `final` form (VarStmt is a localDeclKind too).
		Assert.equals(0, violations('class C {\n\tfunction f():Int { var x = 5000; return x; }\n}').length);
	}

	public function testUnderscoreLiteralFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f(n:Int):Bool { return n > 100_000; }\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('100_000'));
	}

	public function testScientificFloatFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Float { return 1e5; }\n}').length);
	}

	public function testNestedFunctionLiteralFlagged(): Void {
		// `inFunction` is sticky — a literal in a nested local function is still in logic.
		Assert.equals(1, violations('class C {\n\tfunction f():Void { function g():Int { return 5000; } g(); }\n}').length);
	}

	public function testRespectsCheckstyleIgnoreFromDisk(): Void {
		// A checkstyle.json MagicNumber.ignoreNumbers exempts 5000 the check would otherwise flag.
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? tmp : '/tmp';
		final dir: String = '$base/anyparse_mn_cs_${Sys.time()}';
		sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent('$dir/checkstyle.json', '{"checks":[{"type":"MagicNumber","props":{"ignoreNumbers":[-1,0,1,2,5000]}}]}');
		final path: String = '$dir/Foo.hx';
		final src: String = 'class Foo {\n\tfunction f(k:Int):Int { return 5000 * k; }\n}';
		sys.io.File.saveContent(path, src);
		Assert.equals(0, new MagicNumber().run([{ file: path, source: src }], new HaxeQueryPlugin()).length);
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteFile('$dir/checkstyle.json');
		sys.FileSystem.deleteDirectory(dir);
	}

	public function testObjectFieldValueExempt(): Void {
		// A numeric literal that is the direct value of an object-literal field is
		// declarative data, not logic — exempt. A computed field value still flags.
		Assert.equals(0, violations('class C {\n\tfunction f() { return { value: 30, nested: { w: 140 } }; }\n}').length);
		Assert.equals(1, violations('class C {\n\tfunction f(k:Int) { return { value: 30 * k }; }\n}').length);
	}

	public function testArrayIndexLiteralExempt(): Void {
		// A literal in the index slot of a subscript (`args[3]`) is a position, not a
		// hidden quantity — exempt. A computed index keeps the literal under the
		// operator and still flags.
		Assert.equals(0, violations('class C {\n\tfunction f(args:Array<String>):String { return args[3]; }\n}').length);
		Assert.equals(1, violations('class C {\n\tfunction f(args:Array<String>, i:Int):String { return args[i + 3]; }\n}').length);
	}


	public function testSizeComparisonExempt(): Void {
		// A literal compared against a `.length` field access is a structural arity
		// check — exempt. A comparison against a plain value keeps the literal magic.
		Assert.equals(0, violations('class C {\n\tfunction f(args:Array<String>):Bool { return args.length == 6; }\n}').length);
		// A relational size bound is exempt too (structural element count, not a threshold-on-a-plain-value).
		Assert.equals(0, violations('class C {\n\tfunction f(args:Array<String>):Bool { return args.length >= 6; }\n}').length);
		Assert.equals(1, violations('class C {\n\tfunction f(score:Int):Bool { return score == 100; }\n}').length);
	}

	private function violations(src: String): Array<Violation> {
		return new MagicNumber().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
