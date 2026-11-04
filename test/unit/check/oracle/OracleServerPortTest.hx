package unit.check.oracle;

import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.oracle.CompilerDisplayOracle;
import anyparse.check.oracle.CompilerOracle.OracleOutcome;
import anyparse.check.oracle.CompilerServer;
import anyparse.check.oracle.HaxeSpawn;
import anyparse.check.oracle.OracleServerPool;
import anyparse.check.oracle.PendingRuns;
import unit.check.oracle.PortHolder.holding;
import unit.check.oracle.PortHolder.unusedPort;
import unit.check.oracle.PortHolder.watching;

/**
 * A `haxe --wait` server listens on a random loopback port. It exits at once on a port something else holds, and the
 * readiness poll is then answered by that holder or by nothing, so every starter (the pool, the shared server, a mutation
 * slot, the display oracle) takes a candidate only when a bind probe finds it free (`CompilerServer.freePort`) and tries
 * another otherwise; a configuration none of whose candidates is free gets no server.
 */
final class OracleServerPortTest extends Test {

	@:pin('control')
	@:killer('M-SERVER-PORT-PROBE')
	public function testAPortSomethingListensOnIsNotFree(): Void {
		#if nodejs
		final port: Int = unusedPort();
		Assert.isTrue(CompilerServer.portIsFree(port), 'nothing listens yet');
		holding(port, () -> Assert.isFalse(CompilerServer.portIsFree(port), 'a listener holds it'));
		#else
		Assert.pass('non-node target');
		#end
	}

