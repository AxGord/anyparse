package unit.cli;

import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.query.cli.command.ReconPredict;

/** `ReconPredict.stripBalancedPairs`: a pair is balanced over CODE, so a bracket in a string or a comment is not counted. */
@:nullSafety(Strict)
final class ReconPredictTest extends Test {

	@:pin('control')
	@:killer('M-RECON-STRIP-NONCODE')
	public function testABracketInAStringOrACommentIsNotCounted(): Void {
		final source: String = 'f(a, ")" /* ) */ b) c';
		final stripped: StripResult = ReconPredict.stripBalancedPairs(source, HaxeLexicalRegions.scan(source), '(', ')');
		Assert.equals('f c', stripped.out);
		Assert.equals(1, stripped.count);
	}

	public function testALeadInsideAStringStays(): Void {
		final source: String = '"(" f(1)';
		Assert.equals('"(" f', ReconPredict.stripBalancedPairs(source, HaxeLexicalRegions.scan(source), '(', ')').out);
	}

}
