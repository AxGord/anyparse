package unit.query;

import anyparse.query.Glob;

/** `Glob.covers`: whether a configured path pattern selects a file, directly or through a directory above it. */
@:nullSafety(Strict)
final class GlobCoversTest extends Test {

	/** A spec naming a file or a directory covers it and everything beneath, and nothing that merely shares a prefix. */
	@:pin('control')
	@:killer('M-GLOB-COVERS-DIRECTORY')
	public function testASpecCoversAFileAndEverythingBelowADirectory(): Void {
		Assert.isTrue(Glob.covers('src/a/B.hx', 'src/a/B.hx'));
		Assert.isTrue(Glob.covers('src/a', 'src/a/B.hx'));
		Assert.isTrue(Glob.covers('src/a/', 'src/a/sub/C.hx'));
		Assert.isFalse(Glob.covers('src/a', 'src/ab/B.hx'));
		Assert.isFalse(Glob.covers('src/a/B.hx', 'src/a/C.hx'));
	}

	/** A glob spec selects by pattern, at any depth `**` allows, and a directory it selects covers the files beneath. */
	@:pin('control')
	@:killer('M-GLOB-COVERS-DIRECTORY')
	public function testAGlobSpecSelectsByPattern(): Void {
		Assert.isTrue(Glob.covers('src/**/B.hx', 'src/a/b/B.hx'));
		Assert.isTrue(Glob.covers('src/*', 'src/a/B.hx'));
		Assert.isFalse(Glob.covers('src/*/B.hx', 'src/a/b/B.hx'));
		Assert.isFalse(Glob.covers('test/**', 'src/a/B.hx'));
	}

	/** A leading `./` is the same path, and an empty or `.` spec is the whole tree. */
	public function testTheCurrentDirectoryFormIsTheSamePath(): Void {
		Assert.isTrue(Glob.covers('./src', 'src/a/B.hx'));
		Assert.isTrue(Glob.covers('src', './src/a/B.hx'));
		Assert.isTrue(Glob.covers('.', 'src/a/B.hx'));
	}

}
