package unit.query;

import anyparse.query.FileIdentity;
import haxe.io.Path;
import unit.cli.CliFixture;

/**
 * `FileIdentity.realPath`: one identity per file, whichever spelling names it — through a symlinked directory, for a
 * file that does not exist yet, relative or absolute — and never a null or empty key.
 */
@:nullSafety(Strict)
class FileIdentityTest extends Test {

	/**
	 * A file named through a symlinked directory keys like the same file named through its target, and a relative
	 * spelling like its absolute one.
	 */
	@:pin('control') @:killer('M-FILE-IDENTITY-SYMLINK')
	public function testTwoSpellingsOfOneFileAreOneIdentity(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('fileidentity', [{ name: 'real/A.hx', source: 'class A {}\n' }]);
		js.node.Fs.symlinkSync('$dir/real', '$dir/link');
		final viaTarget: String = FileIdentity.realPath('$dir/real/A.hx');
		Assert.equals(viaTarget, FileIdentity.realPath('$dir/link/A.hx'), 'through the link');
		Assert.equals(viaTarget, FileIdentity.realPath('$dir/link/./x/../A.hx/'), 'an unnormalised spelling');
		final cwd: String = Sys.getCwd();
		Sys.setCwd('$dir/link');
		final relative: String = FileIdentity.realPath('A.hx');
		Sys.setCwd(cwd);
		Assert.equals(viaTarget, relative, 'a relative spelling');
		js.node.Fs.unlinkSync('$dir/link');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('symlinks need the node target');
		#end
	}

	/** A file that does not exist yet resolves its nearest existing ancestor, so it keys like the file it will become. */
	@:pin('control') @:killer('M-FILE-IDENTITY-ANCESTOR')
	public function testAMissingFileKeysThroughItsNearestExistingAncestor(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('fileidentitymissing', [{ name: 'real/A.hx', source: 'class A {}\n' }]);
		js.node.Fs.symlinkSync('$dir/real', '$dir/link');
		Assert.equals(FileIdentity.realPath('$dir/real/sub/B.hx'), FileIdentity.realPath('$dir/link/sub/B.hx'));
		js.node.Fs.unlinkSync('$dir/link');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('symlinks need the node target');
		#end
	}

	/**
	 * Never null, empty or the string "null": `fullPath` is declared non-null and on hxnodejs returns null for a path that
	 * is not there, and every caller uses the answer as a map key, where one such null would merge every unresolvable file.
	 */
	@:pin('guard')
	public function testAPathThatIsNotThereStillHasAnAbsoluteIdentity(): Void {
		#if (sys || nodejs)
		final missing: String = FileIdentity.realPath('/private/tmp/apq-no-such-dir/NoSuchFile.hx');
		Assert.notEquals('', missing);
		Assert.notEquals('null', missing);
		Assert.isTrue(Path.isAbsolute(missing), missing);
		Assert.isTrue(Path.isAbsolute(FileIdentity.realPath('.')));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * On a case-insensitive volume two case spellings of one file stay two identities: the caller's casing is kept, so a
	 * case variant is refused as a second file rather than merged by a guess.
	 */
	@:pin('guard')
	public function testACaseVariantSpellingIsNotFoldedOntoTheFile(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('fileidentitycase', [{ name: 'Case/A.hx', source: 'class A {}\n' }]);
		if (sys.FileSystem.exists('$dir/case/A.hx'))
			Assert.notEquals(FileIdentity.realPath('$dir/Case/A.hx'), FileIdentity.realPath('$dir/case/A.hx'));
		else
			Assert.pass('a case-sensitive volume has no second spelling');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('needs the node target');
		#end
	}

}
