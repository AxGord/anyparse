package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

using StringTools;

/**
 * `apq extract-constant` addressed mode end to end: `--select` names a local, `--into` a module of another package
 * that does not exist yet, and one `--write` changes the source and creates the module together.
 */
class ExtractConstantToCliTest extends Test {

	/** The source module, in package `pkg.a` under a `src/` root. */
	private static final WORKER: String =
		'package pkg.a;\n\nclass Worker {\n\n\tfunction f():Int {\n\t\tfinal timeout:Int = 5 * 60;\n\t\treturn timeout;\n\t}\n}\n';

	/** One write: the local reads the constant, the import is added, the module is created. */
	@:pin('control')
	@:killer('M-EXTRACT-CONSTANT-ADDRESSED-UNROUTED')
	public function testTheAddressedModeWritesTheSourceAndTheModule(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('extractto', [{ name: 'src/pkg/a/Worker.hx', source: WORKER }]);
		final into: String = '$dir/src/pkg/b/Limits.hx';
		FileSystem.createDirectory('$dir/src/pkg/b');
		final rc: Int = Cli.run([
			'extract-constant',
			'$dir/src/pkg/a/Worker.hx',
			'--select',
			'FinalStmt:timeout',
			'--name',
			'TIMEOUT',
			'--into',
			into,
			'--write'
		]);
		Assert.equals(0, rc, 'the addressed mode runs');
		final worker: String = File.getContent('$dir/src/pkg/a/Worker.hx');
		Assert.isTrue(worker.contains('final timeout:Int = Limits.TIMEOUT;'), 'the local reads the constant: $worker');
		Assert.isTrue(worker.contains('import pkg.b.Limits;'), 'and imports its module');
		Assert.isTrue(
			FileSystem.exists(into) && File.getContent(into).contains('public static final TIMEOUT:Int = 5 * 60;'), 'the module holds it'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A refusal writes nothing, in either file. */
	public function testARefusalWritesNothing(): Void {
		#if (sys || nodejs)
		final source: String = WORKER.replace('5 * 60', 'Std.int(3.5)');
		final dir: String = CliFixture.writeTree('extractto', [{ name: 'src/pkg/a/Worker.hx', source: source }]);
		final into: String = '$dir/src/pkg/b/Limits.hx';
		final rc: Int = Cli.run([
			'extract-constant',
			'$dir/src/pkg/a/Worker.hx',
			'--select',
			'FinalStmt:timeout',
			'--name',
			'T',
			'--into',
			into,
			'--write'
		]);
		Assert.equals(1, rc, 'refused');
		Assert.equals(source, File.getContent('$dir/src/pkg/a/Worker.hx'), 'the source is untouched');
		Assert.isFalse(FileSystem.exists(into), 'no module was created');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--into` naming the source through a symlink is the source itself: `--to` its own type works. */
	@:pin('control')
	@:killer('M-EXTRACT-CONSTANT-TO-INTO-BY-SPELLING')
	public function testASymlinkedIntoIsTheSourceItself(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('extractto', [
			{ name: 'B.hx', source: 'class B {\n\tfunction f():Int {\n\t\treturn 42;\n\t}\n}\n' }
		]);
		js.node.Fs.symlinkSync('$dir/B.hx', '$dir/M.hx');
		final rc: Int = Cli.run([
			'extract-constant',
			'$dir/B.hx',
			'3:10',
			'--name',
			'ANSWER',
			'--into',
			'$dir/M.hx',
			'--to',
			'B',
			'--write'
		]);
		Assert.equals(0, rc, 'the source type takes its own constant');
		final b: String = File.getContent('$dir/B.hx');
		Assert.isTrue(b.contains('private static inline final ANSWER:Int = 42;'), 'the constant is declared: $b');
		Assert.isTrue(b.contains('return B.ANSWER;'), 'and read: $b');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('needs a symlink');
		#end
	}

	/** A scope reached through a symlink does not scan the module as a consumer of itself. */
	@:pin('control')
	@:killer('M-EXTRACT-CONSTANT-INTO-SCAN-BY-SPELLING')
	public function testAModuleReachedThroughASymlinkedScopeIsNotItsOwnConsumer(): Void {
		#if nodejs
		final dir: String = CliFixture.writeTree('extractinto', [
			{ name: 'src/K.hx', source: "class K {\n\tpublic static final X:String = 'hello';\n}\n" },
			{ name: 'src/U.hx', source: "class U {\n\tfunction f():String {\n\t\treturn 'hello';\n\t}\n}\n" }
		]);
		FileSystem.createDirectory('$dir/alias');
		js.node.Fs.symlinkSync('$dir/src', '$dir/alias/s');
		final rc: Int = Cli.run([
			'extract-constant',
			'$dir/src',
			'--into',
			'$dir/alias/s/K.hx',
			'--name',
			'HELLO',
			'--literal',
			'hello',
			'--write',
			'--lang',
			'haxe'
		]);
		Assert.equals(0, rc, 'the run completes');
		Assert.isTrue(File.getContent('$dir/src/U.hx').contains('K.HELLO'), 'the consumer reads the constant');
		Assert.isTrue(File.getContent('$dir/src/K.hx').contains('HELLO'), 'the module declares it');
		js.node.Fs.unlinkSync('$dir/alias/s');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('needs a symlink');
		#end
	}

}
