package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.CompilerOracle;
import anyparse.check.CompilerServer;
import anyparse.check.FixVerifier;
import anyparse.check.LintConfig.OracleConfig;
import anyparse.check.OracleCoverage;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * `compilerOracle` as a LIST of configurations, end to end against the real compiler — the
 * promise a single configuration cannot keep.
 *
 * One hxml is one set of defines while a `#if` has two or more arms, so for any project with
 * conditional compilation "the oracle typechecks your fix" was false by construction: an edit in
 * code only the android arm compiles is read by nothing a macOS build runs. The directions that
 * together make the list a control rather than a slogan:
 *
 * 1. An edit the FIRST configuration accepts and the SECOND rejects is REVERTED — one
 *    confirmation is not a verdict.
 * 2. The rejection SHORT-CIRCUITS: a third configuration is never asked, so the worst case of one
 *    compile per configuration is paid only for a good edit.
 * 3. A region only the second configuration compiles stops being declined, which is the
 *    capability the list adds.
 * 4. A region NO configuration compiles is still declined, and the sentence carries every
 *    configuration's own reason.
 * 5. A define reaches EVERY `--next` arm of a multi-arm hxml, or the verdict is about a
 *    configuration nobody asked for.
 */
@:nullSafety(Strict)
final class OracleConfigListE2ETest extends Test {

	#if (sys || nodejs)
	/**
	 * The literal `1` is rewritten to `ONLY_IN_FIRST`, which EXISTS only while `second` is
	 * undefined — so the same edit compiles under one configuration and not under the other,
	 * while the original source compiles under both.
	 *
	 * The edit's own span sits outside every `#if`, so both configurations cover it and the
	 * verdict turns on the typecheck rather than on coverage.
	 */
	private static final SHARED: String = 'class Good {\n\n\t#if !second\n\tstatic inline final ONLY_IN_FIRST:Int = 2;\n\t#end\n\n'
		+ '\tpublic static function main() {\n\t\tfinal v:Int = 1;\n\t\ttrace(v);\n\t}\n\n}\n';

	/** One hxml for every configuration — which is also the shape that made the verdict cache share one record. */
	private static final SHARED_HXML: String = '-cp .\n-main Good\n';

	/** The rewritable literal lives in the branch `-D second` KEEPS, so only that configuration typechecks it. */
	private static final REGION: String = 'class Region {\n\n\tpublic static function run():Void {\n\t\t#if second\n'
		+ '\t\tfinal v:Int = 1;\n\t\ttrace(v);\n\t\t#else\n\t\ttrace(0);\n\t\t#end\n\t}\n\n}\n';

	/** The same shape in a branch NEITHER configuration defines — the decline that survives the list. */
	private static final NOWHERE: String = 'class Nowhere {\n\n\tpublic static function run():Void {\n\t\t#if never\n'
		+ '\t\tfinal v:Int = 1;\n\t\ttrace(v);\n\t\t#else\n\t\ttrace(0);\n\t\t#end\n\t}\n\n}\n';
	private static final REGION_MAIN: String =
		'class Main {\n\n\tpublic static function main() {\n\t\tRegion.run();\n\t\tNowhere.run();\n\t}\n\n}\n';
	private static final REGION_HXML: String = '-cp .\n-main Main\n';

	/** Two `--next` arms, each a whole compilation of its own — the shape a trailing `-D` reaches only half of. */
	private static final TWO_ARM_HXML: String = '-cp .\n-main ArmA\n--next\n-cp .\n-main ArmB\n';

	/**
	 * `-D breakme` makes this module's own baseline RED, while the rewritable literal below sits
	 * outside every `#if` — so the configuration that declares the define can judge nothing and
	 * the one that does not still judges the edit perfectly well.
	 */
	private static final RED: String = 'class Red {\n\n\tpublic static function main() {\n\t\t#if breakme\n'
		+ '\t\tfinal broken:Int = \'not an int\';\n\t\ttrace(broken);\n\t\t#end\n\t\tExcluded.run();\n'
		+ '\t\tfinal v:Int = 1;\n\t\ttrace(v);\n\t}\n\n}\n';

	/** The rewritable literal lives in the branch only the EXCLUDED configuration would make live. */
	private static final EXCLUDED: String = 'class Excluded {\n\n\tpublic static function run():Void {\n\t\t#if breakme\n'
		+ '\t\tfinal v:Int = 1;\n\t\ttrace(v);\n\t\t#else\n\t\ttrace(0);\n\t\t#end\n\t}\n\n}\n';
	private static final RED_HXML: String = '-cp .\n-main Red\n';

