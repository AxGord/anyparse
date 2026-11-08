package unit.cli;

import anyparse.query.Cli;
import anyparse.query.RefactorSupport;
import anyparse.query.cli.CliArgs;
#if (sys || nodejs)
import sys.FileSystem;
#end

using StringTools;

/**
 * What names a refactor's type and its destination file: the grammar the file is written in, never a literal `.hx`; and a
 * grammar that describes data documents has no type for a type refactor to name, so it is refused by that meaning.
 */
@:nullSafety(Strict)
final class RefactorGrammarCliTest extends Test {

	private static final SRC: String =
		'package;\n\nclass C {\n\n\tpublic function new() {}\n\n\tpublic function go(): Int {\n\t\treturn 1;\n\t}\n}\n';

	/** A file's type is its basename without the grammar's own extension; without one given, `.hx` is what goes. */
	@:killer('M-TYPE-NAME-FROM-HX')
	@:pin('control')
	public function testTheTypeNameDropsTheGrammarsExtension(): Void {
		Assert.equals('d', CliArgs.typeNameOfFile(CliArgs.JSON_LANG, 'x/d.json'));
		Assert.equals('C', CliArgs.typeNameOfFile('haxe', 'x/C.hx'));
		Assert.equals('Sqlite.cpp', RefactorSupport.baseNameOf('Sqlite.cpp.hx'));
		Assert.equals('d.json', RefactorSupport.baseNameOf('d.json'));
	}

	/** A type refactor over a data document says the grammar declares no types, not that `d.json` is no class. */
	@:killer('M-DATA-GRAMMAR-NOT-REFUSED')
	@:pin('control')
	public function testADataGrammarIsRefusedByMeaning(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('refactor_data', [{ name: 'd.json', source: '{"a": 1}\n' }]);
		final file: String = '$dir/d.json';
		for (argv in [
			['extract-interface', file, 'I', '--lang', 'json'],
			['extract-superclass', file, 'S', '--members', 'a', '--lang', 'json'],
			['move-to-helper', file, 'a', '--to', 'H', '--scope', dir, '--lang', 'json']
		]) {
			var exit: Int = -1;
			final err: String = CliFixture.captureStderr(() -> exit = Cli.run(argv));
			Assert.equals(1, exit, '${argv[0]}: $err');
			Assert.isTrue(err.contains('the json grammar describes data documents'), '${argv[0]}: $err');
			Assert.isFalse(err.contains('no unique'), '${argv[0]}: $err');
		}
		Assert.isFalse(FileSystem.exists('$dir/I.json') || FileSystem.exists('$dir/S.json') || FileSystem.exists('$dir/H.json'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The interface lands beside the source under the extension of the grammar the source is written in. */
	@:killer('M-EXTRACT-INTERFACE-DESTINATION-EXTENSION')
	@:pin('control')
	public function testExtractInterfaceNamesItsDestinationByTheGrammar(): Void {
		assertPreview(['extract-interface', 'C.hx', 'I'], '/I.hx: created');
	}

	/** The superclass lands beside the source under the extension of the grammar the source is written in. */
	@:killer('M-EXTRACT-SUPERCLASS-DESTINATION-EXTENSION')
	@:pin('control')
	public function testExtractSuperclassNamesItsDestinationByTheGrammar(): Void {
		assertPreview(['extract-superclass', 'C.hx', 'S', '--members', 'go'], '/S.hx: created');
	}

	/**
	 * A new helper module lands beside the source under the extension of the grammar the source is written in.
	 */
	@:killer('M-HELPER-DESTINATION-EXTENSION')
	@:pin('control')
	public function testMoveToHelperNamesItsDestinationByTheGrammar(): Void {
		assertPreview(['move-to-helper', 'C.hx', 'go', '--to', 'H', '--dry-run'], '/H.hx (created) ===');
	}

	/** The grammar's extension, not the source's: a Haxe class kept in `C.txt` still gets its helper as `H.hx`. */
	@:killer('M-HELPER-DESTINATION-EXTENSION')
	@:pin('control')
	public function testMoveToHelperIgnoresTheSourceFilesOwnExtension(): Void {
		assertPreview([
			'move-to-helper',
			'C.hx',
			'go',
			'--to',
			'H',
			'--dry-run',
			'--lang',
			'haxe',
			'--type',
			'C'
		], '/H.hx (created) ===', 'C.txt');
	}

	/**
	 * Run `argv` (`C.hx` stands for the source) over a fresh directory holding the source as `srcName`, and assert its
	 * stdout names `expected` after the directory.
	 */
	private function assertPreview(argv: Array<String>, expected: String, srcName: String = 'C.hx'): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('refactor_destination', [{ name: srcName, source: SRC }]);
		final args: Array<String> = argv.map(a -> a == 'C.hx' ? '$dir/$srcName' : a);
		if (argv[0] == 'move-to-helper') {
			args.push('--scope');
			args.push(dir);
		}
		var exit: Int = -1;
		var err: String = '';
		final out: String = CliFixture.captureStdout(() -> err = CliFixture.captureStderr(() -> exit = Cli.run(args)));
		Assert.equals(0, exit, err);
		Assert.isTrue(out.contains(dir + expected), '$expected in: $out');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
