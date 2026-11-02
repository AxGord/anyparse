package unit.dev;

import dev.LandProse;
import devkit.Cmd.cmd;
import devkit.Summary;
import devkit.Summary.Outcome;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `prose-refs` row of `dev land` over a scratch repository: the prose that names a path the head commit deleted or
 * renamed is listed as `file:line`, and what the commit left alone, the records of the past and a name only part of a longer
 * one are not.
 */
@:nullSafety(Strict)
final class LandProseTest extends Test {

	public function testAPathTheCommitTookOutIsListedWhereProseNamesIt(): Void {
		final run: Reading = reading(true);
		Assert.isTrue(run.note.contains('CLAUDE.md:1 test/testkit/mutation-arms.json'), run.note);
		Assert.isTrue(run.note.contains('docs/guide.md:1 mutation-arms.json'), run.note);
		Assert.isTrue(run.note.contains('.claude/workflows/p.md:2 A.hx'), run.note);
		Assert.isTrue(run.note.contains('/skills/s/SKILL.md:1 src/old/B.hx'), run.note);
		Assert.isTrue(run.logged.contains('docs/guide.md:1 mutation-arms.json'), run.logged);
	}

	public function testADirectoryWhoseFilesAllWentIsNamedAndOneThatKeepsAFileIsNot(): Void {
		final run: Reading = reading(true);
		Assert.isTrue(run.note.contains('docs/guide.md:2 src/old'), run.note);
		Assert.isFalse(run.note.contains('docs/guide.md:3'), run.note);
	}

	public function testTheRecordsOfThePastAreNotSearched(): Void {
		final run: Reading = reading(true);
		Assert.isFalse(run.note.contains('journal'), run.note);
		Assert.isFalse(run.note.contains('decisions'), run.note);
		Assert.isFalse(run.note.contains('archive'), run.note);
	}

	public function testARenameNobodyNamesAndABasenameASurvivorSharesAreNotListed(): Void {
		final run: Reading = reading(true);
		Assert.isFalse(run.note.contains('Z.hx'), run.note);
		Assert.isFalse(run.note.contains('docs/guide.md:4'), run.note);
		Assert.isFalse(run.note.contains('docs/guide.md:5'), run.note);
	}

	public function testACommitWhoseCasualtiesNoProseNamesSaysNone(): Void {
		Assert.equals('none', reading(false).note);
	}

	public function testAMissingProseDirectoryIsSkipped(): Void {
		final run: Reading = reading(true, false);
		Assert.isTrue(run.note.contains('CLAUDE.md:1'), run.note);
		Assert.isFalse(run.note.contains('docs/'), run.note);
		Assert.isTrue(run.passed);
	}

	public function testTheRowNamesFewHitsAndCountsTheRest(): Void {
		final hits: Array<String> = [for (index in 1...9) 'f:$index x'];
		Assert.equals('8 hit(s): f:1 x; f:2 x; f:3 x; f:4 x; f:5 x; f:6 x; and 2 more', LandProse.reading(hits));
	}

	public function testOnlyADeletedFileAndTheOldSideOfARenameVanish(): Void {
		final gone: Vanished = LandProse.vanished(['D\ta/b.hx', 'R100\tc/d.hx\te/d.hx', 'M\tf.hx', 'A\tg.hx'], ['e/d.hx', 'f.hx', 'g.hx']);
		Assert.same(['a/b.hx', 'c/d.hx'], gone.files);
		Assert.same(['a', 'c'], gone.dirs);
	}

	public function testOnlyTheTopmostOfAnEmptiedNestIsNamed(): Void {
		final gone: Vanished = LandProse.vanished(['D\ta/b/x.hx', 'D\ta/y.hx', 'D\tk/z.hx'], ['k/w.hx']);
		Assert.same(['a'], gone.dirs);
	}

	public function testABasenameIsNamedOnlyWhenNoSurvivorSharesIt(): Void {
		final gone: Vanished = { files: ['a/Only.hx', 'a/Shared.hx'], dirs: [] };
		Assert.same(['a/Only.hx', 'a/Shared.hx', 'Only.hx'], LandProse.needles(gone, ['b/Shared.hx']));
	}

	public function testANamePartOfALongerOneIsNotAMention(): Void {
		final text: String = 'xA.hx\nA.hx.\nsrc/A.hx and A.hx\nA.hxx\nmy-A.hx\nkeep A.hx.bak\nend A.hx.';
		Assert.same(['f:2 A.hx', 'f:3 A.hx', 'f:7 A.hx'], LandProse.scan('f', text, ['A.hx']));
		Assert.same([], LandProse.scan('f', 'see docs/guide.md', ['docs/guide']));
	}

