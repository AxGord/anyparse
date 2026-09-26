package unit.check;

import anyparse.core.TempScratch;
import anyparse.query.Cli;
import anyparse.query.cli.command.LintCommand;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * How a lint run wires its compiles: the configurations it prepares remember what the compiler answered
 * (`OracleRunMemo`), and a run given every rule starts its facts compiles before its first pass and ends them when no
 * check asked.
 *
 * Compiles are counted by the compiler itself: the fixture's hxml runs an init macro (`Counter.hit`) that appends a
 * line to `compiles.log` in the project directory.
 */
@:nullSafety(Strict)
final class OracleRunWiringTest extends Test {

	#if (sys || nodejs)
	private static final GOOD: String = 'class Good {\n\tpublic function new() {}\n\n\tstatic function main() {\n\t\tfinal a:Good = new '
		+ 'Good();\n\t\tvar x:Dynamic = a;\n\t\tvar y:Good = x;\n\t\ttrace(y);\n\t}\n}\n';
	private static final HXML: String = '-cp .\n-main Good\n' + CompileCounter.MACRO;
	private static final APQLINT: String = '{"compilerOracle":"check.hxml","rules":{"avoid-dynamic":{"enabled":true}}}';
	private static final LIB_A: String = 'package lib;\n\nclass A {\n\tpublic var x:Int = 1;\n\n\tpublic function new() {}\n}\n';
	#end

	/**
	 * A `--fix` run compiles each tree it asks about once: the risky phase's baseline (with `-v`) also answers its
	 * coverage probe, and the verification of the applied edit also answers the next phase's baseline of that tree.
	 */
	@:pin('control')
	@:killer('M-RUNMEMO-NOT-ATTACHED')
	public function testALintRunCompilesEachTreeOnce(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = project();
		if (dir == null) return;
		Cli.run(['lint', '$dir/Good.hx', '--fix', '--rule', 'avoid-dynamic']);
		Assert.isTrue(sys.io.File.getContent('$dir/Good.hx').indexOf('var x:Good') >= 0, 'the risky edit was verified and applied');
		Assert.equals(2, CompileCounter.count(dir), 'the baseline of the first tree and the verification of the second, nothing else');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A project whose own sources reach the compile through `-lib` (a local `.haxelib` whose dev path is the project's
	 * `src`): the compiler's classpath directories are hashed once per process, so without the run's own hash of what it
	 * writes, the edited file fingerprinted at its old content and the verification was answered from the baseline.
	 */
	@:pin('control')
	@:killer('M-RUNMEMO-WRITTEN-UNHASHED')
	public function testAnEditReachedThroughALibraryIsCompiled(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('runwiringlib', [
			{ name: 'src/Main.hx', source: 'class Main {\n\tstatic function main() {\n\t\tlib.B.poke(new lib.A());\n\t}\n}\n' },
			{ name: 'src/lib/A.hx', source: LIB_A },
			{
				name: 'src/lib/B.hx',
				source: 'package lib;\n\nclass B {\n\tpublic static function poke(a:A):Void {\n\t\ta.x = 2;\n\t}\n}\n'
			},
			{ name: 'build.hxml', source: '-lib mylib\n-main Main\n-js out.js\n' },
			{ name: 'apqlint.json', source: '{"compilerOracle":"build.hxml"}' },
			{ name: '.haxelib/.repo-version', source: '1\n' },
			{ name: '.haxelib/mylib/.dev', source: '' }
		]);
		sys.io.File.saveContent('$dir/.haxelib/mylib/.dev', '$dir/src/');
		if (Cli.run(['oracle', '$dir/src/lib/A.hx']) != 0) {
			CliFixture.removeDir(dir);
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		Cli.run(['lint', '$dir/src/lib/A.hx', '--fix', '--rule', 'prefer-final-public-field']);
		Assert.equals(LIB_A, sys.io.File.getContent('$dir/src/lib/A.hx'), 'B writes the field, so the compiler refuses the final');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Only a `--fix` run that could be asked for the facts and is given every rule starts their compiles ahead.
	 */
	@:pin('control')
	@:killer('M-FACTS-NEVER-EARLY')
	public function testAFixRunGivenEveryRuleStartsTheFactsEarly(): Void {
		Assert.isTrue(LintCommand.startsFactsEarly(true, 1, false, false, true));
	}

	@:pin('guard')
	public function testAReportANarrowedOrAnOracleLessRunAsksOnDemand(): Void {
		Assert.isFalse(LintCommand.startsFactsEarly(true, 1, false, false, false), 'a report, whose checks never ask');
		Assert.isFalse(LintCommand.startsFactsEarly(true, 1, false, true, true), 'a --rule run');
		Assert.isFalse(LintCommand.startsFactsEarly(true, 1, true, false, true), 'a --no-oracle run');
		Assert.isFalse(LintCommand.startsFactsEarly(true, 0, false, false, true), 'no configuration');
		Assert.isFalse(LintCommand.startsFactsEarly(false, 1, false, false, true), 'no resolution scope');
	}

	/** The facts compiles a run started and no check asked for are ended with the run, their probe directories deleted. */
	@:pin('control')
	@:killer('M-FACTS-EARLY-DIRS-LEFT')
	public function testUnaskedEarlyFactsLeaveNothingBehind(): Void {
		#if (sys || nodejs)
		final dir: Null<String> = project();
		if (dir == null) return;
		final before: Array<String> = factsDirs();
		Cli.run(['lint', '$dir/Good.hx', '--fix']);
		Assert.same(before, factsDirs(), 'no probe directory outlives the run');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** The fixture project, or null (the test passed) when no compiler is available. */
	private static function project(): Null<String> {
		final dir: String = CliFixture.writeDir('runwiring', [
			{ name: 'Good.hx', source: GOOD },
			{ name: 'Counter.hx', source: CompileCounter.SOURCE },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: APQLINT }
		]);
		final probe: Int = Cli.run(['oracle', '$dir/Good.hx']);
		if (sys.FileSystem.exists('$dir/compiles.log')) sys.FileSystem.deleteFile('$dir/compiles.log');
		if (probe == 0) return dir;
		CliFixture.removeDir(dir);
		Assert.pass('haxe unavailable — skipped');
		return null;
	}


	/** The facts compiles' probe directories under the scratch root, sorted. */
	private static function factsDirs(): Array<String> {
		final found: Array<String> = [
			for (entry in sys.FileSystem.readDirectory(TempScratch.root())) if (StringTools.startsWith(entry, 'anyparse-typed-facts-'))
				entry
		];
		found.sort(Reflect.compare);
		return found;
	}
	#end

}
