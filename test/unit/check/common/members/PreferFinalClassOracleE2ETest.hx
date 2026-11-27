package unit.check.common.members;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.haxe.oracle.CompilerOracle;
import anyparse.proc.ProcessSpawn;
import anyparse.query.Cli;
import unit.cli.CliFixture;

/**
 * `prefer-final-class` through `lint --fix` with the real compiler as the oracle: the class nothing extends becomes `final`,
 * and the class a file the project declares no root for extends keeps its modifier — the compiler refuses the `final` base
 * and the edit is reverted — while the program prints what it printed.
 */
class PreferFinalClassOracleE2ETest extends Test {

	#if (sys || nodejs)
	private static final HXML: String = '-cp .\n-cp ../ext\n-main Main\n--interp\n';
	private static inline final APQ: String =
		'{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."],"rules":{"prefer-final-class":{"closedWorld":true}}}';
	private static final MAIN: String =
		'class Main {\n\tstatic function main() {\n\t\tSys.println(new Used().v() + new Ext().v());\n\t}\n}\n';
	private static final USED: String = 'class Used {\n\tpublic function new() {}\n\n\tpublic function v():Int {\n\t\treturn 1;\n\t}\n}\n';
	private static final BASE: String = 'class Base {\n\tpublic function new() {}\n\n\tpublic function v():Int {\n\t\treturn 2;\n\t}\n}\n';
	private static final EXT: String = 'class Ext extends Base {}\n';
	private static inline final BUFFER: Int = 1 << 20;
	#end

	@:pin('guard')
	public function testTheClassNothingExtendsBecomesFinalAndTheOneAnUnseenFileExtendsKeepsItsModifier(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('pfc-oracle', [
			{ name: 'proj/Main.hx', source: MAIN },
			{ name: 'proj/Used.hx', source: USED },
			{ name: 'proj/Base.hx', source: BASE },
			{ name: 'proj/check.hxml', source: HXML },
			{ name: 'proj/apq.json', source: APQ },
			{ name: 'ext/Ext.hx', source: EXT }
		]);
		final dir: String = '$root/proj';
		if (!CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) {
			CliFixture.removeDir(root);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final before: String = ProcessSpawn.run(['check.hxml'], dir, BUFFER).out;
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-final-class', dir]));
		Assert.stringContains('final class Used', File.getContent('$dir/Used.hx'));
		Assert.isFalse(File.getContent('$dir/Base.hx').indexOf('final class Base') >= 0, 'the oracle reverts the final base');
		Assert.equals(before, ProcessSpawn.run(['check.hxml'], dir, BUFFER).out, 'the program prints what it printed');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
