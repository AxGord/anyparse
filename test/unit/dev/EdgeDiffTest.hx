package unit.dev;

import dev.EdgeDiff;
import utest.Assert;
import utest.Test;

/**
 * `dev edge-diff` takes a library file for the library side only when no project file is the same file: identity, never a
 * bare `fullPath`, which is null for a path that is not there and would merge every such path into one key.
 */
@:nullSafety(Strict)
final class EdgeDiffTest extends Test {

	/** A library path that does not exist stays library when the project holds a different missing path. */
	@:pin('control') @:killer('M-EDGEDIFF-LIBRARY-BARE-FULLPATH')
	public function testADifferentMissingPathIsNotTakenForAProjectFile(): Void {
		final project: Array<{ file: String, source: String }> = [{ file: '/private/tmp/apq-no-such-dir/Held.hx', source: '' }];
		final libs: Array<{ file: String, source: String }> = [
			{ file: '/private/tmp/apq-no-such-dir/Other.hx', source: '' },
			{ file: '/private/tmp/apq-no-such-dir/Held.hx', source: '' },
			{ file: '/private/tmp/apq-no-such-dir/sub/../Held.hx', source: '' }
		];
		Assert.same(['/private/tmp/apq-no-such-dir/Other.hx'], [for (f in EdgeDiff.libraryOnly(project, libs)) f.file]);
	}

}
