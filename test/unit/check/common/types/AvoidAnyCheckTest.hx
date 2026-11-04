package unit.check.common.types;

import anyparse.check.LintConfig;
import anyparse.check.Severity;
import anyparse.check.common.types.AvoidAny;
import anyparse.check.common.types.AvoidDynamic;
import anyparse.runtime.Span;

using StringTools;

/**
 * The `avoid-any` check: `Any` in a declared type position is flagged `Info` through the walk `avoid-dynamic`
 * runs, so the positions, the exact-token span, the extern skip and the `excludePaths` / `excludeMeta` options
 * are the same. The two rules never claim each other's name.
 */
class AvoidAnyCheckTest extends Test {

	public function testEachDeclaredPositionFlagged(): Void {
		final cases: Array<{ src: String, word: String }> = [
			{ src: 'class C {\n\tvar x:Any;\n}', word: 'field' },
			{ src: 'class C {\n\tfunction f(p:Any):Void {}\n}', word: 'parameter' },
			{ src: 'class C {\n\tfunction f():Any { return null; }\n}', word: 'return' },
			{ src: 'class C {\n\tvar m:Map<String, Any>;\n}', word: 'type argument' },
			{ src: 'class C {\n\tfunction f():Void {\n\t\tvar x:Any = null;\n\t}\n}', word: 'local' }
		];
		for (c in cases) {
			final vs: Array<Violation> = violations(c.src);
			Assert.equals(1, vs.length, c.src);
			Assert.equals('avoid-any', vs[0].rule);
			Assert.equals(Severity.Info, vs[0].severity);
			Assert.isTrue(vs[0].message.contains(c.word), vs[0].message);
			Assert.equals('Any', slice(c.src, vs[0]));
		}
	}

	public function testMessageNamesTheSchemaWay(): Void {
		final vs: Array<Violation> = violations('class C {\n\tvar x:Any;\n}');
		Assert.isTrue(vs[0].message.contains('schema typedef'), vs[0].message);
	}

	public function testDynamicAndAnyAreEachOthersBlindSpot(): Void {
		final src: String = 'class C {\n\tvar a:Any;\n\tvar d:Dynamic;\n}';
		final any: Array<Violation> = violations(src);
		Assert.equals(1, any.length);
		Assert.equals('Any', slice(src, any[0]));
		final dyn: Array<Violation> = CheckFixture.violations(new AvoidDynamic(), src);
		Assert.equals(1, dyn.length);
		Assert.equals('avoid-dynamic', dyn[0].rule);
		Assert.equals('Dynamic', slice(src, dyn[0]));
	}

	public function testLongerNameNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tvar a:AnyThing;\n\tvar b:pkg.Any;\n}').length);
	}

	public function testExternMembersSkipped(): Void {
		Assert.equals(0, violations('extern class E {\n\tvar x:Any;\n}').length);
	}

	public function testExcludeMetaConfig(): Void {
		final check: AvoidAny = new AvoidAny();
		check.setConfigResolver(_ -> LintConfig.parse('{"rules":{"avoid-any":{"excludeMeta":["@:keep"]}}}'));
		final vs: Array<Violation> = CheckFixture.violations(check, 'class C {\n\t@:keep var kept:Any;\n\tvar plain:Any;\n}');
		Assert.equals(1, vs.length);
	}

	public function testExcludePathsConfig(): Void {
		final config: LintConfig = LintConfig.parse('{"rules":{"avoid-any":{"excludePaths":["interop/"]}}}');
		final files: Array<{ file: String, source: String }> = [
			{ file: 'src/interop/Native.hx', source: 'class C {\n\tvar x:Any;\n}' },
			{ file: 'src/app/Main.hx', source: 'class D {\n\tvar y:Any;\n}' }
		];
		final vs: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), [new AvoidAny()], _ -> config, true);
		Assert.equals(1, vs.length);
		Assert.equals('src/app/Main.hx', vs[0].file);
	}

	public function testReportOnlyAndOffByDefault(): Void {
		final src: String = 'class C {\n\tvar x:Any;\n}';
		final check: AvoidAny = new AvoidAny();
		Assert.equals(0, CheckFixture.fixOf(check, src, CheckFixture.violations(check, src)).length);
		Assert.notNull(Linter.byId('avoid-any'));
		final off: Array<Violation> = Linter.run(
			[{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), Linter.builtins(), _ -> LintConfig.parse('{}'), true
		);
		Assert.equals(0, off.filter(v -> v.rule == 'avoid-any').length);
	}

	private function slice(src: String, v: Violation): String {
		final span: Null<Span> = v.span;
		return span == null ? '' : src.substring(span.from, span.to);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new AvoidAny(), src);
	}

}
