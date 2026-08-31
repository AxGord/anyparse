package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.PreferInline;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The `prefer-inline` check: a method whose body is a BENEFIT class — empty (the call compiles
 * away), an accessor / thin forward / trivial mutator, or a constant / small-arithmetic expression
 * within the 32-AST-node budget — markable `inline`, per the user's rule. `Severity.Info`, `--fix`
 * inserts `inline ` before the `function` keyword. Anything outside the benefit classes (an
 * allocation: `new` / array / object / interpolated-string literal / `macro` reification / `.bind`;
 * a lambda or computed argument; a loop; a switch; a `super` chain; a multi-statement body) is never
 * a candidate. Soundness misses: a method referenced as a value anywhere (bare / `.bind` /
 * argument), an `override` / subtype-overridden method, an interface-declared method, a `dynamic` /
 * `macro` / constructor / `@:keep` / `Reflect`-string-accessed method, a self-recursive body, and a
 * `null` literal in a value slot (dropped only on the relaxed oracle path).
 */
class PreferInlineCheckTest extends Test {

	public function testArrowGetterFlagged(): Void {
		final vs: Array<Violation> = violations(cls('function get_date():String return _field.text;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-inline', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testDelegationWrapperFlagged(): Void {
		Assert.equals(1, violations(cls('public function stop():Void _other.stop();')).length);
	}

	public function testBlockSingleReturnFlagged(): Void {
		Assert.equals(1, violations(cls('function three():Int { return 3; }')).length);
	}

	public function testBlockSingleExprStmtFlagged(): Void {
		Assert.equals(1, violations(cls('function ping():Void { _other.ping(); }')).length);
	}

	public function testFinalClassFlagged(): Void {
		Assert.equals(1, violations('final class C {\n\tfunction one():Int return 1;\n}').length);
	}

	public function testMultiStatementNotFlagged(): Void {
		Assert.equals(0, violations(cls('function two():Int { step(); return 3; }')).length);
	}

	public function testComprehensionBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function ids():Array<Int> return [for (v in _list) v];')).length,
			'a comprehension is an allocating loop — not a benefit class'
		);
	}

	public function testWhileComprehensionBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function drain():Array<Int> return [while (has()) pop()];')).length,
			'a while-comprehension is an allocating loop — not a benefit class'
		);
	}

	public function testMacroReifiedBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function build():Expr return macro for (i in 0...3) trace(i);')).length,
			'a reification builds an Expr object — an allocation-class body, not a benefit class'
		);
	}

	public function testSwitchBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function pick(v:Int):Int return switch v { case 1: 2; case _: 3; };')).length,
			'a switch body is a dispatch table, not a trivial getter — inlining duplicates every branch at call sites'
		);
	}

	public function testParenSwitchBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function pick(v:Int):Int return switch (v) { case 1: 2; case _: 3; };')).length,
			'a switch is not a benefit class — the parenthesized-subject form included'
		);
	}

	public function testSwitchInLambdaNotFlaggedRelaxed(): Void {
		Assert.equals(
			0, relaxedViolations(cls('function each():Void run(() -> { switch v { case 1: act(); case _: stop(); } });')).length,
			'a lambda argument is not a simple operand — rejected in relaxed mode too'
		);
	}

	public function testOversizedBodyNotFlagged(): Void {
		final body: String =
			'function big():Float return f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9 + f10 + f11 + f12 + f13 + f14 + f15 + f16 + f17;';
		Assert.equals(
			0, violations(cls(body)).length,
			'35 body nodes exceed the 32-node inline budget — a straight-line builder, not a trivial getter'
		);
	}

	public function testBodyAtBudgetStaysFlagged(): Void {
		final body: String =
			'function atBudget():Float return -f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9 + f10 + f11 + f12 + f13 + f14 + f15;';
		Assert.equals(1, violations(cls(body)).length, 'exactly 32 body nodes sit AT the budget — still a candidate');
	}

	public function testBodyOverBudgetByOneNotFlagged(): Void {
		final body: String =
			'function overByOne():Float return f1 + f2 + f3 + f4 + f5 + f6 + f7 + f8 + f9 + f10 + f11 + f12 + f13 + f14 + f15 + f16;';
		Assert.equals(0, violations(cls(body)).length, '33 body nodes are one over the budget — dropped');
	}

	public function testNewFactoryBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function make():Thing return new Thing(a, b);')).length,
			'an allocation in root position never benefits from inline — the new runs either way, only the call site code grows'
		);
	}

	public function testInterpolatedStringBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls("function label():String return 'v: $x';")).length,
			'string interpolation allocates and concatenates — a builder, not a constant'
		);
	}

	public function testPlainSingleQuotedStringBodyFlagged(): Void {
		Assert.equals(
			1, violations(cls("function ext():String return '.drl';")).length,
			'a single-quoted string WITHOUT interpolation carries only Literal parts — a constant, still a candidate'
		);
	}

	public function testArrayLiteralBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function pair():Array<Int> return [a, b];')).length,
			'an array literal is an allocation — nothing folds at the call site'
		);
	}

	public function testComputedArgForwardNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function bump():Void run(x + 1);')).length,
			'a forward is thin only when its arguments are bare chains or literals — a computed arg is work'
		);
	}

	public function testSuperForwardNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('public function baseDispose():Void super.dispose();')).length,
			'Haxe refuses `inline` on a body containing super — the chain leaf must reject it'
		);
	}

	public function testIntervalBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function iter():IntIterator return 0..._n;')).length,
			'an interval builds an IntIterator — an allocation, not a foldable constant'
		);
	}

	public function testBindForwardNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function handler():Void->Void return _h.bind(_n);')).length,
			'`.bind` allocates a closure — a forward through it is not thin'
		);
	}

	public function testAssignmentBodyFlagged(): Void {
		Assert.equals(
			1, violations(cls('function reset():Void { _busy = false; }')).length,
			'a simple field assignment inlines to a direct write — a benefit-class body'
		);
	}

	public function testIncrementBodyFlagged(): Void {
		Assert.equals(1, violations(cls('function bump():Void _count++;')).length, 'an increment over a chain is a trivial mutator');
	}

	public function testLiteralArgForwardFlagged(): Void {
		Assert.equals(
			1, violations(cls('function ping():Void _other.send(1, "ok");')).length, 'chain callee with literal args is a thin forward'
		);
	}

	public function testStaticChainAccessorFlagged(): Void {
		Assert.equals(1, violations(cls('function pi():Float return Math.PI;')).length, 'a static field chain is a bare accessor');
	}

	public function testSafeNavAccessorFlagged(): Void {
		Assert.equals(
			1, violations(cls('function userName():Null<String> return _user?.profile?.name;')).length,
			'a safe-navigation chain is still a bare accessor'
		);
	}

	public function testNullCoalConstFlagged(): Void {
		Assert.equals(
			1, violations(cls('function port():Int return _port ?? 80;')).length,
			'a null-coalescing fallback over a chain and a literal folds at the call site'
		);
	}

	public function testCompoundAssignBodyFlagged(): Void {
		Assert.equals(
			1, violations(cls('function grow():Void _count += 2;')).length,
			'a compound assignment over a chain with a literal operand is a trivial mutator'
		);
	}

	public function testFatDelegationStaysFlagged(): Void {
		Assert.equals(
			1, violations(cls('function go():Void _other.run(alpha, beta, gamma, delta, epsilon, zeta);')).length,
			'a many-argument delegation sits well under the node budget and stays a candidate'
		);
	}

	public function testTernaryBodyStaysFlagged(): Void {
		Assert.equals(
			1, violations(cls('function sign(v:Int):Int return v > 0 ? 1 : -1;')).length,
			'a ternary is the boundary — still a candidate, unlike a switch'
		);
	}

	public function testLoopInLambdaNotFlaggedRelaxed(): Void {
		Assert.equals(
			0, relaxedViolations(cls('function each():Void run(() -> { for (v in _items) act(v); });')).length,
			'a lambda argument is not a simple operand — the benefit-class gate rejects it even in relaxed mode'
		);
	}

	public function testEmptyBodyFlagged(): Void {
		Assert.equals(1, violations(cls('function noop():Void {}')).length, 'inlining an empty method compiles the call away');
	}

	public function testAlreadyInlineNotFlagged(): Void {
		Assert.equals(0, violations(cls('inline function one():Int return 1;')).length);
	}

	public function testDynamicNotFlagged(): Void {
		Assert.equals(0, violations(cls('dynamic function one():Int return 1;')).length);
	}

	public function testMacroNotFlagged(): Void {
		Assert.equals(0, violations(cls('macro static function one():Int return 1;')).length);
	}

	public function testOverrideNotFlagged(): Void {
		Assert.equals(0, violations(cls('override function one():Int return 1;')).length);
	}

	public function testConstructorNotFlagged(): Void {
		Assert.equals(0, violations(cls('function new() init();')).length);
	}

	public function testKeepNotFlagged(): Void {
		Assert.equals(0, violations(cls('@:keep function one():Int return 1;')).length);
	}

	public function testSelfRecursiveNotFlagged(): Void {
		Assert.equals(0, violations(cls('function fac(n:Int):Int return n <= 1 ? 1 : n * fac(n - 1);')).length);
	}

	public function testThisRecursiveNotFlagged(): Void {
		Assert.equals(0, violations(cls('function loop():Void this.loop();')).length);
	}

	public function testMethodValueReferenceSkipsTarget(): Void {
		final vs: Array<Violation> = violations(cls('function target():Int return 1;\n\tfunction caller():Void use(target);'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('caller') >= 0);
	}

	public function testBindReferenceSkips(): Void {
		final vs: Array<Violation> = violations(cls('function handler():Void act();\n\tfunction wire():Void listen(handler.bind());'));
		Assert.isFalse(hasMethod(vs, 'handler'));
	}

	public function testReflectStringSkips(): Void {
		final vs: Array<Violation> = violations(cls('function foo():Int return 1;\n\tfunction r():Void Reflect.callMethod(o, "foo", []);'));
		Assert.isFalse(hasMethod(vs, 'foo'));
	}

	public function testReflectSingleQuotedStringSkips(): Void {
		final vs: Array<Violation> = violations(cls("function foo():Int return 1;\n\tfunction r():Void Reflect.callMethod(o, 'foo', []);"));
		Assert.isFalse(hasMethod(vs, 'foo'), 'a single-quoted Reflect name lives in a Literal child, not node.name');
	}

	public function testSubtypeOverrideSkips(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'B.hx', source: 'class B {\n\tfunction f():Int return 1;\n}' },
			{ file: 'S.hx', source: 'class S extends B {\n\toverride function f():Int return 2;\n}' }
		];
		Assert.equals(0, new PreferInline().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * The implemented interface's SIMPLE name is shared by another package, and the class's own
	 * imports say which one it means: the interface gate resolves instead of blocking on
	 * ambiguity, so a method that fills NO interface slot is still a candidate.
	 */
	public function testAmbiguousInterfaceNameResolvesFromFileImports(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'a/I.hx', source: 'package a;\ninterface I {\n\tfunction f():Int;\n}' },
			{ file: 'b/I.hx', source: 'package b;\ninterface I {\n\tfunction other():Int;\n}' },
			{
				file: 'C.hx',
				source: 'import b.I;\n\nclass C implements I {\n\tfunction other():Int return 1;\n\tfunction g():Int return 2;\n}'
			}
		];
		final vs: Array<Violation> = new PreferInline().run(files, new HaxeQueryPlugin());
		// `other` fills b.I's slot and stays physical; `g` fills nothing and is flagged.
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue(vs[0].message.indexOf("'g'") >= 0, vs[0].message);
	}

	public function testInterfaceImplSkips(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'I.hx', source: 'interface I {\n\tfunction f():Int;\n}' },
			{ file: 'C.hx', source: 'class C implements I {\n\tfunction f():Int return 1;\n}' }
		];
		Assert.equals(0, new PreferInline().run(files, new HaxeQueryPlugin()).length);
	}

	public function testFixInsertsInline(): Void {
		final src: String = cls('public function one():Int return 1;');
		final check: PreferInline = new PreferInline();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('inline function one') >= 0);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testNullLiteralArgBodySkipped(): Void {
		Assert.equals(
			0, violations(cls('public function clear():Void down(null);\n\tfunction down(p:Int):Void { keep(p); log(p); }')).length,
			'null-literal body not inlinable (re-checked in caller Strict context)'
		);
	}

	public function testAnonObjectLiteralBodySkipped(): Void {
		Assert.equals(
			0, violations(cls('private var _f:Int;\n\tpublic function rec():Dynamic return {object: _f};')).length,
			'anon-object-literal body not inlinable'
		);
	}

	public function testBlockLambdaBodySkipped(): Void {
		Assert.equals(
			0, violations(cls('public function loadX():Void run(function() { step(); });')).length,
			'a function-literal argument is not a simple operand — the forward is not thin'
		);
	}

	public function testBlockArrowLambdaBodyNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function each():Void run(v -> { act(v); done(); });')).length,
			'a lambda argument is not a simple operand — the forward is not thin'
		);
	}

	public function testArrowLambdaArgNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('public function wireUp():Void run(y -> handle(y));')).length,
			'a lambda argument constructs a closure — an allocation, so the forward is not thin'
		);
	}

	public function testNullCheckBodyNotSkipped(): Void {
		Assert.equals(
			1, violations(cls('public function isNull(x:Dynamic):Bool return x == null;')).length,
			'a null-CHECK (== null) is context-neutral — not gated'
		);
	}

	public function testAbstractClassDelegationFlagged(): Void {
		Assert.equals(
			1, violations('abstract class C {\n\tpublic function upd():Void _other.upd();\n}').length,
			'an abstract class body is inspected like a plain class'
		);
	}

	public function testAbstractClassSubtypeOverrideSkips(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'B.hx', source: 'abstract class B {\n\tpublic function step():Void _other.step();\n}' },
			{
				file: 'S.hx',
				source: 'class S extends B {\n\toverride public function step():Void {\n\t\tlog();\n\t\t_other.step();\n\t}\n}'
			}
		];
		Assert.equals(
			0, new PreferInline().run(files, new HaxeQueryPlugin()).length, 'a subtype override forbids inlining the abstract base method'
		);
	}

	public function testAbstractMethodNoBodyNotFlagged(): Void {
		Assert.equals(
			0, violations('abstract class C {\n\tpublic abstract function h():Int;\n}').length,
			'a body-less abstract method is not a candidate'
		);
	}

	public function testEmptyBodySubtypeOverrideSkips(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'B.hx', source: 'class B {\n\tpublic function hook():Void {}\n}' },
			{ file: 'S.hx', source: 'class S extends B {\n\toverride public function hook():Void doStuff();\n}' }
		];
		Assert.equals(0, new PreferInline().run(files, new HaxeQueryPlugin()).length, 'an overridden empty hook must stay a real method');
	}

	public function testAbstractClassEmptyBodyFlagged(): Void {
		Assert.equals(
			1, violations('abstract class C {\n\tpublic function noop(index:Int):Void {\n\t\t//TODO: later\n\t}\n}').length,
			'an empty stub in an abstract class is a candidate'
		);
	}

	public function testAbstractSuperclassImplSkips(): Void {
		// An abstract-superclass implementation carries no `override` (Haxe does not
		// require it) — the method fills a base slot and must stay physical.
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'B.hx',
				source: 'abstract class B {\n\tprivate abstract function hook():Void;\n\tprivate abstract function calc():Int;\n}'
			},
			{
				file: 'S.hx',
				source: 'class S extends B {\n\tprivate function hook():Void {}\n\tprivate function calc():Int return 1;\n}'
			}
		];
		Assert.equals(0, new PreferInline().run(files, new HaxeQueryPlugin()).length);
	}

	public function testEmptyBodyMessageNamesTheNoOp(): Void {
		final vs: Array<Violation> = violations(cls('function noop():Void {}'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('empty body') >= 0, vs[0].message);
	}

	/**
	 * A method written inside a member-position `#if` is a method of the class like any other. The
	 * region is ONE child of the container holding every branch's members flattened, so scanning the
	 * container's direct children alone silently exempted it.
	 */
	public function testConditionalMemberFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t#if cpp\n\tpublic function get():Int return 1;\n\t#end\n}').length);
	}

	/**
	 * A modifier written BEFORE the `#if` modifies whichever branch compiles, so it reaches into EVERY
	 * branch: both guarded methods are overrides and neither is a candidate. This is the fixture that
	 * discriminates the per-branch restart — a flat read of the region's flattened children consumes
	 * the `override` on the first member and hands the second one out bare.
	 */
	public function testConditionalOverrideBindsToItsOwnBranch(): Void {
		Assert.equals(
			0,
			violations(
				'class C extends B {\n\toverride\n\t#if cpp\n\tpublic function get():Int return 1;\n\t#else\n'
				+ '\tpublic function calc():Int return 2;\n\t#end\n}'
			).length
		);
	}

	/**
	 * A `@:native` binding's Haxe body is a placeholder the backend discards — the generated call
	 * goes to the foreign symbol. Inlining substitutes the placeholder at the call site instead, so
	 * `nativeThing(x) == 0` silently becomes `0 == 0`. Found on a real tree: the method was inside
	 * `#if cpp` and only became reachable once the region was scanned.
	 */
	public function testNativeMetaMethodNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\t@:native(\'nativeThing\')\n\tprivate static function nativeThing(a:Int):Int return 0;\n'
				+ '\tpublic static function use(a:Int):Bool return nativeThing(a) == 0;\n}'
			).length
		);
	}

	/**
	 * `@:nativeGen` puts the class into the generated output under its own name and the host runtime
	 * calls its methods BY NAME (Unity's `Update()`) — an inlined method has no name there. The
	 * annotation is a module-level sibling BEFORE the class, which the member modifier run never
	 * reaches, so every metadata gate the rule had missed it.
	 */
	public function testNativeGenClassSkips(): Void {
		assertOnlyControlFlagged('@:nativeGen class C extends M {\n\tprivate function Update():Void tick();\n}');
	}

	/**
	 * `@:hlNative` binds every member of the class to a foreign symbol, so the written body is a
	 * placeholder HL discards — inlining substitutes the placeholder at the call site and the binding
	 * never happens. The `@:native` member gate one level up.
	 */
	public function testHlNativeClassSkips(): Void {
		assertOnlyControlFlagged('@:hlNative(\'uv\')\nclass C {\n\tprivate static function stop(h:Int):Bool return false;\n}');
	}

	/**
	 * The class annotation sits inside a `#if` region, so it projects as a `Conditional` sibling and
	 * not as a bare `MetaCall`. The build that defines the flag gets the native binding, so the gate
	 * must refuse on the possibility rather than on the flat reading.
	 */
	public function testConditionalClassMetaSkips(): Void {
		assertOnlyControlFlagged(
			'#if mobile @:hlNative(\'pony\') #end final class C {\n\tprivate static function get_asset(n:Int):Int return 0;\n}'
		);
	}

	/** `@:cppFileCode` injects code the generated class depends on by name — the members stay physical. */
	public function testCppFileCodeClassSkips(): Void {
		assertOnlyControlFlagged('@:cppFileCode(\'int x;\')\nclass C {\n\tprivate static function h():Int return 1;\n}');
	}

	/**
	 * The discriminator for the four gates above: a whitelisted class annotation describes typing, not
	 * code generation, and must not cost the finding. It passes both before and after the change - its
	 * job is to fail if the gate ever over-blocks.
	 */
	public function testNeutralClassMetaStillFlagged(): Void {
		Assert.equals(1, violations('@:nullSafety(Strict)\nfinal class C {\n\tpublic function stop():Void _other.stop();\n}').length);
	}

	/**
	 * A module-level modifier keyword sits BETWEEN the annotation and the declaration as a sibling
	 * node of its own (`(Meta @:nativeGen) (Private) (ClassDecl Inner)`), so a run-ender rule of
	 * "every non-metadata child" attributes the annotation to the keyword — which owns no class body
	 * — and hands the class out bare. Found by probing the gate, not by the report.
	 */
	public function testClassMetaSurvivesModifierKeyword(): Void {
		assertOnlyControlFlagged('@:nativeGen\nprivate class C extends M {\n\tprivate function Update():Void tick();\n}');
	}

	/**
	 * `MemberBranchScan` folds each `#if` branch separately, so an annotation on ONE branch is not a
	 * verdict on the other: the plain branch keeps its finding. The invariant a run-carrier refactor
	 * is most likely to break, since it rests on per-branch state rather than on the flat run.
	 */
	public function testConditionalBranchMetaBlocksOnlyItsOwnBranch(): Void {
		final vs: Array<Violation> = violations(
			'#if cpp\nclass C {\n\tpublic function stop():Void _other.stop();\n}\n#else\n'
			+ '@:nativeGen class D extends M {\n\tprivate function Update():Void tick();\n}\n#end'
		);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue(hasMethod(vs, 'stop'), vs[0].message);
	}

	/** The metadata run resets at each type declaration — a plain class after an annotated one keeps its findings. */
	public function testClassMetaDoesNotLeakToNextType(): Void {
		final vs: Array<Violation> = violations(
			'@:nativeGen class N extends M {\n\tprivate function Update():Void tick();\n}\n\n'
			+ 'class C {\n\tpublic function stop():Void _other.stop();\n}'
		);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue(hasMethod(vs, 'stop'), vs[0].message);
	}

	/**
	 * `@:autoBuild` on the owner means a builder writes an `override` of this method into every
	 * subclass, with no `override` keyword anywhere in the subclass file for the modifier gate to
	 * read. Haxe accepts `inline` on the declaration silently and rejects it at the GENERATED
	 * override site — another file, possibly another project (`Field runCommand is inlined and
	 * cannot be overridden`, the shape found on a real tree).
	 *
	 * The annotation is the owner's OWN, so this fixture is refused by the type-metadata gate and by
	 * the transitive build-macro gate alike — reverting either one leaves it green. The test below is
	 * the one that isolates the transitive gate.
	 */
	public function testBuildMacroOwnerSkips(): Void {
		Assert.equals(0, violations('@:autoBuild(b.B.build())\nclass C {\n\tpublic function runCommand(cmd:String):Void {}\n}').length);
	}

	/**
	 * The build-macro grant is inherited through `extends`: the subclass carries no annotation of its
	 * own, so only `SymbolIndex.transitivelyCarriesBuildMacro` can see it. Reverting that gate is the
	 * one mutation this fixture flips.
	 */
	public function testBuildMacroSupertypeSkips(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'B.hx', source: '@:autoBuild(b.B.build())\nclass B {}' },
			{ file: 'S.hx', source: 'class S extends B {\n\tpublic function runCommand(cmd:String):Void {}\n}' }
		];
		Assert.equals(0, new PreferInline().run(files, new HaxeQueryPlugin()).length);
	}

	/**
	 * `__init__` is a static-init hook the compiler emits for the class; nothing in source ever
	 * calls it, so "mark it inline — the call compiles away" names a call that does not exist.
	 * Found on `hl.UI` in the Haxe std, whose `__init__` forwards to one `@:hlNative` binding —
	 * the class carries no type-level annotation, so the `@:hlNative` / `@:nativeGen` gate above
	 * cannot see it.
	 */
	public function testCompilerInvokedInitHookSkips(): Void {
		assertOnlyControlFlagged('class Boot {\n\tstatic function __init__():Void _other.stop();\n}');
	}

	/** The gate reads the reserved `__…__` convention, not a leading underscore run. */
	public function testAnUnderscorePrefixedOrdinaryMethodIsStillFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function __helper():Void _other.stop();\n}');
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue(hasMethod(vs, '__helper'), vs[0].message);
	}

	/**
	 * A method a FRAMEWORK discovers by name is not a candidate, and the SAME body in a class the
	 * framework does not drive still is — one assertion pair, so neither half passes on its own.
	 * The claim is `NamingSupport.frameworkReachable` through `CheckScan.frameworkReachableMethod`,
	 * the predicate `unused-private` and `unused-public-member` already read; no framework name
	 * appears in the check.
	 *
	 * NOT a soundness gate. Marking a utest `test*` method `inline` is legal and changes nothing —
	 * utest discovers by NAME out of `Context.getBuildFields()` at compile time, and a probe with a
	 * `setup` / sync test / async test / `spec` method printed byte-identical utest output with and
	 * without `inline`. It is a BENEFIT gate: the method's only call site is the one the framework's
	 * own macro writes, so `inline` has nothing to fold it into.
	 */
	public function testFrameworkDiscoveredMethodNotFlagged(): Void {
		Assert.equals(
			0, violations('class T extends Test {\n\tpublic function testThing():Void _other.ping();\n}').length,
			'a utest test method is reached by the framework, never by a written call'
		);
		Assert.equals(
			1, violations('class T extends Helper {\n\tpublic function testThing():Void _other.ping();\n}').length,
			'the same body in a class no contract drives is still a candidate'
		);
	}

	/** The accessory names a contract claims by PREFIX are covered too, not only `test`. */
	public function testFrameworkAccessoryMethodNotFlagged(): Void {
		Assert.equals(
			0, violations('class T extends Test {\n\tpublic function setup():Void _other.reset();\n}').length,
			'`setup` is one of the prefixes the built-in contract claims'
		);
		Assert.equals(
			1, violations('class T extends Test {\n\tpublic function reset():Void _other.reset();\n}').length,
			'a name no prefix claims is still a candidate in the same class'
		);
	}

	/**
	 * The roster is the PROJECT's, not a hardcoded name: a contract declared through the linter's
	 * config resolver carves out a member of a class extending ITS root, and the same member of a
	 * class extending anything else stays a candidate.
	 */
	public function testDeclaredFrameworkContractCarvesOut(): Void {
		final check: PreferInline = new PreferInline();
		check.setConfigResolver(_ -> LintConfig.parse('{"frameworks":[{"root":"MonoBehaviour","names":["Start"],"prefixes":[]}]}'));
		Assert.equals(
			0,
			check.run([
				{ file: 'C.hx', source: 'class T extends MonoBehaviour {\n\tpublic function Start():Void _other.ping();\n}' }
			], new HaxeQueryPlugin())
				.length
		);
		Assert.equals(
			1,
			check.run([
				{ file: 'C.hx', source: 'class T extends Helper {\n\tpublic function Start():Void _other.ping();\n}' }
			], new HaxeQueryPlugin())
				.length
		);
	}

	private function cls(members: String): String {
		return 'class C {\n\t$members\n}';
	}

	/**
	 * Assert that `blockedSource` yields no finding — with a plain control class appended to the same
	 * module, asserted to STILL be flagged. A bare `Assert.equals(0, …)` cannot tell "the gate
	 * blocked it" from "nothing parsed": `CheckScan.parseOrNull` returns null on a parse failure and
	 * `run` then yields `[]`, so a future grammar regression on `#if`-prefixed or argument-carrying
	 * metadata would silently turn every skip fixture into a no-op asserting nothing.
	 */
	private function assertOnlyControlFlagged(blockedSource: String): Void {
		final vs: Array<Violation> =
			violations('$blockedSource\n\nclass Control {\n\tpublic function stillFlagged():Void _other.stop();\n}');
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.isTrue(hasMethod(vs, 'stillFlagged'), vs[0].message);
	}

	private function violations(source: String): Array<Violation> {
		return new PreferInline().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function relaxedViolations(source: String): Array<Violation> {
		final check: PreferInline = new PreferInline();
		check.setOracleRelaxed(true);
		return check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function hasMethod(vs: Array<Violation>, name: String): Bool {
		return vs.exists(v -> v.message.indexOf('\'$name\'') >= 0);
	}

}
