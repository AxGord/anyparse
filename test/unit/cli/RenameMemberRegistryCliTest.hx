package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import sys.FileSystem;

using StringTools;

/**
 * End-to-end tests for `apq rename` on a MEMBER a declared registry names: the registry document follows the
 * declaration, in place and under `--scope`, a preview touches nothing, a document the op cannot read refuses the whole
 * rename, and a project that declares no member keys leaves the document alone.
 */
class RenameMemberRegistryCliTest extends Test {

	private static final BASE: String = 'package p;\n\nclass Base {\n\n\tpublic function new() {}\n\n\tpublic function walk(): Int {\n'
		+ '\t\treturn 1;\n\t}\n\n\tpublic function other(): Int {\n\t\tfinal a: Int = 2;\n'
		+ '\t\tif (a > 1) return walk();\n\t\treturn a;\n\t}\n\n}\n';
	private static final CALLER: String =
		'package p;\n\nclass Caller {\n\n\tpublic static function run(b: Base): Int {\n\t\treturn b.walk();\n\t}\n\n}\n';
	private static final ARMS: String = '{"arms": [\n\t{"name": "OWNER", "type": "p.Base", "method": "walk", "find": "return 1;", '
		+ '"replace": "return 2;"},\n\t{"name": "ESCAPED", "type": "p.Base", "method": "other", "find": '
		+ '"final a: Int = 2;\\n\\t\\tif (a > 1) return walk();", "replace": "final a: Int = 3;\\n\\t\\tif ('
		+ 'a > 1) return walk();"},\n\t{"name": "ARRAY", "type": "p.Base", "method": "other", "find": ['
		+ '"return walk();", "return a;"], "replace": ["return walk() + 1;", "return a + walk();"]},\n'
		+ '\t{"name": "FOREIGN", "type": "p.Caller", "method": "run", "find": "b.walk()", "replace": '
		+ '"b.walk() + 1"},\n\t{"name": "FORCED", "type": "p.Far", "method": "x", "force": "walk"}\n]}\n';
	private static final MEMBERS: String = '"members": {"records": "arms", "name": "name", "type": "type", "member": "method", "kind": '
		+ '"kind", "defaultKind": "FnMember", "find": "find", "replace": "replace", "opaque": ["force"]}';
	private static final FOLLOWED: Array<String> = [
		'"method": "step", "find": "return 1;"',
		'"find": "final a: Int = 2;\\n\\t\\tif (a > 1) return step();", "replace": "final a: Int = 3;\\n\\t\\tif (a > 1) return step();"',
		'"find": ["return step();", "return a;"], "replace": ["return step() + 1;", "return a + step();"]',
		'"find": "b.step()", "replace": "b.step() + 1"',
		'"force": "walk"'
	];

