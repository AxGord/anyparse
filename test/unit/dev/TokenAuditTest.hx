package unit.dev;

import dev.TokenAudit;
import dev.TokenReport;
import dev.TokenTranscript.AgentReading;
import devkit.TempDir;
import haxe.Json;
import sys.io.File;
import utest.Assert;
import utest.Test;

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

	public function testATranscriptReachedByTwoLinksCountsOnceAndOtherFilesAreSkipped(): Void {
		TempDir.with(dir -> {
			File.saveContent(dir.file('agent-a.jsonl'), TRANSCRIPT);
			File.saveContent(dir.file('agent-a.meta.json'), '{"description":"CAT-9 reviewer"}');
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
			final report: Report = TokenReport.summarize(TokenAudit.readDirectories([dir.path]), ['CAT-9']);
			final text: String = TokenAudit.render(report, 5);
			for (section in [
				'agents 1;',
				'tool ',
				'model ',
				'slice ',
				'cache writes:',
				'rewrite gap:',
				'write payloads',
				'* sizes are'
			]) {
				Assert.isTrue(text.contains(section), 'missing $section');
			}
			Assert.isTrue(text.contains('landed slices 0'));
			final parsed: Report = Json.parse(Json.stringify(report));
			Assert.equals(1, parsed.agents);
			Assert.equals(report.cost, parsed.cost);
		});
	}

}
