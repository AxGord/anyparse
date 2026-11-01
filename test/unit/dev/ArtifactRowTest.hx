package unit.dev;

import dev.ArtifactRow;
import devkit.TempDir;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/** `dev.ArtifactRow`: what the slice gate's artifacts row calls build output or too big, and what `--allow` lets through. */
@:nullSafety(Strict)
final class ArtifactRowTest extends Test {

	public function testBuildOutputsAndBigFilesAreProblems(): Void {
		Assert.notNull(ArtifactRow.problem('bin/apq.js', 10));
		Assert.notNull(ArtifactRow.problem('bin/apq.js.v8cache', 10));
		Assert.notNull(ArtifactRow.problem('out/x.txt', 10));
		Assert.notNull(ArtifactRow.problem('dist/x.txt', 10));
		Assert.notNull(ArtifactRow.problem('docs/big.md', ArtifactRow.MAX_BYTES + 1));
		Assert.notNull(ArtifactRow.problem('lib/x.js', 10));
		Assert.isNull(ArtifactRow.problem('bin/hxq', 10));
		Assert.isNull(ArtifactRow.problem('bin/apq-js.hxml', 10));
		Assert.isNull(ArtifactRow.problem('src/A.hx', ArtifactRow.MAX_BYTES));
	}

	public function testOversizeFilesFailOnlyWhenTheBranchAddsOrGrowsThem(): Void {
		final big: Int = ArtifactRow.MAX_BYTES + 500000;
		Assert.isNull(ArtifactRow.problem('a.json', big + 1000, big));
		Assert.isNull(ArtifactRow.problem('a.json', Std.int(big * 5 / 4), big));
		Assert.notNull(ArtifactRow.problem('a.json', Std.int(big * 5 / 4) + 1, big));
		Assert.notNull(ArtifactRow.problem('a.json', 2 * ArtifactRow.MAX_BYTES));
		Assert.notNull(ArtifactRow.problem('a.json', 1600000, 1200000));
		Assert.notNull(ArtifactRow.problem('a.json', ArtifactRow.MAX_BYTES + 1, ArtifactRow.MAX_BYTES));
		Assert.isNull(ArtifactRow.problem('a.json', 10, big));
	}

	public function testAnAllowedPathPassesAndAnotherFails(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('bin'));
			File.saveContent(dir.file('bin/apq.js'), 'x');
			File.saveContent(dir.file('A.hx'), 'class A {}');
			File.saveBytes(dir.file('big.bin'), Bytes.alloc(ArtifactRow.MAX_BYTES + 1));
			final files: Array<String> = ['bin/apq.js', 'A.hx', 'big.bin'];
			Assert.equals(2, ArtifactRow.offenders(dir.path, files, [], _ -> null).length);
			final left: Array<String> = ArtifactRow.offenders(dir.path, files, ['bin/apq.js'], _ -> null);
			Assert.equals(1, left.length);
			Assert.equals('big.bin: over 1 MB (${ArtifactRow.MAX_BYTES + 1} bytes), added', left[0]);
		});
	}

}
