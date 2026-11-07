package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;
import anyparse.query.cli.CliIo;
import anyparse.query.cli.ReadOnlyScope;
import anyparse.query.cli.UsageFailure;
import unit.cli.CliFixture.CliRun;

/**
 * `APQ_READ_ONLY`: the one check on the CLI's single write route (`CliIo.writeFiles` /
 * `deletePath`) that turns every write INTO THE PROTECTED TREE into a refusal with the usage status
 * and nothing written, while a command that only reads — a preview without `--write` — and a write
 * to a scratch directory outside the tree (a harness's own fixtures) are served as before.
 */
class ApqReadOnlyCliTest extends Test {

	#if (sys || nodejs)
	private static final FIXTURE: String = 'class C {\n\tfunction f():Int {\n\t\ttrace(g(1));\n\t\treturn 2;\n\t}\n}\n';
	private static final UNFORMATTED: String = 'class C { var x:Int = 1; }\n';
	private static final LINT_FIXTURE: String = 'package;\n\nimport haxe.io.Path;\n\nclass E {\n\tpublic function new() {}\n}\n';
	private static final REMOVE_CALL: Array<String> = ['--match', 'g($$a)', '--kind', 'ExprStmt', '--write'];
	#end

	@:pin('control')
	@:killer('M-READ-ONLY-NEVER')
	public function testAWriteOpInsideTheTreeIsRefusedAndWritesNothing(): Void {
		#if (sys || nodejs)
		final tree: String = CliFixture.writeDir('ro_patch', [{ name: 'C.hx', source: FIXTURE }]);
		final run: CliRun = refused(tree, ['remove-element', '$tree/C.hx'].concat(REMOVE_CALL));
		Assert.equals(2, run.code);
		Assert.stringContains('read-only', run.out);
		Assert.equals(FIXTURE, File.getContent('$tree/C.hx'));
		Assert.equals('C.hx', FileSystem.readDirectory(tree).join(','), 'nothing was staged beside the target');
		Assert.equals(0, Cli.run(['remove-element', '$tree/C.hx'].concat(REMOVE_CALL)), 'the same op writes without the variable');
		Assert.notEquals(FIXTURE, File.getContent('$tree/C.hx'));
		CliFixture.removeDir(tree);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A harness copies a fixture into its own scratch directory and runs the engine there: that is not
	 * the tree the reviewer judges, so the same op writes — and a reviewer's probe and parity readings
	 * are the readings it would get without the variable.
	 */
	@:pin('control')
	@:killer('M-READ-ONLY-EVERYTHING-PROTECTED')
	public function testTheSameOpOnACopyOutsideTheTreeWrites(): Void {
		#if (sys || nodejs)
		final tree: String = CliFixture.writeDir('ro_tree', []);
		final scratch: String = CliFixture.writeDir('ro_scratch', [{ name: 'C.hx', source: FIXTURE }]);
		var code: Int = -1;
		withReadOnly(tree, () -> CliFixture.captureStdout(() -> code = Cli.run(['remove-element', '$scratch/C.hx'].concat(REMOVE_CALL))));
		Assert.equals(0, code);
		Assert.notEquals(FIXTURE, File.getContent('$scratch/C.hx'));
		CliFixture.removeDir(scratch);
		CliFixture.removeDir(tree);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * With no `APQ_READ_ONLY_ROOT` the tree is the git work tree of the
	 * working directory: the repository is protected, the OS temp root is not.
	 */
	@:pin('control')
	@:killer('M-READ-ONLY-EVERYTHING-PROTECTED')
	public function testTheDefaultTreeIsTheWorkTreeOfTheWorkingDirectory(): Void {
		#if (sys || nodejs)
		withVar(ReadOnlyScope.ROOT_ENV, null, () -> {
			Assert.isTrue(ReadOnlyScope.protects('${Sys.getCwd()}src/Anything.hx'), 'a path in the work tree');
			Assert.isTrue(ReadOnlyScope.protects('${Sys.getCwd()}a/../src/Anything.hx'), 'a spelling with a dot-dot is the same path');
			Assert.isFalse(ReadOnlyScope.protects(CliFixture.write('ro_default', FIXTURE)), 'a scratch file in the OS temp root');
		});
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	public function testAReadOpAndAPreviewAreAnsweredAsBefore(): Void {
		#if (sys || nodejs)
		final tree: String = CliFixture.writeDir('ro_read', [{ name: 'C.hx', source: FIXTURE }]);
		var code: Int = -1;
		var preview: Int = -1;
		withReadOnly(
			tree, () -> CliFixture.captureStdout(() -> {
				code = Cli.run(['lit', 'trace', '$tree/C.hx']);
				preview = Cli.run(['remove-element', '$tree/C.hx', '--match', 'g($$a)', '--kind', 'ExprStmt']);
			})
		);
		Assert.equals(0, code, 'a read command runs');
		Assert.equals(0, preview, 'a write op without --write only previews');
		Assert.equals(FIXTURE, File.getContent('$tree/C.hx'));
		CliFixture.removeDir(tree);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-READ-ONLY-NEVER')
	public function testFixIsRefusedAndTheFileKeepsItsBytes(): Void {
		#if (sys || nodejs)
		final tree: String = CliFixture.writeDir('ro_fix', [{ name: 'E.hx', source: LINT_FIXTURE }]);
		final run: CliRun = refused(tree, ['lint', '$tree/E.hx', '--all', '--no-oracle', '--fix']);
		Assert.equals(2, run.code);
		Assert.stringContains('read-only', run.out);
		Assert.equals(LINT_FIXTURE, File.getContent('$tree/E.hx'));
		CliFixture.removeDir(tree);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-READ-ONLY-NEVER')
	public function testNewAndFmtAreRefusedAndLeaveNoNewFileOrDirectory(): Void {
		#if (sys || nodejs)
		final tree: String = CliFixture.writeDir('ro_new', [{ name: 'F.hx', source: UNFORMATTED }]);
		Assert.equals(2, refused(tree, ['new', '$tree/deep/er/New.hx', '--class', '--write']).code);
		Assert.isFalse(FileSystem.exists('$tree/deep'), 'no directory was made for the refused file');
		Assert.equals(2, refused(tree, ['fmt', '$tree/F.hx', '--write']).code);
		Assert.equals(UNFORMATTED, File.getContent('$tree/F.hx'));
		Assert.equals('F.hx', FileSystem.readDirectory(tree).join(','), 'nothing was staged beside the target');
		CliFixture.removeDir(tree);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A fix that REMOVES a file reaches `deletePath` before any `writeFiles` of its pass, so the delete
	 * carries its own gate: a path in the tree is not deleted, one outside it is.
	 */
	@:pin('control')
	@:killer('M-READ-ONLY-DELETE-UNGATED')
	public function testDeletingAPathInTheTreeIsRefusedAndTheFileRemains(): Void {
		#if (sys || nodejs)
		final tree: String = CliFixture.writeDir('ro_del', [{ name: 'C.hx', source: FIXTURE }]);
		final scratch: String = CliFixture.writeDir('ro_del_out', [{ name: 'C.hx', source: FIXTURE }]);
		withReadOnly(tree, () -> {
			Assert.raises(() -> CliIo.deletePath('$tree/C.hx'), UsageFailure);
			Assert.isTrue(CliIo.deletePath('$scratch/C.hx'), 'a path outside the tree is deleted');
		});
		Assert.isTrue(FileSystem.exists('$tree/C.hx'));
		Assert.isFalse(FileSystem.exists('$scratch/C.hx'));
		CliFixture.removeDir(tree);
		CliFixture.removeDir(scratch);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-READ-ONLY-ZERO-IS-ON')
	public function testOnlyAValueThatMeansOnTurnsTheModeOn(): Void {
		#if (sys || nodejs)
		for (off in ['', '0']) withVar(CliIo.READ_ONLY_ENV, off, () -> Assert.isFalse(CliIo.readOnly(), 'APQ_READ_ONLY="$off" is off'));
		for (on in ['1', 'yes']) withVar(CliIo.READ_ONLY_ENV, on, () -> Assert.isTrue(CliIo.readOnly(), 'APQ_READ_ONLY="$on" is on'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A working directory outside every git work tree protects nothing: a harness's scratch directory is its own. */
	@:pin('control')
	@:killer('M-READ-ONLY-CWD-FALLBACK')
	public function testOutsideAnyWorkTreeNothingIsProtected(): Void {
		#if (sys || nodejs)
		final scratch: String = CliFixture.writeDir('ro_nogit', []);
		final home: String = Sys.getCwd();
		Sys.setCwd(scratch);
		CliFixture.always(() -> {
			Sys.setCwd(home);
			CliFixture.removeDir(scratch);
		}, () -> withVar(ReadOnlyScope.ROOT_ENV, null, () -> Assert.isFalse(ReadOnlyScope.protects('$scratch/x.hx'))));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A write reached through a symlink that points into the tree is a write into the tree: the path counts by its real identity. */
	@:pin('control')
	@:killer('M-READ-ONLY-SPELLING-IDENTITY')
	public function testAWriteThroughASymlinkIntoTheTreeIsRefused(): Void {
		#if nodejs
		final tree: String = CliFixture.writeDir('ro_link', [{ name: 'U.hx', source: UNFORMATTED }]);
		final scratch: String = CliFixture.writeDir('ro_link_out', []);
		js.node.Fs.symlinkSync(tree, '$scratch/lnk');
		final run: CliRun = refused(tree, ['fmt', '$scratch/lnk/U.hx', '--write']);
		Assert.equals(2, run.code);
		Assert.equals(UNFORMATTED, File.getContent('$tree/U.hx'));
		FileSystem.deleteFile('$scratch/lnk');
		CliFixture.removeDir(scratch);
		CliFixture.removeDir(tree);
		#else
		Assert.pass('non-node target');
		#end
	}

	#if (sys || nodejs)
	/** Run `body` with `name` set to `value` (unset when null), the previous value or its absence restored after. */
	private static function withVar(name: String, value: Null<String>, body: () -> Void): Void {
		final saved: Null<String> = Sys.getEnv(name);
		Sys.putEnv(name, value);
		CliFixture.always(() -> Sys.putEnv(name, saved), body);
	}

	/** Run `body` read-only with `tree` as the protected tree. */
	private static function withReadOnly(tree: String, body: () -> Void): Void {
		withVar(CliIo.READ_ONLY_ENV, '1', () -> withVar(ReadOnlyScope.ROOT_ENV, tree, body));
	}

	/** The refusal of `argv` read-only with `tree` protected: its exit status and what it printed on stderr. */
	private static function refused(tree: String, argv: Array<String>): CliRun {
		var code: Int = -1;
		var err: String = '';
		withReadOnly(tree, () -> err = CliFixture.captureStderr(() -> code = Cli.run(argv)));
		return { code: code, out: err };
	}
	#end

}
