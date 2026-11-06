package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JsonFormat;
import dev.BaseEngine;
import dev.BaseSuite;
import dev.BaselineWriter;
import dev.GateReuse;
import dev.GateTree;
import dev.Shard.Tally;
import devkit.Cmd.cmd;
import devkit.Lease.LeaseMode;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/** `dev.BaseSuite`: what a kept reading of the base suite stands for, and when it is read again instead. */
@:nullSafety(Strict)
final class BaseSuiteTest extends Test {

	/** The stamp follows the base commit, the corpus tree's state and the compiler, and not a trailing newline. */
	@:pin('guard')
	public function testTheStampFollowsTheBaseTheCorpusAndTheCompiler(): Void {
		final stamp: String = BaseSuite.stampOf('abc', 'fork s1', 'haxe 4');
		Assert.equals(stamp, BaseSuite.stampOf('abc\n', 'fork s1', 'haxe 4'));
		Assert.notEquals(stamp, BaseSuite.stampOf('abd', 'fork s1', 'haxe 4'));
		Assert.notEquals(stamp, BaseSuite.stampOf('abc', 'fork s2', 'haxe 4'));
		Assert.notEquals(stamp, BaseSuite.stampOf('abc', '', 'haxe 4'));
		Assert.notEquals(stamp, BaseSuite.stampOf('abc', 'fork s1', 'haxe 5'));
	}

	/** A record read back under its own stamp gives the counts and the sweep it was made with; under another stamp, nothing. */
	@:pin('guard')
	public function testARecordIsReadBackOnlyUnderItsStamp(): Void {
		TempDir.with(dir -> {
			final sweep: String = dir.file('sweep-base.json');
			File.saveContent(sweep, '{}');
			final text: String = BaseSuite.encode('s1', { tests: 7, assertions: 9, sweep: sweep });
			final got: Null<BaseReading> = BaseSuite.decode('s1', text, sweep);
			Assert.notNull(got);
			Assert.equals(7, got?.tests);
			Assert.equals(9, got?.assertions);
			Assert.equals(sweep, got?.sweep);
			Assert.isNull(BaseSuite.decode('s2', text, sweep));
		});
	}

	/** A record that names a sweep reads as nothing once the snapshot is gone, and one that names none does not need it. */
	@:pin('guard')
	public function testARecordWhoseSweepIsGoneIsNotUsed(): Void {
		TempDir.with(dir -> {
			final sweep: String = Path.join([dir.file('logs'), 'sweep-base.json']);
			Assert.isNull(BaseSuite.decode('s1', BaseSuite.encode('s1', { tests: 1, assertions: 2, sweep: sweep }), sweep));
			final plain: Null<BaseReading> =
				BaseSuite.decode('s1', BaseSuite.encode('s1', { tests: 1, assertions: 2, sweep: null }), sweep);
			Assert.notNull(plain);
			Assert.isNull(plain?.sweep);
		});
	}

	/** A damaged record is no reading. */
	@:pin('guard')
	public function testADamagedRecordIsNoReading(): Void {
		Assert.isNull(BaseSuite.decode('s1', '', 'x'));
		Assert.isNull(BaseSuite.decode('s1', 's1\nmany\n2\nno sweep\n', 'x'));
		Assert.isNull(BaseSuite.decode('s1', 's1\n1\n', 'x'));
	}

	/** The base checkout is built with the engine its tests spawn beside the runner, not the runner alone. */
	@:pin('control')
	@:killer('M-BASESUITE-ENGINE-NOT-BUILT')
	public function testTheBaseCheckoutBuildsTheEngineBesideTheRunner(): Void {
		final builds: Array<String> = BaseSuite.builds().map(words -> words.join(' '));
		Assert.contains('bin/apq-js.hxml', builds);
		Assert.contains('test-js.hxml', builds);
	}

