package unit.dev;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonFormat;
import anyparse.query.format.json.AstDumpJson;
import dev.ArmHead;
import dev.ArmHeadParser;
import dev.AstDumpJsonParser;
import dev.BatteryPlan;
import dev.BatteryPlanParser;
import dev.BatteryPlanWriter;
import dev.EdgeReadingJson;
import dev.EdgeReadingJsonParser;
import dev.EdgeReadingJsonWriter;
import dev.Expectation;
import dev.HookAnswer;
import dev.HookAnswerParser;
import dev.HookPayload;
import dev.HookPayloadParser;
import dev.HookPayloadWriter;
import dev.Probe;
import dev.Profile;
import dev.ProfileParser;
import dev.ReportRecords;
import dev.ReportRecordsParser;
import dev.SuiteFile;
import dev.SuiteFileParser;
import dev.SuiteInvocation;
import dev.SweepCatalog;
import dev.SweepCatalogParser;
import dev.SweepTrap;
import dev.TranscriptEntry;
import dev.TranscriptEntryParser;
import dev.TranscriptMessage;
import devkit.RawJson;
import devkit.TempDir;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * The developer tools read and write their JSON files through schema typedefs: a document already on disk, spelled here as
 * its tool left it, reads the same as it did through `haxe.Json`.
 */
@:nullSafety(Strict)
final class ToolDocumentsTest extends Test {

	public function testAnArmRecordReadsItsHeadAndIgnoresTheCut(): Void {
		final head: ArmHead = ArmHeadParser.parse(
			'{"name": "M-A", "type": "a.B", "method": "m", "find": ["x"], "replace": "y", "note": "n"}'
		);
		Assert.equals('M-A', head.name);
		Assert.equals('a.B', head.type);
		Assert.equals('m', head.method);
		Assert.isNull(ArmHeadParser.parse('{"name": "M-B"}').type);
		Assert.raises(() -> ArmHeadParser.parse('{"type": "a.B"}'));
	}

	public function testABatteryPlanReadsWithNullsForTheKeysItLeavesUnsetAndRoundTripsOnOneLine(): Void {
		final text: String = '{\n\t"repo": "/r",\n\t"work": "/w",\n\t"cache": "/c",\n\t"head": "abc",\n\t"base": null,\n'
			+ '\t"baseSuite": [3, 9],\n\t"shards": 4,\n\t"quick": false,\n\t"snapshot": true,\n\t"allowBlast": false,\n'
			+ '\t"allow": ["corpus"],\n\t"client": null,\n\t"jvmSkip": "no jvm",\n\t"run": "r1",\n\t"ownLease": true\n}';
		final plan: BatteryPlan = BatteryPlanParser.parse(text);
		Assert.isNull(plan.base);
		Assert.isNull(plan.client);
		Assert.same([3, 9], plan.baseSuite);
		Assert.equals('no jvm', plan.jvmSkip);
		Assert.same(['corpus'], plan.allow);
		final line: String = BatteryPlanWriter.write(plan, JsonFormat.instance.compactWriteOptions);
		Assert.equals(-1, line.indexOf('\n'));
		Assert.equals(-1, line.indexOf('null'));
		final again: BatteryPlan = BatteryPlanParser.parse(line);
		Assert.equals(4, again.shards);
		Assert.isTrue(again.ownLease);
		Assert.same([3, 9], again.baseSuite);
	}

