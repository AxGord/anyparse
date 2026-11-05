package unit.dev;

import anyparse.grammar.json.JsonFormat;
import anyparse.grammar.json.JsonText;
import dev.AuditReport;
import dev.SliceStats.Landing;
import dev.TokenAudit;
import dev.TokenReport;
import dev.TokenReportParser;
import dev.TokenReportWriter;
import dev.TokenTranscript;
import devkit.Args.UsageError;
import devkit.Cmd.cmd;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * `dev token-audit`: which files of a directory are transcripts, a transcript reached by two links counting once, the task
 * line beside a transcript naming its slice, and the text report carrying every section.
 */
@:nullSafety(Strict)
final class TokenAuditTest extends Test {

	private static inline final TRANSCRIPT: String = '{"type":"user","message":{"role":"user","content":"hello"}}\n'
		+ '{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m1","model":"claude-sonnet-5-5","content":'
		+ '[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git log"}}],"usage":{"input_tokens":3,'
		+ '"output_tokens":4,"cache_read_input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":6,"ephemeral_1h_input_tokens":0}}}}\n'
		+ '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"commit abc"}]}}\n';
	private static inline final MS_PER_SECOND: Float = 1000;
	private static inline final SECONDS_PER_HOUR: Float = 3600;
	private static inline final DEC_1: Float = 1764547200;
	private static inline final DEC_2: Float = 1764633600;
	private static inline final JAN_1: Float = 1767225600;
	private static inline final JAN_3: Float = 1767398400;

	/** A `.meta.json` as Claude Code writes one: the task beside keys of every JSON kind this reader does not model. */
	private static inline final META: String = '{"agentType":"general-purpose","description":"CAT-9 reviewer","isBuiltIn":false,"toolUseId":"toolu_01",'
		+ '"worktreePath":null,"model":{"name":"m","effort":["high"]},"startedAt":1767225600,"cwd":"/x"}';

