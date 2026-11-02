package unit.devkit;

import devkit.Excerpt;
import utest.Assert;
import utest.Test;

using StringTools;

/** `devkit.Excerpt`: the lines a table prints for a failed step are few, short, and say what they left out. */
@:nullSafety(Strict)
final class ExcerptTest extends Test {

	public function testErrorLinesWinOverNoiseAndWarningsAreNoError(): Void {
		final log: String =
			'a.hx:1: characters 1-2 : Warning : unused error handler\nbuilding\nb.hx:2: characters 3-4 : Error : Type not found\n';
		Assert.same(['b.hx:2: characters 3-4 : Error : Type not found'], Excerpt.errors(log));
	}

	public function testAnErrorlessLogAnswersItsLastLines(): Void {
		final lines: Array<String> = [for (i in 0...15) 'line $i'];
		Assert.same(lines.slice(5), Excerpt.errors(lines.join('\n') + '\n\n'));
		Assert.same(['line 13', 'line 14'], Excerpt.tail(lines.join('\n'), 2));
	}

	public function testALongExcerptEndsInTheCountOfWhatItLeftOut(): Void {
		final lines: Array<String> = [for (i in 0...25) 'row $i'];
		final cut: Array<String> = Excerpt.cut(lines);
		Assert.equals(Excerpt.MAX_LINES, cut.length);
		Assert.equals('row 8', cut[Excerpt.MAX_LINES - 2]);
		Assert.equals('… 16 more', cut[Excerpt.MAX_LINES - 1]);
		Assert.same(lines.slice(0, Excerpt.MAX_LINES), Excerpt.cut(lines.slice(0, Excerpt.MAX_LINES)), 'ten lines fit as they are');
	}

	public function testALongLineIsClipped(): Void {
		final cut: Array<String> = Excerpt.cut([''.rpad('x', Excerpt.MAX_WIDTH + 50)]);
		final line: String = cut[0];
		Assert.equals(Excerpt.MAX_WIDTH, line.length);
		Assert.isTrue(line.endsWith('…'));
	}

}