	/**
	 * A CLI fixture red under `-D breakme` and green without it, carrying one double-quoted string
	 * for the safe `prefer-single-quotes` fix and one comprehension local only the oracle-assisted
	 * `explicit-local-type` tail can annotate.
	 */
	private static final CLI_MAIN: String = 'class Main {\n\n\tpublic static function main() {\n\t\t#if breakme\n'
		+ '\t\tfinal broken:Int = \'not an int\';\n\t\ttrace(broken);\n\t\t#end\n'
		+ '\t\tvar comp = [for (i in 0...3) i];\n\t\ttrace(comp, "double");\n\t}\n\n}\n';

	/** Two configurations over one hxml: the green one first, the one `-D breakme` makes red second. */
	private static final GREEN_AND_RED: String = '[{"hxml":"check.hxml"},{"hxml":"check.hxml","defines":["breakme"]}]';

	/**
	 * `pick()` returns `Int` under `-D flag` and `String` without it, so the type a display server
	 * names for `v` says which configuration it was warmed and queried under.
	 */
	private static final DISPLAY_MAIN: String = 'class Main {\n\n\tstatic function pick() {\n\t\treturn #if flag 1 #else \'a\' #end;\n'
		+ '\t}\n\n\tpublic static function main() {\n\t\tvar v = pick();\n\t\ttrace(v);\n\t}\n\n}\n';
	private static final CLI_HXML: String = '-cp .\n-main Main\n';

	/**
	 * `CLI_MAIN` behind an UNUSED import, so the safe `unused-import` fix deletes a line above the
	 * `-D breakme` error and the red build's first error line moves between the two phases that
	 * measure it.
	 */
	private static final SHIFTED_MAIN: String = 'import haxe.ds.StringMap;\n\n$CLI_MAIN';

	/** The stderr sentence naming the `-D breakme` exclusion, which a run must print exactly once. */
	private static final BREAKME_EXCLUDED: String = '-D breakme was excluded';
	#end