	public function testALongerNameHidesTheShorterOneItContains(): Void {
		Assert.same(['f:1 src/A.hx'], LandProse.scan('f', 'see src/A.hx', ['src/A.hx', 'A.hx']));
	}

	public function testMoreHitsThanTheRowNamesAreAllInTheLog(): Void {
		final run: Reading = reading(true, true, { many: true });
		Assert.isTrue(run.note.contains('13 hit(s)'), run.note);
		Assert.isTrue(run.note.contains('and 7 more'), run.note);
		Assert.equals(13, run.logged.trim().split('\n').length);
	}

	public function testAStepThatThrowsIsANoteAndNeverAFailure(): Void {
		final run: Reading = reading(true, true, { nowhere: true });
		Assert.isTrue(run.passed);
		Assert.isTrue(run.note.startsWith('not read:'), run.note);
	}

	public function testARepositoryWithoutAParentCommitIsSkipped(): Void {
		final outcome: Outcome = TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			cmd('git -C $repo init -q -b main').run().check();
			File.saveContent('$repo/a.txt', 'a\n');
			commit(repo, 'only');
			final summary: Summary = new Summary();
			summary.time('prose-refs', new LandProse(repo, null, dir.file('log.txt'), summary).run);
		});
		Assert.isTrue(outcome.match(Skipped(_)));
	}

	/**
	 * A repository whose second commit renames the registry, removes `src/old` and `src/a/Util.hx` and renames `Z.hx`, with prose
	 * naming some of it; `named` false leaves out the prose that names a casualty, `docs` false the whole `docs/`.
	 */
	private static function reading(named: Bool, docs: Bool = true, ?odd: Odd): Reading {
		return TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			final skills: String = dir.file('skills');
			final log: String = dir.file(odd?.nowhere == true ? 'nowhere/prose-refs.txt' : 'prose-refs.txt');
			FileSystem.createDirectory(repo);
			cmd('git -C $repo init -q -b main').run().check();
			final hit: String = named ? 'mutation-arms.json' : 'nothing';
			final files: Map<String, String> = [
				'test/testkit/mutation-arms.json' => '{"arms":1}\n',
				'src/old/A.hx' => 'a\n',
				'src/old/B.hx' => 'b\n',
				'src/keep/C.hx' => 'c\n',
				'src/keep/Z.hx' => 'zzz zzz zzz\n',
				'src/a/Util.hx' => 'u1\n',
				'src/b/Util.hx' => 'u2\n',
				'CLAUDE.md' => named ? 'the registry test/testkit/mutation-arms.json\n' : 'nothing\n',
				'.claude/workflows/p.md' => 'x\nuses ${named ? 'A.hx' : 'none'}\n',
				'skills/s/SKILL.md' => named ? 'reads src/old/B.hx\n' : 'nothing\n'
			];
			if (docs) {
				files['docs/guide.md'] = '$hit here\n${named ? 'the dir src/old/ holds' : 'no'} it\nsrc/keep/ stays\n'
					+ 'Util.hx is shared\nonly Z.hxx here\n';
				files['docs/journal/log.md'] = 'mutation-arms.json\n';
				files['docs/decisions.md'] = 'mutation-arms.json\n';
				if (odd?.many == true) files['docs/many.md'] = [for (_ in 0...8) 'mutation-arms.json'].join('\n') + '\n';
				files['docs/archive/old.md'] = 'mutation-arms.json\n';
			}
			for (path => text in files) {
				final target: String = Path.join([path.startsWith('skills/') ? dir.path : repo, path]);
				FileSystem.createDirectory(Path.directory(target));
				File.saveContent(target, text);
			}
			commit(repo, 'base');
			cmd('git -C $repo mv test/testkit/mutation-arms.json test/testkit/arms.json').run().check();
			cmd('git -C $repo rm -q -r src/old src/a').run().check();
			cmd('git -C $repo mv src/keep/Z.hx src/keep/Y.hx').run().check();
			commit(repo, 'move');
			final summary: Summary = new Summary();
			final outcome: Outcome = summary.time('prose-refs', new LandProse(repo, skills, log, summary).run);
			{
				note: summary.steps()[0].note,
				passed: outcome.match(Passed),
				logged: FileSystem.exists(log) ? File.getContent(log) : ''
			};
		});
	}

	private static function commit(repo: String, message: String): Void {
		cmd('git -C $repo add -A').run().check();
		cmd('git -C $repo -c user.name=t -c user.email=t@t commit -q -m $message').run().check();
	}

}

/** What the row said about a scratch repository: its reading, whether it passed, and the log of every hit. */
private typedef Reading = {
	var note: String;
	var passed: Bool;
	var logged: String;
}

/** The oddities a scratch repository can be given: a log that cannot be written, more prose than the row names. */
private typedef Odd = {
	@:optional var nowhere: Bool;
	@:optional var many: Bool;
}
