package unit.check.common.design;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.haxe.oracle.CompilerOracle;
import anyparse.proc.ProcessSpawn;
import anyparse.query.Cli;
import anyparse.query.OracleProvider.OracleOutcome;
import unit.cli.CliFixture;

/**
 * `prefer-read-only-array` through `lint --fix` with the real compiler as the oracle: the parameter nothing mutates becomes
 * read-only in the first run, the field handed to it only in the second, once what receives it is read-only, and the field
 * passed to a function that pushes onto it never — while the program prints what it printed.
 */
class PreferReadOnlyArrayOracleE2ETest extends Test {

	#if (sys || nodejs)
	private static final HXML: String = '-cp .\n-main Main\n--interp\n';
	private static inline final APQ: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."]}';
	private static final MAIN: String = 'final class Main {\n\tstatic final items:Array<Int> = [1, 2];\n'
		+ '\tstatic final kept:Array<Int> = [3];\n\n\tstatic function total(list:Array<Int>):Int {\n'
		+ '\t\tvar sum:Int = 0;\n\t\tfor (x in list) sum += x;\n\t\treturn sum;\n\t}\n\n'
		+ '\tstatic function grow(a:Array<Int>):Void {\n\t\ta.push(4);\n\t}\n\n'
		+ '\tstatic function main() {\n\t\tgrow(kept);\n\t\tSys.println(total(items) + kept.length);\n\t}\n}\n';
	private static inline final BUFFER: Int = 1 << 20;
	#end

	@:pin('guard')
	public function testTheReceivingParameterFirstThenTheFieldHandedToItAndNeverTheOneAFunctionPushesOnto(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('proa-oracle', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apq.json', source: APQ }
		]);
		if (!CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final before: String = ProcessSpawn.run(['check.hxml'], dir, BUFFER).out;
		final fix: () -> String = () -> {
			CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-read-only-array', dir]));
			return File.getContent('$dir/Main.hx');
		};
		final first: String = fix();
		Assert.isTrue(first.contains('list:haxe.ds.ReadOnlyArray<Int>') && first.contains('items:Array<Int>'), first);
		final second: String = fix();
		Assert.isTrue(second.contains('items:haxe.ds.ReadOnlyArray<Int>'), second);
		Assert.isTrue(second.contains('kept:Array<Int>') && second.contains('a:Array<Int>'), second);
		Assert.equals(before, ProcessSpawn.run(['check.hxml'], dir, BUFFER).out, 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
