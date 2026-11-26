package unit.check.common.design;

import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.SourceEntry;
import anyparse.check.common.design.PreferPrivateSecondaryType;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.util.Compare;
import sys.io.File;
import unit.cli.CliFixture;

/**
 * The `prefer-private-secondary-type` check: a secondary type nothing outside its module names becomes `private`. A
 * typedef, an abstract and an enum abstract are rewritten, an enum only while no run-time type-name API occurs in
 * scope, a class and an interface are reported alone. An import, a qualified path, a conditional use, a string path, a
 * bare constructor, a same-named type and the metadata of the type keep it public.
 */
class PreferPrivateSecondaryTypeCheckTest extends Test {

	private static inline final PANEL_FILE: String = 'src/pkg/Panel.hx';
	private static final PANEL: String = 'package pkg;\n\ntypedef PanelOptions = {width:Int, ?title:String}\n\nenum Mode {\n\tA;\n\tB;\n'
		+ '}\n\nclass Panel {\n\tpublic function new(o:PanelOptions, m:Mode) {}\n\n'
		+ '\tpublic function def():Mode\n\t\treturn A;\n}\n';

	@:pin('control')
	@:killer('M-PPST-NO-FIX')
	public function testTheTypedefAndTheEnumBecomePrivateAndTheMainTypeStays(): Void {
		final files: Array<SourceEntry> = [panel()];
		Assert.same(['Mode', 'PanelOptions'], reported(files));
		final text: String = fixed(files);
		Assert.isTrue(text.contains('private typedef PanelOptions'), text);
		Assert.isTrue(text.contains('private enum Mode'), text);
		Assert.isFalse(text.contains('private class'), text);
	}

	@:pin('guard')
	public function testAnImportFromAnotherFileKeepsTheTypePublic(): Void {
		final user: SourceEntry = user('import pkg.Panel.Mode;\n\n', 'public var m:Mode;');
		Assert.same(['PanelOptions'], reported([panel(), user]));
	}

	@:pin('guard')
	public function testAQualifiedPathFromAnotherFileKeepsTheTypePublic(): Void {
		Assert.same(['PanelOptions'], reported([panel(), user('', 'public var m:pkg.Panel.Mode;')]));
	}

	@:pin('guard')
	public function testAUseInAConditionalBranchKeepsTheTypePublic(): Void {
		Assert.same(['PanelOptions'], reported([panel(), user('', '#if neko\n\tpublic var m:pkg.Panel.Mode;\n\t#end')]));
	}

	@:pin('guard')
	public function testAStringNamingTheTypeKeepsItPublic(): Void {
		final user: SourceEntry = user('', 'public function f():Dynamic return Type.resolveEnum(\'pkg.Panel.Mode\');');
		Assert.same(['PanelOptions'], reported([panel(), user]));
	}

	@:pin('control')
	@:killer('M-PPST-NO-PROOF')
	public function testABareConstructorOfAnotherFileKeepsTheTypePublic(): Void {
		Assert.same(['PanelOptions'], reported([panel(), user('', 'public function f(x:Dynamic):Bool return x == A;')]));
	}

	@:pin('guard')
	public function testASameNamedTypeInAnotherModuleKeepsTheTypePublic(): Void {
		final other: SourceEntry = { file: 'src/other/Mode.hx', source: 'package other;\n\nenum Mode {\n\tX;\n}\n' };
		Assert.same(['PanelOptions'], reported([panel(), other]));
	}

	@:pin('control')
	@:killer('M-PPST-META')
	public function testMetadataOnTheTypeKeepsItPublic(): Void {
		for (meta in ['@:keep', '@:rtti', '@:expose', '@:native("X")', '@:build(Macros.run())']) {
			final source: String =
				'package pkg;\n\n$meta\ntypedef Opts = { a:Int }\n\nclass Panel {\n\tpublic function new(o:Opts) {}\n}\n';
			Assert.same([], reported([{ file: PANEL_FILE, source: source }]), meta);
		}
	}

	@:pin('control')
	@:killer('M-PPST-MAIN')
	public function testTheMainTypeAndAPrivateTypeAreLeftAlone(): Void {
		final source: String = 'package pkg;\n\nprivate typedef Opts = { a:Int }\n\nclass Panel {\n\tpublic function new(o:Opts) {}\n}\n';
		Assert.same([], reported([{ file: PANEL_FILE, source: source }]));
	}

	@:pin('control')
	@:killer('M-PPST-CLASS-REWRITTEN')
	public function testAClassAndAnInterfaceAreReportedNotRewritten(): Void {
		final source: String = 'package pkg;\n\nclass Panel {\n\tpublic function new(h:Helper, p:Part) {}\n}\n\n'
			+ 'class Helper {\n\tpublic function new() {}\n}\n\ninterface Part {}\n';
		final files: Array<SourceEntry> = [{ file: PANEL_FILE, source: source }];
		Assert.same(['Helper', 'Part'], reported(files));
		for (v in violations(files)) Assert.notNull(v.declineReason, v.message);
		Assert.equals(source, fixed(files, source));
	}

