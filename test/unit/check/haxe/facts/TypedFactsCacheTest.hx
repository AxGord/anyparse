package unit.check.haxe.facts;

import anyparse.check.haxe.facts.TypedFactsCache;
import anyparse.check.haxe.oracle.OracleRunMemo;
import anyparse.query.ReachLiveness.ReachConfiguration;

/** A fixture directory and its one configuration. */
private typedef Fixture = { final dir: String; final oracle: OracleConfig; }

/**
 * `TypedFactsCache` - a report whose facts compile carries the builds' probe answers an input an earlier report compiled from
 * what that report stored, and a `--fix` run never does. Compiles are counted by the compiler itself (`CompileCounter`); each
 * fixture names its hxml uniquely, since a record is named by the hxml's file name, and removes its record when done.
 */
@:nullSafety(Strict)
final class TypedFactsCacheTest extends Test {

	private static final MAIN: String = 'class Main {\n\tstatic function main() {\n\t\tfinal xs = [1, 2];\n\t\ttrace(xs.length);\n\t}\n}\n';
	private static final EDITED: String =
		'class Main {\n\tstatic function main() {\n\t\tfinal xs = [1, 2, 3];\n\t\ttrace(xs.length);\n\t}\n}\n';

	/** A second report over the same input compiles nothing: its facts, its `-v` typecheck and its build come from the store. */
	@:pin('control')
	@:killer('M-FACTSCACHE-NEVER-LOADS')
	@:killer('M-FACTSCACHE-RIDDEN-UNFILED')
	public function testAReportOverAnInputAlreadyCompiledCompilesNothing(): Void {
		#if (sys || nodejs)
		final fixture: Fixture = project();
		final first: Null<CompilerFacts> = TypedFactsProbe.probeAll(configured(fixture, true));
		Assert.equals(1, CompileCounter.count(fixture.dir), 'the first report compiled');
		Assert.isTrue(sys.FileSystem.exists(TypedFactsCache.recordFile(fixture.oracle)), 'and stored what it compiled');
		final again: Array<OracleConfig> = configured(fixture, true);
		final read: Null<CompilerFacts> = TypedFactsProbe.probeAll(again);
		Assert.equals(1, CompileCounter.count(fixture.dir), 'the second report compiled nothing');
		Assert.same(first?.configurations, read?.configurations);
		Assert.equals(0, read?.dropped.length);
		final builds: Array<Null<ReachConfiguration>> = OracleRunMemo.of(again)?.builds(again) ?? [];
		Assert.notNull(builds[0], 'the stored build answers the run, so its probe compiles nothing either');
		remove(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** An edited source is another input: the report compiles it again. */
	@:pin('control')
	@:killer('M-FACTSCACHE-KEY-BLIND')
	public function testAnEditedInputCompilesAgain(): Void {
		#if (sys || nodejs)
		final fixture: Fixture = project();
		Assert.notNull(TypedFactsProbe.probeAll(configured(fixture, true)));
		sys.io.File.saveContent('${fixture.dir}/Main.hx', EDITED);
		Assert.notNull(TypedFactsProbe.probeAll(configured(fixture, true)));
		Assert.equals(2, CompileCounter.count(fixture.dir), 'the edit missed the stored facts');
		remove(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A `--fix` run compiles its facts itself and stores nothing. */
	@:pin('control')
	@:killer('M-FACTSCACHE-FIX-READS')
	public function testAFixRunNeitherReadsNorStores(): Void {
		#if (sys || nodejs)
		final fixture: Fixture = project();
		Assert.notNull(TypedFactsProbe.probeAll(configured(fixture, false)));
		Assert.notNull(TypedFactsProbe.probeAll(configured(fixture, false)));
		Assert.equals(2, CompileCounter.count(fixture.dir));
		Assert.isFalse(sys.FileSystem.exists(TypedFactsCache.recordFile(fixture.oracle)));
		remove(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A compile is stored only when its input kept its key across the compile and every file it parsed is one the key hashed;
	 * a record is read only under its own key.
	 */
	@:pin('control')
	@:killer('M-FACTSCACHE-STORES-MOVED')
	@:killer('M-FACTSCACHE-STORES-UNHASHED')
	public function testOnlyAnUnmovedFullyHashedCompileIsStoredAndReadUnderItsKey(): Void {
		#if (sys || nodejs)
		final fixture: Fixture = project();
		final file: String = '${fixture.dir}/Main.hx';
		final ridden: TypedFactsRidden = {
			verbose: {
				status: 0,
				out: 'Parsed $file\n',
				err: '',
				failure: '',
				overflowed: false
			},
			configuration: {
				name: 'build',
				defined: [],
				everDefined: [],
				values: [],
				compiled: [file],
				types: []
			}
		};
		final hashed: TypedFactsKey = { key: 'a', base: fixture.dir, hashed: [file => 'h'] };
		TypedFactsCache.store(fixture.oracle, hashed, { key: 'b', base: fixture.dir, hashed: [file => 'h'] }, 'facts', ridden);
		Assert.isFalse(sys.FileSystem.exists(TypedFactsCache.recordFile(fixture.oracle)), 'the input moved during the compile');
		TypedFactsCache.store(
			fixture.oracle, { key: 'a', base: fixture.dir, hashed: [] }, { key: 'a', base: fixture.dir, hashed: [] },
			'facts', ridden
		);
		Assert.isFalse(sys.FileSystem.exists(TypedFactsCache.recordFile(fixture.oracle)), 'the compile parsed a file the key did not hash');
		TypedFactsCache.store(fixture.oracle, hashed, hashed, 'facts', ridden);
		final stored: Null<TypedFactsStored> = TypedFactsCache.load(fixture.oracle, hashed);
		Assert.notNull(stored);
		if (stored != null) Assert.equals('facts', TypedFactsCache.dump(fixture.oracle, stored));
		Assert.isNull(TypedFactsCache.load(fixture.oracle, { key: 'c', base: fixture.dir, hashed: [file => 'h'] }));
		remove(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A dump another run replaced after this run read its record is a miss: that configuration compiles, it is never dropped. */
	@:pin('control')
	@:killer('M-FACTSCACHE-REPLACED-DROPS')
	public function testAReplacedDumpCompilesInsteadOfDropping(): Void {
		#if (sys || nodejs)
		final fixture: Fixture = project();
		final first: Null<CompilerFacts> = TypedFactsProbe.probeAll(configured(fixture, true));
		sys.io.File.saveContent(TypedFactsCache.dumpFile(fixture.oracle), 'the facts of another tree\n');
		final read: Null<CompilerFacts> = TypedFactsProbe.probeAll(configured(fixture, true));
		Assert.equals(2, CompileCounter.count(fixture.dir), 'the replaced dump compiled again');
		Assert.equals(0, read?.dropped.length);
		Assert.same(first?.configurations, read?.configurations);
		remove(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/** A build of `MAIN` that counts its compiles, under an hxml named for this fixture alone. */
	private static function project(): Fixture {
		final hxml: String = 'facts-cache-${Std.random(0x7fffffff)}.hxml';
		final dir: String = CliFixture.writeTree('typed_facts_cache', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'Counter.hx', source: CompileCounter.SOURCE },
			{ name: hxml, source: '-cp .\n-main Main\n--js out.js\n${CompileCounter.MACRO}' }
		]);
		return { dir: dir, oracle: { hxml: hxml, dir: dir, defines: [] } };
	}

	/** The fixture's configuration as a run carries it: a report (`persisted`) or a `--fix` run, its compiles riding the builds' probe. */
	private static function configured(fixture: Fixture, persisted: Bool): Array<OracleConfig> {
		return OracleRunMemo.attach([fixture.oracle], new OracleRunMemo(persisted, () -> [], new HaxeQueryPlugin()));
	}

	/** Delete the fixture and the record its runs stored. */
	private static function remove(fixture: Fixture): Void {
		for (path in [
			TypedFactsCache.recordFile(fixture.oracle),
			TypedFactsCache.dumpFile(fixture.oracle)
		]) if (sys.FileSystem.exists(path)) sys.FileSystem.deleteFile(path);
		CliFixture.removeDir(fixture.dir);
	}
	#end

}
