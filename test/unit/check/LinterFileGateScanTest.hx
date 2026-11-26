package unit.check;

import anyparse.check.Check.FileGated;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.RuleBase;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/** A rule that reports one finding per file it is handed, and refuses the files under `skipped/`. */
private final class ScanProbeRule extends RuleBase implements FileGated {

	public function new() {
		super('scan-probe', 'one finding per scanned file', RuleCategory.Docs);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return files.map(entry -> ({
			file: entry.file,
			span: null,
			rule: id(),
			severity: Severity.Info,
			message: 'scanned'
		}: Violation));
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function skipReason(file: String, config: LintConfig): Null<String> {
		return file.indexOf('skipped/') == 0 ? 'config-excluded' : null;
	}

}

/**
 * `Linter.collect` hands a `FileGated` rule only the files its own file gate keeps: a file the gate refuses is not
 * scanned, so nothing in it can be reported or can colour what the rule says about another file.
 */
@:nullSafety(Strict)
final class LinterFileGateScanTest extends Test {

	/** The rule sees the kept file and never the refused one. */
	@:pin('control')
	@:killer('M-GATE-COLLECT-BYPASS')
	public function testAFileTheGateRefusesIsNotScanned(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'skipped/A.hx', source: 'class A {}' },
			{ file: 'kept/B.hx', source: 'class B {}' }
		];
		final config: LintConfig = LintConfig.parse('{"rules":{"scan-probe":{"enabled":true}}}');
		final found: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), [new ScanProbeRule()], _ -> config, true);
		Assert.same(['kept/B.hx'], found.map(v -> v.file));
	}

}
