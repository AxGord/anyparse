package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.MagicNumber;
import anyparse.check.Severity;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

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

	/**
	 * A literal that is DIRECTLY an argument of a call `ignoreCallArguments` names is a key the callee
	 * owns (`t('Complete with AI', 10233)`), whatever receiver the call is written through.
	 *
	 * RED under M-MAGIC-CALLARG-BLIND (the exemption answers false): the four exempt calls come back as
	 * findings. The nested `100 + k` and the unlisted `other(…, 5000)` are flagged with the exemption on
	 * and off alike, and are what separate "direct arguments of listed calls" from "every argument". A
	 * negated literal (`-55`) is a direct argument too: Haxe spells a negative constant as a negation.
	 */
	@:pin('control')
	@:killer('M-MAGIC-CALLARG-BLIND')
	public function testADirectArgumentOfAnIgnoredCallIsExempt(): Void {
		final src: String = 'class C {\n\tfunction f(k:Int) {\n\t\tt("a", 10233);\n\t\tthis.t("b", 77);\n\t\tmake().t("c", 88);\n'
			+ '\t\tt("x", 100 + k);\n\t\tt("y", -55);\n\t\tother("z", 5000);\n\t}\n}';
		final flagged: Array<String> = [for (v in withCalls(src, ['t'])) v.message.split(' ')[2]];
		Assert.same(['100', '5000'], flagged, 'only the nested and the unlisted call stay flagged');
		Assert.equals(6, violations(src).length, 'without the option every one of them is a finding');
	}

	/**
	 * A dotted entry matches the TAIL of the callee as written, segment for segment: `Lang.t` exempts
	 * `Lang.t(…)` and `macros.Lang.t(…)`, but not a bare `t(…)` imported by name, nor `Blang.t(…)`.
	 *
	 * RED under M-MAGIC-CALLARG-SUFFIX-LOOSE (only the last segment compared, the length guard gone):
	 * the bare `t(…)` is exempted too. The two dotted calls are exempt with and without the arm.
	 */
	@:pin('control')
	@:killer('M-MAGIC-CALLARG-SUFFIX-LOOSE')
	public function testADottedEntryMatchesTheCalleeTail(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tLang.t("a", 11);\n\t\tmacros.Lang.t("b", 22);\n\t\tt("c", 33);\n'
			+ '\t\tBlang.t("d", 44);\n\t}\n}';
		final flagged: Array<String> = [for (v in withCalls(src, ['Lang.t'])) v.message.split(' ')[2]];
		Assert.same(['33', '44'], flagged, 'a bare t() and a different receiver are not Lang.t');
	}

	/**
	 * A negated literal is a DIRECT argument: Haxe has no negative literal, `-18` is `Neg(IntLit 18)`, so
	 * the negation is the argument and the literal sits one level below it. `f(-18)` is exempt exactly when
	 * `f(18)` is.
	 *
	 * RED under M-MAGIC-CALLARG-NEG-BLIND (the negation does not carry the argument context to its
	 * literal): `-18` and `-83.75` come back. A negated operand of arithmetic (`-(3) * k`, `-k * 4`) is no
	 * argument and stays flagged with the arm on and off alike.
	 */
	@:pin('control')
	@:killer('M-MAGIC-CALLARG-NEG-BLIND')
	public function testANegatedArgumentOfAnIgnoredCallIsExempt(): Void {
		final src: String = 'class C {\n\tfunction g(k:Int) {\n\t\tf(18);\n\t\tf(-18);\n\t\tf(-83.75, -k * 4);\n\t}\n}';
		final flagged: Array<String> = [for (v in withCalls(src, ['f'])) v.message.split(' ')[2]];
		Assert.same(['4'], flagged, 'only the literal under arithmetic stays flagged');
		Assert.equals(4, violations(src).length, 'without the option every one of them is a finding');
	}

	/**
	 * A CONSTRUCTOR is listed as `T.new`, the spelling Haxe itself gives a constructor used as a value
	 * (`Point.new`): the entry matches the tail of the constructed type's path followed by `new`, so
	 * `SpriteDescriptor.new` reaches `new SpriteDescriptor(…)` and `new data.SpriteDescriptor(…)`, and type
	 * arguments are no part of the path (`Map.new` reaches `new Map<String, Int>(…)`). A bare `Other`
	 * names a CALL `Other(…)`, never a constructor, so nothing is exempt unless configured.
	 *
	 * RED under M-MAGIC-CALLARG-NEW-BLIND (no constructor is ever a listed callee): 77, 78 and 79 come back.
	 */
	@:pin('control')
	@:killer('M-MAGIC-CALLARG-NEW-BLIND')
	public function testAnIgnoredConstructorIsSpelledDotNew(): Void {
		final src: String = 'class C {\n\tfunction g() {\n\t\tnew SpriteDescriptor("a", 77);\n\t\tnew data.SpriteDescriptor("b", 78);\n'
			+ '\t\tnew Map<String, Int>(79);\n\t\tnew Other("c", 80);\n\t\tnew Blah.SpriteDescriptorX("d", 81);\n\t}\n}';
		final calls: Array<String> = ['SpriteDescriptor.new', 'Map.new', 'Other'];
		final flagged: Array<String> = [for (v in withCalls(src, calls)) v.message.split(' ')[2]];
		Assert.same(['80', '81'], flagged, 'a bare entry and a different type name reach no constructor');
	}

	/**
	 * A value object BUILT IN PLACE as a direct argument of a listed callee carries that callee's data:
	 * `new SpriteDescriptor('sprites:east', new Point(-28, -77.65))` registers the sprite's offset, and the
	 * `Point` is only its carrier. The context passes through `new` alone — an ordinary call
	 * (`make(5)`) or an operator (`3 * k`) inside the argument resets it — and a `Point` built anywhere
	 * else is untouched.
	 *
	 * RED under M-MAGIC-CALLARG-NESTED-NEW (a constructor inside a listed argument does not carry the
	 * context): -28, -77.65 and the 6 inside `new Point(3 * k, 6)` come back.
	 */
	@:pin('control')
	@:killer('M-MAGIC-CALLARG-NESTED-NEW')
	public function testAValueObjectBuiltInAListedArgumentIsExempt(): Void {
		final src: String = 'class C {\n\tfunction g(k:Int) {\n\t\tnew SpriteDescriptor("a", new Point(-28, -77.65));\n'
			+ '\t\tnew SpriteDescriptor("b", make(5));\n\t\tnew SpriteDescriptor("c", new Point(3 * k, 6));\n'
			+ '\t\tnew Point(9, 10);\n\t\tsetHitArea(-16, 4, 80, 64);\n\t}\n}';
		final flagged: Array<String> = [
			for (v in withCalls(src, ['SpriteDescriptor.new', 'setHitArea'])) v.message.split(' ')[2]
		];
		Assert.same(['5', '3', '9', '10'], flagged, 'only what no listed callee receives directly or through a new stays flagged');
	}

	/**
	 * With `literalTables` on, a `switch` whose every arm maps literal patterns to a literal value is a
	 * lookup TABLE (`case 0x410300: 0xC0;`): the patterns are the keys and the values the data, so neither
	 * is a hidden quantity. The subject is logic and stays flagged (`base << 16`). One arm that is not
	 * literal data — a computed value, a guard, a block body, a capture — makes it no table, and every
	 * literal in it is flagged as before.
	 *
	 * RED under M-MAGIC-TABLE-SWITCH-BLIND (no switch is a table): the table's six literals come back.
	 * RED under M-MAGIC-TABLE-SWITCH-ARM-LOOSE (an arm is judged by its value alone): the guarded and the
	 * capturing switches lose their 31 / 32 / 41 / 42.
	 */
	@:pin('control')
	@:killer('M-MAGIC-TABLE-SWITCH-BLIND')
	@:killer('M-MAGIC-TABLE-SWITCH-ARM-LOOSE')
	public function testASwitchOfLiteralArmsIsATable(): Void {
		final src: String = 'class C {\n\tfunction g(base:Int, c:Bool, k:Int):Int {\n'
			+ '\t\tfinal a:Int = switch base << 16 { case 0x410300: 0xC0; case 33 | 44: -55; case _: -1; };\n'
			+ '\t\tfinal b:Int = switch k { case 21: 22; case 23: k; case _: 0; };\n'
			+ '\t\tfinal d:Int = switch k { case 31 if (c): 32; case _: 0; };\n'
			+ '\t\tfinal e:Int = switch k { case 41: 42; case z: 0; };\n'
			+ '\t\tfinal f:Int = switch k { case 51: { 52; } default: 0; };\n'
			+ '\t\treturn switch k { case 61: 62; default: 63; };\n\t}\n}';
		final flagged: Array<String> = [for (v in withTables(src)) v.message.split(' ')[2]];
		Assert.same(
			['16', '21', '22', '23', '31', '32', '41', '42', '51', '52'], flagged, 'the subject and the non-table switches stay flagged'
		);
		Assert.equals(18, violations(src).length, 'with the option off every literal is a finding');
	}

	/**
	 * With `literalTables` on, an array or map literal of literal data is a TABLE when a name gives it its
	 * meaning: the direct initializer of a local (`final widths = [30, 45]`) or the sole return of a
	 * function (`function initDecodeChar() return [-1, 62, 63]`) — the same reasoning that already exempts
	 * `final x = 5000;`. A table passed inline (`draw([3, 4])`) has no name, and one element that is not
	 * data (`[5, k]`) makes it no table.
	 *
	 * RED under M-MAGIC-TABLE-COLLECTION-BLIND (no collection is a named table): the named tables' literals
	 * come back. RED under M-MAGIC-TABLE-COLLECTION-UNNAMED (every all-literal collection is a table): the
	 * inline `draw([3, 4])` loses its findings.
	 */
	@:pin('control')
	@:killer('M-MAGIC-TABLE-COLLECTION-BLIND')
	@:killer('M-MAGIC-TABLE-COLLECTION-UNNAMED')
	public function testANamedCollectionOfLiteralsIsATable(): Void {
		final src: String = 'class C {\n\tfunction g(k:Int) {\n\t\tfinal widths = [30, -45, 60];\n\t\tvar keys = [7 => "a", -8 => "b"];\n'
			+ '\t\tdraw([3, 4]);\n\t\tfinal mixed = [5, k];\n\t}\n\tfunction dec():Array<Int> {\n\t\treturn [-1, 62, 63];\n\t}\n'
			+ '\tfunction enc():Array<Int> return [64, 65];\n\tfunction two():Array<Int> {\n\t\ttrace(1);\n\t\treturn [97, 98];\n\t}\n}';
		final flagged: Array<String> = [for (v in withTables(src)) v.message.split(' ')[2]];
		Assert.same(['3', '4', '5', '97', '98'], flagged, 'an inline, a mixed and a not-sole-return collection stay flagged');
	}

	/**
	 * `literalTables` is OFF unless a project sets it: no existing configuration changes behaviour.
	 *
	 * RED under M-MAGIC-TABLES-DEFAULT-ON (the option read as on when absent): the switch's literals vanish
	 * from a run with no option at all.
	 */
	@:pin('control')
	@:killer('M-MAGIC-TABLES-DEFAULT-ON')
	public function testLiteralTablesAreOffByDefault(): Void {
		final src: String = 'class C {\n\tfunction g(k:Int):Int {\n\t\treturn switch k { case 71: 72; case _: 73; };\n\t}\n}';
		Assert.equals(3, violations(src).length);
		Assert.equals(3, withConfig(src, '{"rules":{"magic-number":{"literalTables":false}}}').length);
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
		final base: String = tmp != null && tmp.length > 0 ? tmp : '/tmp';
		final dir: String = '$base/anyparse_mn_cfg_${Sys.time()}';
		FileSystem.createDirectory(dir);
		File.saveContent('$dir/apqlint.json', '{"rules":{"magic-number":{"ignore":[5000]}}}');
		final path: String = '$dir/Foo.hx';
		final src: String = 'class Foo {\n\tfunction f(k:Int):Int { return 5000 * k; }\n}';
		File.saveContent(path, src);
		Assert.equals(0, CheckFixture.violationsIn(new MagicNumber(), [{ file: path, source: src }]).length);
		FileSystem.deleteFile(path);
		FileSystem.deleteFile('$dir/apqlint.json');
		FileSystem.deleteDirectory(dir);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {\n\tfunction f(n:Int):Bool { return n > 5000; }\n}';
		final check: MagicNumber = new MagicNumber();
		Assert.equals(0, CheckFixture.edits(check, src).length);
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
		final base: String = tmp != null && tmp.length > 0 ? tmp : '/tmp';
		final dir: String = '$base/anyparse_mn_cs_${Sys.time()}';
		FileSystem.createDirectory(dir);
		File.saveContent('$dir/checkstyle.json', '{"checks":[{"type":"MagicNumber","props":{"ignoreNumbers":[-1,0,1,2,5000]}}]}');
		final path: String = '$dir/Foo.hx';
		final src: String = 'class Foo {\n\tfunction f(k:Int):Int { return 5000 * k; }\n}';
		File.saveContent(path, src);
		Assert.equals(0, CheckFixture.violationsIn(new MagicNumber(), [{ file: path, source: src }]).length);
		FileSystem.deleteFile(path);
		FileSystem.deleteFile('$dir/checkstyle.json');
		FileSystem.deleteDirectory(dir);
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

	public function testPositionMethodArgExempt(): Void {
		// A literal reaching a string-position method's argument — directly or through
		// `+` / `-` offset arithmetic (`charCodeAt(i + 5)`, `substr(0, 4)`) — is a position.
		Assert.equals(
			0, violations('class C {\n\tfunction f(s:String, i:Int):Int { return s.charCodeAt(i + 5) + s.substr(0, 4).length; }\n}').length
		);
	}

	public function testSizeArithmeticExempt(): Void {
		// A literal offset from a collection-size field (`s.length - 3`, `a[a.length - 3]`)
		// is structural, like the size-comparison carve-out.
		Assert.equals(
			0, violations('class C {\n\tfunction f(s:String, a:Array<Int>):Int { return (s.length - 3) + a[a.length - 3]; }\n}').length
		);
	}

	public function testBareOffsetStillFlagged(): Void {
		// A bare `x + N` with no size sibling and not a position-call arg stays flagged —
		// the offset carve-outs are narrow (mirrors testThreeIsMagic).
		Assert.equals(1, violations('class C {\n\tfunction f(pos:Int):Int { return pos + 7; }\n}').length);
	}

	public function testNonPositionCallArgStillFlagged(): Void {
		// Only the listed position methods are exempt; an ordinary method call's numeric arg flags.
		Assert.equals(1, violations('class C {\n\tfunction f(s:String):Int { return s.myMethod(7); }\n}').length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new MagicNumber(), src);
	}

	/** The findings on `src` under a config whose `ignoreCallArguments` lists `calls`. */
	private function withCalls(src: String, calls: Array<String>): Array<Violation> {
		return withConfig(src, '{"rules":{"magic-number":{"ignoreCallArguments":${Json.stringify(calls)}}}}');
	}

	/** The findings on `src` with `literalTables` on. */
	private function withTables(src: String): Array<Violation> {
		return withConfig(src, '{"rules":{"magic-number":{"literalTables":true}}}');
	}

	/** The findings on `src` under the `apqlint.json` text `json`. */
	private function withConfig(src: String, json: String): Array<Violation> {
		final check: MagicNumber = new MagicNumber();
		final config: LintConfig = LintConfig.parse(json);
		check.setConfigResolver(_ -> config);
		return CheckFixture.violations(check, src);
	}

}
