package unit.check;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.check.LintConfig;
import anyparse.check.Severity;
import haxe.io.Path;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/**
 * A nested `apqlint.json` EXTENDS the documents above it instead of replacing the
 * nearest one wholesale.
 *
 * The defect these pin is silent by construction: a nested document that names four
 * relaxations inherited nothing else — not the resolution scope, not the oracle, not
 * the rules the root opted into — and a rule that is not in the set does not fail, it
 * finds nothing. This project's own `test/apqlint.json` had `compilerOracle`,
 * `compilerOracleServer` and `resolutionRoots`/`resolutionLibs` copied down into it
 * over four commits in six weeks, each time somebody noticed another absence, while
 * the root's 38 opt-in rules were never noticed at all and 741 files under `test/`
 * were linted with a reduced rule set for six weeks.
 *
 * Six of the first eight cases go red on a `discover` that stops at the first document;
 * the two that do not — nearest-wins and `"inherit": false` — are GUARDS on the new
 * semantics rather than discriminators, since wholesale replacement agrees with both by
 * construction, and each says so at its own definition. Verified by reverting, not
 * reasoned: 13 of the 29 assertions fail with the three source files restored.
 */
@:nullSafety(Strict)
class LintConfigInheritanceTest extends Test {

	public function testAnUnnamedKeyFallsThroughToTheAncestor(): Void {
		#if (sys || nodejs)
		final root: String = tree(
			'{"compilerOracleServer": true, "resolutionLibs": ["utest"], "languageVersion": "4.3"}',
			'{"rules": {"magic-number": {"enabled": false}}}'
		);
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.isTrue(config.compilerOracleServer(), 'compilerOracleServer falls through');
		Assert.same(['utest'], config.resolutionLibs(), 'resolutionLibs falls through');
		Assert.equals('4.3', config.languageVersion(), 'languageVersion falls through');
		Assert.isFalse(config.enabledFor('magic-number'), 'the nested document still disables its own rule');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTheNEARESTDocumentWinsOnAKeyBothDeclare(): Void {
		#if (sys || nodejs)
		// A GUARD, not a discriminator: both keys are declared at the nested level, so
		// wholesale replacement answers identically and this stays green on a revert. It is
		// here because precedence is the one thing a merge can silently get backwards.
		final root: String = tree(
			'{"compilerOracleServer": true, "resolutionStd": true}', '{"compilerOracleServer": false, "resolutionStd": false}'
		);
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.isFalse(config.compilerOracleServer(), 'the nested false overrides the ancestor true');
		Assert.isFalse(config.resolutionStd(), 'the nested false overrides the ancestor true');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRulesMergePerRuleNotAsABlock(): Void {
		#if (sys || nodejs)
		// The whole point of per-RULE merging: a nested document that switches ONE rule off
		// keeps every other rule its ancestor opted into. A wholesale `rules` merge would
		// leave `explicit-local-type` off here, which is the shape that left 741 files
		// linted by a reduced rule set.
		final root: String = tree(
			'{"rules": {"explicit-local-type": {"enabled": true}, "magic-number": {"severity": "error"}}}',
			'{"rules": {"magic-number": {"enabled": false}}}'
		);
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.isTrue(config.enabledFor('explicit-local-type', false), 'a sibling rule the ancestor enabled survives');
		Assert.isFalse(config.enabledFor('magic-number'), 'the nested disable applies');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAnOptionOnlyEntryKeepsTheAncestorEnablementAndOptions(): Void {
		#if (sys || nodejs)
		// `{"oversized-type": {"maxMembers": 100}}` raises one threshold. It must not
		// re-enable a rule the ancestor switched off, nor drop the ancestor's other options.
		final root: String = tree(
			'{"rules": {"oversized-type": {"enabled": false, "maxMembers": 40, "severity": "error"}}}',
			'{"rules": {"oversized-type": {"maxMembers": 100}}}'
		);
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.isFalse(config.enabledFor('oversized-type'), 'an options-only override does not re-enable the rule');
		Assert.equals(100, config.intOption('oversized-type', 'maxMembers'), 'the nested option wins');
		Assert.equals(Severity.Error, config.severityFor('oversized-type'), 'the ancestor severity survives');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testARelativePathResolvesAgainstTheDocumentThatDeclaredIt(): Void {
		#if (sys || nodejs)
		// The chain is folded from documents in DIFFERENT directories, so a root that writes
		// "src" must still mean the root's own `src` for a file two levels down. Resolving it
		// against the nested document's directory instead is the failure this pins.
		final root: String = tree('{"resolutionRoots": ["src"]}', '{"rules": {}}');
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.same([Path.normalize('$root/src')], config.resolutionRoots(), 'the ancestor root resolves against the ANCESTOR dir');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testInheritFalseEndsTheChainAtThatDocument(): Void {
		#if (sys || nodejs)
		// A GUARD, not a discriminator: "inherit nothing" is what the OLD engine did
		// unconditionally, so this stays green on a revert. It pins that the escape hatch
		// still reaches the answer inheritance-by-default took away.
		final root: String = tree('{"resolutionLibs": ["utest"], "languageVersion": "4.3"}', '{"inherit": false, "rules": {}}');
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.equals(0, config.resolutionLibs().length, 'a standalone document inherits no libs');
		Assert.isNull(config.languageVersion(), 'a standalone document inherits no version floor');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTheChainStopsAtAProjectRoot(): Void {
		#if (sys || nodejs)
		// Inheritance without a bound would let ANY writable ancestor directory join every
		// project's config, and `compilerOracle` names an hxml the oracle EXECUTES. So the
		// walk ends at the directory holding a project marker, its own document included.
		// The fixture is three deep: outer (the stray), root (the project), nested (the file).
		final outer: String = CliFixture.writeDir('lintbound', [{ name: 'apqlint.json', source: '{"resolutionLibs": ["intruder"]}' }]);
		FileSystem.createDirectory('$outer/root');
		File.saveContent('$outer/root/apqlint.json', '{"languageVersion": "4.3"}');
		FileSystem.createDirectory('$outer/root/nested');
		File.saveContent('$outer/root/nested/apqlint.json', '{"rules": {}}');
		File.saveContent('$outer/root/nested/Probe.hx', 'class Probe {}\n');
		// No marker yet: the stray IS inherited, which is what makes the next arm mean something.
		Assert.same(['intruder'], LintConfig.discover('$outer/root/nested/Probe.hx').resolutionLibs(), 'unbounded, the stray reaches in');
		for (marker in ['.git', 'haxelib.json']) {
			File.saveContent('$outer/root/$marker', '');
			final config: LintConfig = LintConfig.discover('$outer/root/nested/Probe.hx');
			Assert.equals(0, config.resolutionLibs().length, '"$marker" ends the chain before the stray');
			Assert.equals('4.3', config.languageVersion(), 'and the marked directory\'s OWN document is still read');
			FileSystem.deleteFile('$outer/root/$marker');
		}
		CliFixture.removeDir(outer);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAnUnreadableDocumentIsReportedNotDropped(): Void {
		#if (sys || nodejs)
		// A document that EXISTS and cannot be opened is the one failure with no other
		// symptom: the ancestor's answer silently applies to a question this document
		// already answered. HALF A GUARD, and this says which half — folding PAST it is
		// what the engine always did and stays green on a revert; the DIAGNOSTIC that
		// makes it visible is the new part, and it is written to stderr where no
		// in-process assertion reaches it. Verified by hand instead:
		//   apq: <path> could not be read — ignored, the rest of the chain still applies
		final root: String = tree('{"resolutionLibs": ["utest"]}', '{"resolutionLibs": ["nested"]}');
		Assert.same(['nested'], LintConfig.discover('$root/nested/Probe.hx').resolutionLibs(), 'readable, the nested answer wins');
		Sys.command('chmod', ['000', '$root/nested/apqlint.json']);
		// Skipped rather than asserted when the chmod does not bite (a root-owned CI runner
		// reads it anyway) — a probe that cannot create the condition must not claim it did.
		if (readable('$root/nested/apqlint.json'))
			Assert.pass('chmod 000 did not make the file unreadable for this user')
		else {
			final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
			Assert.same(['utest'], config.resolutionLibs(), 'unreadable, the ancestor applies');
		}
		Sys.command('chmod', ['644', '$root/nested/apqlint.json']);
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAMalformedNestedDocumentDoesNotDiscardTheChain(): Void {
		#if (sys || nodejs)
		// The nearest config being broken must not also throw away the project's: the
		// wholesale fallback used to collapse the resolution scope and every rule toggle.
		final root: String = tree('{"resolutionLibs": ["utest"]}', '{"resolutionLibs": 17}');
		final config: LintConfig = LintConfig.discover('$root/nested/Probe.hx');
		Assert.same(['utest'], config.resolutionLibs(), 'the ancestor still applies past a rejected nested document');
		CliFixture.removeDir(root);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testTheProjectsOwnNestedConfigIsItsSixRelaxationsAndNothingElse(): Void {
		#if (sys || nodejs)
		// The acceptance test for the shrinkage: `test/apqlint.json` is back to the
		// exemptions it was written as — the original four, plus the two the user added on
		// 2026-09-02 from S15's measurement (`duplicate-code` 644 findings / `prefer-typed-throw`
		// 223, 85% of the test tree's stream, both correct checks whose fix test code cannot
		// take) — and every key it used to carry a copy of now reaches it through the chain.
		// Both halves matter — the relaxations must still apply, and the project settings must
		// be the ROOT's, resolved against the ROOT's directory.
		final repo: String = CliFixture.repoRoot();
		final src: LintConfig = LintConfig.discover('$repo/src/anyparse/check/LintConfig.hx');
		final test: LintConfig = LintConfig.discover('$repo/test/unit/LintConfigInheritanceTest.hx');
		Assert.equals(src.compilerOracle(), test.compilerOracle(), 'the oracle hxml is inherited, not copied');
		Assert.equals(src.compilerOracleDir(), test.compilerOracleDir(), 'so is the directory it compiles from');
		// NOT `Assert.equals(src…, test…)`: the ctor defaults an undeclared
		// `compilerOracleServer` to false, so comparing the two answers false == false and
		// would pass with no inheritance at all. The VALUE is the assertion — `21dcdd8a`
		// turned the warm server off at the root ("costs 25% and buys nothing") and the
		// nested copy kept it on for six weeks, so a `true` here is that copy coming back.
		Assert.isFalse(test.compilerOracleServer(), 'test/ takes the root\'s warm-server answer, which is off');
		Assert.isFalse(src.compilerOracleServer(), 'and the root is where that answer is declared');
		Assert.same(src.resolutionRoots(), test.resolutionRoots(), 'so is the resolution scope');
		Assert.same(src.resolutionLibs(), test.resolutionLibs(), 'so are the resolution libs');
		// The 38 opt-in rules the root declares reach `test/` now; a nested document that
		// replaced its parent left every one of them off, silently finding nothing.
		for (id in [
			'explicit-local-type',
			'import-order',
			'anon-type-dup',
			'unused-public-member'
		]) Assert.isTrue(test.enabledFor(id, false), 'the root opt-in "$id" reaches test/');
		// And the six relaxations the document is actually for still apply — the two newer
		// ones are exemptions of rules that are LIVE at the root, so each is asserted on both
		// sides: off under test/, on under src/ (a nested document that switched them off
		// everywhere would pass a one-sided check).
		for (id in ['magic-number', 'string-literal-dup', 'doc-coverage', 'duplicate-code'])
			Assert.isFalse(test.enabledFor(id), 'the test-code relaxation "$id" still applies');
		Assert.isTrue(src.enabledFor('duplicate-code'), 'duplicate-code stays on under src/');
		Assert.isFalse(test.enabledFor('prefer-typed-throw', false), 'prefer-typed-throw is exempt under test/');
		Assert.isTrue(src.enabledFor('prefer-typed-throw', false), 'and stays a live root opt-in under src/');
		Assert.equals(100, test.intOption('oversized-type', 'maxMembers'), 'the oversized-type relaxation still applies');
		Assert.isNull(src.intOption('oversized-type', 'maxMembers'), 'and it does not leak upward into src/');
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	/**
	 * A two-level fixture: `rootConfig` at the top, `nestedConfig` in a `nested/`
	 * subdirectory holding the probe file. Returns the top directory.
	 */
	private function readable(path: String): Bool {
		return try {
			File.getContent(path);
			true;
		} catch (exception: haxe.Exception) false;
	}

	private function tree(rootConfig: String, nestedConfig: String): String {
		final root: String = CliFixture.writeDir('lintinherit', [{ name: 'apqlint.json', source: rootConfig }]);
		FileSystem.createDirectory('$root/nested');
		File.saveContent('$root/nested/apqlint.json', nestedConfig);
		File.saveContent('$root/nested/Probe.hx', 'class Probe {}\n');
		return root;
	}
	#end

}