	@:pin('control')
	@:killer('M-PPST-RUNTIME-NAMES')
	public function testAnEnumIsReportedNotRewrittenWhenTheProjectReadsRunTimeNames(): Void {
		final user: SourceEntry = user('', 'public function n(x:Dynamic):String return Type.getEnumName(x);');
		final files: Array<SourceEntry> = [panel(), user];
		Assert.same(['Mode', 'PanelOptions'], reported(files));
		final text: String = fixed(files);
		Assert.isTrue(text.contains('private typedef PanelOptions') && !text.contains('private enum'), text);
	}

	public function testRegisteredAndOffByDefault(): Void {
		Assert.notNull(Linter.byId('prefer-private-secondary-type'));
		final files: Array<SourceEntry> = [panel()];
		final off: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> LintConfig.parse('{}'), true);
		Assert.equals(0, off.filter(v -> v.rule == 'prefer-private-secondary-type').length);
		final on: LintConfig = LintConfig.parse('{"rules": {"prefer-private-secondary-type": {"enabled": true}}}');
		final found: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> on, true);
		Assert.equals(2, found.filter(v -> v.rule == 'prefer-private-secondary-type').length);
	}

	@:pin('control')
	@:killer('M-PPST-NO-FIX')
	public function testTheCliFixWritesPrivate(): Void {
		final dir: String = CliFixture.writeTree('prefer-private-secondary-type-fix', [
			{ name: 'apq.json', source: '{"rules":{"prefer-private-secondary-type":{"enabled":true}}}' },
			{ name: PANEL_FILE, source: PANEL }
		]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			CliFixture.runIn(dir, ['lint', 'src', '--rule', 'prefer-private-secondary-type', '--all', '--fix']);
			final text: String = File.getContent('$dir/$PANEL_FILE');
			Assert.isTrue(text.contains('private typedef PanelOptions') && text.contains('private enum Mode'), text);
		});
	}

	@:pin('control')
	@:killer('M-PPST-AT-FILE-START')
	public function testPrivateGoesAfterTheNameInertMetadataAndBeforeTheKeyword(): Void {
		final source: String = 'package pkg;\n\n/** Options doc. */\ntypedef PanelOptions = {width:Int};\n\n@:forward\n'
			+ 'abstract ForwardBox(Array<Int>) {\n\tpublic inline function new(a:Array<Int>)\n\t\tthis = a;\n}\n\n'
			+ '@:nullSafety(Strict)\nenum abstract Kind(Int) {\n\tvar K1 = 1;\n}\n\nclass Panel {\n'
			+ '\tpublic function new(o:PanelOptions, w:ForwardBox, k:Kind) {}\n}\n';
		final files: Array<SourceEntry> = [{ file: PANEL_FILE, source: source }];
		Assert.same(['ForwardBox', 'Kind', 'PanelOptions'], reported(files));
		final text: String = fixed(files, source);
		Assert.isTrue(text.contains('/** Options doc. */\nprivate typedef PanelOptions'), text);
		Assert.isTrue(text.contains('@:forward\nprivate abstract ForwardBox'), text);
		Assert.isTrue(text.contains('@:nullSafety(Strict)\nprivate enum abstract Kind'), text);
	}

	private function violations(files: Array<SourceEntry>): Array<Violation> {
		return CheckFixture.violationsIn(new PreferPrivateSecondaryType(), files);
	}

	/** The sorted names of the types the check reports in `files`. */
	private function reported(files: Array<SourceEntry>): Array<String> {
		final names: Array<String> = violations(files).map(v -> v.message.split(' ')[1]);
		names.sort(Compare.compareString);
		return names;
	}

	/** The source of `PANEL_FILE` with every fix of the check applied. */
	private function fixed(files: Array<SourceEntry>, ?source: String): String {
		final check: PreferPrivateSecondaryType = new PreferPrivateSecondaryType();
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final text: String = source ?? PANEL;
		final found: Array<Violation> = CheckFixture.violationsIn(check, files, plugin).filter(v -> v.file == PANEL_FILE);
		return CanonicalEdit.applyEdits(text, check.fix(text, found, plugin));
	}

	private static function panel(): SourceEntry {
		return { file: PANEL_FILE, source: PANEL };
	}

	/** A class of package `app` with `imports` before it and `member` inside. */
	private static function user(imports: String, member: String): SourceEntry {
		return { file: 'src/app/User.hx', source: 'package app;\n\n${imports}class User {\n\t$member\n}\n' };
	}

}
