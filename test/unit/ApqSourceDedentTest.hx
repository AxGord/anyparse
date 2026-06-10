package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

/**
 * `apq source` dedent: by default the common leading-whitespace prefix
 * shared by the shown non-blank lines is stripped (textwrap.dedent), so a
 * nested slice reads without its indentation tax; `--raw` keeps bytes
 * verbatim (for Edit-anchoring / real column positions).
 *
 * The dedent logic lives in the pure helpers (`commonIndentWidth` /
 * `dedentLine`), unit-tested directly via `@:access`. The `runSource`
 * wiring itself writes to `Sys.print` (not capturable here) and is
 * exercised by manual end-to-end verification.
 */
@:access(anyparse.query.Cli)
@:nullSafety(Strict)
class ApqSourceDedentTest extends Test {

	public function testCommonIndentSingleNestedLine():Void {
		Assert.equals(3, Cli.commonIndentWidth(['\t\t\tg();'], 1, 1));
	}

	public function testCommonIndentMinimumAcrossLines():Void {
		// if/} at 2 tabs, body at 3 -> the shared prefix is 2.
		final lines:Array<String> = ['\t\tif (x) {', '\t\t\tg();', '\t\t}'];
		Assert.equals(2, Cli.commonIndentWidth(lines, 1, 3));
	}

	public function testCommonIndentBlankLinesIgnored():Void {
		final lines:Array<String> = ['\t\ta;', '', '\t\tb;'];
		Assert.equals(2, Cli.commonIndentWidth(lines, 1, 3));
	}

	public function testCommonIndentNoSharedPrefixIsZero():Void {
		Assert.equals(0, Cli.commonIndentWidth(['\ta;', 'b;'], 1, 2));
	}

	public function testCommonIndentAllBlankIsZero():Void {
		Assert.equals(0, Cli.commonIndentWidth(['', '\t', '  '], 1, 3));
	}

	public function testCommonIndentMixedTabSpaceExactChars():Void {
		// Tab+space common across both lines.
		Assert.equals(2, Cli.commonIndentWidth(['\t a;', '\t b;'], 1, 2));
		// Tab vs tab+space -> only the tab is common.
		Assert.equals(1, Cli.commonIndentWidth(['\ta;', '\t b;'], 1, 2));
	}

	public function testCommonIndentRangeSubsetOnly():Void {
		// Only lines 2..3 are inspected; line 1's shallow indent is excluded.
		final lines:Array<String> = ['a;', '\t\tb;', '\t\tc;'];
		Assert.equals(2, Cli.commonIndentWidth(lines, 2, 3));
	}

	public function testDedentLineDropsPrefix():Void {
		Assert.equals('g();', Cli.dedentLine('\t\t\tg();', 3));
	}

	public function testDedentLineKeepsRelativeIndent():Void {
		// Strip 2 of 3 -> one level of relative indent remains.
		Assert.equals('\tg();', Cli.dedentLine('\t\t\tg();', 2));
	}

	public function testDedentLineBlankCollapsesToEmpty():Void {
		Assert.equals('', Cli.dedentLine('\t\t', 1));
		Assert.equals('', Cli.dedentLine('', 0));
	}
}
