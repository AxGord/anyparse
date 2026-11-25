package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

/**
 * `apq extract-var` addressed by `--match`: the hoisted local replaces EVERY occurrence
 * equal to the matched expression in its scope, not only the `--nth` one, and carries the
 * type the structural (oracle-free) ladder can name. Each test drives `Cli.run` against a
 * temp fixture with `--write` and reads the file back.
 */
class ExtractVarReplaceAllCliTest extends Test {

	/** Three reads of one class-typed field chain (pure: the index places every member) in one body. */
	private static final REPEATED_FIXTURE: String = 'class B {\n\tpublic var c:B;\n\tpublic var n:Int;\n\n\tfunction f(b:B):Int {\n'
		+ '\t\tfinal x:Int = b.c.n + 1;\n\t\tfinal y:Int = b.c.n * 2;\n\t\treturn b.c.n + x + y;\n\t}\n}\n';

	/**
	 * Three reads of `b.c.n` in one function, addressed by `--nth 1`: all three become the
	 * new local, so the repeated-expression finding the op answers is gone.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-VAR-ONE-OCCURRENCE')
	public function testMatchReplacesEveryEqualOccurrence(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('ev_all', REPEATED_FIXTURE);
		final rc: Int = Cli.run(['extract-var', path, '--match', 'b.c.n', '--nth', '1', 'p', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('= b.c.n;') >= 0, out);
		Assert.isTrue(out.indexOf('final x:Int = p + 1;') >= 0, out);
		Assert.isTrue(out.indexOf('final y:Int = p * 2;') >= 0, out);
		Assert.isTrue(out.indexOf('return p + x + y;') >= 0, out);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A `String` receiver's `toUpperCase()` is typed by the structural ladder without a
	 * compiler, so the hoisted local is written `final up:String = …`, not untyped.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-VAR-UNTYPED')
	public function testHoistCarriesStructuralType(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'ev_type', 'class A {\n\tfunction f(s:String):Int {\n\t\treturn s.toUpperCase().length;\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['extract-var', path, '--match', 's.toUpperCase()', 'up', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(~/final up ?: ?String = s\.toUpperCase\(\);/.match(out), out);
		Assert.isTrue(out.indexOf('return up.length;') >= 0, out);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A write to `b.c` between the second and the third read cuts the run: the two reads before it become the local,
	 * the one after it keeps reading the field.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-VAR-RUN-UNCUT')
	public function testWriteCutsTheReplacedRun(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'ev_cut',
			'class B {\n\tpublic var c:B;\n\tpublic var n:Int;\n\n\tfunction f(b:B):Int {\n'
			+ '\t\tfinal x:Int = b.c.n + 1;\n\t\tfinal y:Int = b.c.n * 2;\n\t\tb.c = b;\n\t\treturn b.c.n + x + y;\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['extract-var', path, '--match', 'b.c.n', '--nth', '1', 'p', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('final y:Int = p * 2;') >= 0, out);
		Assert.isTrue(out.indexOf('return b.c.n + x + y;') >= 0, out);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--single` keeps the old contract: only the addressed occurrence becomes the local. */
	@:pin('control')
	@:killer('M-EXTRACT-VAR-SINGLE-IGNORED')
	public function testSingleReplacesOnlyTheAddressed(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('ev_one', REPEATED_FIXTURE);
		final rc: Int = Cli.run([
			'extract-var',
			path,
			'--match',
			'b.c.n',
			'--nth',
			'2',
			'p',
			'--single',
			'--write'
		]);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('final x:Int = b.c.n + 1;') >= 0, out);
		Assert.isTrue(out.indexOf('final y:Int = p * 2;') >= 0, out);
		Assert.isTrue(out.indexOf('return b.c.n + x + y;') >= 0, out);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Every read of `b.c.n` sits behind a `b.c != null` guard (a braced `if`, an `&&` operand, a ternary arm): nothing is
	 * hoisted above the first guard, which would read through a null `b.c`; the addressed read is hoisted inside it.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-VAR-HOIST-UNGUARDED')
	public function testGuardKeepsTheHoistInside(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'ev_guard',
			'class G {\n\tpublic var c:G;\n\tpublic var n:Int;\n\n\tfunction f(b:G):Int {\n\t\tvar s:Int = 0;\n\t\tif (b.c != null) {\n'
			+ '\t\t\ts = b.c.n;\n\t\t}\n\t\tif (b.c != null && b.c.n > 0) s += 1;\n\t\treturn s + (b.c == null ? 0 : b.c.n);\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['extract-var', path, '--match', 'b.c.n', '--nth', '1', 'p', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('if (b.c != null) {\n\t\t\tfinal p = b.c.n;\n\t\t\ts = p;') >= 0, out);
		Assert.isTrue(out.indexOf('b.c != null && b.c.n > 0') >= 0, out);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The earliest replaceable read follows a write to the same chain inside a branch: the local is declared after the
	 * write, inside the branch, and the read after the branch is not rewritten to a value computed above it.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-VAR-HOIST-UNDOMINATED')
	public function testWriteInBranchKeepsTheHoistAfterIt(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'ev_branch',
			'class W {\n\tpublic var c:W;\n\tpublic var n:Int;\n\n\tfunction f(b:W, cond:Bool):Int {\n\t\tif (cond) {\n'
			+ '\t\t\tb.c.n = 5;\n\t\t\ttrace(b.c.n + 1);\n\t\t}\n\t\treturn b.c.n * 2;\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['extract-var', path, '--match', 'b.c.n', '--nth', '2', 'p', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('b.c.n = 5;\n\t\t\tfinal p = b.c.n;\n\t\t\ttrace(p + 1);') >= 0, out);
		Assert.isTrue(out.indexOf('return b.c.n * 2;') >= 0, out);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A write to `b.c` earlier in the statement holding the earliest read: no local declared before that statement may
	 * stand for the reads, so the later `return` keeps reading the field.
	 */
	@:pin('control')
	@:killer('M-EXTRACT-VAR-HOIST-WRITE-CROSSED')
	public function testWriteInTheStatementKeepsTheLaterRead(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'ev_stmt',
			'class W {\n\tpublic var c:W;\n\tpublic var n:Int;\n\n\tfunction f(b:W, o:W):Int {\n\t\ttrace(b.c = o, b.c.n);\n'
			+ '\t\treturn b.c.n * 2;\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['extract-var', path, '--match', 'b.c.n', '--nth', '1', 'p', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('return b.c.n * 2;') >= 0, out);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