	public function testATranscriptReachedByTwoLinksCountsOnceAndOtherFilesAreSkipped(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('agent-a.jsonl'), TRANSCRIPT);
			File.saveContent(dir.file('agent-a.meta.json'), META);
			js.node.Fs.symlinkSync(dir.file('agent-a.jsonl'), dir.file('link.output'));
			js.node.Fs.symlinkSync(dir.file('missing.jsonl'), dir.file('dangling.output'));
			File.saveContent(dir.file('notes.txt'), TRANSCRIPT);
			final agents: Array<AgentReading> = TokenAudit.readDirectories([dir.path]);
			Assert.equals(1, agents.length);
			Assert.equals('agent-a', agents[0].id);
			Assert.equals('CAT-9', agents[0].slice);
			Assert.equals(1, agents[0].tools['git log']?.calls);
		});
	}

	public function testTheTextReportCarriesEverySectionAndTheJsonRoundTrips(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('agent-a.jsonl'), TRANSCRIPT);
			final report: AuditReport = TokenReport.summarize(TokenAudit.readDirectories([dir.path]), ['CAT-9']);
			final text: String = TokenAudit.render(report, 5);
			for (section in [
				'agents 1;',
				'tool ',
				'role ',
				'    3 tok  git log',
				'model ',
				'slice ',
				'cache writes:',
				'rewrite gap:',
				'write payloads',
				'* sizes are'
			]) Assert.isTrue(text.contains(section), 'missing $section');
			Assert.isTrue(text.contains('landed slices 0'));
			final parsed: AuditReport = TokenReportParser.parse(TokenReportWriter.write(report, JsonFormat.instance.defaultWriteOptions));
			Assert.equals(1, parsed.agents);
			Assert.equals(report.cost, parsed.cost);
			Assert.equals('git log', parsed.roles[0].key);
			Assert.equals('git log', parsed.roles[0].biggest[0].call);
		});
	}

	public function testEachRoleRowIsFollowedByItsOwnCallsEvenWhenAKeyHadANewline(): Void {
		final agent: AgentReading = TokenTranscript.read('a', '{"type":"user","message":{"role":"user","content":"x"}}\n' + [
			for (i => command in ['hxq show two.hx', '**\nfoo bar', 'date']) {
				final size: Int = [400, 200, 40][i];
				'{"type":"assistant","message":{"id":"m$i","content":[{"type":"tool_use","id":"t$i","name":"Bash","input":'
					+ '{"command":${JsonText.quote(command)}}'
					+ '}]}}\n{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t$i","content":"'
					+ ''.lpad('x', size)
					+ '"}]}}';
			}
		].join('\n'), null);
		final lines: Array<String> = TokenAudit.render(TokenReport.summarize([agent], null), 5).split('\n');
		var at: Int = -1;
		for (i => line in lines) if (line.startsWith('other') && line.contains('hxq show')) at = i;
		Assert.isTrue(at >= 0);
		Assert.equals('    100 tok  hxq show two.hx', lines[at + 1]);
		Assert.isTrue(lines[at + 2].contains('sh **'));
		Assert.equals('    50 tok  ** foo bar', lines[at + 3]);
		Assert.isTrue(lines[at + 4].contains('sh date'));
		Assert.equals('    10 tok  date', lines[at + 5]);
	}

	public function testTheSubagentDirectoriesOfEverySessionOfAProjectAreFoundAndOthersSkipped(): Void {
		TempDir.with(dir -> {
			for (session in ['s2', 's1']) {
				FileSystem.createDirectory(dir.file(session));
				FileSystem.createDirectory(dir.file('$session/subagents'));
			}
			FileSystem.createDirectory(dir.file('memory'));
			File.saveContent(dir.file('s1.jsonl'), TRANSCRIPT);
			Assert.same([dir.file('s1/subagents'), dir.file('s2/subagents')], TokenAudit.subagentDirs(dir.path));
			Assert.raises(() -> TokenAudit.subagentDirs(dir.file('missing')), UsageError);
		});
	}

	public function testTheProjectDirectoryNamesATreeByItsPathWithEveryOddCharacterDashed(): Void {
		final project: String = TokenAudit.projectOf('/Users/a.b/dev/x_y');
		Assert.isTrue(project.endsWith('/projects/-Users-a-b-dev-x-y'));
	}

	public function testAWindowKeepsTheAgentsThatBeganInsideItAndThoseOfASliceThatLandedInIt(): Void {
		final kept: AgentReading = TokenTranscript.read('kept', transcript('KEEP-1', '2026-01-01'), null);
		final dropped: AgentReading = TokenTranscript.read('dropped', transcript('DROP-1', '2026-01-01'), null);
		final late: AgentReading = TokenTranscript.read('late', transcript('LATE-1', '2026-02-01'), null);
		final empty: AgentReading = TokenTranscript.read('empty', '', null);
		final all: Array<AgentReading> = [kept, dropped, late, empty];
		final edge: Float = kept.turns[0].start;
		Assert.equals(4, TokenAudit.startedFrom(all, 0, []).length);
		Assert.same(['kept', 'dropped', 'late'], TokenAudit.startedFrom(all, edge, []).map(a -> a.id));
		Assert.same(['late'], TokenAudit.startedFrom(all, edge + 1, []).map(a -> a.id));
		Assert.same(['kept', 'late'], TokenAudit.startedFrom(all, edge + 1, ['KEEP-1']).map(a -> a.id));
	}

	public function testASliceLineCarriesItsOutputAndLandedAndAMissingSliceHasNone(): Void {
		final prompt: String = '{"type":"user","message":{"role":"user","content":"You are the worker of anyparse slice CAT-9."}}\n';
		final agent: AgentReading = TokenTranscript.read('a', prompt + TRANSCRIPT.substr(TRANSCRIPT.indexOf('\n') + 1), null);
		final report: AuditReport = TokenReport.summarize([agent], ['CAT-9']);
		final line: Null<String> = TokenAudit.sliceLine(report, 'CAT-9');
		Assert.notNull(line);
		Assert.isTrue(line?.contains('agents 1; turns 1; output 4 tok;') == true);
		Assert.isTrue(line?.endsWith('landed yes') == true);
		Assert.isNull(TokenAudit.sliceLine(report, 'CAT-8'));
		Assert.isTrue(TokenAudit.sliceLine(TokenReport.summarize([agent], []), 'CAT-9')?.endsWith('landed no') == true);
	}

	public function testALandingMarksOnlyASliceWithAnAgentThatBeganAtOrBeforeIt(): Void {
		final early: AgentReading = TokenTranscript.read('early', transcript('W-1', '2026-01-01'), null);
		final late: AgentReading = TokenTranscript.read('late', transcript('W-2', '2026-02-01'), null);
		final empty: AgentReading = TokenTranscript.read('empty', '', null);
		final started: Float = early.turns[0].start / MS_PER_SECOND;
		final landings: Array<Landing> = [
			landing('W-1', started),
			landing('W-2', started + SECONDS_PER_HOUR),
			landing('W-3', started)
		];
		Assert.same(['W-1'], TokenAudit.landedIds(landings, [early, late, empty]));
		Assert.same([], TokenAudit.landedIds([landing('W-1', started - 1)], [early]));
	}

	public function testTheCommandWindowsTheLandingsAndTheAgentsByTheCommitAndReadsLandedWithoutAWindow(): Void {
		TempDir.with(dir -> {
			final sessions: String = dir.file('project/s1/subagents');
			FileSystem.createDirectory(dir.file('project'));
			FileSystem.createDirectory(dir.file('project/s1'));
			FileSystem.createDirectory(sessions);
			File.saveContent('$sessions/agent-in.jsonl', transcript('SLICE-IN', '2026-01-02'));
			File.saveContent('$sessions/agent-out.jsonl', transcript('SLICE-OUT', '2026-01-02'));
			File.saveContent('$sessions/agent-old.jsonl', transcript('SLICE-OLD', '2025-12-01'));
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main']);
			git(repo, ['commit', '-q', '--allow-empty', '-m', 'base']);
			git(repo, ['commit', '-q', '--allow-empty', '-m', 'old\n\nSlice: SLICE-OLD']);
			git(repo, ['commit', '-q', '--allow-empty', '-m', 'out\n\nSlice: SLICE-OUT'], DEC_2);
			git(repo, ['commit', '-q', '--allow-empty', '-m', 'window'], JAN_1);
			git(repo, ['commit', '-q', '--allow-empty', '-m', 'in\n\nSlice: SLICE-IN'], JAN_3);
			final windowed: String = dir.file('windowed.json');
			Assert.equals(0, TokenAudit.main([
				'--repo',
				repo,
				'--project',
				dir.file('project'),
				'--since',
				'HEAD~1',
				'--json',
				windowed
			]));
			Assert.same([true, false], landedOf(windowed, ['SLICE-IN', 'SLICE-OUT']));
			Assert.isFalse(hasRow(windowed, 'SLICE-OLD'));
			final whole: String = dir.file('whole.json');
			Assert.equals(0, TokenAudit.main([
				'--repo',
				repo,
				'--project',
				dir.file('project'),
				'--slice',
				'SLICE-IN',
				'--json',
				whole
			]));
			Assert.same([true, false], landedOf(whole, ['SLICE-IN', 'SLICE-OUT']));
			Assert.same([true], landedOf(whole, ['SLICE-OLD']));
			Assert.equals(1, TokenAudit.main(['--repo', repo, '--project', dir.file('project'), '--slice', 'NO-SUCH']));
		});
	}

	/** A report with no landed set leaves `landed` out of its JSON, and reading that JSON back leaves it null. */
	public function testAnUnsetOptionalKeyIsLeftOutOfTheWrittenReport(): Void {
		final report: AuditReport = TokenReport.summarize([], null);
		final json: String = TokenReportWriter.write(report, JsonFormat.instance.defaultWriteOptions);
		Assert.isFalse(json.contains('"landed"'));
		Assert.isNull(TokenReportParser.parse(json).landed);
		Assert.isTrue(TokenReportWriter.write(TokenReport.summarize([], []), JsonFormat.instance.defaultWriteOptions).contains('"landed"'));
	}

	private static function landedOf(file: String, slices: Array<String>): Array<Bool> {
		final report: AuditReport = TokenReportParser.parse(File.getContent(file));
		return [for (slice in slices) report.slices.filter(row -> row.slice == slice)[0].landed];
	}

	private static function transcript(slice: String, day: String): String {
		return '{"type":"user","message":{"role":"user","content":"You are the worker of anyparse slice $slice."}}\n'
			+ TRANSCRIPT.substr(TRANSCRIPT.indexOf('\n') + 1).replace('2026-01-01', day);
	}

	private static function landing(id: String, landed: Float): Landing {
		return {
			id: id,
			commit: 'c',
			base: 'b',
			branch: 'b..c',
			landed: landed,
			started: landed,
			rounds: null,
			tokens: null
		};
	}

	/** `git <words>` in `repo`, authored and committed at `at` seconds. */
	private static function git(repo: String, words: Array<String>, at: Float = DEC_1): Void {
		cmd('git -c user.name=audit -c user.email=audit@example.com -c commit.gpgsign=false -C $repo $words')
			.env('GIT_AUTHOR_DATE', '@${Std.int(at)} +0000')
			.env('GIT_COMMITTER_DATE', '@${Std.int(at)} +0000')
			.run()
			.check();
	}

	private static function hasRow(file: String, slice: String): Bool {
		final report: AuditReport = TokenReportParser.parse(File.getContent(file));
		return report.slices.exists(row -> row.slice == slice);
	}

}