	public function testTheRegistryFollowsAScopeRename(): Void {
		#if (sys || nodejs)
		final dir: String = project(MEMBERS);
		final printed: String = CliFixture.captureStderr(() -> Assert.equals(0, renameInScope(dir, true)));
		final document: String = File.getContent('$dir/reg/p.json');
		for (spelling in FOLLOWED) Assert.isTrue(document.contains(spelling), '$spelling in $document');
		Assert.isTrue(printed.contains('arm FORCED:'), printed);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTheRegistryFollowsAnInFileRename(): Void {
		#if (sys || nodejs)
		final dir: String = project(MEMBERS);
		final printed: String = CliFixture.captureStderr(() -> Assert.equals(0, renameInFile(dir, true)));
		final document: String = File.getContent('$dir/reg/p.json');
		Assert.isTrue(File.getContent('$dir/src/p/Base.hx').contains('function step()'));
		Assert.isTrue(document.contains(FOLLOWED[0]), document);
		Assert.isTrue(document.contains(FOLLOWED[1]), document);
		Assert.isTrue(document.contains('"find": "b.walk()"'), 'the file the in-file rename left alone keeps its record: $document');
		Assert.isTrue(printed.contains('arm FORCED:'), printed);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testEveryFollowedCutAppliesAfterTheRename(): Void {
		#if (sys || nodejs)
		final dir: String = project(MEMBERS);
		CliFixture.captureStderr(() -> Assert.equals(0, renameInScope(dir, true)));
		final base: String = '$dir/src/p/Base.hx';
		final caller: String = '$dir/src/p/Caller.hx';
		applies(base, 'FnMember:step', 'return 1;\n====\nreturn 2;');
		applies(
			base, 'FnMember:other',
			'final a: Int = 2;\n\t\tif (a > 1) return step();\n====\nfinal a: Int = 3;\n\t\tif (a > 1) return step();'
		);
		applies(base, 'FnMember:other', 'return step();\n====\nreturn step() + 1;\n====\nreturn a;\n====\nreturn a + step();');
		applies(caller, 'FnMember:run', 'b.step()\n====\nb.step() + 1');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAPreviewLeavesTheRegistryAndNamesIt(): Void {
		#if (sys || nodejs)
		final dir: String = project(MEMBERS);
		final scopeOut: String = CliFixture.captureStdout(() ->
			CliFixture.captureStderr(() -> Assert.equals(0, renameInScope(dir, false)))
		);
		Assert.isTrue(scopeOut.contains('reg/p.json: '), scopeOut);
		Assert.equals(ARMS, File.getContent('$dir/reg/p.json'));
		var inFile: String = '';
		CliFixture.captureStdout(() -> inFile = CliFixture.captureStderr(() -> Assert.equals(0, renameInFile(dir, false))));
		Assert.isTrue(inFile.contains('reg/p.json would follow'), inFile);
		Assert.isTrue(inFile.contains('arm FORCED:'), inFile);
		Assert.equals(ARMS, File.getContent('$dir/reg/p.json'));
		Assert.equals(BASE, File.getContent('$dir/src/p/Base.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testADocumentThatDoesNotParseRefusesBeforeAnyWrite(): Void {
		#if (sys || nodejs)
		final dir: String = project(MEMBERS);
		File.saveContent('$dir/reg/p.json', '{"arms": [');
		refusesBoth(dir, 'reg/p.json');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testADocumentThatCannotBeReadRefusesBeforeAnyWrite(): Void {
		#if (sys || nodejs)
		final dir: String = project(MEMBERS);
		FileSystem.createDirectory('$dir/reg/q.json');
		refusesBoth(dir, 'reg/q.json');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAMoveSectionThatDoesNotReadRefusesBeforeAnyWrite(): Void {
		#if (sys || nodejs)
		final dir: String = project('"members": {"record": "arms"}');
		refusesBoth(dir, 'apq.json');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testARegistryWithoutMemberKeysIsLeftAlone(): Void {
		#if (sys || nodejs)
		final dir: String = project('"byPackage": true');
		CliFixture.captureStderr(() -> Assert.equals(0, renameInFile(dir, true)));
		Assert.isTrue(File.getContent('$dir/src/p/Base.hx').contains('function step()'));
		Assert.equals(ARMS, File.getContent('$dir/reg/p.json'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function renameInFile(dir: String, write: Bool): Int {
		return Cli.run(['rename', '$dir/src/p/Base.hx', '--select', 'FnMember:walk', 'step'].concat(write ? ['--write'] : []));
	}

	private static function renameInScope(dir: String, write: Bool): Int {
		return Cli.run([
			'rename',
			'$dir/src/p/Base.hx',
			'--select',
			'FnMember:walk',
			'step',
			'--scope',
			'$dir/src'
		].concat(write ? ['--write'] : []));
	}

	/** Both paths, written and previewed, refuse naming `named` and leave the tree as it was. */
	private static function refusesBoth(dir: String, named: String): Void {
		for (write in [true, false]) for (run in [renameInFile, renameInScope]) {
			final printed: String = CliFixture.captureStderr(() -> Assert.notEquals(0, run(dir, write)));
			Assert.isTrue(printed.contains(named), printed);
			Assert.isTrue(printed.contains('nothing written'), printed);
			Assert.equals(BASE, File.getContent('$dir/src/p/Base.hx'));
			Assert.equals(CALLER, File.getContent('$dir/src/p/Caller.hx'));
		}
	}

	/** `apq patch` takes the cut, as the arm applier hands it. */
	private static function applies(file: String, select: String, payload: String): Void {
		final path: String = '$file.payload';
		File.saveContent(path, payload);
		final printed: String = CliFixture.captureStderr(() -> {
			CliFixture.captureStdout(() -> Assert.equals(0, Cli.run(['patch', file, '--select', select, '--from-file', path])));
		});
		Assert.isFalse(printed.contains('does not occur'), printed);
		FileSystem.deleteFile(path);
	}

	/** A project of two modules, its arms registry and an `apq.json` whose registry entry carries `extra`. */
	private static function project(extra: String): String {
		return CliFixture.writeTree('rn_member_registry', [
			{ name: 'src/p/Base.hx', source: BASE },
			{ name: 'src/p/Caller.hx', source: CALLER },
			{ name: 'reg/p.json', source: ARMS },
			{ name: 'hxformat.json', source: File.getContent('hxformat.json') },
			{
				name: 'apq.json',
				source: '{"move": {"scope": ["src"], "registries": [{"file": "reg", "keys": ["arms.type"], $extra}]}}\n'
			}
		]);
	}
	#end

}
