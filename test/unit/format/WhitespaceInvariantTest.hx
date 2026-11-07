package unit.format;

import anyparse.format.WhitespaceInvariant;
import anyparse.format.comment.CommentScan;
import anyparse.grammar.haxe.HaxeLexicalRegions;

/**
 * The non-whitespace invariant behind `apq fmt --verify`.
 *
 * The first case is the positive control: the exact before/after pair of the
 * conditional-region separator defect. Without it the rest of this file would only
 * prove that two equal strings compare equal, which is the failure mode an invariant
 * check is most likely to have and least likely to show.
 */
class WhitespaceInvariantTest extends Test {

	/** The Haxe grammar's comment lexer, the seam every pin reads comments through. */
	private static final HAXE: CommentScan = HaxeLexicalRegions.scanComments;

	public function testDetectsTheCommaTheWriterAddedAfterEnd(): Void {
		// The shape from `pony.events.Event0`: the source's comma lives INSIDE the
		// region; the pre-fix writer emitted a second one after `#end`.
		final source: String = '@:forward(\n\tempty,\n\t#if flag changeEmpty, #end\n\tonTake\n)\nabstract A(Int) {}\n';
		final broken: String = '@:forward(empty, #if flag changeEmpty, #end, onTake)\nabstract A(Int) {}\n';
		final d: Null<Divergence> = WhitespaceInvariant.firstDivergence(source, broken, HAXE);
		Assert.notNull(d);
		if (d == null) return;
		Assert.equals(4, d.line, 'the divergence is reported at the SOURCE line the next real token sits on');
		Assert.stringContains('onTake', d.expected);
		Assert.stringContains(',onTake', d.actual);
	}

	public function testWhitespaceOnlyReformatHolds(): Void {
		Assert.isNull(
			WhitespaceInvariant.firstDivergence('class A{function f(){g();}}', 'class A {\n\tfunction f() {\n\t\tg();\n\t}\n}\n', HAXE)
		);
	}

	public function testIdenticalStringsHold(): Void {
		Assert.isNull(WhitespaceInvariant.firstDivergence('class A {}\n', 'class A {}\n', HAXE));
	}

	public function testEmptyPairHolds(): Void {
		Assert.isNull(WhitespaceInvariant.firstDivergence('', '   \n\t\n', HAXE));
	}

	public function testADroppedTrailingTokenIsReportedWithAnEmptyActual(): Void {
		final d: Null<Divergence> = WhitespaceInvariant.firstDivergence('a;\nb;\n', 'a;\n', HAXE);
		Assert.notNull(d);
		if (d == null) return;
		Assert.equals(2, d.line);
		Assert.equals('b;', d.expected);
		Assert.equals('', d.actual);
	}

	public function testAnAddedTrailingTokenIsReportedWithAnEmptyExpected(): Void {
		final d: Null<Divergence> = WhitespaceInvariant.firstDivergence('a;\n', 'a;\nb;\n', HAXE);
		Assert.notNull(d);
		if (d == null) return;
		Assert.equals('', d.expected);
		Assert.equals('b;', d.actual);
	}

	@:pin('control')
	@:killer('M-VERIFY-TRAILING-COMMA-EXEMPT-OFF')
	public function testADroppedTrailingCommaHoldsInAnyLayout(): Void {
		Assert.isNull(WhitespaceInvariant.firstDivergence('var a = [1, 2,];\n', 'var a = [1, 2];\n', HAXE));
		Assert.isNull(WhitespaceInvariant.firstDivergence('var a = [\n\t1,\n\t2,\n];\n', 'var a = [\n\t1,\n\t2\n];\n', HAXE));
		Assert.isNull(WhitespaceInvariant.firstDivergence('f(a, b,);\n', 'f(a, b);\n', HAXE));
		Assert.isNull(WhitespaceInvariant.firstDivergence('var o = {a: 1,};\n', 'var o = {a: 1};\n', HAXE));
	}

	@:pin('control')
	@:killer('M-VERIFY-TRAILING-COMMA-EXEMPT-OFF')
	public function testAnAddedTrailingCommaHolds(): Void {
		Assert.isNull(WhitespaceInvariant.firstDivergence('var a = [1, 2];\n', 'var a = [\n\t1,\n\t2,\n];\n', HAXE));
	}

	@:pin('control')
	@:killer('M-VERIFY-COMMA-EXEMPT-ANYWHERE')
	public function testADroppedNonTrailingCommaIsReported(): Void {
		final d: Null<Divergence> = WhitespaceInvariant.firstDivergence('var a = [1, 2,];\n', 'var a = [1 2];\n', HAXE);
		Assert.notNull(d);
		if (d == null) return;
		Assert.stringContains(',2', d.expected);
		Assert.stringContains('2', d.actual);
	}

	@:pin('control')
	@:killer('M-VERIFY-COMMA-EXEMPT-ANYWHERE')
	public function testACommaBeforeANonCloserIsReported(): Void {
		Assert.notNull(WhitespaceInvariant.firstDivergence('f(a, b);\n', 'f(a b);\n', HAXE));
	}

	@:pin('control')
	@:killer('M-VERIFY-COMMENT-TRANSPARENCY-OFF')
	public function testADroppedTrailingCommaHoldsThroughALineComment(): Void {
		Assert.isNull(WhitespaceInvariant.firstDivergence('var a = [\n\t1,\n\t2, // two\n];\n', 'var a = [\n\t1,\n\t2 // two\n];\n', HAXE));
	}

	@:pin('control')
	@:killer('M-VERIFY-COMMENT-TRANSPARENCY-OFF')
	public function testADroppedTrailingCommaHoldsThroughAnOwnLineComment(): Void {
		Assert.isNull(
			WhitespaceInvariant.firstDivergence('var a = [\n\t1,\n\t2,\n\t// tail\n];\n', 'var a = [\n\t1,\n\t2\n\t// tail\n];\n', HAXE)
		);
	}

	@:pin('control')
	@:killer('M-VERIFY-COMMENT-TRANSPARENCY-OFF')
	public function testADroppedTrailingCommaHoldsThroughABlockComment(): Void {
		Assert.isNull(WhitespaceInvariant.firstDivergence('f(a, b, /* c */);\n', 'f(a, b /* c */);\n', HAXE));
	}

	@:pin('control')
	@:killer('M-VERIFY-COMMA-EXEMPT-ANYWHERE')
	public function testADroppedCommaBeforeACommentThenANonCloserIsReported(): Void {
		Assert.notNull(WhitespaceInvariant.firstDivergence('f(a, /* c */ b);\n', 'f(a /* c */ b);\n', HAXE));
	}

	public function testACloserInsideACommentDoesNotDropTheComma(): Void {
		Assert.notNull(WhitespaceInvariant.firstDivergence('f(a, // )\n\tb);\n', 'f(a // )\n\tb);\n', HAXE));
	}

}
