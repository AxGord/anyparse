package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;

/**
 * `apq new --arm`: a module and the arm records its pinned tests name are written in one step or not at all, into the
 * registry the project declares (or `--arms-dir`).
 */
@:nullSafety(Strict)
final class NewArmCliTest extends Test {

	private static final CONFIG: String = '{"move":{"registries":[{"file":"arms","keys":["arms.type"],"byPackage":true}]}}';
	private static final EXISTING: String = '{\n\t"$$comment": [\n\t\t"c"\n\t],\n\t"arms": [\n\t\t{\n\t\t\t"name": "M-A",\n'
		+ '\t\t\t"type": "p.X",\n\t\t\t"method": "m",\n\t\t\t"force": "1",\n\t\t\t"note": "n"\n\t\t}\n\t]\n}\n';
	private static final RECORD: String = '{"name":"M-B","type":"p.Y","method":"go","force":"2","note":"n"}';
	private static final SCAFFOLD: Array<String> = ['--kind', 'class', '--field', 'public var v: Int;'];

	@:pin('control')
	@:killer('M-NEW-ARMS-WRITTEN-WITH-MODULE')
	@:killer('M-NEW-ARMS-DEFAULT-DIRECTORY')
	public function testTheModuleAndItsArmRecordAreWrittenTogether(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		Assert.equals(0, Cli.run(['new', '$dir/p/FooTest.hx'].concat(SCAFFOLD).concat(['--arm', RECORD, '--write'])));
		Assert.isTrue(FileSystem.exists('$dir/p/FooTest.hx'));
		final registry: String = File.getContent('$dir/arms/p.json');
		Assert.isTrue(registry.indexOf('"name": "M-A"') > 0, 'the record already there stays');
		Assert.isTrue(registry.indexOf('"name": "M-B"') > registry.indexOf('"name": "M-A"'), 'the new one follows it');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-NEW-ARMS-DIR-OVERRIDE')
	public function testArmsDirNamesTheRegistryWhenTheProjectDeclaresNone(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('newarm', [{ name: 'reg/p.json', source: EXISTING }]);
		Assert.equals(
			0, Cli.run(['new', '$dir/p/FooTest.hx'].concat(SCAFFOLD).concat(['--arm', RECORD, '--arms-dir', '$dir/reg', '--write']))
		);
		Assert.isTrue(File.getContent('$dir/reg/p.json').indexOf('"name": "M-B"') > 0);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-ARMRECORDS-DUPLICATE-NAME')
	public function testARefusedRecordLeavesNeitherTheModuleNorTheRegistryChanged(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		final taken: String = '{"name":"M-A","type":"p.Y","method":"go","force":"2","note":"n"}';
		Assert.equals(1, Cli.run(['new', '$dir/p/FooTest.hx'].concat(SCAFFOLD).concat(['--arm', taken, '--write'])));
		Assert.isFalse(FileSystem.exists('$dir/p/FooTest.hx'));
		Assert.equals(EXISTING, File.getContent('$dir/arms/p.json'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('guard')
	public function testWithoutWriteNothingIsWritten(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		Assert.equals(0, Cli.run(['new', '$dir/p/FooTest.hx'].concat(SCAFFOLD).concat(['--arm', RECORD])));
		Assert.isFalse(FileSystem.exists('$dir/p/FooTest.hx'));
		Assert.equals(EXISTING, File.getContent('$dir/arms/p.json'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-NEW-ARM-FILE-READ')
	public function testArmFileTakesTheRecordFromTheFile(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('newarm', [
			{ name: 'apq.json', source: CONFIG },
			{ name: 'arms/p.json', source: EXISTING },
			{ name: 'record.json', source: RECORD }
		]);
		Assert.equals(0, Cli.run(['new', '$dir/p/FooTest.hx'].concat(SCAFFOLD).concat(['--arm-file', '$dir/record.json', '--write'])));
		Assert.isTrue(FileSystem.exists('$dir/p/FooTest.hx'));
		Assert.isTrue(File.getContent('$dir/arms/p.json').indexOf('"name": "M-B"') > 0);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-NEW-ARM-FILE-MISSING')
	public function testAMissingArmFileIsAUsageErrorAndNothingIsWritten(): Void {
		#if (sys || nodejs)
		final dir: String = fixture();
		Assert.equals(2, Cli.run(['new', '$dir/p/FooTest.hx'].concat(SCAFFOLD).concat(['--arm-file', '$dir/none.json', '--write'])));
		Assert.isFalse(FileSystem.exists('$dir/p/FooTest.hx'));
		Assert.equals(EXISTING, File.getContent('$dir/arms/p.json'));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private static function fixture(): String {
		return CliFixture.writeTree('newarm', [{ name: 'apq.json', source: CONFIG }, { name: 'arms/p.json', source: EXISTING }]);
	}
	#end

}
