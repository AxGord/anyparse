package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedImport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

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

	/**
	 * The `rules` section is an OPEN map — an arbitrary rule id is a key, and a rule's option
	 * bag keeps every key other than `enabled` / `severity` verbatim. This is the
	 * `Map<String, JValue>` ByName schema field the config is the first consumer of, so the
	 * empty map and the empty entry object are pinned here too.
	 */
	public function testRulesMapArbitraryKeys(): Void {
		final cfg: LintConfig = LintConfig.parse(
			'{"rules":{"a-rule":{"enabled":false,"severity":"info","max":3,"names":["x","y"]},"b-rule":{},"c-rule":{"flag":true}}}'
		);
		Assert.isFalse(cfg.enabledFor('a-rule'));
		Assert.equals(Severity.Info, cfg.severityFor('a-rule'));
		Assert.equals(3, cfg.intOption('a-rule', 'max'), 'a rule-specific option survives next to the framework keys');
		Assert.same(['x', 'y'], cfg.stringListOption('a-rule', 'names'));
		Assert.isTrue(cfg.enabledFor('b-rule'), 'an empty rule object parses and declares nothing');
		Assert.isTrue(cfg.boolOption('c-rule', 'flag'));
		Assert.isTrue(cfg.enabledFor('unlisted'), 'an id absent from the map keeps the default');
		Assert.isTrue(LintConfig.parse('{"rules":{}}').enabledFor('naming'), 'an empty rules map is valid — the loop short-circuits');
	}

	/** A `rules` entry whose value is not a JSON object is not a rule config — dropped, exactly as the untyped reader skipped a non-object. */
	public function testRulesNonObjectEntryDropped(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"a-rule":5,"b-rule":{"severity":"error"}}}');
		Assert.isNull(cfg.severityFor('a-rule'));
		Assert.isTrue(cfg.enabledFor('a-rule'));
		Assert.equals(Severity.Error, cfg.severityFor('b-rule'), 'a sibling object entry is unaffected');
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
			files, plugin,
			[new UnusedImport()],
			(_) -> LintConfig.parse('{"rules":{"unused-import":{"severity":"error"}}}')
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

	/**
	 * The `resolutionRoots` key: absent yields no declared roots. NOT an inertness claim any
	 * more — the CLI joins the auto-discovered Haxe std whatever this returns, so "no key" means
	 * "nothing DECLARED", not "no scope". What the empty array still buys is that the
	 * null-decision short-circuits before any `haxelib` spawn.
	 */
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

	/**
	 * A `resolutionRoots` value contradicting the schema — a non-array, or an array holding a
	 * non-string element — degrades the WHOLE config, not just that key: the typed
	 * `ApqLintConfigParser` rejects the document and `parse` falls back to an empty config, the
	 * same boundary `CheckstyleConfigLoader` moved to. The previous untyped reader dropped the
	 * offending elements and kept the rest.
	 */
	public function testResolutionRootsMalformedDegradesWholesale(): Void {
		Assert.equals(0, LintConfig.parse('{"resolutionRoots":"lib"}', '/p').resolutionRoots().length, 'a non-array value yields no roots');
		final mixed: LintConfig = LintConfig.parse('{"resolutionRoots":["ok",5,null,true],"resolutionStd":false}', '/p');
		Assert.equals(0, mixed.resolutionRoots().length, 'a non-string element rejects the whole array — no partial list');
		Assert.isTrue(mixed.resolutionStd(), 'and every other key degrades with it, back to the default');
	}


	/**
	 * The `resolutionLibs` key: absent yields no declared libs — again a statement about what the
	 * project DECLARED, not about the run being inert (the implicit std scope is independent of
	 * this key). Its live consequence is that nothing is passed to `haxelib libpath`.
	 */
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

	/** The `resolutionLibs` twin of `testResolutionRootsMalformedDegradesWholesale` — same typed-schema boundary. */
	public function testResolutionLibsMalformedDegradesWholesale(): Void {
		Assert.equals(0, LintConfig.parse('{"resolutionLibs":"openfl"}', '/p').resolutionLibs().length, 'a non-array value yields no libs');
		final mixed: LintConfig = LintConfig.parse('{"resolutionLibs":["ok",5,null,true],"resolutionStd":false}', '/p');
		Assert.equals(0, mixed.resolutionLibs().length, 'a non-string element rejects the whole array — no partial list');
		Assert.isTrue(mixed.resolutionStd(), 'and every other key degrades with it, back to the default');
	}

	/** The `resolutionStd` opt-out defaults to ON — absent, the auto-discovered std joins the scope, which is the whole point of it being implicit. */
	public function testResolutionStdDefaultsOn(): Void {
		Assert.isTrue(LintConfig.parse('{}').resolutionStd(), 'no key keeps the implicit std scope');
	}

	/** `"resolutionStd": false` declines it — the per-project opt-out for a source tree targeting a different Haxe version than the installed one. */
	public function testResolutionStdFalseDeclines(): Void {
		Assert.isFalse(LintConfig.parse('{"resolutionStd":false}').resolutionStd(), 'an explicit false declines the std');
		Assert.isTrue(LintConfig.parse('{"resolutionStd":true}').resolutionStd(), 'an explicit true is the default, spelled out');
	}

	/**
	 * A non-boolean `resolutionStd` rejects the WHOLE document (the typed
	 * parser throws, `parse` degrades to defaults) — the same wholesale
	 * contract the roots / libs siblings pin. The default `true` still
	 * stands, and a co-declared key is wiped with it; a discovered
	 * config additionally reports the drop on stderr.
	 */
	public function testResolutionStdMalformedDegradesWholesale(): Void {
		final degraded: LintConfig = LintConfig.parse('{"resolutionStd":"false","resolutionLibs":["pony"]}');
		Assert.isTrue(degraded.resolutionStd(), 'a string rejects the whole document — the default true stands');
		Assert.equals(0, degraded.resolutionLibs().length, 'and every other key degrades with it');
		final numeric: LintConfig = LintConfig.parse('{"resolutionStd":0,"resolutionLibs":["pony"]}');
		Assert.isTrue(numeric.resolutionStd(), 'a number rejects the document too');
		Assert.equals(0, numeric.resolutionLibs().length, 'discriminating: the co-declared key is wiped with it');
	}


	/**
	 * The `compilerOracle` key resolves against the config directory, but the compile CWD is the
	 * HXML's OWN directory — an `.hxml`'s `-cp` entries are written relative to where the hxml
	 * lives, so a config in a subdirectory naming a parent hxml (`"../build.hxml"`) must still
	 * compile from that parent. Running it from the CONFIG dir resolves every classpath one level
	 * too deep and the build never typechecks.
	 */
	public function testCompilerOracleRunsFromTheHxmlDirectory(): Void {
		final nested: LintConfig = LintConfig.parse('{"compilerOracle":"../build.hxml"}', '/proj/src');
		Assert.equals('/proj/build.hxml', nested.compilerOracle(), 'the hxml resolves against the config dir');
		Assert.equals('/proj', nested.compilerOracleDir(), 'and the compile runs from the hxml dir, not the config dir');
		final sibling: LintConfig = LintConfig.parse('{"compilerOracle":"build.hxml"}', '/proj');
		Assert.equals('/proj/build.hxml', sibling.compilerOracle(), 'a same-dir hxml resolves to the same absolute path');
		Assert.equals('/proj', sibling.compilerOracleDir(), 'and its compile dir is the config dir — the root-config case, unchanged');
		final absolute: LintConfig = LintConfig.parse('{"compilerOracle":"/elsewhere/build.hxml"}', '/proj/src');
		Assert.equals('/elsewhere/build.hxml', absolute.compilerOracle(), 'an absolute hxml is kept verbatim');
		Assert.equals('/elsewhere', absolute.compilerOracleDir(), 'and still compiles from its own directory');
		final atRoot: LintConfig = LintConfig.parse('{"compilerOracle":"build.hxml"}', '/');
		Assert.equals(
			'/', atRoot.compilerOracleDir(), 'an hxml directly under the filesystem root compiles from the root, never an empty cwd'
		);
	}

	/**
	 * Parsed with no base directory there is nothing to resolve against — the path stays verbatim
	 * and no compile dir is claimed. This branch is unchanged by the resolution above; it is
	 * pinned because without its explicit null the compile dir would become the meaningless
	 * `haxe.io.Path.directory('../build.hxml')` == `'..'`.
	 */
	public function testCompilerOracleWithoutBaseDirStaysVerbatim(): Void {
		final cfg: LintConfig = LintConfig.parse('{"compilerOracle":"../build.hxml"}');
		Assert.equals('../build.hxml', cfg.compilerOracle(), 'no base dir leaves the declared path untouched');
		Assert.isNull(cfg.compilerOracleDir(), 'and claims no compile dir');
	}

}
