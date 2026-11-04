package unit.check.oracle;

import anyparse.check.oracle.CompilerOracle;
import anyparse.query.Cli;

/**
 * A `--fix` run whose edit creates an ambient import file and removes the statements it replaces: the hoist ends applied and
 * the tree it leaves compiles cold. Whether the run's warm servers took part is the pool's own tests' business
 * (`OracleServerStaleTest`).
 */
@:nullSafety(Strict)
final class OracleServerHoistE2ETest extends Test {

	private static final STATEMENT: String = 'import qqz.Zqqwwee;';

	@:pin('guard')
	public function testAHoistThatCreatesTheImportFileIsAppliedAndCompiles(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('poolhoist', [
			{ name: 'qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {\n\tpublic function new() {}\n}\n' },
			{ name: 'aqq/OneQq.hx', source: module('OneQq') },
			{ name: 'aqq/TwoQq.hx', source: module('TwoQq') },
			{ name: 'aqq/ThreeQq.hx', source: module('ThreeQq') },
			{ name: 'aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {\n\tpublic static var b:Int = 0;\n}\n' },
			{
				name: 'Main.hx',
				source: 'class Main {\n\tstatic function main():Void {\n\t\ttrace([aqq.OneQq.a, aqq.TwoQq.a, aqq.ThreeQq.a]);\n'
				+ '\t\ttrace(aqq.FourQq.b);\n\t}\n}\n'
			},
			{ name: 'check.hxml', source: '-cp .\n-main Main\n--interp\n' },
			{
				name: 'apq.json',
				source: '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"reachConfigurationsComplete":true,'
				+ '"rules":{"hoist-common-import":{"enabled":true}}}'
			}
		]);
		if (CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) {
			var err: String = '';
			CliFixture.captureStdout(
				() -> err = CliFixture.captureStderr(Cli.run.bind(['lint', '--fix', '--rule', 'hoist-common-import', dir]))
			);
			final ambient: String = '$dir/import.hx';
			Assert.isTrue(sys.FileSystem.exists(ambient), 'the hoist created the ambient import file: $err');
			Assert.isTrue(
				sys.FileSystem.exists(ambient) && sys.io.File.getContent(ambient).indexOf(STATEMENT) >= 0, 'it carries the statement'
			);
			for (name in ['OneQq', 'TwoQq', 'ThreeQq'])
				Assert.equals(-1, sys.io.File.getContent('$dir/aqq/$name.hx').indexOf(STATEMENT), '$name no longer spells it');
			Assert.isTrue(CompilerOracle.typecheck('check.hxml', dir).match(Confirmed), 'a cold compile of the result is green');
		} else {
			Assert.pass('haxe unavailable — skipped');
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	#if nodejs
	private static function module(name: String): String {
		return 'package aqq;\n\n$STATEMENT\n\nclass $name {\n\tpublic static var a:Null<Zqqwwee>;\n}\n';
	}
	#end

}
