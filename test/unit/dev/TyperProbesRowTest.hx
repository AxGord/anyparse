package unit.dev;

import dev.TyperProbesRow;
import devkit.Summary.Outcome;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/** `dev.TyperProbesRow`: the one row the slice gate and the battery share for the typer's probe projects. */
@:nullSafety(Strict)
final class TyperProbesRowTest extends Test {

	@:pin('control')
	@:killer('M-TYPERROW-SHOWS-TAIL')
	public function testAFailedRunShowsTheDifferentProbesNotTheTail(): Void {
		final shown: Array<String> = [];
		final outcome: Outcome = ran(1, 'DIFFERENT a.hx:1\n' + [for (i in 0...30) 'noise $i'].join('\n'), shown);
		Assert.isTrue(outcome.match(Failed(_)), '$outcome');
		Assert.same(['DIFFERENT a.hx:1'], shown.join('\n').split('\n'));
	}

	public function testAFailureNamingNoProbeShowsTheTailOfTheRun(): Void {
		final shown: Array<String> = [];
		final outcome: Outcome = ran(1, [for (i in 0...30) 'line $i'].join('\n'), shown);
		Assert.isTrue(outcome.match(Failed(_)), '$outcome');
		Assert.stringContains('line 29', shown.join('\n'));
		Assert.isFalse(shown.join('\n').contains('line 3\n'), 'only the tail');
	}

	public function testAPassingRunShowsNothing(): Void {
		final shown: Array<String> = [];
		Assert.isTrue(ran(0, 'DIFFERENT would not matter', shown).match(Passed));
		Assert.same([], shown);
	}

	/** The probes can only move when the engine, the probe corpus or the harness moved. */
	@:pin('control')
	@:killer('M-TYPERROW-REACHED-ENGINE-BLIND')
	public function testTheRowIsReachedByTheEngineAProbeOrTheHarness(): Void {
		Assert.isTrue(TyperProbesRow.reached(['docs/a.md', 'src/anyparse/query/TypingService.hx']));
		Assert.isTrue(TyperProbesRow.reached(['apq.json']));
		Assert.isTrue(TyperProbesRow.reached(['tools/typer-facts/guards/Main.hx']));
		Assert.isTrue(TyperProbesRow.reached(['tools/src/dev/TyperConformance.hx']));
		Assert.isFalse(TyperProbesRow.reached([
			'test/unit/dev/A.hx',
			'tools/src/dev/Battery.hx',
			'docs/a.md',
			'tools/typer-factsx/a'
		]));
		Assert.isFalse(TyperProbesRow.reached([]));
	}

	/** `probes` run in a tree whose `bin/dev.js` exits `code` after printing `text`; what `show` got is added to `shown`. */
	private static function ran(code: Int, text: String, shown: Array<String>): Outcome {
		return TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('bin'));
			File.saveContent(dir.file('bin/out.txt'), text);
			File.saveContent(
				dir.file('bin/dev.js'),
				'process.stdout.write(require("fs").readFileSync(__dirname + "/out.txt", "utf8")); process.exit($code);'
			);
			return TyperProbesRow.outcome(dir.file(''), shown.push);
		});
	}

}