	public function testAKitReadsEveryKeyItHolds(): Void {
		final text: String = '{"about": "a kit", "files": {"A.hx": "class A {}\\n"}, "compile": {"args": ['
			+ '"-main", "A"], "defines": [["x"]], "run": true}, "invocations": [{"name": "one", "note": "n", '
			+ '"knownDefect": "d", "fixpoint": "fx", "outShape": "^a", "outMinLines": 3, "argv": ["hxq", "fmt"], "stdin": '
			+ '"s", "files": {"B.hx": "b"}, "compile": {"args": ["-main", "B"]}, "expect": {"exit": 0, "out": "o", "err": '
			+ '"", "files": "f", "compiles": [true], "sameRun": [false], "onePass": true, "commentsKept": false}}]}';
		final kit: SuiteFile = SuiteFileParser.parse(text);
		final row: SuiteInvocation = (kit.invocations ?? [])[0];
		Assert.equals('a kit', kit.about);
		Assert.equals('class A {}\n', RawJson.string(JValueTools.field(kit.files, 'A.hx')));
		Assert.same(['-main', 'A'], kit.compile?.args);
		Assert.equals(true, kit.compile?.run);
		Assert.same([['x']], kit.compile?.defines);
		Assert.equals(3, row.outMinLines);
		Assert.equals('n', row.note);
		Assert.equals('d', row.knownDefect);
		Assert.equals('fx', row.fixpoint);
		Assert.equals('^a', row.outShape);
		Assert.same(['hxq', 'fmt'], row.argv);
		Assert.equals('s', row.stdin);
		Assert.equals('b', RawJson.string(JValueTools.field(row.files, 'B.hx')));
		Assert.same(['-main', 'B'], row.compile?.args);
		Assert.equals('o', row.expect?.out);
		Assert.equals(0, row.expect?.exit);
		Assert.equals('f', row.expect?.files);
		Assert.same([true], row.expect?.compiles);
		Assert.same([false], row.expect?.sameRun);
		Assert.equals(true, row.expect?.onePass);
		Assert.equals(false, row.expect?.commentsKept);
	}

	public function testATrapCatalogReadsItsFilesAsAnObjectAndItsProbes(): Void {
		final catalog: SweepCatalog = SweepCatalogParser.parse(
			'{"traps": [{"name": "t", "files": {"A.hx": ["class A {}", ""]}, "probes": [{"file": "A.hx"}, {'
			+ '"file": "B.hx", "text": ["x"]}]}]}'
		);
		final trap: SweepTrap = catalog.traps[0];
		Assert.equals('t', trap.name);
		Assert.same(['class A {}', ''], RawJson.strings(JValueTools.field(trap.files, 'A.hx')));
		Assert.isNull(trap.probes[0].text);
		Assert.same(['x'], trap.probes[1].text);
	}

	public function testAProfileReadsItsTreeAndItsSamples(): Void {
		final profile: Profile = ProfileParser.parse(
			'{"nodes": [{"id": 1, "callFrame": {"functionName": "f", "url": "", "lineNumber": 0}, "children": [2]},'
			+ ' {"id": 2, "callFrame": {"functionName": "", "url": "u.js", "lineNumber": 3}}], "samples": [2, 1], "timeDeltas": [1.5, 2]}'
		);
		Assert.equals(2, profile.nodes.length);
		Assert.same([2], profile.nodes[0].children);
		Assert.isNull(profile.nodes[1].children);
		Assert.equals('u.js', profile.nodes[1].callFrame.url);
		Assert.same([1.5, 2.0], profile.timeDeltas);
	}

	public function testALintReportInItsEnvelopeAndAnAstDumpReadAsTheyAreProduced(): Void {
		final report: ReportRecords = ReportRecordsParser.parse(
			'{"findings":[{"file": "A.hx", "line": 3, "col": 5, "severity": "info", "rule": "r", "message": "2 statements duplicated '
			+ 'from A.hx:9"}]}'
		);
		Assert.equals(3, report.findings[0].line);
		Assert.equals('A.hx', report.findings[0].file);
		final ast: AstDumpJson = AstDumpJsonParser.parse(
			'{"file": "A.hx", "tree": {"kind": "Module", "children": [{"kind": "Class", "span": {"start": [1, 1], "end": ['
			+ '4, 2]}, "children": []}]}}'
		);
		Assert.same([4, 2], ast.tree.children[0].span?.end);
	}

	public function testTheEdgesOfARevisionRoundTripAsPairs(): Void {
		final reading: EdgeReadingJson = { files: ['A.hx'], edges: [['A.f -> A.g', 'A.hx'], ['A.g -> B.h', '']] };
		final line: String = EdgeReadingJsonWriter.write(reading, JsonFormat.instance.compactWriteOptions);
		Assert.equals('{"files":["A.hx"],"edges":[["A.f -> A.g","A.hx"],["A.g -> B.h",""]]}', line);
		Assert.same(reading.edges, EdgeReadingJsonParser.parse(line).edges);
	}

