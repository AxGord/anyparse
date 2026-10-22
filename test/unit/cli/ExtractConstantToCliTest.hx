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

}
