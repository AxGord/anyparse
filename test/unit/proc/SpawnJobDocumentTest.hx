package unit.proc;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;

/** The file `ProcessSpawn.writeJobs` hands the process driver: a job's set fields under their own names, and nothing it left unset. */
class SpawnJobDocumentTest extends Test {

	#if nodejs
	public function testEverySetFieldReachesTheDocument(): Void {
		final batch: Null<DriverBatch> = ProcessSpawn.writeJobs([
			{
				args: ['a"b', 'c\nd'],
				cwd: 'here',
				cmd: 'tool',
				env: JObject([JValueTools.entry('K', JString('v')), JValueTools.entry('a"b', JString('c"d'))]),
				stdin: 'in',
				shell: 'sh',
				timeout: 1000,
				groupFile: 'g',
				tethered: true,
				reap: false,
				idle: 5,
				progress: 'p',
				awaitProgress: true
			}
		], 'apq-job-document-');
		if (batch == null) {
			Assert.fail('no batch');
			return;
		}
		final text: String = sys.io.File.getContent(batch.jobs);
		ProcessSpawn.dropBatch(batch.dir);
		Assert.equals(-1, text.indexOf('\n'));
		final job: JValue = soleJob(text);
		Assert.isTrue(same(JArray([JString('a"b'), JString('c\nd')]), JValueTools.field(job, 'args')));
		Assert.isTrue(
			same(JObject([JValueTools.entry('K', JString('v')), JValueTools.entry('a"b', JString('c"d'))]), JValueTools.field(job, 'env'))
		);
		for (key => value in [
			'cwd' => 'here',
			'cmd' => 'tool',
			'stdin' => 'in',
			'shell' => 'sh',
			'groupFile' => 'g',
			'progress' => 'p'
		]) Assert.isTrue(same(JString(value), JValueTools.field(job, key)), key);
		Assert.isTrue(same(JNumber(1000), JValueTools.field(job, 'timeout')));
		Assert.isTrue(same(JNumber(5), JValueTools.field(job, 'idle')));
		Assert.isTrue(same(JBool(true), JValueTools.field(job, 'tethered')));
		Assert.isTrue(same(JBool(false), JValueTools.field(job, 'reap')));
		Assert.isTrue(same(JBool(true), JValueTools.field(job, 'awaitProgress')));
	}

	public function testAnUnsetFieldIsAbsent(): Void {
		final batch: Null<DriverBatch> = ProcessSpawn.writeJobs([{ args: [], cwd: null }, { args: ['x'] }], 'apq-job-document-');
		if (batch == null) {
			Assert.fail('no batch');
			return;
		}
		final text: String = sys.io.File.getContent(batch.jobs);
		ProcessSpawn.dropBatch(batch.dir);
		switch JValueParser.parse(text) {
			case JArray([JObject(first), JObject(second)]):
				Assert.same(['args'], [for (entry in first) (entry.key: String)]);
				Assert.same(['args'], [for (entry in second) (entry.key: String)]);
			case _:
				Assert.fail(text);
		}
	}

	/** The environment a command carries becomes a job's `env`. */
	public function testAnEnvironmentBecomesADocument(): Void {
		final env: haxe.DynamicAccess<String> = {};
		env['a"b'] = 'v';
		env['GONE'] = null;
		Assert.isTrue(JValueTools.equals(
			JObject([JValueTools.entry('a"b', JString('v')), JValueTools.entry('GONE', JNull)]), ProcessSpawn.environment(env)
		));
	}

	private static function soleJob(text: String): JValue {
		return switch JValueParser.parse(text) {
			case JArray([job]): job;
			case _: throw new haxe.Exception('not one job: $text');
		};
	}

	private static function same(expected: JValue, actual: Null<JValue>): Bool {
		return actual != null && JValueTools.equals(expected, actual);
	}
	#else
	public function testNothingToWriteOffNode(): Void {
		Assert.pass();
	}
	#end

}
