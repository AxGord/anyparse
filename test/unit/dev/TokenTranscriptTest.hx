package unit.dev;

import anyparse.grammar.json.JsonText;
import dev.TokenTranscript;
import devkit.TempDir;
import haxe.io.Bytes;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `TokenTranscript`: what one transcript's tool calls, model turns, slice and bypasses read as — the row a command lands on,
 * the sizes of a call and its answer, the usage of a message written once per content block, the slice a prompt names, and
 * the shell reads and writes of repo `.hx` that go round hxq.
 */
@:nullSafety(Strict)
final class TokenTranscriptTest extends Test {

	public function testACommandLandsOnTheRowOfTheProgramItRuns(): Void {
		Assert.equals(
			'hxq show', TokenTranscript.bashKey(TokenTranscript.normalize('cd /w && export HXQ_BIN=/w/bin/apq.js && hxq show f.hx'))
		);
		Assert.equals('hxq lint', TokenTranscript.bashKey('node /w/bin/apq.js lint f.hx'));
		Assert.equals('dev token-audit', TokenTranscript.bashKey('node bin/dev.js token-audit dir'));
		Assert.equals('git diff', TokenTranscript.bashKey('git -C /w diff main..HEAD'));
		Assert.equals('sh sed', TokenTranscript.bashKey('/usr/bin/sed -n 1,5p f'));
	}

	public function testAnAssignmentChainedWithAndAndIsStrippedWhole(): Void {
		Assert.equals('hxq show f', TokenTranscript.normalize('cd /w && S=/tmp/x && F=a.hx && HXQ_BIN=b hxq show f'));
		Assert.equals('git log', TokenTranscript.normalize('rtk proxy git log'));
	}

	public function testACallAndItsAnswerAreSummedUnderTheRow(): Void {
		final big: String = ''.lpad('x', 8004 * TokenTranscript.CHARS_PER_TOKEN - 32);
		final agent: AgentReading = TokenTranscript.read('a', transcript([
			user('slice S1 go'),
			call('t1', 'Bash', ['command' => 'hxq show f.hx']),
			result('t1', big),
			call('t2', 'Bash', ['command' => 'hxq show g.hx']),
			result('t2', 'ok')
		]), null);
		final stat: Null<ToolStat> = agent.tools['hxq show'];
		Assert.equals(2, stat?.calls);
		Assert.equals(1, stat?.over2k);
		Assert.equals(1, stat?.over5k);
		Assert.equals(big.length + 2, stat?.outChars);
	}

