package unit.format;

import anyparse.format.WhitespaceInvariant;
import utest.Assert;
import utest.Test;

/**
 * The non-whitespace invariant behind `apq fmt --verify`.
 *
 * The first case is the positive control: the exact before/after pair of the
 * conditional-region separator defect. Without it the rest of this file would only
 * prove that two equal strings compare equal, which is the failure mode an invariant
 * check is most likely to have and least likely to show.
 */
class WhitespaceInvariantTest extends Test {

	public function testDetectsTheCommaTheWriterAddedAfterEnd(): Void {
		// The shape from `pony.events.Event0`: the source's comma lives INSIDE the
		// region; the pre-fix writer emitted a second one after `#end`.
		final source: String = '@:forward(\n\tempty,\n\t#if flag changeEmpty, #end\n\tonTake\n)\nabstract A(Int) {}\n';
		final broken: String = '@:forward(empty, #if flag changeEmpty, #end, onTake)\nabstract A(Int) {}\n';
		final d: Null<Divergence> = WhitespaceInvariant.firstDivergence(source, broken);
		Assert.notNull(d);
		if (d == null) return;
		Assert.equals(4, d.line, 'the divergence is reported at the SOURCE line the next real token sits on');
		Assert.stringContains('onTake', d.expected);
		Assert.stringContains(',onTake', d.actual);
	}

	public function testWhitespaceOnlyReformatHolds(): Void {
		Assert.isNull(
			WhitespaceInvariant.firstDivergence('class A{function f(){g();}}', 'class A {\n\tfunction f() {\n\t\tg();\n\t}\n}\n')
		);
	}

	public function testIdenticalStringsHold(): Void {
		Assert.isNull(WhitespaceInvariant.firstDivergence('class A {}\n', 'class A {}\n'));
	}

	public function testEmptyPairHolds(): Void {
		Assert.isNull(WhitespaceInvariant.firstDivergence('', '   \n\t\n'));
	}

	public function testADroppedTrailingTokenIsReportedWithAnEmptyActual(): Void {
		final d: Null<Divergence> = WhitespaceInvariant.firstDivergence('a;\nb;\n', 'a;\n');
		Assert.notNull(d);
		if (d == null) return;
		Assert.equals(2, d.line);
		Assert.equals('b;', d.expected);
		Assert.equals('', d.actual);
	}

	public function testAnAddedTrailingTokenIsReportedWithAnEmptyExpected(): Void {
		final d: Null<Divergence> = WhitespaceInvariant.firstDivergence('a;\n', 'a;\nb;\n');
		Assert.notNull(d);
		if (d == null) return;
		Assert.equals('', d.expected);
		Assert.equals('b;', d.actual);
	}

}
