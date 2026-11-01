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

	public function testAnAllowedPathPassesAndAnotherFails(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('bin'));
			File.saveContent(dir.file('bin/apq.js'), 'x');
			File.saveContent(dir.file('A.hx'), 'class A {}');
			File.saveBytes(dir.file('big.bin'), Bytes.alloc(ArtifactRow.MAX_BYTES + 1));
			final files: Array<String> = ['bin/apq.js', 'A.hx', 'big.bin'];
			Assert.equals(2, ArtifactRow.offenders(dir.path, files, []).length);
			final left: Array<String> = ArtifactRow.offenders(dir.path, files, ['bin/apq.js']);
			Assert.equals(1, left.length);
			Assert.equals('big.bin: over 1 MB (${ArtifactRow.MAX_BYTES + 1} bytes)', left[0]);
		});
	}

}
