package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

using StringTools;

/**
 * `apq rename --scope` on a field of a `typedef` structure, and the scope the op is given. A field of a structure has no value
 * binding, so the declaration and the object literals building it were left behind while a typed read moved: a tree that does
 * not compile, reported as a success.
 */
class RenameTypedefFieldCliTest extends Test {

	#if (sys || nodejs)
	/** A structure, a literal returned as it, a literal an annotated local holds, and a read through an annotated parameter. */
	private static final DECLARING: String = 'package p;\n\ntypedef Ctx = {\n\tfinal flag: Bool;\n\tfinal other: Int;\n}\n\nclass Build {\n'
		+ '\tpublic static function make(): Ctx {\n\t\treturn {flag: true, other: 1};\n\t}\n\n'
		+ '\tpublic static function held(): Bool {\n\t\tfinal c: Ctx = {flag: false, other: 2};\n\t\treturn c.flag;\n\t}\n}\n';
	private static final READER: String =
		'package p;\n\nimport p.Build.Ctx;\n\nclass Reader {\n\tpublic static function read(c: Ctx): Bool {\n\t\treturn c.flag;\n\t}\n}\n';
	#end

	/** The declaration, both literals and the reads of every file move together. */
	@:killer('M-STRUCTURE-FIELD-DECL')
	@:pin('control')
	public function testDeclarationLiteralsAndReadsAllMove(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('rntypedeffield', [
			{ name: 'src/p/Build.hx', source: DECLARING },
			{ name: 'src/p/Reader.hx', source: READER }
		]);
		final rc: Int = Cli.run([
			'rename',
			'$dir/src/p/Build.hx',
			'--select',
			'FinalField:flag',
			'enabled',
			'--scope',
			'$dir/src',
			'--write'
		]);
		Assert.equals(0, rc);
		final declaring: String = File.getContent('$dir/src/p/Build.hx');
		final reader: String = File.getContent('$dir/src/p/Reader.hx');
		Assert.isFalse(declaring.contains('flag'), declaring);
		Assert.isFalse(reader.contains('flag'), reader);
		Assert.isTrue(declaring.contains('final enabled: Bool;'), declaring);
		Assert.isTrue(declaring.contains('{enabled: true, other: 1}'), declaring);
		Assert.isTrue(declaring.contains('{enabled: false, other: 2}'), declaring);
		Assert.isTrue(declaring.contains('return c.enabled;'), declaring);
		Assert.isTrue(reader.contains('return c.enabled;'), reader);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Each `--scope` counts: a read in the second directory moves with the first's, none is dropped silently. */
	@:killer('M-RENAME-SCOPE-REPEAT')
	@:pin('control')
	public function testEveryRepeatedScopeIsCovered(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('rntypedefscopes', [
			{ name: 'src/p/Build.hx', source: DECLARING },
			{ name: 'test/p/Reader.hx', source: READER }
		]);
		final rc: Int = Cli.run([
			'rename',
			'$dir/src/p/Build.hx',
			'--select',
			'FinalField:flag',
			'enabled',
			'--scope',
			'$dir/src',
			'--scope',
			'$dir/test',
			'--write'
		]);
		Assert.equals(0, rc);
		Assert.isFalse(File.getContent('$dir/src/p/Build.hx').contains('flag'));
		Assert.isFalse(File.getContent('$dir/test/p/Reader.hx').contains('flag'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A cursor file spelled one way under a scope spelled another is one file, so its type is not declared twice. */
	@:killer('M-SCOPE-FILES-BY-SPELLING')
	@:pin('control')
	public function testCursorFileSpelledOtherwiseThanTheScopeIsOneFile(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('rntypedefspelling', [
			{ name: 'src/p/Build.hx', source: DECLARING },
			{ name: 'src/p/Reader.hx', source: READER }
		]);
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run([
			'rename',
			'$dir/src/p/Build.hx',
			'--select',
			'FinalField:flag',
			'enabled',
			'--scope',
			relative('$dir/src'),
			'--write'
		]));
		Assert.equals(0, rc, printed);
		Assert.isFalse(printed.contains('ambiguous'), printed);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A scope that matches no file refuses the rename: the rest of the scopes would otherwise rename a part of the tree. */
	@:pin('control')
	@:killer('M-RENAME-SCOPE-UNMATCHED')
	public function testAScopeMatchingNoFileRefuses(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('rntypedefunmatched', [{ name: 'src/p/Build.hx', source: DECLARING }]);
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run([
			'rename',
			'$dir/src/p/Build.hx',
			'--select',
			'FinalField:flag',
			'enabled',
			'--scope',
			'$dir/src',
			'--scope',
			'$dir/nothere',
			'--write'
		]));
		Assert.equals(2 > 1, rc != 0, printed);
		Assert.stringContains('nothere', printed);
		Assert.isTrue(File.getContent('$dir/src/p/Build.hx').contains('flag'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Two scopes spelling one directory differently hold each file once: the type is still declared once under scope. */
	@:pin('control')
	@:killer('M-SCOPE-FILES-OVERLAP')
	public function testOverlappingScopesSpellingOneFileOtherwiseAreOneFile(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('rntypedefoverlap', [
			{ name: 'src/p/Build.hx', source: DECLARING },
			{ name: 'src/p/Reader.hx', source: READER }
		]);
		var rc: Int = 0;
		final printed: String = CliFixture.captureStderr(() -> rc = Cli.run([
			'rename',
			'$dir/src/p/Build.hx',
			'--select',
			'FinalField:flag',
			'enabled',
			'--scope',
			'$dir/src',
			'--scope',
			relative('$dir/src'),
			'--write'
		]));
		Assert.equals(0, rc, printed);
		Assert.isFalse(File.getContent('$dir/src/p/Reader.hx').contains('flag'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** `path` spelled relative to the working directory, climbing to the root first. */
	private static function relative(path: String): String {
		final cwd: String = FileSystem.absolutePath(Sys.getCwd());
		final depth: Int = [for (segment in cwd.split('/')) if (segment != '') segment].length;
		return [for (_ in 0...depth) '..'].join('/') + FileSystem.absolutePath(path);
	}
	#end

}
