package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.cli.CliIo;
import anyparse.query.cli.WriteJournal;

/**
 * `WriteJournal`: what one run wrote through `CliIo`, recorded only inside `during`, and put back by `rollback` — a
 * rewritten file to its old text, a created file and the directories made for it removed, a deleted file restored —
 * and written again by `replay`.
 */
@:nullSafety(Strict)
class WriteJournalTest extends Test {

	/** `rwxr-xr-x`: a mode a staged write would not reproduce by default. */
	private static inline final EXECUTABLE: Int = 0x1ED;

	@:pin('control')
	@:killer('M-WRITE-JOURNAL-DIRS-KEPT')
	public function testRollbackPutsBackEveryWriteCreationAndDeletion(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('writejournal', [{ name: 'a.txt', source: 'a' }, { name: 'b.txt', source: 'b' }]);
		final journal: WriteJournal = new WriteJournal();
		WriteJournal.during(journal, () -> {
			CliIo.writeFile('$dir/a.txt', 'A');
			CliIo.writeFile('$dir/made/deep/c.txt', 'c');
			Assert.isTrue(CliIo.deletePath('$dir/b.txt'));
			return 0;
		});
		journal.rollback();
		Assert.equals('a', File.getContent('$dir/a.txt'), 'a rewritten file gets its old text');
		Assert.equals('b', File.getContent('$dir/b.txt'), 'a deleted file comes back');
		Assert.isFalse(FileSystem.exists('$dir/made/deep/c.txt'), 'a created file is removed');
		Assert.isFalse(FileSystem.exists('$dir/made'), 'and so are the directories made for it');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-JOURNAL-NO-RECORD')
	public function testOnlyTheWritesInsideDuringAreRecordedAndReplayWritesThemAgain(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('writejournal', [{ name: 'a.txt', source: 'a' }, { name: 'b.txt', source: 'b' }]);
		final journal: WriteJournal = new WriteJournal();
		CliIo.writeFile('$dir/b.txt', 'outside');
		WriteJournal.during(journal, () -> {
			CliIo.writeFile('$dir/a.txt', 'A');
			return 0;
		});
		Assert.equals(1, journal.changed().length, 'only the write made inside `during` is recorded');
		final written: Array<JournalState> = journal.current();
		journal.rollback();
		Assert.equals('a', File.getContent('$dir/a.txt'));
		Assert.equals('outside', File.getContent('$dir/b.txt'), 'a write outside `during` is not the run\'s to undo');
		journal.replay(written);
		Assert.equals('A', File.getContent('$dir/a.txt'), 'replay writes the run\'s text again');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-JOURNAL-SEAT-KEPT')
	public function testABodyThatThrowsPutsTheRecordingSeatBack(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('writejournal', [{ name: 'a.txt', source: 'a' }]);
		final journal: WriteJournal = new WriteJournal();
		final threw: Bool = try {
			WriteJournal.during(journal, function(): Int {
				throw new haxe.Exception('the run failed');
			});
			false;
		} catch (exception: haxe.Exception) true;
		Assert.isTrue(threw, 'the body\'s exception reaches the caller');
		CliIo.writeFile('$dir/a.txt', 'after the run');
		Assert.equals(0, journal.changed().length, 'a write after the run is not recorded in its journal');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-WRITE-JOURNAL-MODE-LOST')
	public function testARolledBackDeletionRestoresTheFilesMode(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('writejournal', [{ name: 'run.sh', source: 'echo run\n' }]);
		js.node.Fs.chmodSync('$dir/run.sh', EXECUTABLE);
		final journal: WriteJournal = new WriteJournal();
		Assert.isTrue(WriteJournal.during(journal, () -> CliIo.deletePath('$dir/run.sh')));
		journal.rollback();
		Assert.equals('echo run\n', File.getContent('$dir/run.sh'));
		Assert.equals(EXECUTABLE, FileSystem.stat('$dir/run.sh').mode & CliIo.PERMISSION_BITS, 'the deleted file comes back 0755');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('mode bits are restored on nodejs only');
		#end
	}

}
