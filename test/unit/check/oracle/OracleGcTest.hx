package unit.check.oracle;

import anyparse.check.oracle.HaxeSpawn;

using StringTools;

/**
 * Every `haxe` the compiler oracle starts runs under the tuned OCaml collector (`HaxeSpawn.gcSetting`): a single spawn,
 * the jobs of the parallel driver and those of a batch started in the background alike. The probe is a compile that
 * prints the `OCAMLRUNPARAM` it was started with, so what is asserted is the environment the compiler really saw.
 */
@:nullSafety(Strict)
final class OracleGcTest extends Test {

	private static inline final GIB: Float = 1024.0 * 1024 * 1024;

	/** Output cap of the probe compiles: one line each. */
	private static inline final BUFFER: Int = 1024 * 1024;

	/** The variables the probes set, restored after each. */
	private static final VARIABLES: Array<String> = ['APQ_ORACLE_GC', 'OCAMLRUNPARAM', 'CAMLRUNPARAM'];

	#if (sys || nodejs)
	private static final MAIN: String =
		'class Main {\n\n\tpublic static function main() {\n\t\tSys.println("GC=" + Sys.getEnv("OCAMLRUNPARAM"));\n\t}\n\n}\n';
	#end

	@:pin('control')
	@:killer('M-GC-RUN-INHERITS')
	@:killer('M-GC-DRIVER-INHERITS')
	@:killer('M-GC-PENDING-INHERITS')
	public function testEveryKindOfSpawnRunsUnderTheDefault(): Void {
		#if (sys || nodejs)
		final seen: Null<Array<String>> = probe(['APQ_ORACLE_GC' => '', 'OCAMLRUNPARAM' => '', 'CAMLRUNPARAM' => '']);
		if (seen == null) return;
		Assert.same([
			'GC=s=16M,o=400',
			'GC=s=16M,o=400',
			'GC=s=16M,o=400',
			'GC=s=16M,o=400',
			'GC=s=16M,o=400'
		], seen);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	@:killer('M-GC-INHERITED-OVERRIDDEN')
	@:killer('M-GC-OFF-IGNORED')
	public function testTheCallersOwnSettingStaysAndOffAddsNothing(): Void {
		#if (sys || nodejs)
		final kept: Null<Array<String>> = probe(['APQ_ORACLE_GC' => '', 'OCAMLRUNPARAM' => 's=1M,b', 'CAMLRUNPARAM' => '']);
		final off: Null<Array<String>> = probe(['APQ_ORACLE_GC' => 'off', 'OCAMLRUNPARAM' => 'b', 'CAMLRUNPARAM' => '']);
		if (kept == null || off == null) return;
		Assert.equals('GC=s=1M,b,o=400', kept[0], 'a parameter the caller set wins, ours join for the rest');
		Assert.equals('GC=b', off[0], 'off leaves the inherited setting alone');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	@:killer('M-GC-OFF-IGNORED')
	@:killer('M-GC-EMPTY-DECLARED-OFF')
	@:killer('M-GC-INHERITED-OVERRIDDEN')
	public function testTheParameters(): Void {
		Assert.equals(HaxeSpawn.DEFAULT_GC, HaxeSpawn.gcParams(null, null), 'unset: the default');
		Assert.equals(HaxeSpawn.DEFAULT_GC, HaxeSpawn.gcParams(' ', ''), 'empty is unset, the way a test restores a variable');
		Assert.isNull(HaxeSpawn.gcParams('off', null), 'off: none');
		Assert.equals('b', HaxeSpawn.gcParams('off', 'b'));
		Assert.equals('s=4M', HaxeSpawn.gcParams('s=4M', null), 'a declared setting replaces the default');
		Assert.equals('o=200,s=16M', HaxeSpawn.gcParams(null, 'o=200'), 'the caller keeps its own parameter');
		Assert.equals('s=1M,o=80', HaxeSpawn.gcParams(null, 's=1M,o=80'), 'and adds none it set itself');
	}

	@:pin('guard')
	@:killer('M-GC-MEMORY-UNCOUNTED')
	public function testATunedCollectorCostsMemory(): Void {
		Assert.equals(5, HaxeSpawn.parallelismFor(16, 10 * GIB, false), 'ten GiB hold five compiles at two each');
		Assert.equals(4, HaxeSpawn.parallelismFor(16, 10 * GIB, true), 'and four at two and a half');
		Assert.equals(15, HaxeSpawn.parallelismFor(16, 64 * GIB, true), 'the cores still bound a big machine');
	}

	#if (sys || nodejs)
	/**
	 * What the probe printed under `env`, through `run`, through the parallel driver (two jobs) and through a batch
	 * started in the background (two jobs); null when `haxe` cannot run the probe, the test then passing as skipped.
	 */
	private function probe(env: Map<String, String>): Null<Array<String>> {
		final dir: String = CliFixture.writeDir('oraclegc', [{ name: 'Main.hx', source: MAIN }]);
		final args: Array<String> = ['-cp', dir, '--run', 'Main'];
		final saved: Map<String, String> = [for (v in VARIABLES) v => Sys.getEnv(v) ?? ''];
		var runs: Array<HaxeRun> = [];
		CliFixture.always(() -> {
			for (v => value in saved) Sys.putEnv(v, value);
			CliFixture.removeDir(dir);
		}, () -> {
			for (v => value in env) Sys.putEnv(v, value);
			final jobs: Array<SpawnJob> = [{ args: args, cwd: dir }, { args: args, cwd: dir }];
			runs = [HaxeSpawn.run(
				args, dir, BUFFER
			)].concat(HaxeSpawn.runAll(jobs, BUFFER, 2)).concat(HaxeSpawn.startAll(jobs, BUFFER, 2).await());
		});
		if (runs[0].status != 0) {
			Assert.pass('haxe unavailable — skipped (${runs[0].failure}${runs[0].err})');
			return null;
		}
		return [for (r in runs) r.out.trim()];
	}
	#end

}
