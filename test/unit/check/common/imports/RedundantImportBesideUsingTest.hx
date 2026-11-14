package unit.check.common.imports;

import anyparse.check.Check;
import anyparse.check.common.imports.RedundantImport;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;

/**
 * `redundant-import` — a plain `import pkg.Mod;` beside an unguarded `using pkg.Mod;` of the same
 * module: the `using` already imports every type the module declares, so the import adds nothing.
 */
class RedundantImportBesideUsingTest extends Test {

	private static final UT: String =
		'package q;\n\nclass Ut {\n\n\tpublic static function up(s:String):String {\n\t\treturn s;\n\t}\n\n}\n';
	private static final BODY: String = '\nclass C {\n\n\tvar u:Ut;\n\n\tfunction f(s:String):String {\n\t\treturn s.up();\n\t}\n\n}\n';

	@:pin('control')
	@:killer('M-IMPORT-BESIDE-USING-TWIN-OFF')
	public function testImportBesideUsingOfTheSameModuleIsRedundant(): Void {
		final src: String = 'package app;\n\nimport q.Ut;\nusing q.Ut;\n$BODY';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('redundant-import', vs[0].rule);
		final span: Null<Span> = vs[0].span;
		Assert.notNull(span);
		if (span != null) Assert.equals(3, span.lineCol(src).line);
	}

	public function testFixDeletesTheImportAndKeepsTheUsing(): Void {
		final src: String = 'package app;\n\nimport q.Ut;\nusing q.Ut;\n$BODY';
		final fixed: String = CanonicalEdit.applyEdits(src, edits(src));
		Assert.isFalse(fixed.contains('import q.Ut;'));
		Assert.isTrue(fixed.contains('using q.Ut;'));
	}

	public function testUsingBelowTheImportOrAboveIsTheSame(): Void {
		Assert.equals(1, violations('package app;\n\nusing q.Ut;\nimport q.Ut;\n$BODY').length);
	}

	public function testUsingOfASubModuleBesideTheModuleImportIsKept(): Void {
		final src: String = 'package app;\n\nimport q.Ut;\nusing q.Ut.Sub;\n$BODY';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'q/Ut.hx', source: '$UT\nclass Sub {}\n' }
		];
		Assert.equals(0, CheckFixture.violationsIn(new RedundantImport(), files).length);
	}

	public function testGuardedUsingDoesNotMakeTheImportRedundant(): Void {
		Assert.equals(0, violations('package app;\n\nimport q.Ut;\n#if js\nusing q.Ut;\n#end\n$BODY').length);
	}

	@:pin('control')
	@:killer('M-IMPORT-TWIN-VALUES-BLIND')
	public function testAModuleLevelFieldKeepsTheImport(): Void {
		final src: String =
			'package app;\n\nimport q.Ut;\nusing q.Ut;\n\nclass C {\n\n\tvar u:Ut;\n\n\tfunction f():Int {\n\t\treturn lvl();\n\t}\n\n}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'q/Ut.hx', source: '$UT\nfunction lvl():Int {\n\treturn 1;\n}\n' }
		];
		Assert.equals(0, CheckFixture.violationsIn(new RedundantImport(), files).length);
	}

	@:pin('control')
	@:killer('M-IMPORT-TWIN-THIRD-BINDER-BLIND')
	public function testAThirdBinderOfTheNameKeepsTheImport(): Void {
		final src: String = 'package app;\n\nimport q.Ut;\nimport r.Ut;\nusing q.Ut;\n$BODY';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'app/C.hx', source: src },
			{ file: 'q/Ut.hx', source: UT },
			{ file: 'r/Ut.hx', source: 'package r;\n\nclass Ut {}\n' }
		];
		Assert.equals(0, CheckFixture.violationsIn(new RedundantImport(), files).length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violationsIn(new RedundantImport(), fileSet(src));
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final files: Array<{ file: String, source: String }> = fileSet(src);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: RedundantImport = new RedundantImport();
		return check.fix(src, CheckFixture.violationsIn(check, files, plugin), plugin, CheckFixture.index(files, plugin));
	}

	private function fileSet(src: String): Array<{ file: String, source: String }> {
		return [{ file: 'app/C.hx', source: src }, { file: 'q/Ut.hx', source: UT }];
	}

}