	public function testAHookPayloadKeepsItsSnakeCaseKeysAndAnAnswerItsCamelCaseOnes(): Void {
		final line: String = HookPayloadWriter.write({
			sessionId: 's',
			cwd: '/',
			toolName: 'Bash',
			toolInput: { command: 'ls' },
			toolResponse: { stdout: 'o', stderr: '' }
		}, JsonFormat.instance.compactWriteOptions);
		Assert.equals(
			'{"session_id":"s","cwd":"/","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"o","stderr":""}}',
			line
		);
		final payload: HookPayload = HookPayloadParser.parse(line);
		Assert.equals('s', payload.sessionId);
		Assert.equals('ls', payload.toolInput?.command);
		final answer: HookAnswer = HookAnswerParser.parse('{"hookSpecificOutput": {"permissionDecision": "deny", "extra": 1}}');
		Assert.equals('deny', answer.hookSpecificOutput?.permissionDecision);
		Assert.isNull(HookAnswerParser.parse('{}').hookSpecificOutput);
	}

	public function testATranscriptLineReadsItsUsageUnderTheKeysItIsSpelledWith(): Void {
		final entry: TranscriptEntry = TranscriptEntryParser.parse(
			'{"type": "assistant", "timestamp": "2026-01-01T00:00:00Z", "cwd": "/w", "uuid": "u", "message": {"id": "m", "model": "x",'
			+ ' "content": [{"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": "ls"}}],'
			+ ' "usage": {"input_tokens": 1, "output_tokens": 2, "cache_read_input_tokens": 3, "cache_creation_input_tokens": 4,'
			+ ' "cache_creation": {"ephemeral_5m_input_tokens": 5, "ephemeral_1h_input_tokens": 6}}}}'
		);
		final message: Null<TranscriptMessage> = entry.message;
		Assert.equals('m', message?.id);
		Assert.equals(2, message?.usage?.outputTokens);
		Assert.equals(3, message?.usage?.cacheReadInputTokens);
		Assert.equals(4, message?.usage?.cacheCreationInputTokens);
		Assert.equals(5, message?.usage?.cacheCreation?.ephemeral5mInputTokens);
		Assert.equals(6, message?.usage?.cacheCreation?.ephemeral1hInputTokens);
		final block: JValue = RawJson.items(message?.content)[0];
		Assert.equals('Bash', RawJson.stringAt(block, 'name'));
		Assert.equals('{"command":"ls"}', RawJson.print(JValueTools.field(block, 'input') ?? JNull));
	}

	public function testRecordingAKitReplacesTheExpectationsAndNothingElse(): Void {
		final top: String = '{\n\t"about": "k",\n\t"extra": {\n\t\t"n": 3\n\t},\n\t"invocations": [\n\t\t{\n\t\t\t"name": "one",\n';
		final argv: String = '\t\t\t"argv": [\n\t\t\t\t"hxq"\n\t\t\t]';
		final old: String = '\t\t\t"expect": {\n\t\t\t\t"exit": 0,\n\t\t\t\t"out": "o",\n\t\t\t\t"err": "",\n\t\t\t\t"files": "f"\n\t\t\t}';
		final fresh: String = '\t\t\t"expect": {\n\t\t\t\t"exit": 1,\n\t\t\t\t"out": "p",\n\t\t\t\t"err": "e",\n\t\t\t\t"files": "g",\n'
			+ '\t\t\t\t"compiles": [\n\t\t\t\t\ttrue\n\t\t\t\t]\n\t\t\t}';
		final close: String = '\n\t\t}\n\t]\n}\n';
		final answer: Expectation = {
			exit: 1,
			out: 'p',
			err: 'e',
			files: 'g',
			compiles: [true]
		};
		TempDir.with(dir -> {
			final file: String = dir.file('kit.json');
			File.saveContent(file, '$top$argv,\n$old$close');
			Probe.write(file, [
				{
					answer: answer,
					out: '',
					err: '',
					failure: ''
				}
			]);
			Assert.equals(
				'$top$argv,\n$fresh$close', File.getContent(file), 'the expectation is replaced where it stood, the rest byte for byte'
			);
			File.saveContent(file, '$top$argv$close');
			Probe.write(file, [
				{
					answer: answer,
					out: '',
					err: '',
					failure: ''
				}
			]);
			Assert.equals('$top$argv,\n$fresh$close', File.getContent(file), 'a row with none takes it last');
		});
	}

}
