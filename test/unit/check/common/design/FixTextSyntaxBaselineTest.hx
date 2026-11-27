package unit.check.common.design;

import anyparse.check.LintConfig;
import anyparse.check.LintDocuments;
import anyparse.check.Linter;
import anyparse.check.common.design.FixTextSyntax;
import anyparse.query.Glob;
import anyparse.query.LintDiff;
import anyparse.query.format.LintFormat;
import sys.io.File;

/**
 * The ratchet of `fix-text-syntax` over this repository: the sites the rule finds under the roots `apq.json` names
 * are the ones the committed snapshot records, no more and no fewer. A new site fails the suite; a site a slice
 * migrated away fails it too, until the snapshot is recorded again, so the baseline only ever shrinks.
 *
 * The rule is run here WITHOUT the `baseline` option `apq.json` gives it (which is what keeps a lint run quiet about
 * the recorded sites), so the full list is compared. Record the snapshot again after a migration:
 *
 *     APQ_FIX_TEXT_RECORD=1 APQ_TEST=unit.check.common.design.FixTextSyntaxBaselineTest node bin/test.js
 */
@:nullSafety(Strict)
class FixTextSyntaxBaselineTest extends Test {

	/** The snapshot, relative to the repository root. */
	private static inline final SNAPSHOT: String = 'test/testkit/fix-text-syntax.baseline.json';

	private static inline final RULE_ID: String = 'fix-text-syntax';
	private static inline final LISTED: Int = 20;
	private static inline final RECORD_ENV: String = 'APQ_FIX_TEXT_RECORD';

	@:pin('control')
	@:killer('M-FIX-TEXT-SYNTAX-TOKEN-UNREAD')
	public function testTheSitesFoundAreTheSitesRecorded(): Void {
		final config: LintConfig = configOf();
		final files: Array<{ file: String, source: String }> = [
			for (root in config.stringListOption(RULE_ID, 'roots') ?? [])
				for (path in Glob.expand(root, 'hx')) { file: path, source: File.getContent(path) }
		];
		Assert.isTrue(files.length > 0, 'the roots of $RULE_ID in apq.json name no file');
		final found: Array<Violation> = CheckFixture.violationsIn(new FixTextSyntax(), files, null, _ -> config);
		final sources: Map<String, String> = [ for (entry in files) entry.file => entry.source ];
		if (Sys.getEnv(RECORD_ENV) == '1') {
			File.saveContent(SNAPSHOT, LintFormat.json(found, sources));
			return;
		}
		final identities: LintMessageIdentities = Linter.messageIdentities();
		final now: LintDiffTally = LintDiff.tally(LintDiff.parseReport(LintFormat.json(found, sources)), '', identities);
		final recorded: LintDiffTally = LintDiff.tally(LintDiff.parseReport(File.getContent(SNAPSHOT)), '', identities);
		final delta: LintDiffResult = LintDiff.compare(recorded, now);
		final listing: String = '\n' + LintDiff.render(delta, RULE_ID, LISTED).join('\n');
		Assert.equals(0, delta.addedTotal, 'a new site spells syntax in an edit text — ask a grammar component for it$listing');
		Assert.equals(0, delta.removedTotal, 'the snapshot records sites that are gone — record it again (see the class doc)$listing');
	}

	private static function configOf(): LintConfig {
		final document: Null<LintDocument> = LintDocuments.parseDocument(File.getContent('apq.json'), '.');
		Assert.notNull(document);
		if (document == null) return LintConfig.parse('{}');
		document.rules[RULE_ID]?.props.remove('baseline');
		return LintDocuments.fromDocument(document);
	}

}