	/**
	 * The base suite runs with the engine variable on its own checkout's engine, and the gate's value is back afterwards, even
	 * when the run throws.
	 */
	@:pin('control')
	@:killer('M-BASESUITE-ENGINE-UNPINNED')
	@:killer('M-BASESUITE-ENGINE-LEAKS')
	public function testTheBaseSuiteRunsTheEngineOfItsOwnCheckout(): Void {
		final before: Null<String> = Sys.getEnv(GateTree.ENGINE_VAR);
		CliFixture.always(() -> BaseSuite.setEngine(before), () -> {
			BaseSuite.setEngine('/tip/bin/apq.js');
			var seen: String = '';
			final status: Int = BaseSuite.withEngine('/base', () -> {
				seen = Sys.getEnv(GateTree.ENGINE_VAR) ?? '';
				return 3;
			});
			Assert.equals(3, status);
			Assert.equals('/base/bin/apq.js', seen);
			Assert.equals('/tip/bin/apq.js', Sys.getEnv(GateTree.ENGINE_VAR));
			Assert.raises(() -> BaseSuite.withEngine('/base', () -> throw 'red'), String);
			Assert.equals('/tip/bin/apq.js', Sys.getEnv(GateTree.ENGINE_VAR));
		});
	}

	/** An impact gate, or one whose own suite is red, reads no base suite: no record, no base checkout, no build. */
	@:pin('control')
	@:killer('M-BASESUITE-IMPACT-READS-BASE')
	@:killer('M-BASESUITE-RED-GATE-READS-BASE')
	public function testAnImpactOrRedGateRunsNoBaseSuite(): Void {
		TempDir.with(dir -> {
			final gate: GateTree = gateOf(dir);
			final sum: Tally = {
				tests: 107,
				assertions: 210,
				failures: 0,
				errors: 0
			};
			Assert.equals('', BaseSuite.deltaNote(gate, Unpooled, sum, 0, ['unit.dev.SomeTest']));
			Assert.equals('', BaseSuite.deltaNote(gate, Unpooled, sum, 1, null));
			Assert.isFalse(FileSystem.exists(gate.log(BaseSuite.FILE)));
			Assert.isFalse(FileSystem.exists(gate.log('suite-base-build.log')));
		});
	}

	/** A green whole-suite gate with a base reading in its logs prints its counts beside the base's. */
	@:pin('control')
	@:killer('M-BASESUITE-DELTA-DROPPED')
	public function testAWholeGreenGatePrintsItsDeltaAgainstTheKeptBaseReading(): Void {
		TempDir.with(dir -> {
			final gate: GateTree = gateOf(dir);
			final stamp: String = BaseSuite.stampOf(gate.base, GateReuse.forkState(), BaseEngine.toolchain());
			File.saveContent(gate.log(BaseSuite.FILE), BaseSuite.encode(stamp, { tests: 100, assertions: 200, sweep: null }));
			final sum: Tally = {
				tests: 107,
				assertions: 190,
				failures: 0,
				errors: 0
			};
			Assert.equals(' (+7 / -10)', BaseSuite.deltaNote(gate, Unpooled, sum, 0, null));
		});
	}

	/** A git tree with one commit and the baseline record of it in a logs directory beside, as a gate over it reads them. */
	private static function gateOf(dir: TempDir): GateTree {
		final tree: String = dir.file('tree');
		final logs: String = dir.file('logs');
		FileSystem.createDirectory(tree);
		FileSystem.createDirectory(logs);
		File.saveContent(Path.join([tree, 'keep']), tree);
		final git: Array<String> = ['-c', 'user.name=t', '-c', 'user.email=t@t'];
		cmd('git init -q -b main').at(tree).check();
		cmd('git add -A').at(tree).check();
		cmd('git $git commit -q -m base').at(tree).check();
		final base: String = cmd('git rev-parse HEAD').at(tree).check().out.trim();
		File.saveContent(
			Path.join([logs, GateTree.BASELINE_FILE]), BaselineWriter.write({
				base: base,
				lists: JObject([]),
				lint: '',
				infra: [],
				frozen: []
			}, JsonFormat.instance.compactWriteOptions)
		);
		return new GateTree({
			tree: tree,
			logs: logs,
			baseline: false,
			frozen: [],
			infra: [],
			arms: [],
			allow: [],
			allowArms: [],
			noArms: false,
			threads: null,
			run: 'r'
		});
	}

}
