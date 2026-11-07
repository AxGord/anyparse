package unit.check.oracle;

import anyparse.check.oracle.GenerationRecord;
import anyparse.check.oracle.GenerationRecordParser;
import anyparse.check.oracle.GenerationRecordWriter;
import anyparse.check.oracle.OracleCache;
import anyparse.check.oracle.OracleVerdictRecord;
import anyparse.check.oracle.OracleVerdictRecordParser;
import anyparse.check.oracle.OracleVerdictRecordWriter;
import anyparse.check.oracle.ServerState;
import anyparse.check.oracle.ServerStateParser;
import anyparse.check.oracle.ServerStateWriter;
import anyparse.core.FileHash;
import anyparse.core.TempScratch;
import anyparse.grammar.json.JsonFormat;
import anyparse.query.OracleProvider.OracleOutcome;
import haxe.Exception;
import haxe.io.Path;

/**
 * The records the oracle keeps on disk: a document an earlier engine wrote (spelled here as it wrote it, one line with no
 * spaces) still reads, and a record written now reads back on one line.
 */
class OracleRecordDocumentsTest extends Test {

	public function testAnEarlierServerRecordReads(): Void {
		final state: ServerState = ServerStateParser.parse('{"port":40123,"pid":777,"compiledAt":1790000000}');
		Assert.equals(40123, state.port);
		Assert.equals(777, state.pid);
		Assert.equals(1790000000, state.compiledAt);
	}

	public function testAServerRecordMissingAKeyDoesNotRead(): Void {
		Assert.raises(() -> ServerStateParser.parse('{"port":40123,"pid":777}'), Exception);
	}

	public function testAServerRecordRoundTrips(): Void {
		final text: String = ServerStateWriter.write({ port: 1, pid: 2, compiledAt: 3 }, JsonFormat.instance.compactWriteOptions);
		Assert.equals(-1, text.indexOf('\n'));
		final state: ServerState = ServerStateParser.parse(text);
		Assert.equals(1, state.port);
		Assert.equals(2, state.pid);
		Assert.equals(3, state.compiledAt);
	}

	public function testAnEarlierVerdictReads(): Void {
		final record: OracleVerdictRecord = OracleVerdictRecordParser.parse(
			'{"fingerprint":"abc","verdict":"rejected","errors":"a.hx:1: \\"x\\"\\n"}'
		);
		Assert.equals('abc', record.fingerprint);
		Assert.equals('rejected', record.verdict);
		Assert.equals('a.hx:1: "x"\n', record.errors);
	}

	public function testATruncatedVerdictCarriesOnlyWhatItHolds(): Void {
		final record: OracleVerdictRecord = OracleVerdictRecordParser.parse('{"verdict":"confirmed","errors":null}');
		Assert.isNull(record.fingerprint);
		Assert.isNull(record.errors);
		Assert.equals('confirmed', record.verdict);
	}

	public function testAVerdictRoundTrips(): Void {
		final text: String = OracleVerdictRecordWriter.write(
			{ fingerprint: 'f', verdict: 'rejected', errors: 'a "b"\nc' }, JsonFormat.instance.compactWriteOptions
		);
		Assert.equals(-1, text.indexOf('\n'));
		final record: OracleVerdictRecord = OracleVerdictRecordParser.parse(text);
		Assert.equals('f', record.fingerprint);
		Assert.equals('a "b"\nc', record.errors);
	}

	public function testAnEarlierGenerationRecordReads(): Void {
		final record: GenerationRecord = GenerationRecordParser.parse(
			'{"format":"v1","command":"lime update","inputs":[{"path":"a","hash":"1"}],"outputs":[{"path":"b","hash":"2"}],'
			+ '"implicit":[{"path":"c","hash":"3"},{"path":"d","hash":"4"}],"later":{"key":[1,2]}}'
		);
		Assert.equals('v1', record.format);
		Assert.equals('lime update', record.command);
		Assert.equals('a', sole(record.inputs).path);
		Assert.equals('2', sole(record.outputs).hash);
		Assert.equals(2, record.implicit?.length);
	}

	public function testARecordOfAnotherSchemeCarriesOnlyWhatItHolds(): Void {
		final record: GenerationRecord = GenerationRecordParser.parse('{"format":"v0"}');
		Assert.equals('v0', record.format);
		Assert.isNull(record.command);
		Assert.isNull(record.implicit);
	}

	public function testAGenerationRecordRoundTrips(): Void {
		final text: String = GenerationRecordWriter.write({
			format: 'v1',
			command: 'c',
			inputs: [],
			outputs: [{ path: 'p', hash: 'h' }],
			implicit: []
		}, JsonFormat.instance.compactWriteOptions);
		Assert.equals(-1, text.indexOf('\n'));
		final record: GenerationRecord = GenerationRecordParser.parse(text);
		Assert.equals(0, record.inputs?.length);
		Assert.equals('h', sole(record.outputs).hash);
	}

	private static function sole(hashes: Null<Array<FileHash>>): FileHash {
		return (hashes ?? [{ path: '', hash: '' }])[0];
	}

	#if (sys || nodejs)
	/** An earlier engine's file answers the lookup as the verdict it recorded, and a store replaces it with a readable one. */
	public function testAnEarlierVerdictFileAnswersTheLookup(): Void {
		final dir: String = '${TempScratch.root()}/oracle-record-documents-${Std.random(0x7FFFFFFF)}';
		sys.FileSystem.createDirectory(dir);
		final hxml: String = Path.join([dir, 'check.hxml']);
		sys.io.File.saveContent(hxml, '-cp .\n');
		final path: String = OracleCache.cacheFile(hxml, dir);
		sys.io.File.saveContent(path, '{"fingerprint":"abc","verdict":"rejected","errors":"boom"}');
		try {
			Assert.isTrue(outcomeIs(OracleCache.lookup(hxml, dir, 'abc'), 'boom'));
			Assert.isNull(OracleCache.lookup(hxml, dir, 'other'));
			OracleCache.store(hxml, dir, 'new', Rejected('again'));
			Assert.isTrue(outcomeIs(OracleCache.lookup(hxml, dir, 'new'), 'again'));
		} catch (exception: Exception) {
			Assert.fail(exception.message);
		}
		sys.FileSystem.deleteFile(path);
		sys.FileSystem.deleteFile(hxml);
		sys.FileSystem.deleteDirectory(dir);
	}

	private static function outcomeIs(outcome: Null<OracleOutcome>, errors: String): Bool {
		return switch outcome {
			case Rejected(held): held == errors;
			case _: false;
		};
	}
	#end

}
