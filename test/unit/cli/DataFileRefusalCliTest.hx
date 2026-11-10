package unit.cli;

import anyparse.query.Cli;

using StringTools;

/**
 * A code op over a data document is refused by meaning — the grammar declares no types — and not by a lookup that names
 * the file as the class it could not find.
 */
@:nullSafety(Strict)
final class DataFileRefusalCliTest extends Test {

	private static final DOCUMENT: String = '{"a": 1}\n';
	private static final FILE: String = '<file>';
	private static final DIR: String = '<dir>';

	/** `encapsulate-field` over a data document is refused by meaning. */
	@:killer('M-ENCAPSULATE-FIELD-DATA-NOT-REFUSED')
	@:pin('control')
	public function testEncapsulateFieldRefusesADataFile(): Void {
		assertRefused(['encapsulate-field', FILE, 'a']);
	}

	/** `make-final` over a data document is refused by meaning. */
	@:killer('M-MAKE-FINAL-DATA-NOT-REFUSED')
	@:pin('control')
	public function testMakeFinalRefusesADataFile(): Void {
		assertRefused(['make-final', FILE, 'a']);
	}

	/** `move-member` over a data document is refused by meaning. */
	@:killer('M-MOVE-MEMBER-DATA-NOT-REFUSED')
	@:pin('control')
	public function testMoveMemberRefusesADataFile(): Void {
		assertRefused(['move-member', FILE, 'a', '--to', 'D', '--scope', DIR]);
	}

	/** `pull-up` over a data document is refused by meaning. */
	@:killer('M-PULL-UP-DATA-NOT-REFUSED')
	@:pin('control')
	public function testPullUpRefusesADataFile(): Void {
		assertRefused(['pull-up', FILE, 'a', '--to', 'D', '--scope', DIR]);
	}

	/** `safe-delete` over a data document is refused by meaning. */
	@:killer('M-SAFE-DELETE-DATA-NOT-REFUSED')
	@:pin('control')
	public function testSafeDeleteRefusesADataFile(): Void {
		assertRefused(['safe-delete', FILE, 'a', '--scope', DIR]);
	}

	/** Run `argv` against a data document: exit 1, the meaning refusal and none of the lookup misses, the file untouched. */
	private function assertRefused(argv: Array<String>): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('data_file_refusal', [{ name: 'd.json', source: DOCUMENT }]);
		final full: Array<String> = argv.map(a -> a.replace(FILE, '$dir/d.json').replace(DIR, dir)).concat(['--lang', 'json']);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(full));
		Assert.equals(1, exit, '${argv[0]}: $err');
		Assert.isTrue(err.contains('the json grammar describes data documents'), '${argv[0]}: $err');
		Assert.isFalse(err.contains('no unique') || err.contains('no member') || err.contains('no field'), '${argv[0]}: $err');
		Assert.equals(DOCUMENT, sys.io.File.getContent('$dir/d.json'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
