package unit.dev;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
#end
import dev.TyperConformance;
import utest.Assert;
import utest.Test;

/**
 * `dev typer-conformance probes` as a gate: a probe project's run counts only when it read something — every configuration
 * compiled, some project file compiled, some case scored — so a project that does not compile, or a compiler that does not
 * start, fails the gate instead of passing it with no DIFFERENT to show.
 */
@:nullSafety(Strict)
final class TyperConformanceTest extends Test {

	#if (sys || nodejs)
	private static final PROBE: String = 'class Probe {\n\tstatic function main() {\n\t\tfinal n: Int = 1;\n\t\ttrace(n + 1);\n\t}\n}\n';
	private static final BROKEN: String = 'class Probe {\n\tstatic function main() {\n\t\tfinal n: Int = "one";\n\t\ttrace(n);\n\t}\n}\n';
	private static final HXML: String = '-cp src\n-main Probe\n--interp\n--no-output\n';
	private static final CONFIG: String =
		'{\n\t"compilerOracle": "typer.hxml",\n\t"compilerOracleServer": false,\n\t"resolutionRoots": ["src"]\n}\n';
	#end

	public function testARunThatReadNothingIsRefused(): Void {
		Assert.isNull(TyperConformance.probeRefusal(run([], 1, 1, 3)), 'a run that compiled and scored');
		Assert.notNull(TyperConformance.probeRefusal(run(['p.hxml: the compile failed'], 1, 1, 3)), 'a dropped configuration');
		Assert.notNull(TyperConformance.probeRefusal(run([], 0, 0, 0)), 'no configuration compiled');
		Assert.notNull(TyperConformance.probeRefusal(run([], 1, 0, 0)), 'no project file compiled');
		Assert.notNull(TyperConformance.probeRefusal(run([], 1, 1, 0)), 'no case scored');
	}

	/** A probe project with a type error fails the gate, where the same project compiling passes it. */
	public function testAProbeProjectThatDoesNotCompileFailsTheGate(): Void {
		#if (sys || nodejs)
		final good: String = corpus(PROBE);
		final broken: String = corpus(BROKEN);
		CliFixture.always(() -> {
			CliFixture.removeDir(good);
			CliFixture.removeDir(broken);
		}, () -> {
			Assert.equals(0, TyperConformance.main(['probes', good]), 'the project compiling');
			Assert.equals(1, TyperConformance.main(['probes', broken]), 'the project with a type error');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A compiler that does not start (no `haxe` on the `PATH`) fails the gate rather than reading zero cases as a pass. */
	public function testACompilerThatDoesNotStartFailsTheGate(): Void {
		#if (sys || nodejs)
		final dir: String = corpus(PROBE);
		final empty: String = CliFixture.writeDir('nohaxe', []);
		final path: Null<String> = Sys.getEnv('PATH');
		Sys.putEnv('PATH', empty);
		CliFixture.always(() -> {
			Sys.putEnv('PATH', path ?? '');
			CliFixture.removeDir(dir);
			CliFixture.removeDir(empty);
		}, () -> Assert.equals(1, TyperConformance.main(['probes', dir]), 'no haxe to launch'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function run(dropped: Array<String>, configurations: Int, compiled: Int, cases: Int): FactsRun {
		return {
			configurations: configurations,
			dropped: dropped,
			files: 1,
			compiled: compiled,
			cases: cases
		};
	}

	#if (sys || nodejs)
	/** A probe corpus of one project, `probe/`, whose one module is `source`. */
	private static function corpus(source: String): String {
		final root: String = CliFixture.writeDir('typerprobes', []);
		FileSystem.createDirectory('$root/probe/src');
		File.saveContent('$root/probe/src/Probe.hx', source);
		File.saveContent('$root/probe/typer.hxml', HXML);
		File.saveContent('$root/probe/apqlint.json', CONFIG);
		return root;
	}
	#end

}
