package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import haxe.crypto.Md5;

using StringTools;

/**
 * `apq move-elements` end to end: `--dry-run` prints the moved entries and their digest and writes nothing; `--write`
 * changes both modules together.
 */
class MoveElementsCliTest extends Test {

	private static final A: String = "class A {\n\tpublic static final XS:Array<String> = ['a', 'b', 'c'];\n}\n";
	private static final B: String = "class B {\n\tpublic static final YS:Array<String> = ['z'];\n}\n";

	/** The dry run lists the entries with their indices and the digest, and leaves both files as they were. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-DRY-RUN-UNROUTED')
	public function testTheDryRunPrintsTheDigestAndWritesNothing(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('moveelements', [{ name: 'A.hx', source: A }, { name: 'B.hx', source: B }]);
		var rc: Int = -1;
		final printed: String = CliFixture.captureStdout(() -> rc = Cli.run([
			'move-elements',
			'$dir/A.hx',
			'--select',
			'FinalMember:XS',
			'--range',
			'2..3',
			'--into',
			'$dir/B.hx',
			'--append',
			'FinalMember:YS',
			'--dry-run'
		]));
		Assert.equals(0, rc, 'the dry run succeeds');
		#if nodejs
		Assert.isTrue(printed.contains("2\t'b'\n3\t'c'\n"), 'the entries, indexed: $printed');
		final digest: String = Md5.encode("'b'\n'c'");
		Assert.isTrue(printed.contains('digest $digest'), 'and the digest');
		#end
		Assert.equals(A, File.getContent('$dir/A.hx'), 'the source is untouched');
		Assert.equals(B, File.getContent('$dir/B.hx'), 'the destination is untouched');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--write` moves the slice: both files change together. */
	public function testTheWriteMovesTheSlice(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('moveelements', [{ name: 'A.hx', source: A }, { name: 'B.hx', source: B }]);
		final rc: Int = Cli.run([
			'move-elements',
			'$dir/A.hx',
			'--select',
			'FinalMember:XS',
			'--range',
			'1',
			'--into',
			'$dir/B.hx',
			'--sorted',
			'FinalMember:YS',
			'--write'
		]);
		Assert.equals(0, rc, 'the move succeeds');
		Assert.equals("class A {\n\tpublic static final XS:Array<String> = ['b', 'c'];\n}\n", File.getContent('$dir/A.hx'));
		Assert.equals("class B {\n\tpublic static final YS:Array<String> = ['a', 'z'];\n}\n", File.getContent('$dir/B.hx'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--into` naming the source through a symlink is the same module: one in-place edit, not a two-file write of one file. */
	@:pin('control')
	@:killer('M-MOVE-ELEMENTS-INTO-BY-SPELLING')
	public function testASymlinkedIntoIsTheSameModule(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('moveelements', [
			{
				name: 'A.hx',
				source: "class A {\n\tpublic static final XS:Array<String> = ['a', 'b'];\n\tpublic static final ZS:Array<String> = ['z'];\n"
				+ '}\n'
			}
		]);
		js.node.Fs.symlinkSync('$dir/A.hx', '$dir/L.hx');
		final rc: Int = Cli.run([
			'move-elements',
			'$dir/A.hx',
			'--select',
			'FinalMember:XS',
			'--range',
			'1',
			'--into',
			'$dir/L.hx',
			'--append',
			'FinalMember:ZS',
			'--write'
		]);
		Assert.equals(0, rc, 'the move succeeds');
		Assert.equals(
			"class A {\n\tpublic static final XS:Array<String> = ['b'];\n\tpublic static final ZS:Array<String> = ['z', 'a'];\n}\n",
			File.getContent('$dir/A.hx'), 'one edit holds both halves'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('needs a symlink');
		#end
	}

}
