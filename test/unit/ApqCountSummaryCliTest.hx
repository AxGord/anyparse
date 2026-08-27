package unit;

import anyparse.check.Check.Violation;
import anyparse.check.Naming;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;

using StringTools;
#end

/**
 * The run-summary COUNT lines, pinned against the tree they describe.
 *
 * Three recorded defects of one shape: a summary whose WORDING promises one
 * quantity and whose VALUE is a different one. `fmt --write` was reported
 * saying `formatted 0 file(s), 3 failed` while 24 files were rewritten, and
 * once saying 5 where 4 differed; `lint --fix` said `fixed 4 issue(s)` for
 * three findings. Each cost a real measurement arm, because the line is the
 * only thing a reader has in the middle of a long run.
 *
 * Every `fmt` assertion here compares the line against the BYTES — a snapshot
 * of the fixture directory taken before the run and re-read after it — never
 * against `fmt --list`, which answers about the tree the run has already
 * rewritten. And every direction is covered on purpose: a count pinned only
 * where some file changed passes just as happily when it over-reports, when it
 * under-reports to zero, and when a file could not be written at all.
 */
@:access(anyparse.query.Cli)
@:nullSafety(Strict)
final class ApqCountSummaryCliTest extends Test {

	/**
	 * ONE `naming` finding whose fix rewrites FOUR spans: the declaration and its
	 * three reads. Nothing cascades here — no edit of it exposes a second finding —
	 * so it separates "the count is edits" from the fold cascade the defect was
	 * first blamed on.
	 */
	private static final ONE_FINDING_FOUR_EDITS: String = 'class Probe {\n\n\tpublic static function main() {\n'
		+ '\t\tvar BadName = 1;\n\t\ttrace(BadName);\n\t\ttrace(BadName + 1);\n\t\ttrace(BadName + 2);\n\t}\n\n}\n';

	#if (sys || nodejs)
	/** Parses, and the writer rewrites it in ONE pass — ordinary drift, not a writer defect. */
	private static final DRIFTED: String = 'class A{function f(){g();}}\n';

	/** Already the writer's own output under compiled defaults: the run must count it as neither. */
	private static final CANONICAL: String = 'class A {}\n';

	/** Refused at the parse gate — `failed`, and never a rewrite. */
	private static final UNPARSEABLE: String = 'class {\n';
	#end

