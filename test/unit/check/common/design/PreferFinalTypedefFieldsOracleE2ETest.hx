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
 * `prefer-final-typedef-fields` through `lint --fix` with the real compiler as the oracle: a typedef nothing writes by name
 * is made final, and one the compiler rejects as final — here because a function takes the same shape written as a writable
 * inline structure, which a final one does not unify with — keeps its text, while the program prints what it printed.
 */
class PreferFinalTypedefFieldsOracleE2ETest extends Test {

	#if (sys || nodejs)
	private static final HXML: String = '-cp .\n-main Main\n--interp\n';
	private static inline final APQ: String = '{"compilerOracle":[{"hxml":"check.hxml"}],"resolutionRoots":["."]}';
	private static inline final PT: String = 'typedef Pt = {x:Int, y:Int}\n';
	private static inline final BOX: String = 'typedef Box = {w:Int, ?label:String}\n';
	private static final MAIN: String = 'class Main {\n\tstatic function sum(p:{x:Int, y:Int}):Int {\n\t\treturn p.x + p.y;\n\t}\n\n'
		+ '\tstatic function main() {\n\t\tfinal p:Pt = {x: 1, y: 2};\n\t\tfinal b:Box = {w: 3};\n\t\tSys.println(sum(p) + b.w);\n\t}\n}\n';
	private static inline final BUFFER: Int = 1 << 20;
	#end

	@:pin('guard')
	public function testTheCompilerKeepsTheTypedefItRejectsAndTheRestBecomesFinal(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('pftf-oracle', [
			{ name: 'Pt.hx', source: PT },
			{ name: 'Box.hx', source: BOX },
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
		CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--rule', 'prefer-final-typedef-fields', dir]));
		Assert.equals(PT, File.getContent('$dir/Pt.hx'), 'the typedef the compiler rejects as final keeps its text');
		final box: String = File.getContent('$dir/Box.hx');
		Assert.isTrue(box.contains('final w:Int;') && box.contains('final ?label:String;'), box);
		Assert.equals(before, ProcessSpawn.run(['check.hxml'], dir, BUFFER).out, 'the program prints what it printed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
