package unit.check;

import anyparse.check.LintDocuments;
import anyparse.check.Linter;

/**
 * Every rule that reads options out of its `apq.json` entry declares them, so a typo in its entry is said once and the keys
 * this repository's configs write are accepted.
 */
@:nullSafety(Strict)
final class RuleOptionKeysDeclaredTest extends Test {

	/** The option keys the configs of this repository write, by rule. */
	private static final WRITTEN: Map<String, Array<String>> = [
		'hand-source-scanner' => ['allow'],
		'avoid-any' => ['excludePaths'],
		'hoist-common-import' => ['threshold', 'sinkThreshold', 'usingAllowList'],
		'helper-copy' => ['homes'],
		'map-as-set' => ['set', 'bits'],
		'naming' => ['catchVarName', 'handlerSuffix'],
		'oversized-type' => ['grants', 'maxMembers'],
		'prefer-helper' => ['marker'],
		'prefer-static-extension' => ['types'],
		'prefer-compare-function' => ['compare'],
		'refusal-assert-ignores-message' => ['refusalConstructors', 'passCalls'],
		'zero-count-unparsed-fixture' => ['zeroAsserts', 'countFields', 'sourceFields', 'skipParseTests'],
		'guard-pin-arm-reach' => ['pinMeta', 'guardArgument', 'killerMeta', 'armRegistry']
	];

	/** Every key a repository config writes is accepted by the rule it sits under. */
	@:pin('control')
	@:killer('M-OPTKEYS-DECLARED-KEY-LEFT-OUT')
	public function testEveryWrittenKeyIsAccepted(): Void {
		final accepted: Map<String, Array<String>> = Linter.acceptedOptions();
		for (id => keys in WRITTEN) {
			final entry: String = keys.map(key -> '"$key":1').join(',');
			Assert.same([], unknown('{"rules":{"$id":{$entry}}}', accepted), id);
		}
	}

	/** A key no rule reads is said for each of those rules, so none is left silently unchecked. */
	@:pin('control')
	@:killer('M-OPTKEYS-DECLARED-ACCEPTS-ANY')
	public function testATypoUnderAnyOfThemIsSaid(): Void {
		final accepted: Map<String, Array<String>> = Linter.acceptedOptions();
		for (id => _ in WRITTEN) {
			final said: Array<String> = unknown('{"rules":{"$id":{"zzNoSuchOption":1}}}', accepted);
			Assert.equals(1, said.length, id);
		}
	}

	/** The rule entries of this repository's own `apq.json` files name no key the rules do not read. */
	@:pin('control')
	@:killer('M-OPTKEYS-DECLARED-KEY-LEFT-OUT')
	public function testTheRepositoryConfigsNameNoUnknownKey(): Void {
		#if (sys || nodejs)
		final accepted: Map<String, Array<String>> = Linter.acceptedOptions();
		for (path in ['apq.json', 'test/apq.json']) if (sys.FileSystem.exists(path))
			Assert.same([], unknown(sys.io.File.getContent(path), accepted), path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	private static function unknown(config: String, accepted: Map<String, Array<String>>): Array<String> {
		final doc: Null<LintDocument> = LintDocuments.parseDocument(config);
		return doc == null ? ['document rejected'] : LintDocuments.unknownOptions(doc, accepted);
	}

}
