package unit.check;

import anyparse.check.oracle.CompilerOracle;
import anyparse.query.Cli;
import unit.cli.CliFixture;

using StringTools;

/** One lint run of the fixture: its hoists as `<module>:<statement>`, sorted and joined, and its stderr. */
private typedef LintOutcome = {
	final hoisted: String;
	final err: String;
}

/**
 * `hoist-common-import` in a project that declares its build list complete, through the CLI: a run that compiles nothing
 * reads the builds an oracle run stored for the same input and hoists exactly what the oracle run did, and one with no
 * such record holds every hoist the implicit tier does not vouch for and says so.
 */
@:nullSafety(Strict)
class HoistCommonImportBuildsE2ETest extends Test {

	#if (sys || nodejs)
	private static final HOISTED: String = 'aqq/OneQq.hx:qqz.Zqqwwee,aqq/ThreeQq.hx:qqz.Zqqwwee,aqq/TwoQq.hx:qqz.Zqqwwee';
	private static final HELD_NOTE: String = 'hoist-common-import held what only the builds can vouch for';
	#end

	@:pin('control') @:killer('M-HOIST-UNKNOWN-BUILDS-GUESSED') @:killer('M-REACH-STORED-UNREAD') @:killer('M-HOIST-HELD-UNSAID')
	public function testANoOracleRunHoistsWhatTheStoredBuildsVouchForAndHoldsWithoutThem(): Void {
		#if nodejs
		final dir: Null<String> = tree();
		if (dir == null) return;
		final fresh: LintOutcome = lint(dir, true);
		Assert.equals('', fresh.hoisted, 'no oracle run yet: no build is known, so nothing is hoisted');
		Assert.isTrue(fresh.err.indexOf(HELD_NOTE) >= 0, fresh.err);
		final oracle: LintOutcome = lint(dir, false);
		Assert.equals(HOISTED, oracle.hoisted, 'the one build parsing every receiver parses the statement\'s module');
		Assert.isTrue(oracle.err.indexOf(HELD_NOTE) < 0, oracle.err);
		final stored: LintOutcome = lint(dir, true);
		Assert.equals(HOISTED, stored.hoisted, 'the next run reads the builds the oracle run stored');
		Assert.isTrue(stored.err.indexOf(HELD_NOTE) < 0, stored.err);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	/**
	 * A run over paths whose configs name different oracle lists reads no list as complete; one of them declared its list
	 * complete, so the evidence a project with no declared list falls back on vouches for nothing a build of it reads.
	 */
	@:pin('control') @:killer('M-HOIST-MIXED-LISTS-GUESSED')
	public function testARunOverPathsWithDifferentOracleListsHolds(): Void {
		#if nodejs
		final dir: Null<String> = tree('{"hxml":"check.hxml"}', [
			{ name: 'other/apqlint.json', source: '{"compilerOracle":[{"hxml":"other.hxml"}]}' },
			{ name: 'other/other.hxml', source: '-cp ..\n-main Main\n--interp\n' },
			{ name: 'other/Oqqther.hx', source: 'package other;\n\nclass Oqqther {}\n' }
		]);
		if (dir == null) return;
		final mixed: LintOutcome = lint(dir, true);
		Assert.equals('', mixed.hoisted);
		Assert.isTrue(mixed.err.indexOf(HELD_NOTE) >= 0, mixed.err);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	/** A declared build the reach probe cannot read (a `--next` hxml) leaves the run with no builds: it holds and says so. */
	@:pin('control') @:killer('M-HELD-NOTE-LOST-WITH-FACTS') @:killer('M-HOIST-HELD-UNSAID')
	public function testALiveBuildThatDoesNotAnswerHoldsAndSaysSo(): Void {
		#if nodejs
		final dir: Null<String> = tree('{"hxml":"check.hxml"},{"hxml":"next.hxml"}', [
			{ name: 'next.hxml', source: '-cp .\n-main Main\n--interp\n--next\n-cp .\n-main Main\n--interp\n' }
		]);
		if (dir == null) return;
		final live: LintOutcome = lint(dir, false);
		Assert.equals('', live.hoisted);
		Assert.isTrue(live.err.indexOf(HELD_NOTE) >= 0, live.err);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('stdout capture needs the node target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * Four modules of `aqq`, three importing `qqz.Zqqwwee`, all compiled by `check.hxml`, under a config declaring `oracles`
	 * complete, plus `extra`; null (after passing) without haxe.
	 */
	private static function tree(oracles: String = '{"hxml":"check.hxml"}', ?extra: Array<{ name: String, source: String }>): Null<String> {
		final dir: String = CliFixture.writeTree('hoistbuilds', [
			{ name: 'qqz/Zqqwwee.hx', source: 'package qqz;\n\nclass Zqqwwee {\n\tpublic function new() {}\n}\n' },
			{
				name: 'aqq/OneQq.hx',
				source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass OneQq {\n\tpublic static var a:Null<Zqqwwee>;\n}\n'
			},
			{
				name: 'aqq/TwoQq.hx',
				source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass TwoQq {\n\tpublic static var a:Null<Zqqwwee>;\n}\n'
			},
			{
				name: 'aqq/ThreeQq.hx',
				source: 'package aqq;\n\nimport qqz.Zqqwwee;\n\nclass ThreeQq {\n\tpublic static var a:Null<Zqqwwee>;\n}\n'
			},
			{ name: 'aqq/FourQq.hx', source: 'package aqq;\n\nclass FourQq {\n\tpublic static var b:Int = 0;\n}\n' },
			{
				name: 'Main.hx',
				source: 'class Main {\n\tstatic function main():Void {\n\t\ttrace([aqq.OneQq.a, aqq.TwoQq.a, aqq.ThreeQq.a]);\n'
				+ '\t\ttrace(aqq.FourQq.b);\n\t}\n}\n'
			},
			{ name: 'check.hxml', source: '-cp .\n-main Main\n--interp\n' },
			{
				name: 'apqlint.json',
				source: '{"compilerOracle":[$oracles],"resolutionRoots":["."],"reachConfigurationsComplete":true,'
				+ '"rules":{"hoist-common-import":{"enabled":true}}}'
			}
		].concat(extra ?? []));
		if (CompilerOracle.typecheck('check.hxml', dir).match(Confirmed)) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}

	/** The hoists a `hoist-common-import` lint of `dir` reports, as `<module>:<statement>` sorted, and what it said on stderr. */
	private static function lint(dir: String, noOracle: Bool): LintOutcome {
		final args: Array<String> = ['lint', '--rule', 'hoist-common-import', '--flat'].concat(noOracle ? ['--no-oracle'] : [])
			.concat([dir]);
		var err: String = '';
		final out: String = CliFixture.captureStdout(() -> err = CliFixture.captureStderr(Cli.run.bind(args)));
		final hoisted: Array<String> = [];
		for (line in out.split('\n')) {
			final quoted: Array<String> = line.split('\'');
			if (line.indexOf('(hoist-common-import)') >= 0 && line.startsWith('$dir/'))
				hoisted.push('${line.substring(dir.length + 1, line.indexOf(':'))}:${quoted[1]}');
		}
		hoisted.sort(Reflect.compare);
		return { hoisted: hoisted.join(','), err: err };
	}
	#end

}
