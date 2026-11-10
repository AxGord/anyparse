package unit.macro;

import anyparse.runtime.StringInput;
import unit.macro.ExtentFixtures.LineCondScan;

/**
 * `ExtentScanLowering` over a second, C-like shape (`ExtentFixtures.LineCond`): the generated reader follows the PEG
 * the shape declares and nothing else. Every expected offset is spelled from the fixture text.
 */
@:nullSafety(Strict)
final class ExtentScanLoweringTest extends Test {

	/** A constructor that fails part-way hands the text to the next one, which here takes the rest of the line. */
	@:pin('control')
	@:killer('M-EXTENT-ORDERED-CHOICE')
	public function testAFailedConstructorFallsBackToTheNext(): Void {
		final unclosed: String = 'defined(X\nnext';
		Assert.equals(unclosed.indexOf('\n'), end(unclosed, 0));
	}

	/** A field's `@:trail` is part of its extent, so the first constructor stops right after the declared closer. */
	@:pin('control')
	@:killer('M-EXTENT-PART-TRAIL')
	public function testTheFieldTrailEndsTheExtent(): Void {
		final source: String = 'defined(X) && Y';
		Assert.equals(source.indexOf(')') + 1, end(source, 0));
	}

	/** An optional part is consumed when present and skipped when absent. */
	@:pin('control')
	@:killer('M-EXTENT-OPTIONAL-PART')
	public function testAnOptionalPartIsTakenWhenPresent(): Void {
		final spaced: String = 'defined (X) y';
		Assert.equals(spaced.indexOf(')') + 1, end(spaced, 0));
		final tight: String = 'defined(X) y';
		Assert.equals(tight.indexOf(')') + 1, end(tight, 0));
	}

	/** The reader starts exactly at its offset, and a match of no text answers that offset. */
	@:pin('guard')
	public function testTheReaderStartsAtItsOffsetAndAnEmptyMatchIsNone(): Void {
		final source: String = '#if a && b\n#end';
		final at: Int = '#if '.length;
		final lineEnd: Int = source.indexOf('\n');
		Assert.equals(lineEnd, end(source, at));
		Assert.equals(lineEnd, end(source, lineEnd));
	}

	private static function end(source: String, at: Int): Int {
		return LineCondScan.endAt(new StringInput(source), at);
	}

}
