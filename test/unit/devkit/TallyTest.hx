package unit.devkit;

import devkit.Tally;
import devkit.TempDir;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `Tally` — a count kept as files in a directory, each claim an exclusive create, so a number is never handed out twice
 * and only the newest file stays.
 */
@:nullSafety(Strict)
final class TallyTest extends Test {

	public function testClaimsCountFromOneInADirectoryMadeOnDemand(): Void {
		TempDir.with(dir -> {
			final tally: String = Path.join([dir.path, 'nested', 'landings']);
			Assert.equals(1, Tally.next(tally));
			Assert.equals(2, Tally.next(tally));
			Assert.equals(3, Tally.next(tally));
		});
	}

	public function testOnlyTheNewestClaimStays(): Void {
		TempDir.with(dir -> {
			final tally: String = dir.file('tally');
			Assert.equals(1, Tally.next(tally));
			Assert.equals(2, Tally.next(tally));
			Assert.same(['2'], FileSystem.readDirectory(tally));
		});
	}

	public function testANumberAlreadyClaimedIsNeverHandedOutAgain(): Void {
		TempDir.with(dir -> {
			final tally: String = dir.file('tally');
			FileSystem.createDirectory(tally);
			File.saveContent(Path.join([tally, '7']), '');
			File.saveContent(Path.join([tally, 'notes.txt']), 'kept');
			Assert.equals(8, Tally.next(tally));
			Assert.same(['8', 'notes.txt'], FileSystem.readDirectory(tally));
		});
	}

	public function testRemovingAFileAnotherClaimantPrunedFirstIsNoError(): Void {
		TempDir.with(dir -> {
			final file: String = dir.file('3');
			File.saveContent(file, '');
			Tally.remove(file);
			Assert.isFalse(FileSystem.exists(file));
			Tally.remove(file);
			Assert.isFalse(FileSystem.exists(file));
		});
	}

}