	/** Asking `freePort` never touches the held port; a starter that tried it and recovered would have connected. */
	@:pin('control')
	@:killer('M-POOL-DRAWS-NO-FREE-PORT')
	public function testAServerComesUpOnTheNextPortWhenTheFirstIsHeld(): Void {
		#if nodejs
		final held: Int = unusedPort();
		final next: Int = unusedPort();
		watching(held, connections -> {
			final candidates: Array<Int> = [held, next];
			final served: Served = serving(() -> candidates.shift() ?? next);
			Assert.isTrue(served.running, 'a warm server comes up past the held port');
			Assert.equals(0, served.status, 'and typechecks through it');
			Assert.equals(0, connections(), 'and nothing ever connected to the held port');
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
		final pads: Array<String> = [for (k in 0...OracleServerPool.RESTART_AT + 1) '$root/pad$k.hx'];
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

	/** A bind probe that cannot run says nothing about the port, and `warm`/`ready` stay the verdict on a server that does not come up. */
	@:pin('control')
	@:killer('M-SERVER-PROBE-FAILS-CLOSED')
	public function testAProbeThatCannotRunReadsFree(): Void {
		#if nodejs
		final port: Int = unusedPort();
		holding(port, () -> {
			final node: String = js.Node.process.execPath;
			CliFixture.always(() -> setExecPath(node), () -> {
				setExecPath('$node-missing');
				Assert.isTrue(CompilerServer.portIsFree(port), 'held, but the probe never ran');
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

	/** The shared server skips a held candidate, without touching it, and is recorded on the port it came up on. */
	@:pin('control')
	@:killer('M-SERVER-DRAWS-NO-FREE-PORT')
	public function testTheSharedServerComesUpOnTheNextPortWhenTheFirstIsHeld(): Void {
		#if nodejs
		final held: Int = unusedPort();
		final next: Int = unusedPort();
		final root: String = oneModule();
		CliFixture.always(() -> {
			CompilerServer.stopShared('build.hxml', root, []);
			CliFixture.removeDir(root);
		}, () -> watching(held, connections -> {
			final candidates: Array<Int> = [held, next];
			final outcome: Null<OracleOutcome> = CompilerServer.typecheck('build.hxml', root, [], [], () -> candidates.shift() ?? next);
			Assert.equals(0, connections(), 'nothing ever connected to the held port');
			Assert.equals('Confirmed', Std.string(outcome), 'a warm typecheck through the free port');
			final recorded: { port: Int } = haxe.Json.parse(sys.io.File.getContent(CompilerServer.stateFile('build.hxml', root, [])));
			Assert.equals(next, recorded.port, 'recorded on the free port, not the held one');
		}));
		#else
		Assert.pass('non-node target');
		#end
	}

	/** With every candidate held the shared server starts nothing and records nothing. */
	@:pin('guard')
	public function testTheSharedServerIsNotStartedWhenEveryCandidateIsHeld(): Void {
		#if nodejs
		final held: Int = unusedPort();
		final root: String = oneModule();
		CliFixture.always(() -> {
			CompilerServer.stopShared('build.hxml', root, []);
			CliFixture.removeDir(root);
		}, () -> holding(held, () -> {
			Assert.isNull(CompilerServer.typecheck('build.hxml', root, [], [], () -> held), 'no port to bind: no warm verdict');
			Assert.isFalse(sys.FileSystem.exists(CompilerServer.stateFile('build.hxml', root, [])), 'and no server on record');
		}));
		#else
		Assert.pass('non-node target');
		#end
	}

	/** The display oracle skips a held candidate, without touching it, and answers through the server on the next one. */
	@:pin('control')
	@:killer('M-DISPLAY-DRAWS-NO-FREE-PORT')
	public function testTheDisplayServerComesUpOnTheNextPortWhenTheFirstIsHeld(): Void {
		#if nodejs
		final held: Int = unusedPort();
		final next: Int = unusedPort();
		final root: String = oneModule();
		CliFixture.always(
			CliFixture.removeDir.bind(root), () -> watching(held, connections -> {
				final candidates: Array<Int> = [held, next];
				final display: Null<CompilerDisplayOracle> = CompilerDisplayOracle.start(
					new HaxeQueryPlugin().typeSyntax, 'build.hxml', root, [], () -> candidates.shift() ?? next
				);
				final type: Null<String> = display?.typeAt('$root/Main.hx', sys.io.File.getContent('$root/Main.hx').indexOf('1)'));
				display?.stop();
				Assert.equals('Int', type, 'a real display server answers, on a port that was free');
				Assert.equals(0, connections(), 'and nothing ever connected to the held port');
			})
		);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A connect refused by nobody: `warm` believes only a server's reply, so a listener that drops the connection warms nothing. */
	@:pin('control')
	@:killer('M-SERVER-WARM-TRUSTS-ANY-LISTENER')
	public function testAWarmOnAHeldPortIsFalse(): Void {
		#if nodejs
		final held: Int = unusedPort();
		final root: String = oneModule();
		CliFixture.always(
			CliFixture.removeDir.bind(root),
			() -> holding(held, () -> Assert.isFalse(CompilerServer.warm(held, 'build.hxml', root), 'not a server: not warm'))
		);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A server that exits on a port the probe found free loses to something that took it since: the start tries another. */
	@:pin('control')
	@:killer('M-POOL-START-ONE-SHOT')
	public function testAServerThatExitsOnItsPortIsBroughtUpOnAnother(): Void {
		#if nodejs
		final lost: Int = unusedPort();
		final next: Int = unusedPort();
		withStubHaxe(lost, waits -> {
			final candidates: Array<Int> = [lost, next];
			final served: Served = serving(() -> candidates.shift() ?? next);
			Assert.same(['$lost', '$next'], waits(), 'the first server exited and a second was started');
			Assert.isTrue(served.running, 'the second one serves');
			Assert.equals(0, served.status, 'and typechecks');
		});
		#else
		Assert.pass('non-node target');
		#end
	}

	/** The restart a drifted server takes is the same bounded bring-up. */
	@:pin('control')
	@:killer('M-POOL-RESTART-ONE-SHOT')
	public function testARestartThatExitsOnItsPortIsBroughtUpOnAnother(): Void {
		#if nodejs
		final first: Int = unusedPort();
		final lost: Int = unusedPort();
		final next: Int = unusedPort();
		final candidates: Array<Int> = [first, lost, next];
		withStubHaxe(
			lost, waits -> drifting(() -> candidates.shift() ?? next, (pool, config, drift, _) -> {
				drift();
				Assert.equals(0, pool.compile([config])[0]?.status, 'the compile answers through a server on the third port');
				Assert.same(['$first', '$lost', '$next'], waits(), 'the restart exited once and tried another');
			})
		);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A server that lives and never answers has a configuration it cannot process, which another port does not mend. */
	@:pin('control')
	@:killer('M-POOL-START-RETRIES-A-LIVE-SERVER')
	public function testALiveServerThatDoesNotAnswerIsNotStartedAgain(): Void {
		#if nodejs
		final root: String = oneModule();
		withStubHaxe(0, waits -> {
			final pool: OracleServerPool = new OracleServerPool(() -> []);
			CliFixture.always(() -> {
				pool.stop();
				CliFixture.removeDir(root);
			}, () -> {
				pool.start([{ hxml: 'missing.hxml', dir: root, defines: [] }]);
				Assert.isFalse(pool.running(), 'no server for a configuration that cannot be processed');
				Assert.equals(1, waits().length, 'and one server was started for it');
			});
		});
		#else
		Assert.pass('non-node target');
		#end
	}

	/** The same at a restart: the drift took the build file away. */
	@:pin('control')
	@:killer('M-POOL-RESTART-RETRIES-A-LIVE-SERVER')
	public function testARestartThatDoesNotAnswerIsNotStartedAgain(): Void {
		#if nodejs
		withStubHaxe(
			0, waits -> drifting(CompilerServer.randomPort, (pool, config, drift, root) -> {
				sys.FileSystem.deleteFile('$root/build.hxml');
				drift();
				Assert.isNull(pool.compile([config])[0], 'nothing answers');
				Assert.isFalse(pool.running(), 'and no server stays');
				Assert.equals(2, waits().length, 'the first server and one restart');
			})
		);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** A client that did not run says nothing about the server: the poll goes on and reads the reply that follows. */
	@:pin('control')
	@:killer('M-POOL-READY-GIVES-UP-ON-A-FAILED-CONNECT')
	@:access(anyparse.check.oracle.OracleServerPool)
	public function testAClientThatDidNotRunDoesNotEndTheReadinessPoll(): Void {
		#if nodejs
		final server: PendingRuns = HaxeSpawn.startAll([
			{
				cmd: js.Node.process.execPath,
				args: ['-e', 'setTimeout(()=>{},60000)'],
				cwd: null,
				tethered: true
			}
		], 1024, 1);
		final replies: Array<Null<ConnectResult>> = [null, { status: 0, output: '{"jsonrpc":"2.0","id":1,"result":null}' }];
		CliFixture.always(
			server.cancel, () -> Assert.isTrue(OracleServerPool.answers(server, () -> replies.shift()), 'the second reply reads')
		);
		#else
		Assert.pass('non-node target');
		#end
	}

	/** An exited server is not polled. */
	@:pin('control')
	@:killer('M-POOL-POLLS-AN-EXITED-SERVER')
	@:access(anyparse.check.oracle.OracleServerPool)
	public function testAServerThatExitedIsNotPolled(): Void {
		#if nodejs
		final server: PendingRuns = HaxeSpawn.startAll([
			{
				cmd: js.Node.process.execPath,
				args: ['-e', ''],
				cwd: null,
				tethered: true
			}
		], 1024, 1);
		Assert.equals(1, server.await().length, 'the job ran');
		Assert.isFalse(server.running(), 'and ended');
		var asked: Int = 0;
		Assert.isFalse(
			OracleServerPool.answers(server, () -> {
				asked++;
				return null;
			}),
			'never answers'
		);
		Assert.equals(0, asked, 'and is not asked');
		#else
		Assert.pass('non-node target');
		#end
	}

	/**
	 * A live server replies with an error to a configuration it cannot process: `warm` reads no server there, so a caller moves
	 * on to its next configuration instead of holding an oracle that answers nothing.
	 */
	@:pin('control')
	@:killer('M-SERVER-WARM-TRUSTS-ANY-LISTENER')
	public function testNoDisplayServerForAConfigurationTheServerCannotProcess(): Void {
		#if nodejs
		final root: String = oneModule();
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final display: Null<CompilerDisplayOracle> = CompilerDisplayOracle.start(
				new HaxeQueryPlugin().typeSyntax, 'missing.hxml', root, []
			);
			display?.stop();
			Assert.isNull(display, 'a server that cannot process the configuration is no oracle');
		});
		#else
		Assert.pass('non-node target');
		#end
	}

	/** With every candidate held the display oracle starts no server, and never touches one. */
	@:pin('control')
	@:killer('M-DISPLAY-DRAWS-NO-FREE-PORT')
	public function testNoDisplayServerIsStartedWhenEveryCandidateIsHeld(): Void {
		#if nodejs
		final held: Int = unusedPort();
		final root: String = oneModule();
		CliFixture.always(
			CliFixture.removeDir.bind(root), () -> watching(held, connections -> {
				final display: Null<CompilerDisplayOracle> = CompilerDisplayOracle.start(
					new HaxeQueryPlugin().typeSyntax, 'build.hxml', root, [], () -> held
				);
				display?.stop();
				Assert.isNull(display, 'no port to bind: no display server');
				Assert.equals(0, connections(), 'and nothing ever connected to the held port');
			})
		);
		#else
		Assert.pass('non-node target');
		#end
	}

	#if nodejs
	/** A pool over a one-module tree, started with `candidate` as its port source; stopped and removed after. */
	private function serving(candidate: () -> Int): Served {
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

	/**
	 * `body` run with a `haxe` first on PATH that logs each `--wait` port, exits at once on `lost` as a server does whose port
	 * went to something else after the probe, and is the real one otherwise; `body` is given a reading of the logged ports.
	 */
	private static function withStubHaxe(lost: Int, body: (waits:() -> Array<String>) -> Void): Void {
		final dir: String = CliFixture.writeDir('apq_port_stub', []);
		final log: String = '$dir/waits';
		final path: String = Sys.getEnv('PATH') ?? '';
		sys.io.File.saveContent(
			'$dir/haxe',
			'#!/bin/sh\nif [ "$$1" = --wait ]; then echo "$$2" >> \'$log\'; [ "$$2" = $lost ] && exit 1; fi\nPATH=\'$path'
			+ '\' exec haxe "$$@"\n'
		);
		js.node.Fs.chmodSync('$dir/haxe', '755');
		Sys.putEnv('PATH', '$dir:$path');
		CliFixture.always(() -> {
			Sys.putEnv('PATH', path);
			CliFixture.removeDir(dir);
		}, () -> body(() -> sys.FileSystem.exists(log) ? sys.io.File.getContent(log).split('\n').filter(line -> line != '') : []));
	}

	/**
	 * A pool over a one-module tree whose written paths can drift by more than invalidating them is worth, given to `body` with
	 * a server up on `candidate`.
	 */
	@:access(anyparse.check.oracle.OracleServerPool)
	private static function drifting(
		candidate: () -> Int, body: (pool:OracleServerPool, config:OracleConfig, drift:() -> Void, root:String) -> Void
	): Void {
		final root: String = oneModule();
		final pads: Array<String> = [for (k in 0...OracleServerPool.RESTART_AT + 1) '$root/pad$k.hx'];
		for (pad in pads) sys.io.File.saveContent(pad, 'a');
		final config: OracleConfig = { hxml: 'build.hxml', dir: root, defines: [] };
		final pool: OracleServerPool = new OracleServerPool(() -> pads, candidate);
		CliFixture.always(() -> {
			pool.stop();
			CliFixture.removeDir(root);
		}, () -> {
			pool.start([config]);
			Assert.isTrue(pool.running(), 'a server came up to drift from');
			body(pool, config, () -> for (pad in pads) sys.io.File.saveContent(pad, 'b'), root);
		});
	}

	/** A tree of one module and its build file. */
	private static function oneModule(): String {
		return CliFixture.writeTree('apq_port', [
			{ name: 'Main.hx', source: 'class Main {\n\tstatic function main() {\n\t\ttrace(1);\n\t}\n}\n' },
			{ name: 'build.hxml', source: '-cp .\n-main Main\n--no-output\n' }
		]);
	}

	/** Point `process.execPath`, the program `portIsFree` runs, at `path`. */
	private static function setExecPath(path: String): Void {
		js.Syntax.code('process.execPath = {0}', path);
	}
	#end

}

/** What a pool over a one-module tree did: whether a server came up, and the status of a compile through it. */
private typedef Served = { running: Bool, status: Null<Int> };
