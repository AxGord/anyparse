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
		// Declaring stub keeps the out-of-scope import a verifiable Warning.
		final files: Array<{ file: String, source: String }> = [
			{ file: 'C.hx', source: src },
			{ file: 'a/b/Unused.hx', source: 'package a.b;\nclass Unused {}' }
		];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();

		final base: Array<Violation> = Linter.run(files, plugin, [new UnusedImport()]);
		Assert.equals(1, base.length);
		Assert.equals(Severity.Warning, base[0].severity, 'unused-import is Warning by default');

		final promoted: Array<Violation> = Linter.run(
			files, plugin, [new UnusedImport()], (_) -> LintConfig.parse('{"rules":{"unused-import":{"severity":"error"}}}')
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

	/**
	 * `resolveWith` uses an injected resolver when present and falls back to
	 * `discover` when null — the seam the option-reading checks resolve config
	 * through, so a direct `check.run` (null resolver) still discovers correctly.
	 */
	public function testResolveWithUsesResolverElseDiscovers(): Void {
		final viaResolver: LintConfig = LintConfig.resolveWith((_) -> LintConfig.parse('{"rules":{"complexity":{"max":5}}}'), 'X.hx');
		Assert.equals(5, viaResolver.intOption('complexity', 'max'), 'a provided resolver is used');
		final viaDiscover: LintConfig = LintConfig.resolveWith(null, 'no/such/dir/X.hx');
		Assert.isNull(viaDiscover.intOption('complexity', 'max'), 'a null resolver falls back to discover (empty when no file on disk)');
	}

	/** The `resolutionRoots` key: absent yields an empty scope, so no-key projects are byte-inert. */
	public function testResolutionRootsAbsentIsEmpty(): Void {
		Assert.equals(0, LintConfig.parse('{}').resolutionRoots().length, 'no key yields an empty resolution scope');
	}

	/** Each declared root is resolved to absolute against the config directory; an absolute root is kept verbatim. */
	public function testResolutionRootsResolvedAgainstBaseDir(): Void {
		final roots: Array<String> = LintConfig.parse('{"resolutionRoots":["lib","../shared/src","/abs/root"]}', '/proj/cfg')
			.resolutionRoots();
		Assert.equals(3, roots.length);
		Assert.equals('/proj/cfg/lib', roots[0], 'a relative root joins the config dir');
		Assert.equals('/proj/shared/src', roots[1], 'a ../ root normalises against the config dir');
		Assert.equals('/abs/root', roots[2], 'an absolute root is kept verbatim');
	}

	/** A non-array `resolutionRoots`, or non-string elements, are dropped — never coerced. */
	public function testResolutionRootsMalformedFiltered(): Void {
		Assert.equals(0, LintConfig.parse('{"resolutionRoots":"lib"}', '/p')
			.resolutionRoots()
			.length, 'a non-array value yields no roots');
		final mixed: Array<String> = LintConfig.parse('{"resolutionRoots":["ok",5,null,true]}', '/p').resolutionRoots();
		Assert.equals(1, mixed.length, 'non-string elements are dropped');
		Assert.equals('/p/ok', mixed[0]);
	}


	/** The `resolutionLibs` key: absent yields an empty list, so no-key projects are byte-inert. */
	public function testResolutionLibsAbsentIsEmpty(): Void {
		Assert.equals(0, LintConfig.parse('{}').resolutionLibs().length, 'no key yields no resolution libs');
	}

	/** Library names are kept VERBATIM — never path-resolved at parse time (resolution is the CLI's lazy job). */
	public function testResolutionLibsKeptVerbatim(): Void {
		final libs: Array<String> = LintConfig.parse('{"resolutionLibs":["openfl","lime"]}', '/proj/cfg').resolutionLibs();
		Assert.equals(2, libs.length);
		Assert.equals('openfl', libs[0], 'a lib name is not joined to the config dir');
		Assert.equals('lime', libs[1]);
	}

	/** A non-array `resolutionLibs`, or non-string elements, are dropped — never coerced. */
	public function testResolutionLibsMalformedFiltered(): Void {
		Assert.equals(0, LintConfig.parse('{"resolutionLibs":"openfl"}', '/p')
			.resolutionLibs()
			.length, 'a non-array value yields no libs');
		final mixed: Array<String> = LintConfig.parse('{"resolutionLibs":["ok",5,null,true]}', '/p').resolutionLibs();
		Assert.equals(1, mixed.length, 'non-string elements are dropped');
		Assert.equals('ok', mixed[0]);
	}

}
