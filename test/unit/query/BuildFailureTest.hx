package unit.query;

import anyparse.query.BuildFailure;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Unit cover for `apq mutation-verdict --build` — the reason a mutated tree did
 * not compile, named rather than left in a log the reader has to open.
 *
 * Every fixture here drives a VERBATIM compiler line, copied out of a real
 * failing build rather than paraphrased: the classifier reads compiler prose,
 * so a hand-shaped approximation of that prose would pin nothing. The two that
 * matter most are the two arm-authoring blind spots that reach the compiler —
 * a nullable in a structure literal (S147) and a forced return ahead of an
 * `inline` body (S96).
 */
@:nullSafety(Strict)
class BuildFailureTest extends Test {

	/** The measured S147 line, from cutting `region: region` to `region: span`. */
	private static final NULL_SAFETY_STRUCTURE: String = 'src/anyparse/query/CondRegionScan.hx:107: lines 107-112 : Null safety: Cannot '
		+ 'unify { region : Null<anyparse.runtime.Span>, kind : String, gaps : ' + 'Array<anyparse.runtime.Span>,'
		+ ' formatted : Array<anyparse.runtime.Span> } with anyparse.query.OpaqueCondRegion';

	/** utest emits this on every build of this tree — it must never be read as the failure. */
	private static final DEPRECATION_WARNING: String = '/Users/x/haxelib/utest/1,13,2/src/utest/utils/TestBuilder.hx:12: characters 1-7 :'
		+ ' Warning : (WDeprecatedEnumAbstract) `@:enum abstract` is deprecated in favor of `enum abstract`';

	public function testTheStructureLiteralRefusalGetsItsOwnName(): Void {
		Assert.equals('null-safety-structure', classify(NULL_SAFETY_STRUCTURE));
	}

	public function testAnotherNullSafetyRefusalIsNotTheStructureOne(): Void {
		Assert.equals(
			'null-safety', classify('src/F.hx:9: characters 3-11 : Null safety: Cannot assign nullable value to not-nullable field.')
		);
	}

	public function testTheForcedReturnAheadOfAnInlineBodyIsNamed(): Void {
		Assert.equals('inline-return', classify('src/F.hx:3: characters 3-11 : Cannot inline a not final return'));
	}

	public function testTheRegistryOwnCrossCheckIsNamed(): Void {
		Assert.equals(
			'arm-registry',
			classify(
				'test/unit/T.hx:12: characters 2-20 : test/testkit/mutation-arms.json declares "M-X", which no @:killer in the test tree '
				+ 'names'
			)
		);
	}

	public function testAnUnparseableCutIsSyntax(): Void {
		Assert.equals('syntax', classify('src/F.hx:41: characters 9-10 : Missing ;'));
	}

	public function testAWrongTypeIsType(): Void {
		Assert.equals('type', classify('src/F.hx:41: characters 9-10 : String should be Int'));
	}

	public function testAnUnrecognisedLineIsOtherAndKeepsItsText(): Void {
		final result: BuildFailureResult = BuildFailure.classify('src/F.hx:41: characters 9-10 : Something entirely new');
		Assert.equals('other', BuildFailure.label(result.cause));
		Assert.equals('src/F.hx:41: characters 9-10 : Something entirely new', result.line);
	}

	public function testAGlobalErrorWithNoPositionIsStillRead(): Void {
		Assert.equals('other', classify('Error: Multiple targets'));
	}

	/**
	 * A warning carries a position exactly like an error does, and this tree emits one on
	 * EVERY build — reading it as the failure would name the wrong cause every single time.
	 */
	public function testTheDeprecationWarningIsNotTheFailure(): Void {
		Assert.equals('null-safety-structure', classify('$DEPRECATION_WARNING\n$NULL_SAFETY_STRUCTURE'));
	}

	public function testALogWithOnlyWarningsHasNoError(): Void {
		final result: BuildFailureResult = BuildFailure.classify('$DEPRECATION_WARNING\n');
		Assert.equals('no-error', BuildFailure.label(result.cause));
		Assert.equals('', result.line);
	}

	public function testAnEmptyLogHasNoError(): Void {
		Assert.equals('no-error', classify(''));
	}

	/**
	 * A structure-literal unify message names every field of the structure, so the raw line
	 * runs past 200 characters and the report row would wrap off screen.
	 */
	public function testALongLineIsCappedForTheReportRow(): Void {
		final result: BuildFailureResult = BuildFailure.classify(NULL_SAFETY_STRUCTURE);
		Assert.isTrue(NULL_SAFETY_STRUCTURE.length > result.line.length, 'the measured line is longer than the cap');
		Assert.equals(201, result.line.length);
		Assert.isTrue(result.line.endsWith('…'), 'a capped line says so');
	}

	/** The label of the cause `BuildFailure.classify` reads off `log`. */
	private static function classify(log: String): String {
		return BuildFailure.label(BuildFailure.classify(log).cause);
	}

}
