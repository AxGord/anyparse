package unit.check;

import anyparse.check.LintConfig;
import anyparse.check.LintDocuments;
import unit.cli.CliFixture;

/** A `compilerOracle` value stays raw through config parsing and is read by the run's own grammar. */
class OracleDeclaredTest extends Test {

	@:pin('control')
	@:killer('M-ORACLE-READ-DROPS-LOST')
	public function testParsingAConfigReadsNoDeclaration(): Void {
		final config: LintConfig = LintConfig.parse('{"compilerOracle":["b.hxml"]}', '/proj');
		Assert.same([], config.drops(), 'parsing needs no grammar, so nothing has judged the entries yet');
		Assert.same([], config.compilerOracles(new HaxeQueryPlugin()), 'the one entry is unusable');
		Assert.same(['compilerOracle[0] is not an object — dropped'], config.drops(), 'the read reports them');
	}

	@:pin('control')
	@:killer('M-ORACLE-SHADOWED-DROPS-LOST')
	public function testADroppedEntryOfAShadowedDocumentIsStillReported(): Void {
		final near: Null<LintDocument> = LintDocuments.parseDocument('{"compilerOracle":"near.hxml"}', '/near');
		final far: Null<LintDocument> = LintDocuments.parseDocument('{"compilerOracle":["b.hxml"]}', '/far');
		if (near == null || far == null) {
			Assert.fail('both documents parse');
			return;
		}
		final config: LintConfig = LintDocuments.fromDocument(LintDocuments.mergeDocuments(near, far));
		Assert.same(['/near/near.hxml'], config.compilerOracles(new HaxeQueryPlugin()).map(oracle -> oracle.hxml), 'the nearest wins');
		Assert.same(['compilerOracle[0] is not an object — dropped'], config.drops(), 'the shadowed mistake is still said');
	}

	@:pin('control')
	@:killer('M-ORACLE-OVERRIDE-LOSES-DECLARATION')
	public function testARunOverridingAnOptionKeepsTheUnreadDeclaration(): Void {
		final config: LintConfig = LintConfig.parse('{"compilerOracle":"a.hxml"}', '/proj').withIntOption('naming', 'max', 1);
		Assert.same(['/proj/a.hxml'], config.compilerOracles(new HaxeQueryPlugin()).map(oracle -> oracle.hxml));
	}

	@:pin('control')
	@:killer('M-ORACLE-DROP-WARNED-UNDER-NO-DOCUMENT')
	public function testAShadowedDocumentsDropIsWarnedUnderThatDocument(): Void {
		final root: String = CliFixture.writeTree('oracle_attribution', [
			{ name: 'apq.json', source: '{"compilerOracle":["b.hxml"]}' },
			{ name: 'sub/apq.json', source: '{"compilerOracle":"near.hxml"}' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final config: LintConfig = LintConfig.discover('$root/sub/A.hx');
			final warned: String = CliFixture.captureStderr(() -> Assert.equals(1, config.compilerOracles(new HaxeQueryPlugin()).length));
			Assert.stringContains('apq: $root/apq.json: compilerOracle[0] is not an object — dropped', warned);
		});
	}

}
