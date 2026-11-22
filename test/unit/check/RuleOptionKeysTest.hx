package unit.check;

import anyparse.check.LintConfig;
import anyparse.check.LintDocuments;
import anyparse.check.Linter;
import anyparse.query.Cli;
import unit.cli.CliFixture;

/**
 * A key a rule's config object names that its check does not read is said once, with the keys it does read nearest
 * first, so a typo or a key borrowed from another rule is not silently ignored. A rule id no check has is said with the
 * ids nearest it.
 */
@:nullSafety(Strict)
final class RuleOptionKeysTest extends Test {

	/** The CLI run says the note: the table is handed in from the registry, not from the test. */
	@:pin('control')
	@:killer('M-OPTKEYS-NOT-HANDED')
	public function testATypoKeyIsReportedWithTheKeyItResemblesInTheCliRun(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('ruleoptionkeys', [
			{ name: 'apq.json', source: '{"rules":{"avoid-any":{"excludePath":["x"]}}}' },
			{ name: 'Foo.hx', source: 'class Foo {}\n' }
		]);
		final said: String = CliFixture.captureStderr(() -> Cli.run(['lint', '--no-oracle', '$dir/Foo.hx']));
		CliFixture.removeDir(dir);
		#if nodejs
		Assert.isTrue(said.indexOf('rules "avoid-any" has unknown option "excludePath" — ignored; accepts: excludePaths, ') >= 0, said);
		#else
		Assert.pass('stderr is captured on node only');
		#end
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A nested document's key is attributed to that document, and the ancestor's keys stay quiet. */
	@:pin('control')
	@:killer('M-OPTKEYS-DOCUMENT-ATTRIBUTION')
	public function testANestedDocumentsKeyIsNamedWithItsOwnFile(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeTree('ruleoptionkeysnested', [
			{ name: 'apq.json', source: '{"rules":{"avoid-any":{"excludePaths":["x"]}}}' },
			{ name: 'sub/apq.json', source: '{"rules":{"avoid-dynamic":{"excludeMetas":["y"]}}}' },
			{ name: 'sub/Foo.hx', source: 'class Foo {}\n' }
		]);
		final notes: Array<ConfigNote> = [];
		final config: LintConfig = LintConfig.discover('$dir/sub/Foo.hx', notes, Linter.acceptedOptions());
		CliFixture.removeDir(dir);
		Assert.isTrue(config.enabledFor('naming'), 'the unknown key is ignored, the config still applies');
		Assert.equals(1, notes.length, 'one note: the root document is clean');
		final message: String = notes.length == 1 ? notes[0].message : '';
		Assert.isTrue(message.indexOf('/sub/apq.json: rules "avoid-dynamic" has unknown option "excludeMetas"') >= 0, message);
		Assert.isTrue(message.indexOf('accepts: excludeMeta, ') >= 0, message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The thread-safety rule's own keys come from the contract: a typo is said by it, every key it reads is quiet. */
	@:pin('control')
	@:killer('M-OPTKEYS-THREAD-SAFETY-DECLARED')
	public function testThreadSafetyDeclaresItsKeysOnTheContract(): Void {
		final said: Array<String> = unknown(
			'{"rules":{"thread-safety":{"sinks":["a"],"closedWorld":true,"repeatBudgetMs":5,"boundedRepeats":[],"shortSink":[]}}}',
			Linter.acceptedOptions()
		);
		Assert.equals(1, said.length, said.join('\n'));
		Assert.isTrue(
			said.length == 1 && said[0].indexOf('has unknown option "shortSink" — ignored; accepts: shortSinks, ') >= 0, said.join('\n')
		);
	}

	/** Every key `avoid-any` and `avoid-dynamic` read is accepted. */
	@:pin('control')
	@:killer('M-OPTKEYS-AVOID-ANY-DECLARED')
	@:killer('M-OPTKEYS-AVOID-DYNAMIC-DECLARED')
	public function testEveryKeyTheAvoidRulesReadIsAccepted(): Void {
		Assert.same(
			[],
			unknown(
				'{"rules":{"avoid-any":{"excludePaths":[],"excludeMeta":[]},"avoid-dynamic":{"excludePaths":[],"excludeMeta":[],'
				+ '"boundaryCalls":[]}}}',
				Linter.acceptedOptions()
			)
		);
	}

	/** A rule declaring no keys says `accepts: none`. */
	@:pin('control')
	@:killer('M-OPTKEYS-ACCEPTS-NONE')
	public function testARuleWithNoOptionsAcceptsNone(): Void {
		Assert.same(
			['rules "bare" has unknown option "excludePaths" — ignored; accepts: none'],
			unknown('{"rules":{"bare":{"enabled":true,"excludePaths":["x"]}}}', ['bare' => []])
		);
	}

	/** The accepted keys are listed nearest the unknown one first, then in their declared order. */
	@:pin('control')
	@:killer('M-OPTKEYS-NEAREST-FIRST')
	public function testAcceptedKeysComeNearestFirst(): Void {
		Assert.same([
			'rules "r" has unknown option "maxMember" — ignored; accepts: maxMembers, alpha, omega'
		], unknown('{"rules":{"r":{"maxMember":1}}}', ['r' => ['alpha', 'omega', 'maxMembers']]));
	}

	/** An id the table does not hold names no rule: its keys are not judged, the id is said once. */
	@:pin('control')
	@:killer('M-OPTKEYS-UNDECLARED-RULE')
	public function testAnIdTheTableLacksNamesNoRule(): Void {
		Assert.same(['rules "free" names no rule — ignored'], unknown('{"rules":{"free":{"anything":1}}}', ['other' => []]));
	}

	/** The ids nearest the unknown one are named, nearest first. */
	@:pin('control')
	@:killer('M-OPTKEYS-UNKNOWN-RULE-NEAREST')
	public function testAnUnknownIdNamesTheNearestRules(): Void {
		Assert.same(
			['rules "naming-x" names no rule — ignored; nearest: naming'],
			unknown('{"rules":{"naming-x":{"enabled":true}}}', ['naming' => [], 'unrelated-rule' => []])
		);
	}

	/** A mistyped `enabled` / `severity` lands among the options but is a value of the wrong shape, not an unknown key. */
	@:pin('control')
	@:killer('M-OPTKEYS-LIFTED-KEYS')
	public function testAMistypedEnabledOrSeverityIsNotAnUnknownKey(): Void {
		Assert.same([], unknown('{"rules":{"bare":{"enabled":"yes","severity":3}}}', ['bare' => []]));
	}

	private static function unknown(config: String, accepted: Map<String, Array<String>>): Array<String> {
		final doc: Null<LintDocument> = LintDocuments.parseDocument(config);
		return doc == null ? ['document rejected'] : LintDocuments.unknownOptions(doc, accepted);
	}

}