	/**
	 * The over- and under-report directions at once: the reported count must equal
	 * the number of files whose bytes moved, measured independently of the run.
	 */
	public function testWriteCountsExactlyTheFilesItRewrote(): Void {
		#if (sys || nodejs)
		final dir: String = fixtureDir('apq_count_write', 3, 2, 0);
		final before: Map<String, String> = snapshot(dir);
		final run: FmtRunResult = Cli.fmtRun([dir, '--write']);
		Assert.equals(0, run.exit);
		Assert.equals('apq fmt: rewrote 3 of 5 file(s)\n', run.summary);
		Assert.equals(3, changedSince(dir, before), 'the line must name the files whose bytes actually moved');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The T163 shape. A run that rewrote nothing must still say how many files it
	 * CONSIDERED — `formatted 0 file(s)` alone is what read as "the run was inert"
	 * on a tree of 870, and nothing on the line could tell that reading apart from
	 * the true one.
	 */
	public function testWriteOnACanonicalTreeStillNamesItsDenominator(): Void {
		#if (sys || nodejs)
		final dir: String = fixtureDir('apq_count_write_clean', 0, 4, 0);
		final before: Map<String, String> = snapshot(dir);
		final run: FmtRunResult = Cli.fmtRun([dir, '--write']);
		Assert.equals(0, run.exit);
		Assert.equals('apq fmt: rewrote 0 of 4 file(s)\n', run.summary);
		Assert.equals(0, changedSince(dir, before), 'a canonical tree must be left alone');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A file the run could not answer for is counted apart from the ones it rewrote. */
	public function testWriteCountsFailuresApartFromRewrites(): Void {
		#if (sys || nodejs)
		final dir: String = fixtureDir('apq_count_write_fail', 2, 0, 1);
		final before: Map<String, String> = snapshot(dir);
		final run: FmtRunResult = Cli.fmtRun([dir, '--write']);
		Assert.notEquals(0, run.exit);
		Assert.equals('apq fmt: rewrote 2 of 3 file(s), 1 failed\n', run.summary);
		Assert.equals(2, changedSince(dir, before), 'the unparseable file is not a rewrite');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A write that THROWS used to take the whole run down: an uncaught host error,
	 * no summary line at all, and the files already rewritten left with nothing
	 * said about them — the extreme of this family, since the count never reaches
	 * the reader. The read side was caught from the start; the write side was not.
	 */
	public function testUnwritableFileIsAFailureAndTheRunStillReports(): Void {
		#if (sys || nodejs)
		final dir: String = fixtureDir('apq_count_write_ro', 2, 0, 0);
		final locked: String = '$dir/D1.hx';
		Sys.command('chmod', ['444', locked]);
		if (Sys.command('test', ['-w', locked]) == 0) {
			CliFixture.removeDir(dir);
			Assert.pass('chmod 444 is not a write barrier here (running as root?) — skipped');
			return;
		}
		final before: Map<String, String> = snapshot(dir);
		final run: FmtRunResult = Cli.fmtRun([dir, '--write']);
		Sys.command('chmod', ['644', locked]);
		Assert.notEquals(0, run.exit);
		Assert.equals('apq fmt: rewrote 1 of 2 file(s), 1 failed\n', run.summary);
		Assert.equals(1, changedSince(dir, before), 'the file that could not be written is not a rewrite');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--list` used to say NOTHING unless a file failed, so a run that scanned a
	 * whole project and a run that matched three files were the same silence — and
	 * its drift count was reported nowhere at all.
	 */
	public function testListNamesBothItsDriftCountAndItsDenominator(): Void {
		#if (sys || nodejs)
		final dir: String = fixtureDir('apq_count_list', 2, 2, 0);
		final before: Map<String, String> = snapshot(dir);
		final run: FmtRunResult = Cli.fmtRun([dir, '--list']);
		Assert.equals(0, run.exit);
		Assert.equals('apq fmt --list: 2 of 4 file(s) would be rewritten\n', run.summary);
		Assert.equals(0, changedSince(dir, before), '--list must not write');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The number is EDIT SPANS and the line has to say so. One assertion over the
	 * whole sentence, because asserting the number alone passes for a line that
	 * still calls it `issue(s)` — which is the defect.
	 */
	public function testLintFixSummaryNamesItsNumberEdits(): Void {
		Assert.equals('apq lint --fix: 4 edit(s) in 1 file(s) over 2 pass(es)', Cli.lintFixSummary(4, 1, 2));
	}

	/**
	 * Why that line must not call its number findings: a check answers with one
	 * edit span per site it rewrites, so ONE finding here is FOUR spans — and
	 * `--fix` sums exactly those spans. The recorded diagnosis blamed a cascading
	 * fold; this fixture cascades nowhere and still reads four.
	 */
	public function testOneFindingCostsFourEditSpans(): Void {
		final files: Array<{ file: String, source: String }> = [{ file: 'Probe.hx', source: ONE_FINDING_FOUR_EDITS }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final check: Naming = new Naming();
		final found: Array<Violation> = check.run(files, plugin);
		Assert.equals(1, found.length, 'the fixture must carry exactly ONE finding');
		final edits: Array<{ span: Span, text: String }> = check.fix(ONE_FINDING_FOUR_EDITS, found, plugin, index);
		Assert.equals(4, edits.length, 'one finding, four edit spans — the declaration and its three reads');
	}

	#if (sys || nodejs)
	/** A temp directory holding `drifted` + `canonical` + `unparseable` `.hx` files. */
	private static function fixtureDir(prefix: String, drifted: Int, canonical: Int, unparseable: Int): String {
		final files: Array<{ name: String, source: String }> = [for (i in 0...drifted) { name: 'D$i.hx', source: DRIFTED }];
		for (i in 0...canonical) files.push({ name: 'C$i.hx', source: CANONICAL });
		for (i in 0...unparseable) files.push({ name: 'U$i.hx', source: UNPARSEABLE });
		return CliFixture.writeDir(prefix, files);
	}

	/** Every `.hx` directly under `dir`, by name — the ground truth a count line is checked against. */
	private static function snapshot(dir: String): Map<String, String> {
		final out: Map<String, String> = [];
		for (entry in FileSystem.readDirectory(dir)) if (entry.endsWith('.hx')) out[entry] = File.getContent('$dir/$entry');
		return out;
	}

	/** How many of `before`'s files hold different bytes now. */
	private static function changedSince(dir: String, before: Map<String, String>): Int {
		var moved: Int = 0;
		for (name => bytes in before) if (File.getContent('$dir/$name') != bytes) moved++;
		return moved;
	}
	#end

}
