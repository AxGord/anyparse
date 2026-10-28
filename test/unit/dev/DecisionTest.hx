package unit.dev;

import dev.Decision;
import devkit.Args.UsageError;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev decision`, the only writer of `docs/decisions.md`, over a scratch ledger, and the line shape `dev slice-gate` checks
 * on the lines a slice added to it.
 */
@:nullSafety(Strict)
final class DecisionTest extends Test {

	@:pin('control')
	@:killer('M-DECISION-APPEND-GLUED')
	public function testALedgerWithoutAFinalNewlineGetsOneFirst(): Void {
		TempDir.with(dir -> {
			final file: String = ledger(dir, 'head\n---\n- old → A-1');
			Decision.append(file, '- new → B-2');
			Assert.equals('head\n---\n- old → A-1\n- new → B-2\n', File.getContent(file));
		});
	}

	@:pin('control')
	@:killer('M-DECISION-APPEND-BLANK')
	public function testAppendsOneLineDirectlyAfterTheLast(): Void {
		TempDir.with(dir -> {
			final file: String = ledger(dir, 'head\n---\n- old → A-1\n');
			Decision.append(file, '- new → B-2');
			Assert.equals('head\n---\n- old → A-1\n- new → B-2\n', File.getContent(file));
		});
	}

	@:pin('control')
	@:killer('M-DECISION-NO-LENGTH-LIMIT')
	public function testRefusesATextOverTheLimit(): Void {
		final longest: String = [for (_ in 0...Decision.MAX_TEXT) 'x'].join('');
		Assert.isNull(Decision.problem(longest, 'S-1'));
		refused(['--slice', 'S-1', '${longest}y']);
		Assert.notNull(Decision.entryProblem('- ${longest}y → S-1'));
	}

	@:pin('control')
	@:killer('M-DECISION-MULTILINE')
	public function testRefusesAMultiLineText(): Void {
		refused(['--slice', 'S-1', 'tried x\n  → no']);
		refused(['--slice', 'S-1', 'tried x\r']);
	}

	@:pin('control')
	@:killer('M-DECISION-ANY-SLICE')
	public function testRefusesAnEmptyOrMalformedSlice(): Void {
		refused(['--slice', '', 'tried x → no']);
		refused(['--slice', 'abc1234', 'tried x → no']);
		refused(['tried x → no']);
		Assert.isNull(Decision.problem('tried x → no', 'FB-2b'));
	}

	public function testRefusesATextThatAlreadyNamesItsSlice(): Void {
		refused(['--slice', 'S-1', 'tried x → no → S-1']);
	}

	@:pin('control')
	@:killer('M-DECISION-GATE-NO-ARROW')
	public function testTheGateCatchesALineWithoutItsSlice(): Void {
		Assert.notNull(Decision.entryProblem('- tried x, no'));
		Assert.notNull(Decision.entryProblem('- tried x → `5adf8213c`'));
		Assert.notNull(Decision.entryProblem('  a wrapped continuation → S-1'));
		Assert.isNull(Decision.entryProblem('- tried x → no → S-1'));
	}

	@:pin('control')
	@:killer('M-DECISION-GATE-SEES-NOTHING')
	public function testTheGateTakesOnlyTheLinesASliceAddedBelowTheHeader(): Void {
		final base: String = 'head\n---\n\n- old → A-1\n';
		final now: String = 'head, reworded\n---\n\n- old → A-1\n\n## B-2\n\n- new → B-2\n';
		Assert.same(['- new → B-2'], Decision.addedLines(base, now));
		Assert.same([], Decision.addedLines(base, base));
	}

	/** `dev decision <args>` against a scratch tree must refuse and leave its ledger as it was. */
	private static function refused(args: Array<String>): Void {
		TempDir.with(dir -> {
			final file: String = ledger(dir, 'head\n---\n');
			Assert.raises(() -> Decision.main(args.concat(['--repo', dir.path])), UsageError);
			Assert.equals('head\n---\n', File.getContent(file));
		});
	}

	/** A scratch tree's ledger holding `text`. */
	private static function ledger(dir: TempDir, text: String): String {
		final file: String = Path.join([dir.path, Decision.LEDGER]);
		FileSystem.createDirectory(Path.directory(file));
		File.saveContent(file, text);
		return file;
	}

}