	public function testReadsOfAnHxFileAreSplitFromOtherReads(): Void {
		final agent: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Read', ['file_path' => '/w/src/A.hx']),
			result('t1', 'a'),
			call('t2', 'Read', ['file_path' => '/w/log.txt']),
			result('t2', 'b'),
			call('t3', 'mcp__plugin_workflow_wf__status', []),
			result('t3', 'c'),
			call('t4', 'mcp__other__ping', []),
			result('t4', 'd')
		]), null);
		Assert.equals(1, agent.tools['Read .hx']?.calls);
		Assert.equals(1, agent.tools['Read other']?.calls);
		Assert.equals(1, agent.tools['wf status']?.calls);
		Assert.equals(1, agent.tools['mcp other__ping']?.calls);
	}

	public function testAMessageWrittenPerContentBlockIsOneTurnWithItsLastUsage(): Void {
		final agent: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			assistant(
				'm1', 1000,
				'{"input_tokens":2,"output_tokens":5,"cache_read_input_tokens":10,'
				+ '"cache_creation":{"ephemeral_5m_input_tokens":7,"ephemeral_1h_input_tokens":3}}'
			),
			assistant(
				'm1', 4000,
				'{"input_tokens":2,"output_tokens":150,"cache_read_input_tokens":10,'
				+ '"cache_creation":{"ephemeral_5m_input_tokens":7,"ephemeral_1h_input_tokens":3}}'
			),
			assistant('m2', 9000, '{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":40}')
		]), null);
		Assert.equals(2, agent.turns.length);
		Assert.equals(150, agent.turns[0].output);
		Assert.equals(7, agent.turns[0].write5m);
		Assert.equals(3, agent.turns[0].write1h);
		Assert.equals(1000.0, agent.turns[0].start);
		Assert.equals(4000.0, agent.turns[0].end);
		Assert.equals(40, agent.turns[1].write5m);
		Assert.equals(0, agent.turns[1].write1h);
	}

	public function testTheSliceComesFromThePromptElseTheTaskLine(): Void {
		Assert.equals('TOKEN-AUDIT', TokenTranscript.sliceOfPrompt('You are the worker of anyparse slice TOKEN-AUDIT. Go.'));
		Assert.equals('DOC-1', TokenTranscript.sliceOfPrompt('Ты воркер среза DOC-1 проекта'));
		Assert.isNull(TokenTranscript.sliceOfPrompt('a slice ID is its directory name'));
		Assert.equals('W1b', TokenTranscript.sliceOfDescription('W1b enum-ctor conditional args'));
		Assert.isNull(TokenTranscript.sliceOfDescription('Cache TTL verification probe'));
		final fallback: AgentReading = TokenTranscript.read('a', transcript([user('do the thing')]), 'CAT-5B reviewer');
		Assert.equals('CAT-5B', fallback.slice);
		final prompted: AgentReading = TokenTranscript.read('a', transcript([user('your slice S146 now')]), 'CAT-5B reviewer');
		Assert.equals('S146', prompted.slice);
	}

	public function testTheRoleComesFromTheOpeningOfTheFirstPrompt(): Void {
		for (opening => role in [
			'You are the slice driver for anyparse slice A-1' => TokenTranscript.ROLE_DRIVER,
			'You are the task driver of' => TokenTranscript.ROLE_DRIVER,
			'You are the driver of the queue' => TokenTranscript.ROLE_DRIVER,
			'You are the worker of anyparse slice A-1' => TokenTranscript.ROLE_WORKER,
			'Ты воркер среза A-1 проекта' => TokenTranscript.ROLE_WORKER,
			'You review anyparse slice A-1, read-only' => TokenTranscript.ROLE_REVIEWER,
			'Ты ревьюер среза A-1 проекта' => TokenTranscript.ROLE_REVIEWER,
			'Срез ENG-8 в workflow-движке' => TokenTranscript.ROLE_ENGINE_WORKER,
			'Review engine slice ENG-8 READ-ONLY' => TokenTranscript.ROLE_ENGINE_REVIEWER,
			'Ревью среза ENG-8 в workflow-движке' => TokenTranscript.ROLE_ENGINE_REVIEWER,
			'You are the worker for slice **S233** of the queue' => TokenTranscript.ROLE_WORKER,
			'You are the READ-ONLY worker for slice **S233**' => TokenTranscript.ROLE_WORKER,
			'You are the worker of engine slice ENG-8' => TokenTranscript.ROLE_ENGINE_WORKER,
			'You are the pre-merge REVIEWER of slice A-1 in anyparse' => TokenTranscript.ROLE_REVIEWER,
			'You are the REVIEWER of anyparse slice **A-1**' => TokenTranscript.ROLE_REVIEWER,
			'You are the READ-ONLY adversarial reviewer of A-1' => TokenTranscript.ROLE_REVIEWER,
			'You are the READ-ONLY reviewer of A-1' => TokenTranscript.ROLE_REVIEWER,
			'Review slice A-1: branch `batch/hxqb-A1`' => TokenTranscript.ROLE_REVIEWER,
			'Measure the new lint' => TokenTranscript.ROLE_OTHER,
			'' => TokenTranscript.ROLE_OTHER
		]) {
			Assert.equals(role, TokenTranscript.roleOfPrompt(opening), opening);
			Assert.equals(role, TokenTranscript.read('a', transcript([user(opening)]), null).role, opening);
		}
	}

	public function testTheBoilerplateBeforeThePromptDoesNotHideItsRole(): Void {
		final lines: String = 'IMPORTANT: Override the default rule.\nDo NOT call start().\n';
		Assert.equals(TokenTranscript.ROLE_WORKER, TokenTranscript.roleOfPrompt('${lines}\nYou are the worker of anyparse slice A-1'));
		Assert.equals(TokenTranscript.ROLE_REVIEWER, TokenTranscript.roleOfPrompt('${lines}---\nYou review anyparse slice A-1, read-only'));
		Assert.equals(TokenTranscript.ROLE_OTHER, TokenTranscript.roleOfPrompt('${lines}just do it'));
	}

	public function testACommandBehindAnExportAndASemicolonIsKeyedByTheProgram(): Void {
		final agent: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Bash', ['command' => 'cd /w && export HXQ_BIN=/w/bin/apq.js; hxq show f.hx']),
			result('t1', 'ok'),
			call('t2', 'Bash', ['command' => 'HXQ_BIN=/w/bin/apq.js hxq show g.hx']),
			result('t2', 'ok')
		]), null);
		Assert.equals(2, agent.tools['hxq show']?.calls);
		Assert.equals('hxq show g.hx', agent.tools['hxq show']?.biggest[1].call);
		Assert.equals('hxq show a.hx; echo done', TokenTranscript.normalize('export X=/x\nhxq show a.hx; echo done'));
		Assert.equals('hxq patch f.hx <<\'EOF\'\nx\nEOF', TokenTranscript.normalize('export X=/x\nhxq patch f.hx <<\'EOF\'\nx\nEOF'));
	}

	public function testAKeyIsOneLineWhateverTheFirstWordOfTheCommandHolds(): Void {
		Assert.equals('sh **', TokenTranscript.bashKey('**\nfoo bar'));
		Assert.equals('sh foo', TokenTranscript.bashKey('/usr/bin/foo\tbar'));
	}

	public function testTheThreeLargestCallsOfARowAreKeptLargestFirstAndClipped(): Void {
		final long: String = ''.lpad('y', 300);
		final agent: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Bash', ['command' => 'git log one']),
			result('t1', 'a'),
			call('t2', 'Bash', ['command' => 'git log two']),
			result('t2', 'aaaaaa'),
			call('t3', 'Bash', ['command' => 'git log\n  three $long']),
			result('t3', 'aaaa'),
			call('t4', 'Bash', ['command' => 'git log four']),
			result('t4', 'aa'),
			call('t5', 'Read', ['file_path' => '/w/notes.txt']),
			result('t5', 'a')
		]), null);
		final biggest: Array<BigCall> = agent.tools['git log']?.biggest ?? [];
		Assert.equals(3, biggest.length);
		Assert.equals('git log four', biggest[2].call);
		Assert.equals('git log two', biggest[0].call);
		Assert.equals(6, biggest[0].outChars);
		Assert.isTrue(biggest[1].call.startsWith('git log three yyy'));
		Assert.equals(120, biggest[1].call.length);
		Assert.equals('/w/notes.txt', agent.tools['Read other']?.biggest[0].call);
	}

	public function testBypassesAndWritePayloadsAreCollectedPerAgent(): Void {
		final agent: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Bash', ['command' => 'sed -n 1,9p src/A.hx']),
			result('t1', 'r'),
			call('t2', 'Edit', ['file_path' => '/w/anyparse/src/A.hx', 'new_string' => '\tx\n\t\ty']),
			result('t2', 'r'),
			call('t3', 'Write', ['file_path' => '/tmp/scratch/src/B.hx', 'content' => 'z']),
			result('t3', 'r'),
			call('t4', 'Bash', ['command' => "hxq patch f.hx --write 'a\n====\n  b'"]),
			result('t4', 'r'),
			call('t5', 'Bash', ['command' => "sed -i '' 's/a/b/' src/A.hx"]),
			result('t5', 'r'),
			call('t6', 'Bash', ['command' => 'cd /tmp/fx && cat > src/F.hx']),
			result('t6', 'r')
		]), null);
		Assert.equals(1, agent.hxReads.length);
		Assert.equals(2, agent.hxWrites.length);
		Assert.isTrue(agent.hxWrites[0].endsWith('/w/anyparse/src/A.hx'));
		Assert.equals(TokenTranscript.indentation('\tx\n\t\ty'), 3);
		Assert.isTrue(agent.indentChars >= 5);
		Assert.isTrue(agent.writeChars > 0);
	}

	public function testLeadingBlanksAreCountedPerLine(): Void {
		Assert.equals(0, TokenTranscript.indentation('a\nb'));
		Assert.equals(5, TokenTranscript.indentation('\ta\n    b'));
	}

	public function testALineThatIsNotJsonIsSkipped(): Void {
		final agent: AgentReading = TokenTranscript.read('a', 'not json\n' + transcript([user('slice S2 x')]), null);
		Assert.equals('S2', agent.slice);
	}

	public function testAHookDeniedCallIsADeniedAttemptNotABypass(): Void {
		final denied: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Bash', ['command' => 'sed -n 1p src/A.hx']),
			failure('t1', 'PreToolUse:Bash hook error: hxq gate: viewing a parseable .hx via sed')
		]), null);
		Assert.equals(0, denied.hxReads.length);
		Assert.equals(1, denied.deniedReads.length);
		final ran: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Bash', ['command' => 'sed -n 1p src/A.hx']),
			result('t1', 'class A {}')
		]), null);
		Assert.equals(1, ran.hxReads.length);
		Assert.equals('sed -n 1p src/A.hx', ran.hxReads[0]);
		Assert.equals(0, ran.deniedReads.length);
	}

	public function testACallThatFailedByItselfStillRan(): Void {
		final agent: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Bash', ['command' => 'cp /tmp/x.bak src/A.hx']),
			failure('t1', 'cp: /tmp/x.bak: No such file')
		]), null);
		Assert.equals(1, agent.hxWrites.length);
		Assert.equals(0, agent.deniedWrites.length);
	}

	public function testAScriptThatWritesAHxIsASeparateCountAndADeniedWriteIsNotCounted(): Void {
		final script: String = "python3 - <<'EOF'\nopen('src/A.hx', 'w').write('x')\nEOF";
		final ran: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Bash', ['command' => script]),
			result('t1', '')
		]), null);
		Assert.equals(1, ran.scriptWrites.length);
		Assert.equals(0, ran.hxWrites.length);
		final denied: AgentReading = TokenTranscript.read('a', transcript([
			user('x'),
			call('t1', 'Bash', ['command' => script]),
			failure('t1', 'PreToolUse:Bash hook error: nope')
		]), null);
		Assert.equals(0, denied.scriptWrites.length);
		Assert.equals(1, denied.deniedWrites.length);
	}

	/** A transcript file is read a line at a time, whatever its line count: the file reading equals the reading of its text. */
	@:pin('guard')
	public function testATranscriptFileOfManyLinesIsReadLineByLineAndEqualsTheReadingOfItsText(): Void {
		final pairs: Int = 30000;
		final events: Array<String> = [user('slice STREAM-1 please'), call('wide', 'Bash', ['command' => 'git log'])];
		final probe: String = result('wide', '€');
		Assert.isTrue(probe.indexOf('€') >= 0);
		final euroAt: Int = events.join('\n').length + 1 + Bytes.ofString(probe.substr(0, probe.indexOf('€'))).length;
		events.push(result('wide', 'a'.lpad('a', TokenTranscript.CHUNK_BYTES - 1 - euroAt) + '€'));
		events.push(call('long', 'Bash', ['command' => 'git log']));
		events.push(result('long', 'y'.lpad('y', TokenTranscript.CHUNK_BYTES * 2) + 'é'));
		for (index in 0...pairs) {
			events.push(call('t$index', 'Bash', ['command' => 'git log']));
			events.push(result('t$index', 'commit $index'));
		}
		final text: String = transcript(events);
		TempDir.with(dir -> {
			File.saveContent(dir.file('agent-big.jsonl'), text);
			final streamed: AgentReading = TokenTranscript.readFile('big', dir.file('agent-big.jsonl'), null);
			final whole: AgentReading = TokenTranscript.read('big', text, null);
			Assert.equals(pairs + 2, streamed.tools['git log']?.calls);
			Assert.equals(whole.tools['git log']?.outChars, streamed.tools['git log']?.outChars);
			Assert.equals('STREAM-1', streamed.slice);
			Assert.equals(whole.role, streamed.role);
		});
	}

	/** The JSONL text of `events`, each a line of JSON. */
	private static function transcript(events: Array<String>): String {
		return events.join('\n');
	}

	private static function user(prompt: String): String {
		return '{"type":"user","message":{"role":"user","content":${JsonText.quote(prompt)}}}';
	}

	private static function call(id: String, name: String, input: Map<String, String>): String {
		final fields: Array<String> = [for (key => value in input) '${JsonText.quote(key)}:${JsonText.quote(value)}'];
		return '{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","cwd":"/w/anyparse","message":{"id":${JsonText.quote('m$id')},'
			+ '"model":"claude-opus-5-5","content":[{"type":"tool_use","id":${JsonText.quote(id)},"name":${JsonText.quote(name)},'
			+ '"input":{${fields.join(',')}}}]}}';
	}

	private static function result(id: String, text: String): String {
		return '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":${JsonText.quote(id)},'
			+ '"content":${JsonText.quote(text)}}]}}';
	}

	/** An assistant entry of the message `id` stamped `at` milliseconds after the epoch, `usage` its usage as JSON. */
	private static function assistant(id: String, at: Float, usage: String): String {
		return
			'{"type":"assistant","timestamp":${JsonText.quote(new js.lib.Date(at).toISOString())},"message":{"id":${JsonText.quote(id)},'
				+ '"model":"claude-opus-5-5","content":[],"usage":$usage}}';
	}

	private static function failure(id: String, text: String): String {
		return
			'{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":${JsonText.quote(id)},"is_error":true,'
				+ '"content":${JsonText.quote(text)}}]}}';
	}

}
