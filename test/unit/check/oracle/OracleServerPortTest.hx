package unit.check.oracle;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.OracleServerPool;
import anyparse.check.oracle.PendingRuns;

/**
 * A pool server listens on a random loopback port. `haxe --wait` exits at once on a port something else holds, and the
 * readiness poll is then answered by that holder or by nothing, so the pool takes a candidate only when a bind probe finds
 * it free (`OracleServerPool.portIsFree`) and tries another otherwise; a configuration none of whose candidates is free
 * gets no server.
 */
final class OracleServerPortTest extends Test {

	#if nodejs
	/** How many tenth-seconds a holder is given to say whether it bound its port. */
	private static inline final HOLDER_TRIES: Int = 300;

	/**
	 * Listens on 127.0.0.1 at its last argument and drops every connection unanswered (a silent one would hang the readiness
	 * connect): not a haxe server. It renames into the file its first argument names `listening`, or the bind's error code.
	 */
	private static inline final HOLDER: String = 'const [f,p]=process.argv.slice(-2),fs=require("fs");'
		+ 'const say=s=>{fs.writeFileSync(f+".t",s);fs.renameSync(f+".t",f)};'
		+ 'require("net").createServer(c=>c.destroy()).once("error",e=>{say(String(e.code));process.exit(1)})'
		+ '.listen(Number(p),"127.0.0.1",()=>say("listening"))';
	#end

	@:pin('control')
	@:killer('M-POOL-PORT-PROBE')
	public function testAPortSomethingListensOnIsNotFree(): Void {
		#if nodejs
		final port: Int = unusedPort();
		Assert.isTrue(OracleServerPool.portIsFree(port), 'nothing listens yet');
		holding(port, () -> Assert.isFalse(OracleServerPool.portIsFree(port), 'a listener holds it'));
		#else
		Assert.pass('non-node target');
		#end
	}

	@:pin('control')
	@:killer('M-POOL-PORT-PROBE')
	public function testAServerComesUpOnTheNextPortWhenTheFirstIsHeld(): Void {
		#if nodejs
		final held: Int = unusedPort();
		final next: Int = unusedPort();
		holding(held, () -> {
			final candidates: Array<Int> = [held, next];
			final served: { running: Bool, status: Null<Int> } = serving(() -> candidates.shift() ?? next);
			Assert.isTrue(served.running, 'a warm server comes up past the held port');
			Assert.equals(0, served.status, 'and typechecks through it');
		});
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A drifted server is ended before its replacement's port is looked for, so finding none leaves the configuration with no server. */
	@:pin('guard')
	@:access(anyparse.check.oracle.OracleServerPool)
	public function testARestartWithNoFreePortLeavesNoServer(): Void {
		#if nodejs
		final held: Int = unusedPort();
		var candidate: Int = unusedPort();
		final root: String = oneModule();
		final pads: Array<String> = [for (k in 0...OracleServerPool.RESTART_AT + 1) '$root/pad$k.txt'];
		for (pad in pads) sys.io.File.saveContent(pad, 'a');
		final config: OracleConfig = { hxml: 'build.hxml', dir: root, defines: [] };
		final pool: OracleServerPool = new OracleServerPool(() -> pads, () -> candidate);
		CliFixture.always(() -> {
			pool.stop();
			CliFixture.removeDir(root);
		}, () -> holding(held, () -> {
			pool.start([config]);
			Assert.isTrue(pool.running(), 'the first candidate is free: a server comes up');
			candidate = held;
			for (pad in pads) sys.io.File.saveContent(pad, 'b');
			Assert.isNull(pool.compile([config])[0], 'a drifted configuration with no port to restart on answers nothing');
			Assert.isFalse(pool.running(), 'and keeps no server');
		}));
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A bind probe that cannot run says nothing about the port, and `ready` stays the verdict on a server that does not come up. */
	@:pin('control')
	@:killer('M-POOL-PROBE-FAILS-CLOSED')
	public function testAProbeThatCannotRunReadsFree(): Void {
		#if nodejs
		final port: Int = unusedPort();
		holding(port, () -> {
			final node: String = js.Node.process.execPath;
			CliFixture.always(() -> setExecPath(node), () -> {
				setExecPath('$node-missing');
				Assert.isTrue(OracleServerPool.portIsFree(port), 'held, but the probe never ran');
			});
		});
		#else
		Assert.pass('non-node target');
		#end
	}

	@:pin('guard')
	public function testNoServerIsStartedWhenEveryCandidateIsHeld(): Void {
		#if nodejs
		final held: Int = unusedPort();
		holding(held, () -> Assert.isFalse(serving(() -> held).running, 'no port to bind: no server, never one on the holder'));
		#else
		Assert.pass('non-node target');
		#end
	}

	#if nodejs
	/** A pool over a one-module tree, started with `candidate` as its port source; stopped and removed after. */
	private function serving(candidate: () -> Int): { running: Bool, status: Null<Int> } {
		final root: String = oneModule();
		final config: OracleConfig = { hxml: 'build.hxml', dir: root, defines: [] };
		final pool: OracleServerPool = new OracleServerPool(() -> [], candidate);
		pool.start([config]);
		final running: Bool = pool.running();
		final status: Null<Int> = running ? pool.compile([config])[0]?.status : null;
		pool.stop();
		CliFixture.removeDir(root);
		return { running: running, status: status };
	}

	/** A tree of one module and its build file. */
	private static function oneModule(): String {
		return CliFixture.writeTree('apq_port', [
			{ name: 'Main.hx', source: 'class Main {\n\tstatic function main() {}\n}\n' },
			{ name: 'build.hxml', source: '-cp .\n-main Main\n--no-output\n' }
		]);
	}

	/** Point `process.execPath`, the program `portIsFree` runs, at `path`. */
	private static function setExecPath(path: String): Void {
		js.Syntax.code('process.execPath = {0}', path);
	}

	/** A port nothing listens on now, drawn at random. */
	private static function unusedPort(): Int {
		var port: Int = 20000 + Std.random(40000);
		while (!OracleServerPool.portIsFree(port)) port = 20000 + Std.random(40000);
		return port;
	}

	/**
	 * `body` run while a holder (`HOLDER`) listens on `port`, once the holder itself said so. Never polled through `portIsFree`:
	 * a bind probe run while the holder boots can take the port first, the holder then dies on EADDRINUSE and every later probe
	 * reads free. A tethered job: ended after `body`, and gone with this process should that be killed first.
	 */
	private static function holding(port: Int, body: () -> Void): Void {
		final dir: String = CliFixture.writeDir('apq_port_holder', []);
		final said: String = '$dir/said';
		final holder: PendingRuns = HaxeSpawn.startAll([
			{
				cmd: js.Node.process.execPath,
				args: ['-e', HOLDER, said, '$port'],
				cwd: dir,
				tethered: true
			}
		], 1024, 1);
		CliFixture.always(() -> {
			holder.cancel();
			CliFixture.removeDir(dir);
		}, () -> {
			var tries: Int = 0;
			while (!sys.FileSystem.exists(said) && ++tries < HOLDER_TRIES) Sys.sleep(0.1);
			final state: String = sys.FileSystem.exists(said) ? sys.io.File.getContent(said) : 'nothing after $tries tries';
			Assert.equals('listening', state, 'the holder binds $port');
			if (state == 'listening') body();
		});
	}
	#end

}
