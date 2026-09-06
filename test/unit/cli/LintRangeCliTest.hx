package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * End-to-end probe for `apq lint --range` and for the `--fix` it exists to serve on the
 * writer-emit ops.
 *
 * The window is what makes an automatic post-write fix safe to hand someone: without it
 * a `--fix` behind a one-line edit is a whole-file rewrite, and on a tree that is not
 * already a fixer fixed point that rewrites code the author never touched. So the
 * discriminating fixture here is not "did it fix what I wrote" — it is "did it leave the
 * finding that was already standing three lines away". That one is
 * `testWriteFixLeavesAStandingFindingOutsideTheWindow`, and it goes red the moment the
 * filter stops being applied.
 *
 * `testWriteWithoutFixChangesNothing` is its control: without it, a fixture whose
 * standing finding survives proves nothing, because a run that fixed NOTHING would pass
 * it too.
 */
class LintRangeCliTest extends Test {

	/** Two foldable concatenations, on lines 6 and 8 of the fixture below. */
	private static inline final FOLDABLE_A: String = "'aaa' + 'bbb'";

	private static inline final FOLDABLE_B: String = "'ccc' + 'ddd'";

	/** A window around a finding gates the run; a window beside it does not. */
	public function testRangeNarrowsTheReport(): Void {
		#if (sys || nodejs)
		final file: String = fixture();
		Assert.equals(1, lint(file, ['--range', '6:6']), 'the finding on line 6 is inside the window');
		Assert.equals(0, lint(file, ['--range', '7:7']), 'line 7 carries no finding, so the run has nothing to gate on');
		Assert.equals(1, lint(file, []), 'without a window both findings are reported');
		FileSystem.deleteFile(file);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The window narrows what gets REWRITTEN, not only what gets printed. */
	public function testRangeNarrowsTheFix(): Void {
		#if (sys || nodejs)
		final file: String = fixture();
		Assert.equals(0, Cli.run([
			'lint',
			file,
			'--no-oracle',
			'--fix',
			'--rule',
			'fold-adjacent-string-literals',
			'--range',
			'6:6'
		]), 'a scoped fix run is still a successful run');
		final after: String = File.getContent(file);
		Assert.isFalse(after.indexOf(FOLDABLE_A) >= 0, 'the finding inside the window was fixed');
		Assert.isTrue(after.indexOf(FOLDABLE_B) >= 0, 'the finding outside it was not');
		FileSystem.deleteFile(file);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A window is a claim about one file's lines, so a multi-file scope refuses it. */
	public function testRangeRefusesAMultiFileScope(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('lintrange', [
			{ name: 'A.hx', source: 'package pkg;\n\nclass A {}\n' },
			{ name: 'B.hx', source: 'package pkg;\n\nclass B {}\n' }
		]);
		Assert.equals(2, Cli.run(['lint', dir, '--no-oracle', '--range', '1:2']), 'two files cannot share one line window');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Both ends are required and ordered — a clamped window would narrow silently. */
	public function testMalformedRangeIsAUsageError(): Void {
		#if (sys || nodejs)
		final file: String = fixture();
		Assert.equals(2, Cli.run(['lint', file, '--no-oracle', '--range', '6']), 'a bare line number is not a window');
		Assert.equals(2, Cli.run(['lint', file, '--no-oracle', '--range', '8:6']), 'a reversed window is refused');
		Assert.equals(2, Cli.run(['lint', file, '--no-oracle', '--range', '0:3']), 'lines are 1-based');
		FileSystem.deleteFile(file);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** CONTROL for the two below: a write op without `--fix` rewrites nothing. */
	@:pin('control')
	@:killer('M-LINT-RANGE-INERT')
	public function testWriteWithoutFixChangesNothing(): Void {
		#if (sys || nodejs)
		final file: String = fixture();
		Assert.equals(0, patch(file, false), 'the patch itself lands');
		final after: String = File.getContent(file);
		Assert.isTrue(after.indexOf(FOLDABLE_A) >= 0, 'the standing finding is untouched');
		Assert.isTrue(after.indexOf("'eee' + 'fff'") >= 0, 'and so is the one the patch just introduced');
		FileSystem.deleteFile(file);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--fix` on the op folds the concatenation the patch itself introduced. */
	public function testWriteFixFoldsWhatTheOpIntroduced(): Void {
		#if (sys || nodejs)
		final file: String = fixture();
		Assert.equals(0, patch(file, true), 'the patch itself lands');
		Assert.isFalse(File.getContent(file).indexOf("'eee' + 'fff'") >= 0, 'the introduced finding was fixed');
		FileSystem.deleteFile(file);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** THE discriminating one: a finding outside the changed lines survives the fix. */
	@:pin('killer')
	@:killer('M-LINT-RANGE-INERT')
	public function testWriteFixLeavesAStandingFindingOutsideTheWindow(): Void {
		#if (sys || nodejs)
		final file: String = fixture();
		Assert.equals(0, patch(file, true), 'the patch itself lands');
		final after: String = File.getContent(file);
		Assert.isTrue(after.indexOf(FOLDABLE_A) >= 0, 'the standing finding above the edit is untouched');
		Assert.isTrue(after.indexOf(FOLDABLE_B) >= 0, 'and so is the one below it');
		FileSystem.deleteFile(file);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The dispatcher strips `--fix` only for a command that declares `PostWriteFix`, so
	 * `lint`'s own `--fix` — a different thing entirely — must still reach it.
	 */
	public function testLintKeepsItsOwnFixFlag(): Void {
		#if (sys || nodejs)
		final file: String = fixture();
		Assert.equals(
			0, Cli.run(['lint', file, '--no-oracle', '--fix', '--rule', 'fold-adjacent-string-literals']),
			'lint --fix reached lint, not the dispatcher'
		);
		final after: String = File.getContent(file);
		Assert.isFalse(after.indexOf(FOLDABLE_A) >= 0, 'lint --fix still fixes');
		Assert.isFalse(after.indexOf(FOLDABLE_B) >= 0, 'over the whole file, since no window was given');
		FileSystem.deleteFile(file);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * A canonical fixture with a foldable concatenation on line 6 and another on line 8.
	 *
	 * Canonicalised through `fmt --write` before it is handed to anything, because
	 * `--fix` is canonical-in / canonical-out: it SKIPS a file it would have to reformat
	 * first, and a skipped file reads exactly like a fixer that declined the shape.
	 */
	private static function fixture(): String {
		final path: String = CliFixture.write(
			'lintrange',
			'package pkg;\n\nclass C {\n\n\tpublic static function main(): Void {\n\t\tfinal a: String = $FOLDABLE_A;\n\t\ttrace(a);\n'
			+ '\t\tfinal b: String = $FOLDABLE_B;\n\t\ttrace(b);\n\t}\n\n}\n'
		);
		Assert.equals(0, Cli.run(['fmt', path, '--write']), 'the fixture canonicalises');
		return path;
	}

	/** Report-only lint over one file, gated on Info so the exit code carries the answer. */
	private static function lint(file: String, extra: Array<String>): Int {
		return Cli.run([
			'lint',
			file,
			'--no-oracle',
			'--rule',
			'fold-adjacent-string-literals',
			'--fail-on',
			'info'
		].concat(extra));
	}

	/** Insert a third foldable concatenation after `trace(a);`, with or without `--fix`. */
	private static function patch(file: String, fix: Bool): Int {
		final payload: String = CliFixture.writeAs(
			'lintrangepayload', 'txt', "trace(a);\n====\ntrace(a);\nfinal c: String = 'eee' + 'fff';\ntrace(c);\n"
		);
		final args: Array<String> = ['patch', file, '--select', 'FnMember:main', '--from-file', payload, '--write'];
		if (fix) args.push('--fix');
		final code: Int = Cli.run(args);
		FileSystem.deleteFile(payload);
		return code;
	}
	#end

}
