package unit.ds;

import anyparse.check.oracle.HaxeRun;
import anyparse.check.oracle.HaxeSpawn;
import haxe.Exception;
import unit.cli.CliFixture;

/**
 * `anyparse.ds.Set` on the targets the suite itself does not run on: the membership contract on the interpreter (the
 * `Map`-backed arm), and the compile-time refusal of an enum-value key on both arms.
 */
class SetTargetsTest extends Test {

	private static inline final BUFFER: Int = 8 * 1024 * 1024;
	private static final CONTRACT: String = 'import anyparse.ds.Set;\nclass Holder { public function new() {} }\n'
		+ 'class Main {\n\tstatic function main() {\n\t\tfinal s = new Set<String>();\n\t\ts.add("a"); s.add("a");\n'
		+ '\t\tfinal i = new Set<Int>(); i.add(3);\n\t\tfinal h = new Holder(); final o = new Set<Holder>(); o.add(h);\n'
		+ '\t\tfinal copy = i.copy(); i.add(4); copy.add(5);\n\t\tvar n = 0; for (k in s) n++;\n'
		+ '\t\tSys.println([s.has("a"), s.has("b"), i.has(3), i.has(5), copy.has(3), copy.has(4), o.has(h), o.has(new Holder()), n == 1,\n'
		+ '\t\t\ts.remove("a"), s.remove("a"), s.has("a")].join(","));\n\t\ts.add("z"); s.clear(); Sys.println(s.has("z"));\n\t}\n}\n';
	private static final ENUM_KEY: String =
		'class Main {\n\tstatic function main() {\n\t\tfinal s = new anyparse.ds.Set<haxe.ds.Option<Int>>();\n\t\ts.add(None);\n\t}\n}\n';

	public function testMembershipContractOnTheInterpreter(): Void {
		final run: Null<HaxeRun> = compile(CONTRACT, ['--interp']);
		if (run == null) return;
		Assert.equals(0, run.status);
		Assert.equals('true,false,true,false,true,false,true,false,true,true,false,false\nfalse\n', run.out.split('\r').join(''));
	}

	/** `Map` compares an enum value structurally and a native set by identity: no target gets such a key. */
	@:pin('control')
	@:killer('M-DS-SET-ENUM-KEY')
	public function testEnumKeyIsRefusedOnBothArms(): Void {
		for (target in [['--interp'], ['-js', 'out.js']]) {
			final run: Null<HaxeRun> = compile(ENUM_KEY, target);
			if (run == null) return;
			Assert.notEquals(0, run.status, target.join(' '));
			Assert.stringContains('has no @:to function', run.err, target.join(' '));
		}
	}

	/** The run of `source` as `Main` under `args`, or null when this host has no working `haxe`. */
	private static function compile(source: String, args: Array<String>): Null<HaxeRun> {
		final dir: String = CliFixture.writeDir('settargets', [{ name: 'Main.hx', source: source }]);
		try {
			final run: HaxeRun = HaxeSpawn.run(['-cp', '${CliFixture.repoRoot()}/src', '-cp', dir, '-main', 'Main'].concat(
				args
			), dir, BUFFER);
			CliFixture.removeDir(dir);
			if (run.failure == '') return run;
			Assert.pass('haxe unavailable - skipped');
			return null;
		} catch (exception: Exception) {
			CliFixture.removeDir(dir);
			throw exception;
		}
	}

}
