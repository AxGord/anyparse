package unit.check.haxe.imports;

import anyparse.check.Check.FixEdit;
import anyparse.check.Severity;
import anyparse.check.SourceEntry;
import anyparse.check.haxe.imports.PreferUsingOverStaticImport;
import anyparse.query.CanonicalEdit;

/**
 * The `prefer-using-over-static-import` check: `import Ext.deco;` beside `using Ext;` is flagged `Info`, and the fix
 * rewrites each bare `deco(w, 1)` to `w.deco(1)` and deletes the import. An import whose every use is not a provable
 * call with a receiver stays, report-only, with the reason on the finding.
 */
class PreferUsingOverStaticImportCheckTest extends Test {

	private static inline final WIDGET_SOURCE: String = 'class Widget {}\n';
	private static final EXT_SOURCE: String = 'class Ext {\n\tpublic static function deco(w: Widget, n: Int): Widget return w;\n}\n';
	private static final HEAD: String = 'import Ext.deco;\n\nusing Ext;\n\n';

	public function testBareCallsRewrittenAndImportDeleted(): Void {
		final files: Array<SourceEntry> = fileSet(HEAD, 'deco(w, 1);\n\t\tdeco(w, 2);');
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-using-over-static-import', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isNull(vs[0].declineReason);
		final out: String = fixResultOf(files);
		Assert.equals(-1, out.indexOf('import Ext.deco'), out);
		Assert.isTrue(out.indexOf('using Ext;') != -1, out);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('w.deco(2);') != -1, out);
	}

	@:pin('control')
	@:killer('M-PUOSI-NO-USING')
	public function testNoUsingNoFinding(): Void {
		Assert.equals(0, violationsOf(fileSet('import Ext.deco;\n\n', 'deco(w, 1);')).length);
	}

	public function testAliasedAndGuardedImportsAreNoFinding(): Void {
		Assert.equals(0, violationsOf(fileSet('import Ext.deco as d;\n\nusing Ext;\n\n', 'd(w, 1);')).length);
		Assert.equals(0, violationsOf(fileSet('#if FLAG\nimport Ext.deco;\n#end\nusing Ext;\n\n', 'deco(w, 1);')).length);
	}

	public function testUnusedImportIsLeftToUnusedImport(): Void {
		Assert.equals(0, violationsOf(fileSet(HEAD, 'w;')).length);
	}

	@:pin('control')
	@:killer('M-PUOSI-OTHER-USE')
	public function testNonCallUseKeepsImport(): Void {
		final files: Array<SourceEntry> = fileSet(HEAD, 'deco(w, 1);\n\t\tfinal g = deco;');
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.notNull(vs[0].declineReason);
		Assert.equals(0, editsOf(files).length);
	}

	@:pin('control')
	@:killer('M-PUOSI-VERDICT')
	public function testUnprovableReceiverKeepsImport(): Void {
		final source: String = 'import Ext.deco;\n\nusing Ext;\n\nclass C {\n\tfunction f(w):Void {\n\t\tdeco(w, 1);\n\t}\n}\n';
		final files: Array<SourceEntry> = fileSetOf(source);
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.notNull(vs[0].declineReason);
		Assert.equals(0, editsOf(files).length);
	}

	@:pin('control')
	@:killer('M-PUOSI-LOCAL-NAME')
	public function testLocalOfTheSameNameIsNoUseOfTheImport(): Void {
		final source: String = HEAD
			+ 'class C {\n\tfunction f(w:Widget):Void {\n\t\tdeco(w, 1);\n\t}\n\n\tfunction g(deco:Int):Int {\n\t\treturn deco;\n\t}\n}\n';
		final files: Array<SourceEntry> = fileSetOf(source);
		Assert.isNull(violationsOf(files)[0].declineReason);
		final out: String = fixResultOf(files);
		Assert.isTrue(out.indexOf('w.deco(1);') != -1, out);
		Assert.isTrue(out.indexOf('return deco;') != -1, out);
	}

	@:pin('control')
	@:killer('M-PUOSI-BINDING-DECLINE')
	public function testMemberOfTheEnclosingTypeOutranksTheImport(): Void {
		final own: String = '${HEAD}class C {\n\tfunction deco(w:Widget, n:Int):Widget {\n\t\treturn w;\n\t}\n\n'
			+ '\tfunction f(w:Widget):Void {\n\t\tdeco(w, 1);\n\t}\n}\n';
		Assert.equals(0, violationsOf(fileSetOf(own)).length);
		final inherited: String = '${HEAD}class C extends Base {\n\tfunction f(w:Widget):Void {\n\t\tdeco(w, 1);\n\t}\n}\n';
		final files: Array<SourceEntry> = fileSetOf(inherited);
		files.push({ file: 'Base.hx', source: 'class Base {\n\tfunction deco(w:Widget, n:Int):Widget {\n\t\treturn w;\n\t}\n}\n' });
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.notNull(vs[0].declineReason);
		Assert.equals(0, editsOf(files).length);
	}

	public function testCommentInDeletedRegionKeepsImport(): Void {
		final files: Array<SourceEntry> = fileSet(HEAD, 'deco(/* c */ w, 1);');
		Assert.equals(1, violationsOf(files).length);
		Assert.equals(0, editsOf(files).length);
	}

	public function testStringToolsFastCodeAt(): Void {
		final source: String = 'import StringTools.fastCodeAt;\n\nusing StringTools;\n\nclass C {\n\tfunction f(s:String):Int {\n'
			+ '\t\treturn fastCodeAt(s, 0);\n\t}\n}\n';
		final files: Array<SourceEntry> = CheckFixture.withStd(source);
		files.push({
			file: 'StringTools.hx',
			source: 'class StringTools {\n\tpublic static function fastCodeAt(s: String, index: Int): Int return 0;\n}\n'
		});
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.isNull(vs[0].declineReason, vs[0].declineReason);
		final out: String = fixResultOf(files);
		Assert.isTrue(out.indexOf('return s.fastCodeAt(0);') != -1, out);
		Assert.equals(-1, out.indexOf('import StringTools'), out);
	}

	public function testRegisteredInBuiltins(): Void {
		CheckFixture.assertRegistered('prefer-using-over-static-import');
	}

	@:pin('control')
	@:killer('M-PUOSI-INTERP-READ')
	public function testInterpolatedReadKeepsImport(): Void {
		final files: Array<SourceEntry> = fileSet(HEAD, 'trace(\'$$deco\');\n\t\tdeco(w, 1);');
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length);
		Assert.notNull(vs[0].declineReason);
		Assert.equals(0, editsOf(files).length);
	}

	public function testInterpolatedLocalIsNoUseOfTheImport(): Void {
		final source: String = '${HEAD}class C {\n\tfunction f(w:Widget):Void {\n\t\tdeco(w, 1);\n\t}\n\n\tfunction g(deco:Int):String {\n'
			+ '\t\treturn \'$$deco\';\n\t}\n}\n';
		final files: Array<SourceEntry> = fileSetOf(source);
		Assert.isNull(violationsOf(files)[0].declineReason);
		Assert.isTrue(fixResultOf(files).indexOf('w.deco(1);') != -1);
	}

	public function testCallInsideAnInterpolationBlockIsRewritten(): Void {
		final files: Array<SourceEntry> = fileSet(HEAD, 'trace(\'$${deco(w, 1)}\');');
		Assert.isNull(violationsOf(files)[0].declineReason);
		final out: String = fixResultOf(files);
		Assert.isTrue(out.indexOf('$${w.deco(1)}') != -1, out);
		Assert.equals(-1, out.indexOf('import Ext.deco'), out);
	}

	private function fileSet(head: String, body: String): Array<SourceEntry> {
		return fileSetOf('${head}class C {\n\tfunction f(w:Widget):Void {\n\t\t$body\n\t}\n}\n');
	}

	private function fileSetOf(source: String): Array<SourceEntry> {
		return [
			{ file: 'C.hx', source: source },
			{ file: 'Ext.hx', source: EXT_SOURCE },
			{ file: 'Widget.hx', source: WIDGET_SOURCE }
		];
	}

	private function violationsOf(files: Array<SourceEntry>): Array<Violation> {
		return CheckFixture.violationsIn(new PreferUsingOverStaticImport(), files).filter(v -> v.file == files[0].file);
	}

	private function editsOf(files: Array<SourceEntry>): Array<FixEdit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferUsingOverStaticImport = new PreferUsingOverStaticImport();
		final own: Array<Violation> = violationsOf(files);
		return check.fix(files[0].source, own, plugin, CheckFixture.index(files, plugin));
	}

	private function fixResultOf(files: Array<SourceEntry>): String {
		switch CanonicalEdit.canonicalize(files[0].source, editsOf(files), false, new HaxeQueryPlugin()) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
