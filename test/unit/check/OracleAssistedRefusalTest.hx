package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check;
import anyparse.check.CompilerOracle;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.Cli;
import anyparse.query.cli.command.LintFixVerify;
import anyparse.runtime.Span;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * The oracle-assisted phase of `lint --fix` reports what the writer-emit gate refused, and a refused
 * annotation costs only itself.
 *
 * `LintFixVerify.applyOracleAssistedFixes` used to canonicalise a file's whole assisted edit set and
 * drop it through `case _:` on any refusal: no decline line, no count on the summary, no ledger row,
 * and every other annotation in the file lost with the refused one. The phase now goes through the
 * safe loop's salvage (`LintFixDriver.salvageFileLintEdits`, a rule at a time and a refused rule a
 * finding at a time), names each refused file on a line of its own, and gives the refusal to the
 * rule's ledger row.
 */
@:nullSafety(Strict)
final class OracleAssistedRefusalTest extends Test {

	/** Two literals, one per finding; the writer's fixed point under the compiled defaults. */
	private static final SOURCE: String =
		'package p;\n\nclass C {\n\n\tpublic function f():String {\n\t\treturn "aaa" + "bbb";\n\t}\n\n}\n';

	#if (sys || nodejs)
	/** One local only the compiler can type, in a file that is NOT the writer's fixed point. */
	private static final DRIFTED: String =
		'class Main {\n\n\tstatic function main() {\n\t\tvar comp = [for (i in 0...3) i];\n\t\ttrace(  comp);\n\t}\n\n}\n';
	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	public function new(): Void {
		super();
	}

	/**
	 * One rule, two findings, one of them un-writable (it leaves an unterminated string): the
	 * writable one lands, the other is blamed at its own site, and the count is the edit that landed.
	 * The groups are hand-built so the refusal and the split are exactly the facts under test.
	 */
	@:pin('control')
	@:killer('M-ASSISTED-SPLIT-NONE')
	@:killer('M-ASSISTED-SALVAGE-NONE')
	@:killer('M-ASSISTED-SALVAGED-COUNT-ALL')
	public function testARefusedFindingCostsItsAssistedRuleNothingElse(): Void {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		Assert.isTrue(CanonicalEdit.isWriterCanonical(SOURCE, plugin, null), 'the fixture must be the writer fixed point');
		final good: Int = SOURCE.indexOf('"aaa"');
		final bad: Int = SOURCE.indexOf('"bbb"');
		final goodFinding: Violation = finding(good);
		final badFinding: Violation = finding(bad);
		final goodEdit: { span: Span, text: String } = { span: new Span(good, good + 5), text: '"AAA"' };
		final badEdit: { span: Span, text: String } = { span: new Span(bad, bad + 5), text: '"BBB' };
		final whole: RuleEdits = group([goodFinding, badFinding], [goodEdit, badEdit]);
		final parts: Array<RuleEdits> = [group([goodFinding], [goodEdit]), group([badFinding], [badEdit])];
		final blamed: Array<String> = [];
		final settled: Null<{ text: String, edits: Int }> = LintFixVerify.settleAssistedFile(
			SOURCE, [whole], plugin, null, blamed, _ -> parts
		);
		if (settled == null) {
			Assert.fail('the refusal took the writable annotation with it');
			return;
		}
		Assert.isTrue(settled.text.indexOf('return "AAA" + "bbb";') != -1, 'the writable edit landed, the other did not: ${settled.text}');
		Assert.equals(1, settled.edits, 'the count is the edits that landed, not the edits asked for');
		Assert.equals(1, blamed.length, 'one finding is blamed: $blamed');
		Assert.isTrue(blamed[0].indexOf('r-assisted at 6:') == 0, 'and it is named at its site: ${blamed[0]}');
		Assert.notNull(parts[1].refusal, 'the refused part carries the gate sentence');
		Assert.isNull(parts[0].refusal, 'the landed part carries none');
	}

	/**
	 * A file the writer cannot round-trip: the phase names it, counts it on the summary line and
	 * gives the refusal to the rule's ledger row. Driven through the real `apq lint --fix` with a real
	 * oracle; skips with no `haxe` on PATH.
	 */
	@:pin('control')
	@:killer('M-ASSISTED-REFUSAL-SILENT')
	@:killer('M-ASSISTED-REFUSAL-LEDGER-NONE')
	public function testAnAssistedRefusalIsReported(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final apqlint: String = '{"compilerOracle":"check.hxml","rules":{"explicit-local-type":{"enabled":true}}}';
		final dir: String = CliFixture.writeDir('assistedrefusal', [
			{ name: 'Main.hx', source: DRIFTED },
			{ name: 'check.hxml', source: HXML },
			{ name: 'apqlint.json', source: apqlint }
		]);
		final err: String = CliFixture.captureStderr(() -> Cli.run(['lint', '--fix', '--verbose', '--rule', 'explicit-local-type', dir]));
		Assert.equals(DRIFTED, File.getContent('$dir/Main.hx'), 'nothing is written to a file the writer refuses');
		Assert.isTrue(err.indexOf('oracle-assisted REFUSED $dir/Main.hx: file is not in canonical form') != -1, 'the file is named:\n$err');
		Assert.isTrue(err.indexOf('1 file(s) REFUSED by the writer (1 edit(s) left report-only)') != -1, 'and counted:\n$err');
		Assert.isTrue(
			err.indexOf('explicit-local-type: 1 edit set(s) refused — file is not in canonical form') != -1, 'and ledgered:\n$err'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('assistedrefusal', [
			{ name: 'Main.hx', source: 'class Main {\n\n\tstatic function main() {}\n\n}\n' },
			{ name: 'check.hxml', source: HXML }
		]);
		final ok: Bool = CompilerOracle.typecheck('check.hxml', dir).match(Confirmed);
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

	private static function finding(at: Int): Violation {
		return {
			file: 'C.hx',
			span: new Span(at, at + 5),
			rule: 'r-assisted',
			severity: Severity.Warning,
			message: 'a literal'
		};
	}

	private static function group(findings: Array<Violation>, edits: Array<{ span: Span, text: String }>): RuleEdits {
		return {
			rule: 'r-assisted',
			findings: findings,
			edits: edits,
			carried: [],
			overlapped: false,
			refusal: null
		};
	}

}
