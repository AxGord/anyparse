package unit.query;

import anyparse.query.RegistryFiles;
import unit.cli.CliFixture;

/** `RegistryFiles`: a file names itself, a directory its `.json` documents in name order, and nothing names nothing. */
@:nullSafety(Strict)
final class RegistryFilesTest extends Test {

	public function testAFileNamesItself(): Void {
		final dir: String = CliFixture.writeTree('regfiles', [{ name: 'one.json', source: '{}' }]);
		Assert.same(['$dir/one.json'], RegistryFiles.of('$dir/one.json'));
		CliFixture.removeDir(dir);
	}

	public function testADirectoryNamesItsJsonDocumentsInNameOrder(): Void {
		final dir: String = CliFixture.writeTree('regfiles', [
			{ name: 'b.json', source: '{}' },
			{ name: 'a.json', source: '{}' },
			{ name: 'notes.txt', source: '' },
			{ name: 'sub/c.json', source: '{}' }
		]);
		Assert.same(['$dir/a.json', '$dir/b.json'], RegistryFiles.of(dir));
		CliFixture.removeDir(dir);
	}

	public function testAMissingPathNamesNothing(): Void {
		Assert.same([], RegistryFiles.of('/no/such/registry'));
	}

}