	/**
	 * Direction 1, and the test that goes red on "the first configuration is enough".
	 *
	 * Both halves in ONE run: the same edit under the first configuration alone is APPLIED, and
	 * with the second configuration beside it is REVERTED. Without the applied half a gate that
	 * refused everything would pass this; without the reverted half the incident it exists to
	 * prevent — an edit that compiled on mac and broke android — would.
	 */
	@:pin('control')
	@:killer('M-ORACLE-FIRST-CONFIGURATION-IS-ENOUGH')
	public function testAnEditTheSecondConfigurationRejectsIsReverted(): Void {
		#if (sys || nodejs)
		final dir: String = sharedDir();
		if (skipWithoutHaxe(dir, 'check.hxml')) return;
		final alone: FixVerifyResult = rewrite(dir, 'Good.hx', SHARED, 'ONLY_IN_FIRST', [oracle(dir, 'check.hxml', [])]);
		Assert.same(['$dir/Good.hx'], alone.applied, 'the first configuration accepts the edit on its own');
		Assert.isTrue(File.getContent('$dir/Good.hx').indexOf('= ONLY_IN_FIRST;') != -1, 'and the rewrite reached disk');
		final both: FixVerifyResult = rewrite(dir, 'Good.hx', SHARED, 'ONLY_IN_FIRST', [
			oracle(dir, 'check.hxml', []),
			oracle(dir, 'check.hxml', ['second'])
		]);
		Assert.isTrue(both.baseline.match(Confirmed), 'the original source typechecks under BOTH configurations');
		Assert.equals(0, both.applied.length, 'an edit the second configuration rejects is not applied');
		Assert.equals(1, both.reverted.length, 'it is REVERTED');
		Assert.isTrue(both.reverted[0].cause.match(OracleRejected), 'by a compiler that read it, not by a coverage gap');
		Assert.equals(SHARED, File.getContent('$dir/Good.hx'), 'and the file is restored byte for byte');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Direction 2: the first REJECTION decides, so a third configuration is never asked.
	 *
	 * Counted in compiler SPAWNS, because that is the whole claim — the verdict is the same either
	 * way. Three baseline typechecks (every configuration confirms before any candidate is judged)
	 * plus two for the candidate: accepted by the first, refused by the second, third not reached.
	 */
	public function testARejectionShortCircuitsTheRemainingConfigurations(): Void {
		#if (sys || nodejs)
		final dir: String = sharedDir();
		if (skipWithoutHaxe(dir, 'check.hxml')) return;
		final before: Int = CompilerOracle.invocations;
		final result: FixVerifyResult = rewrite(dir, 'Good.hx', SHARED, 'ONLY_IN_FIRST', [
			oracle(dir, 'check.hxml', []),
			oracle(dir, 'check.hxml', ['second']),
			oracle(dir, 'check.hxml', ['third'])
		]);
		Assert.equals(1, result.reverted.length, 'the second configuration still decides the outcome');
		Assert.equals(
			5, CompilerOracle.invocations - before,
			'3 baseline typechecks + 2 for the candidate — the third is never asked once the second refuses'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A configuration whose OWN baseline is red is EXCLUDED and NAMED, and its green sibling
	 * still judges everything it covers.
	 *
	 * Four directions in one run, because each alone passes for the wrong reason. The edit the
	 * green configuration covers is APPLIED — a whole-phase stop on the red sibling would leave
	 * it, which on a cross-platform tree is one broken target disabling every risky fix. The
	 * excluded configuration is NAMED — silence makes it indistinguishable from one that
	 * confirmed. An edit only IT would have covered is DECLINED with the exclusion carried in the
	 * sentence, since otherwise the reader hunts an hxml's classpath for a file whose own build
	 * was dropped. And with EVERY configuration red the phase declines whole, exactly as one red
	 * oracle always did.
	 */
	@:pin('control')
	@:killer('M-ORACLE-RED-BASELINE-STOPS-THE-PHASE')
	public function testARedBaselineExcludesItsConfigurationRatherThanThePhase(): Void {
		#if (sys || nodejs)
		final dir: String = redDir();
		if (skipWithoutHaxe(dir, 'red.hxml')) return;
		final green: OracleConfig = oracle(dir, 'red.hxml', []);
		final red: OracleConfig = oracle(dir, 'red.hxml', ['breakme']);
		final mixed: FixVerifyResult = rewrite(dir, 'Red.hx', RED, '2', [green, red]);
		Assert.isTrue(mixed.baseline.match(Confirmed), 'one green configuration is enough for the phase to run');
		Assert.same(['$dir/Red.hx'], mixed.applied, 'and it judges the edit it covers');
		Assert.equals(1, mixed.excluded.length, 'the red configuration is excluded, not a reason to stop');
		Assert.stringContains('-D breakme', mixed.excluded[0].sentence);
		Assert.stringContains('does not typecheck before any edit', mixed.excluded[0].sentence);
		final onlyExcluded: FixVerifyResult = rewrite(dir, 'Excluded.hx', EXCLUDED, '2', [green, red]);
		Assert.equals(1, onlyExcluded.declined.length, 'the branch only the excluded configuration would compile is unverifiable');
		Assert.stringContains('-D breakme', onlyExcluded.declined[0].reason);
		Assert.stringContains('is live under no compiled arm', onlyExcluded.declined[0].reason);
		final allRed: FixVerifyResult = rewrite(dir, 'Red.hx', RED, '2', [red]);
		Assert.isTrue(allRed.baseline.match(Rejected(_)), 'with NO configuration left the phase declines whole, as before');
		Assert.equals(0, allRed.applied.length);
		Assert.equals(1, allRed.excluded.length, 'and the one configuration that judged nothing is still named');
		Assert.equals(RED, File.getContent('$dir/Red.hx'), 'and nothing was written');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A seeded probe is reused only for the configuration it was taken for — never by position.
	 *
	 * The seed is the `-D second` build's probe, which DOES make the rewritten branch live, while the
	 * run judges with the define-less build alone, which does not. Paired by position, the seed would
	 * answer for the define-less build, the edit would be written into a branch that build never
	 * compiles, and its exit 0 would read as `verified`. Paired by configuration, the define-less build
	 * is probed for itself and the edit is declined. The second half runs the same seed with BOTH
	 * configurations, so a gate that simply refused every seed cannot pass.
	 */
	@:pin('control')
	@:killer('M-ORACLE-COVERAGE-PAIRED-BY-INDEX')
	public function testASeededProbeAnswersOnlyForItsOwnConfiguration(): Void {
		#if (sys || nodejs)
		final dir: String = regionDir();
		if (skipWithoutHaxe(dir, 'main.hxml')) return;
		final plain: OracleConfig = oracle(dir, 'main.hxml', []);
		final second: OracleConfig = oracle(dir, 'main.hxml', ['second']);
		final seed: Array<ConfigCoverage> = [{ config: second, coverage: OracleCoverage.probe('main.hxml', dir, ['second']) }];
		final alone: FixVerifyResult = rewrite(dir, 'Region.hx', REGION, '2', [plain], seed);
		Assert.equals(0, alone.applied.length, 'another configuration\'s probe cannot vouch for this one');
		Assert.equals(1, alone.declined.length, 'the define-less build is probed for itself and cannot typecheck the branch');
		Assert.equals(REGION, File.getContent('$dir/Region.hx'), 'so nothing is written into it');
		final both: FixVerifyResult = rewrite(dir, 'Region.hx', REGION, '2', [plain, second], seed);
		Assert.same(['$dir/Region.hx'], both.applied, 'the seed still answers for the configuration it was taken for');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A configuration whose compiled set is UNKNOWN is excluded and named, like a red baseline, and its
	 * siblings still judge — the phase stops only when no configuration is left.
	 *
	 * The unknown answer is staged through the seed, since a real probe that fails while the same
	 * build's typecheck succeeds is an environment accident no fixture can arrange.
	 */
	@:pin('control')
	@:killer('M-ORACLE-UNKNOWN-COVERAGE-STOPS-THE-PHASE')
	public function testAnUnknownCompiledSetExcludesItsConfigurationRatherThanThePhase(): Void {
		#if (sys || nodejs)
		final dir: String = sharedDir();
		if (skipWithoutHaxe(dir, 'check.hxml')) return;
		final known: OracleConfig = oracle(dir, 'check.hxml', []);
		final unknown: OracleConfig = oracle(dir, 'check.hxml', ['third']);
		final mixed: FixVerifyResult = rewrite(
			dir, 'Good.hx', SHARED, '3', [known, unknown],
			[{ config: unknown, coverage: OracleCoverage.unknown('staged unknown') }]
		);
		Assert.isNull(mixed.coverageUnknown, 'one known configuration is enough for the phase to run');
		Assert.same(['$dir/Good.hx'], mixed.applied, 'and it judges the edit it covers');
		Assert.equals(1, mixed.excluded.length, 'the configuration that cannot say what it compiles is excluded');
		Assert.stringContains('-D third', mixed.excluded[0].sentence);
		Assert.stringContains('compiled set is unknown (staged unknown)', mixed.excluded[0].sentence);
		final none: FixVerifyResult = rewrite(
			dir, 'Good.hx', SHARED, '3', [unknown],
			[{ config: unknown, coverage: OracleCoverage.unknown('staged unknown') }]
		);
		Assert.equals('staged unknown', none.coverageUnknown, 'with no configuration left the phase stops, as before');
		Assert.equals(0, none.applied.length);
		Assert.equals(SHARED, File.getContent('$dir/Good.hx'), 'and nothing was written');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A configuration whose compiled set is unknown vouches for no edit but keeps its VETO.
	 *
	 * Its baseline is green, so a rejection from it is attributable: the edit compiles under the
	 * known configuration and breaks under the unknown one, and it must be REVERTED. Dropping the
	 * unknown configuration from the post-edit typecheck is how a shared-code edit that compiled on mac
	 * and broke an android build whose `-v` probe failed was applied.
	 */
	@:pin('control')
	@:killer('M-ORACLE-UNKNOWN-COVERAGE-NO-VETO')
	public function testAConfigurationWithAnUnknownCompiledSetStillVetoesAnEdit(): Void {
		#if (sys || nodejs)
		final dir: String = sharedDir();
		if (skipWithoutHaxe(dir, 'check.hxml')) return;
		final known: OracleConfig = oracle(dir, 'check.hxml', []);
		final unknown: OracleConfig = oracle(dir, 'check.hxml', ['second']);
		final result: FixVerifyResult = rewrite(
			dir, 'Good.hx', SHARED, 'ONLY_IN_FIRST', [known, unknown],
			[{ config: unknown, coverage: OracleCoverage.unknown('staged unknown') }]
		);
		Assert.isNull(result.coverageUnknown, 'the known configuration makes the edit judgeable');
		Assert.equals(0, result.applied.length, 'an edit the unknown-coverage build rejects is not applied');
		Assert.equals(1, result.reverted.length, 'it is REVERTED');
		Assert.isTrue(result.reverted[0].cause.match(OracleRejected), 'by the compiler, not by a coverage gap');
		Assert.equals(SHARED, File.getContent('$dir/Good.hx'), 'and the file is restored byte for byte');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A red configuration is named ONCE per run even when its reason's wording moves between phases.
	 *
	 * The safe `unused-import` fix deletes a line above the `-D breakme` error, so the safe-pass net
	 * (taken before its writes) and the oracle-assisted phase (taken after them) quote two
	 * different line numbers for the same build. The report dedupes by configuration and cause.
	 */
	@:pin('control')
	@:killer('M-ORACLE-EXCLUSIONS-KEYED-BY-SENTENCE')
	public function testARedConfigurationWhoseErrorLineMovesIsNamedOnce(): Void {
		#if nodejs
		final dir: String = cliDir('{"compilerOracle":$GREEN_AND_RED,"rules":{"explicit-local-type":{"enabled":true}}}', SHIFTED_MAIN);
		if (skipWithoutHaxe(dir, 'check.hxml')) return;
		final stderr: String = CliFixture.captureStderr(() ->
			Cli.run(['lint', '--rule', 'unused-import', '--rule', 'explicit-local-type', '--fix', dir])
		);
		Assert.equals(-1, File.getContent('$dir/Main.hx').indexOf('import haxe.ds.StringMap'), 'the safe fix moved the error line');
		Assert.equals(1, stderr.split(BREAKME_EXCLUDED).length - 1, 'named once despite two line numbers: $stderr');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stderr capture needs the node target');
		#end
	}

	/**
	 * A SAFE-ONLY `--fix` run names the configuration its revert net ran without.
	 *
	 * The net shrinks to the green subset when a build is red before the run, and in silence that reads
	 * as a net over every build — the sentence the run used to print when its one oracle was red.
	 */
	@:pin('control')
	@:killer('M-ORACLE-EXCLUSIONS-UNNAMED')
	public function testASafeOnlyRunNamesTheConfigurationItsNetRanWithout(): Void {
		#if nodejs
		final dir: String = cliDir('{"compilerOracle":$GREEN_AND_RED}', CLI_MAIN);
		if (skipWithoutHaxe(dir, 'check.hxml')) return;
		final stderr: String = CliFixture.captureStderr(() -> Cli.run(['lint', '--rule', 'prefer-single-quotes', '--fix', dir]));
		Assert.isTrue(File.getContent('$dir/Main.hx').indexOf('trace(comp, \'double\');') != -1, 'the safe fix landed');
		Assert.equals(1, stderr.split(BREAKME_EXCLUDED).length - 1, 'the excluded configuration is named once: $stderr');
		Assert.stringContains('apq lint --fix: compiler oracle ', stderr);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stderr capture needs the node target');
		#end
	}

	/**
	 * The oracle-assisted phase names its exclusions too, and a run whose safe pass ALREADY named the
	 * same configuration does not name it a second time.
	 */
	public function testTheAssistedPhaseNamesItsExclusionOncePerRun(): Void {
		#if nodejs
		final dir: String = cliDir('{"compilerOracle":$GREEN_AND_RED,"rules":{"explicit-local-type":{"enabled":true}}}', CLI_MAIN);
		if (skipWithoutHaxe(dir, 'check.hxml')) return;
		final stderr: String = CliFixture.captureStderr(() -> Cli.run([
			'lint',
			'--rule',
			'explicit-local-type',
			'--rule',
			'prefer-single-quotes',
			'--fix',
			dir
		]));
		final packed: String = File.getContent('$dir/Main.hx').split(' ').join('');
		Assert.isTrue(packed.indexOf('varcomp:Array<Int>') != -1, 'the green configuration judged the annotation: $packed');
		Assert.equals(1, stderr.split(BREAKME_EXCLUDED).length - 1, 'named once across both phases that measured it: $stderr');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stderr capture needs the node target');
		#end
	}

	/**
	 * The display server is warmed and queried under the defines of the configuration it serves.
	 *
	 * The only configuration declares `-D flag`, under which `v` is an `Int`. A server that dropped the
	 * define names `String`, the annotation then fails the `-D flag` typecheck and is reverted; with the
	 * define carried, `Int` is written and kept.
	 */
	@:pin('control')
	@:killer('M-DISPLAY-ORACLE-DROPS-DEFINES')
	public function testTheDisplayServerAnswersForTheConfigurationItServes(): Void {
		Assert.same(
			['-D', 'flag', '--connect', '7000', 'check.hxml', '--display', 'Main.hx@1@type'],
			CompilerServer.connectArgs(7000, 'check.hxml', ['--display', 'Main.hx@1@type'], ['flag']),
			'a display request leads with its defines and no --each, which would silence its reply'
		);
		Assert.same(
			['-D', 'flag', '--each', '--connect', '7000', 'check.hxml', '--no-output'],
			CompilerServer.connectArgs(7000, 'check.hxml', ['--no-output'], ['flag']), 'a compile still spreads them to every arm'
		);
		#if nodejs
		final dir: String = cliDir(
			'{"compilerOracle":[{"hxml":"check.hxml","defines":["flag"]}],"rules":{"explicit-local-type":{"enabled":true}}}', DISPLAY_MAIN
		);
		if (skipWithoutHaxe(dir, 'check.hxml')) return;
		Cli.run(['lint', '--rule', 'explicit-local-type', '--fix', dir]);
		final packed: String = File.getContent('$dir/Main.hx').split(' ').join('');
		Assert.isTrue(packed.indexOf('varv:Int') != -1, 'the type the -D flag build infers is annotated: $packed');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('the display server needs the node target');
		#end
	}

	/**
	 * Direction 3: a `#if` branch only the SECOND configuration compiles is no longer declined.
	 *
	 * Asserted against the same fixture under the first configuration alone, where it still is —
	 * so the test cannot be satisfied by a gate that merely stopped declining.
	 */
	public function testARegionOnlyTheSecondConfigurationCompilesIsNoLongerDeclined(): Void {
		#if (sys || nodejs)
		final dir: String = regionDir();
		if (skipWithoutHaxe(dir, 'main.hxml')) return;
		final alone: FixVerifyResult = rewrite(dir, 'Region.hx', REGION, '2', [oracle(dir, 'main.hxml', [])]);
		Assert.equals(1, alone.declined.length, 'one configuration cannot typecheck the branch it excludes');
		Assert.equals(REGION, File.getContent('$dir/Region.hx'), 'so nothing is written into it');
		final both: FixVerifyResult = rewrite(dir, 'Region.hx', REGION, '2', [
			oracle(dir, 'main.hxml', []),
			oracle(dir, 'main.hxml', ['second'])
		]);
		Assert.equals(0, both.declined.length, 'the configuration that DOES compile the branch verifies the edit');
		Assert.same(['$dir/Region.hx'], both.applied);
		Assert.isTrue(File.getContent('$dir/Region.hx').indexOf('final v:Int = 2;') != -1, 'and the rewrite reached the branch');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Direction 4: a branch NO configuration makes live is still declined, and the sentence
	 * carries every configuration's own reason instead of one of them.
	 */
	public function testARegionNoConfigurationCompilesIsDeclinedNamingEachReason(): Void {
		#if (sys || nodejs)
		final dir: String = regionDir();
		if (skipWithoutHaxe(dir, 'main.hxml')) return;
		final result: FixVerifyResult = rewrite(dir, 'Nowhere.hx', NOWHERE, '2', [
			oracle(dir, 'main.hxml', []),
			oracle(dir, 'main.hxml', ['second'])
		]);
		Assert.equals(1, result.declined.length, 'a branch neither configuration defines is unverifiable by either');
		final reason: String = result.declined[0].reason;
		Assert.stringContains('no configured compiler oracle typechecks this edit', reason);
		Assert.equals(
			2, reason.split('is live under no compiled arm').length - 1, 'one clause per configuration, not one for the set: got $reason'
		);
		Assert.equals(NOWHERE, File.getContent('$dir/Nowhere.hx'), 'and nothing was written');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Direction 5: the define reaches EVERY `--next` arm.
	 *
	 * `--each` pushes what precedes it into each arm, so the `-D` goes ahead of it; a trailing one
	 * joins the LAST arm only and the first arm then fails on a fixture written to fail without
	 * the define. The pure argument vector is asserted beside the compiler's verdict, because the
	 * placement is the thing under test and a machine without `haxe` can still check it.
	 */
	public function testADefineReachesEveryArmOfAMultiArmHxml(): Void {
		Assert.same(['build.hxml', '--no-output'], CompilerOracle.oracleArgs('build.hxml', []), 'no defines, no --each — as before');
		Assert.same(
			['-D', 'flag', '-D', 'other', '--each', 'build.hxml', '--no-output'],
			CompilerOracle.oracleArgs('build.hxml', ['flag', 'other']), 'every -D precedes --each, and --no-output still follows the hxml'
		);
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('oraclelistarms', [
			{ name: 'ArmA.hx', source: arm('ArmA') },
			{ name: 'ArmB.hx', source: arm('ArmB') },
			{ name: 'two.hxml', source: TWO_ARM_HXML }
		]);
		final withDefine: OracleOutcome = CompilerOracle.typecheck('two.hxml', dir, ['flag']);
		final withoutDefine: OracleOutcome = CompilerOracle.typecheck('two.hxml', dir, []);
		CliFixture.removeDir(dir);
		if (withoutDefine.match(Unavailable(_))) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		Assert.isTrue(
			withoutDefine.match(Rejected(_)), 'the fixture must FAIL without the define, else the assertion below proves nothing'
		);
		Assert.isTrue(withDefine.match(Confirmed), 'with the define ahead of --each, BOTH arms see it: got $withDefine');
		#end
	}

	#if (sys || nodejs)
	/**
	 * True when this host has no working `haxe` — the fixtures typecheck by construction, so a
	 * rejection means no compiler. Carries the skip verdict AND the teardown.
	 */
	private function skipWithoutHaxe(dir: String, hxml: String): Bool {
		if (CompilerOracle.typecheck(hxml, dir).match(Confirmed)) return false;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return true;
	}

	/** One arm's module: it typechecks only while `flag` is defined, so an arm the define missed fails. */
	private static function arm(name: String): String {
		return 'class $name {\n\n\tpublic static function main() {\n\t\t#if flag\n\t\ttrace(\'ok\');\n\t\t#else\n'
			+ '\t\tfinal x:Int = \'not an int\';\n\t\ttrace(x);\n\t\t#end\n\t}\n\n}\n';
	}

	/** One configuration over a fixture's hxml, differing from its siblings only in `defines`. */
	private static function oracle(dir: String, hxml: String, defines: Array<String>): OracleConfig {
		return {
			hxml: hxml,
			dir: dir,
			defines: defines
		};
	}

	/** The one-module fixture the cross-configuration verdict directions share. */
	private static function sharedDir(): String {
		return CliFixture.writeDir('oraclelist', [
			{ name: 'Good.hx', source: SHARED },
			{ name: 'check.hxml', source: SHARED_HXML }
		]);
	}

	/** The two-module fixture the red-baseline direction uses. */
	private static function redDir(): String {
		return CliFixture.writeDir('oraclelistred', [
			{ name: 'Red.hx', source: RED },
			{ name: 'Excluded.hx', source: EXCLUDED },
			{ name: 'red.hxml', source: RED_HXML }
		]);
	}

	/** The three-module fixture the region directions share. */
	private static function regionDir(): String {
		return CliFixture.writeDir('oraclelistregion', [
			{ name: 'Main.hx', source: REGION_MAIN },
			{ name: 'Region.hx', source: REGION },
			{ name: 'Nowhere.hx', source: NOWHERE },
			{ name: 'main.hxml', source: REGION_HXML }
		]);
	}
	/** A one-module `Main` fixture with the given `apqlint.json`, for the scenarios that run the whole CLI. */
	private static function cliDir(apqlint: String, main: String): String {
		return CliFixture.writeDir('oraclelistcli', [
			{ name: 'Main.hx', source: main },
			{ name: 'check.hxml', source: CLI_HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
	}

	/**
	 * One `test-risky-literal-rewrite` pass over ONE module of a fixture, coverage probed for
	 * real; the module is restored to `source` first, so a scenario may run several passes.
	 */
	private static function rewrite(
		dir: String, name: String, source: String, replacement: String, oracles: Array<OracleConfig>, ?seed: Array<ConfigCoverage>
	): FixVerifyResult {
		File.saveContent('$dir/$name', source);
		return FixVerifier.verify(
			[{ file: '$dir/$name', source: source }],
			[new TestRiskyLiteralRewrite(replacement)],
			new HaxeQueryPlugin(), oracles, File.saveContent, null, seed
		);
	}
	#end

}
