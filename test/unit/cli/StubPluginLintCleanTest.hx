package unit.cli;

import anyparse.check.Check.Violation;
import anyparse.check.common.members.InlineConstant;
import sys.io.File;
import unit.CheckFixture;

/**
 * The stub grammar plugin's `SHEBANG` String constant, read only by a string interpolation, is not left
 * `inline`: nothing needs its value at compile time, and main's whole lint stays green.
 */
@:nullSafety(Strict)
class StubPluginLintCleanTest extends Test {

	@:pin('guard')
	public function testStubPluginCarriesNoInlineConstantFinding(): Void {
		final files: Array<{ file: String, source: String }> = [
			for (path in ['test/unit/cli/StubQueryPlugin.hx', 'test/unit/cli/GrammarRegistryTest.hx']) {
				file: path,
				source: File.getContent(path)
			}
		];
		final found: Array<Violation> = CheckFixture.violationsIn(new InlineConstant(), files)
			.filter(v -> v.message.indexOf("'SHEBANG'") >= 0);
		Assert.equals(0, found.length, found.map(v -> '${v.file}: ${v.message}').join('\n'));
	}

}
