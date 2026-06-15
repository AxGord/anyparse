package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The project-level `apqlint.json` config: the pure `LintConfig.parse`
 * accessors (enabled / severity / int option, plus malformed-input tolerance)
 * and the `Linter.run` severity remap that rewrites a real finding's severity
 * from the config. Enable-filtering and the complexity-threshold option are
 * exercised end-to-end (they need the CLI / disk) in `LintConfigCliTest`.
 */
class LintConfigTest extends Test {

	public function testEnabledDefaultsTrue(): Void {
		final cfg: LintConfig = LintConfig.parse('{}');
		Assert.isTrue(cfg.enabledFor('naming'));
	}

	public function testEnabledExplicitFalse(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"naming":{"enabled":false}}}');
		Assert.isFalse(cfg.enabledFor('naming'));
		Assert.isTrue(cfg.enabledFor('complexity'), 'an unlisted rule stays enabled');
	}

	public function testSeverityOverrideParsed(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"naming":{"severity":"error"},"unused-import":{"severity":"info"}}}');
		Assert.equals(Severity.Error, cfg.severityFor('naming'));
		Assert.equals(Severity.Info, cfg.severityFor('unused-import'));
		Assert.isNull(cfg.severityFor('complexity'), 'no override yields null');
	}

	public function testUnknownSeverityIsNull(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"naming":{"severity":"nope"}}}');
		Assert.isNull(cfg.severityFor('naming'));
	}

	public function testIntOption(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"complexity":{"max":15}}}');
		Assert.equals(15, cfg.intOption('complexity', 'max'));
		Assert.isNull(cfg.intOption('complexity', 'absent'), 'absent key yields null');
		Assert.isNull(cfg.intOption('naming', 'max'), 'unlisted rule yields null');
	}

	public function testMalformedJsonIsEmpty(): Void {
		final cfg: LintConfig = LintConfig.parse('not json at all');
		Assert.isTrue(cfg.enabledFor('naming'), 'garbage degrades to an empty (no-op) config');
		Assert.isNull(cfg.severityFor('naming'));
	}

	public function testLinterAppliesSeverityOverride(): Void {
		final src: String = 'package p;\nimport a.b.Unused;\nclass C {}';
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: src }];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();

		final base: Array<Violation> = Linter.run(files, plugin, [new UnusedImport()]);
		Assert.equals(1, base.length);
		Assert.equals(Severity.Warning, base[0].severity, 'unused-import is Warning by default');

		final promoted: Array<Violation> = Linter.run(
			files, plugin, [new UnusedImport()], LintConfig.parse('{"rules":{"unused-import":{"severity":"error"}}}')
		);
		Assert.equals(1, promoted.length);
		Assert.equals(Severity.Error, promoted[0].severity, 'the config promotes it to Error');
	}

	public function testMalformedOptionsAreIgnored(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"complexity":{"max":"oops"},"naming":{"enabled":"yes","severity":5}}}');
		Assert.isNull(cfg.intOption('complexity', 'max'), 'a non-number max is ignored (no-op), not coerced to 0/1');
		Assert.isTrue(cfg.enabledFor('naming'), 'a non-bool enabled is treated as unset (enabled)');
		Assert.isNull(cfg.severityFor('naming'), 'a non-string severity yields no override');
	}

}
