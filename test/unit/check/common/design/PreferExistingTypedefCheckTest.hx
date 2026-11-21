package unit.check.common.design;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.SourceEntry;
import anyparse.check.common.design.PreferExistingTypedef;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import sys.io.File;
import unit.cli.CliFixture;

/**
 * The `prefer-existing-typedef` check: an anonymous structure TYPE that exactly one project typedef already spells is
 * rewritten to the typedef's name, with the import the printer decides. No configuration names anything — the typedef IS the
 * decision. A shape two typedefs spell, a typedef that carries metadata, sits under `#if`, takes type parameters or is private
 * to another module, and a structure whose type names bind to other declarations than the typedef's, are never rewritten.
 */
class PreferExistingTypedefCheckTest extends Test {

	private static inline final STRUCTURE: String = '{ b:String, a:Int }';

	/** The same structure in the writer spelling: a `--fix` over a tree refuses a file that is not canonical. */
	private static inline final SHAPE: String = '{b:String, a:Int}';

	@:pin('control')
	@:killer('M-PET-NO-PLAN')
	public function testAReorderedStructureBecomesTheTypedef(): Void {
		final files: Array<SourceEntry> = [pair('typedef Pair = { a:Int, b:String };'), user('app')];
		final found: Array<Violation> = violations(files);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.contains('typedef pkg.Pair'), found[0].message);
		Assert.isNull(found[0].declineReason);
		final groups: Array<Array<CrossFileEdits>> = fixGroups(files);
		Assert.equals(1, groups.length);
		final text: String = applied(files, groups[0])['src/app/User.hx'] ?? '';
		Assert.isTrue(text.contains('f(): Pair') && text.contains('import pkg.Pair;') && !text.contains('b:String'), text);
	}

	public function testTheTypedefsOwnPackageNeedsNoImport(): Void {
		final files: Array<SourceEntry> = [pair('typedef Pair = { a:Int, b:String };'), user('pkg')];
		final groups: Array<Array<CrossFileEdits>> = fixGroups(files);
		Assert.equals(1, groups.length);
		final text: String = applied(files, groups[0])['src/pkg/User.hx'] ?? '';
		Assert.isTrue(text.contains('f(): Pair') && !text.contains('import'), text);
	}

	@:pin('control')
	@:killer('M-PET-AMBIGUOUS')
	public function testTwoTypedefsOfTheShapeAreReportedNotRewritten(): Void {
		final files: Array<SourceEntry> = [
			pair('typedef Pair = { a:Int, b:String };\ntypedef Twin = { b:String, a:Int };'),
			user('app')
		];
		final found: Array<Violation> = violations(files);
		Assert.equals(1, found.length);
		Assert.isTrue((found[0].declineReason ?? '').contains('ambiguous'), found[0].message);
		Assert.equals(0, fixGroups(files).length);
	}

	@:pin('control')
	@:killer('M-PET-DENOTES')
	public function testTheSameNameOverAnotherDeclarationIsNotTheSameType(): Void {
		final files: Array<SourceEntry> = [
			{ file: 'src/one/Foo.hx', source: 'package one;\n\nclass Foo {}\n' },
			{ file: 'src/two/Foo.hx', source: 'package two;\n\nclass Foo {}\n' },
			pair('typedef Pair = { a:Foo, b:Int };', 'import one.Foo;'),
			{
				file: 'src/app/User.hx',
				source: 'package app;\n\nimport two.Foo;\n\nclass User {\n\tpublic function f(): { a:Foo, b:Int } return null;\n}\n'
			}
		];
		Assert.equals(0, violations(files).length);
		final same: Array<SourceEntry> = files.slice(0, 3).concat([
			{
				file: 'src/app/User.hx',
				source: 'package app;\n\nimport one.Foo;\n\nclass User {\n\tpublic function f(): { a:Foo, b:Int } return null;\n}\n'
			}
		]);
		Assert.equals(1, violations(same).length);
	}

	@:pin('control')
	@:killer('M-PET-META')
	public function testATypedefWithMetadataIsReportedNotRewritten(): Void {
		final files: Array<SourceEntry> = [pair('@:structInit\ntypedef Pair = { a:Int, b:String };'), user('app')];
		assertRefused(files, 'metadata');
	}

	@:pin('control')
	@:killer('M-PET-PARAMS')
	public function testAParameterisedTypedefIsReportedNotRewritten(): Void {
		assertRefused([pair('typedef Pair<T> = { a:Int, b:String };'), user('app', STRUCTURE)], 'type parameters');
	}

	@:pin('control')
	@:killer('M-PET-GUARD')
	public function testAConditionalTypedefIsReportedNotRewritten(): Void {
		final files: Array<SourceEntry> = [pair('#if js\ntypedef Pair = { a:Int, b:String };\n#end'), user('app')];
		assertRefused(files, 'conditional');
	}

	@:pin('control')
	@:killer('M-PET-PRIVATE')
	public function testAnotherModulesPrivateTypedefIsReportedNotRewritten(): Void {
		final files: Array<SourceEntry> = [pair('private typedef Pair = { a:Int, b:String };'), user('pkg')];
		assertRefused(files, 'private');
	}

	public function testTheTypedefBodiesAreNotOccurrences(): Void {
		final files: Array<SourceEntry> = [pair('typedef Pair = { a:Int, b:String };\ntypedef Twin = { b:String, a:Int };')];
		Assert.equals(0, violations(files).length);
	}

	public function testADifferentShapeIsLeftAlone(): Void {
		final files: Array<SourceEntry> = [
			pair('typedef Pair = { a:Int, b:String };'),
			user('app', '{ b:String, a:Float }')
		];
		Assert.equals(0, violations(files).length);
		Assert.equals(0, violations([files[0], user('app', '{ a:Int, ?b:String }')]).length);
	}

	public function testRegisteredAndOffByDefault(): Void {
		Assert.notNull(Linter.byId('prefer-existing-typedef'));
		final files: Array<SourceEntry> = [pair('typedef Pair = { a:Int, b:String };'), user('app')];
		final off: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> LintConfig.parse('{}'), true);
		Assert.equals(0, off.filter(v -> v.rule == 'prefer-existing-typedef').length);
		final on: LintConfig = LintConfig.parse('{"rules": {"prefer-existing-typedef": {"enabled": true}}}');
		final reported: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> on, true);
		Assert.equals(1, reported.filter(v -> v.rule == 'prefer-existing-typedef').length);
	}

	@:pin('control')
	@:killer('M-PET-NO-PLAN')
	public function testTheCliFixWritesTheNameAndTheImport(): Void {
		final dir: String = CliFixture.writeTree('prefer-existing-typedef-fix', [
			{ name: 'apq.json', source: '{"rules":{"prefer-existing-typedef":{"enabled":true}}}' },
			{ name: 'src/pkg/Pair.hx', source: 'package pkg;\n\ntypedef Pair = {a:Int, b:String};\n' },
			{
				name: 'src/app/User.hx',
				source: 'package app;\n\nclass User {\n\tpublic function f():$SHAPE {\n\t\treturn null;\n\t}\n\n'
				+ '\tpublic function g(p:$SHAPE):Void {}\n}\n'
			}
		]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			CliFixture.runIn(dir, ['lint', 'src', '--rule', 'prefer-existing-typedef', '--all', '--fix']);
			final text: String = File.getContent('$dir/src/app/User.hx');
			Assert.isTrue(text.contains('import pkg.Pair;') && text.contains('f():Pair') && !text.contains('b:String'), text);
			Assert.equals(2, text.split(':Pair').length - 1);
		});
	}

	@:pin('control')
	@:killer('M-PET-PARAM-SHADOW')
	public function testATypeParameterOfTheClassOrTheFunctionIsNotTheTypedefsType(): Void {
		final foo: SourceEntry = { file: 'src/pkg/Foo.hx', source: 'package pkg;\n\nclass Foo {}\n' };
		final named: SourceEntry = pair('typedef Pair = { a:Foo };');
		final plain: SourceEntry = {
			file: 'src/pkg/D.hx',
			source: 'package pkg;\n\nclass D {\n\tpublic function f(): { a:Foo } return null;\n}\n'
		};
		Assert.equals(1, violations([foo, named, plain]).length);
		final ofClass: SourceEntry = {
			file: 'src/pkg/C.hx',
			source: 'package pkg;\n\nclass C<Foo> {\n\tpublic function f(): { a:Foo } return null;\n}\n'
		};
		final ofFunction: SourceEntry = {
			file: 'src/pkg/E.hx',
			source: 'package pkg;\n\nclass E {\n\tpublic function f<Foo>(): { a:Foo } return null;\n}\n'
		};
		Assert.equals(0, violations([foo, named, ofClass]).length);
		Assert.equals(0, violations([foo, named, ofFunction]).length);
	}

	@:pin('control')
	@:killer('M-PET-NESTED')
	public function testAStructureInsideAnotherRewrittenOneIsLeftToTheOuterEdit(): Void {
		final files: Array<SourceEntry> = [
			pair('typedef Inner = { a:Int, b:String };\ntypedef Outer = { x:{ a:Int, b:String } };'),
			user('pkg', '{ x:{ a:Int, b:String } }')
		];
		Assert.equals(1, violations(files).filter(v -> v.file == 'src/pkg/User.hx').length);
		final groups: Array<Array<CrossFileEdits>> = fixGroups(files).filter(g -> g[0].file == 'src/pkg/User.hx');
		Assert.equals(1, groups.length);
		final text: String = applied(files, groups[0])['src/pkg/User.hx'] ?? '';
		Assert.isTrue(text.contains('f(): Outer') && text.contains('import pkg.Pair.Outer;') && !text.contains('Inner'), text);
	}

	/** One finding naming the typedef, carrying the reason it is not rewritten, and no fix group. */
	private function assertRefused(files: Array<SourceEntry>, reason: String): Void {
		final found: Array<Violation> = violations(files);
		Assert.equals(1, found.length);
		Assert.isTrue((found[0].declineReason ?? '').contains(reason), found[0].message);
		Assert.equals(0, fixGroups(files).length);
	}

	private function violations(files: Array<SourceEntry>): Array<Violation> {
		return CheckFixture.violationsIn(new PreferExistingTypedef(), files);
	}

	private function fixGroups(files: Array<SourceEntry>): Array<Array<CrossFileEdits>> {
		final check: PreferExistingTypedef = new PreferExistingTypedef();
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final found: Array<Violation> = CheckFixture.violationsIn(check, files, plugin);
		return check.crossFileFix(files, found, plugin, CheckFixture.index(files, plugin));
	}

	/** The module `pkg.Pair` holding `declaration`, after the optional `imports` line. */
	private static function pair(declaration: String, ?imports: String): SourceEntry {
		return { file: 'src/pkg/Pair.hx', source: 'package pkg;\n\n${imports == null ? '' : imports + '\n\n'}$declaration\n' };
	}

	/** A class of package `pkg` with one method returning `structure`. */
	private static function user(pkg: String, structure: String = STRUCTURE): SourceEntry {
		return { file: 'src/$pkg/User.hx', source: 'package $pkg;\n\nclass User {\n\tpublic function f(): $structure return null;\n}\n' };
	}

	/** `files` with the slices applied: an edit list is spliced into the file's source. */
	private static function applied(files: Array<SourceEntry>, slices: Array<CrossFileEdits>): Map<String, String> {
		final out: Map<String, String> = [ for (f in files) f.file => f.source ];
		for (slice in slices) out[slice.file] = CanonicalEdit.applyEdits(out[slice.file] ?? '', slice.edits);
		return out;
	}

}
