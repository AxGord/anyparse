package unit.dev;

import sys.FileSystem;
import unit.cli.CliFixture;

/** `test/unit/dev` declares its ambient imports once in an `import.hx`, so a new dev test does not repeat them. */
@:nullSafety(Strict)
final class DevTestAmbientImportsTest extends Test {

	public function testTheDevTestFolderHasAnAmbientImportFile(): Void {
		Assert.isTrue(FileSystem.exists('${CliFixture.repoRoot()}/test/unit/dev/import.hx'));
	}

}
