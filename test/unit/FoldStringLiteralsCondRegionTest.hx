package unit;

import utest.Assert;
import anyparse.check.FoldStringLiterals;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

using StringTools;

/**
 * `fold-adjacent-string-literals` inside an OPERAND-RUN conditional-compilation
 * region (`RefShape.condOperandRunKinds`, Haxe `CondSpliceOpExpr`).
 *
 * `A + #if c B + C + #end D` is a token splice, not a precedence tree: with `c` on it
 * is `A + B + C + D`, with `c` off it is `A + D`, because the `+` before `#if` lives
 * outside the region and the one before `#end` lives inside it. The region's children
 * project as the in-branch operands followed by ONE post-directive tail, and the
 * operators between them project as no node at all — so the rule's ordinary
 * `+`-spine walk cannot reach the run, and a rule that reached it naively would move
 * text across a directive seam and break exactly one of the two builds silently.
 *
 * What the arm therefore owes, and what each test here holds it to: it folds the
 * in-branch operands, it stops at the first literal (the arithmetic before it may
 * belong to a chain that starts on the other side of the `#if`), it never touches the
 * tail, it refuses a gap that is not the concatenation operator, and its output is a
 * fixed point.
 */
class FoldStringLiteralsCondRegionTest extends FoldStringLiteralsCheckTestBase {

	/** The TM `crashdumper/SystemData.hx:137` shape, reduced: two literals and an operand inside the branch. */
	private static inline final LIVE: String =
		"class C { function f(p:String) { final a = 'head\\n' + #if flash 'b: ' + p + '\\n' + #end 'tail\\n'; } }";

	/** The in-branch run folds into ONE interpolated literal. */
	public function testInBranchRunFolds(): Void {
		Assert.equals(1, violations(LIVE).length);
		Assert.equals("'b: $p\\n'", foldOf(LIVE));
	}

	/**
	 * The EDIT stays between the first folded operand and the last one — the directive
	 * bytes, the condition and the tail are all outside it. This is the property that
	 * makes the fold safe in both builds, so it is asserted on the span and not inferred
	 * from the emitted text.
	 */
	public function testEditSpanStaysInsideTheBranch(): Void {
		final check: FoldStringLiterals = new FoldStringLiterals();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			LIVE, check.run([{ file: 'C.hx', source: LIVE }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		final replaced: String = LIVE.substring(edits[0].span.from, edits[0].span.to);
		Assert.equals("'b: ' + p + '\\n'", replaced);
		Assert.isTrue(LIVE.substring(0, edits[0].span.from).endsWith('#if flash '));
		Assert.isTrue(LIVE.substring(edits[0].span.to).startsWith(' + #end '));
	}

	/** The post-`#end` operand is never merged in: it is not compiled in the branch the literal would move into. */
	public function testTailIsNotMerged(): Void {
		Assert.isFalse(foldOf(LIVE).indexOf('tail') >= 0);
	}

	/**
	 * One in-branch operand is nothing to merge, whatever the tail looks like. The
	 * literals carry a backslash so the ENCLOSING chain refuses the region as an
	 * operand of its own (a `${ … }` block cannot hold one) — otherwise this fixture
	 * would measure that older behaviour instead of this arm.
	 */
	public function testSingleOperandRunIsNotACandidate(): Void {
		Assert.equals(0, violations("class C { function f(p:String) { final a = 'h\\n' + #if flash 'b\\n' + #end 'tail\\n'; } }").length);
	}

	/** The rule's own output is a fixed point — the folded run has one operand left. */
	public function testFoldedRunIsAFixedPoint(): Void {
		Assert.equals(
			0, violations("class C { function f(p:String) { final a = 'head\\n' + #if flash 'b: $p\\n' + #end 'tail\\n'; } }").length
		);
	}

	/**
	 * The ARITHMETIC head is left alone. `+` is left-associative and the addition the
	 * run's leading numbers belong to starts on the other side of the `#if`: measured on
	 * Haxe 4.3.7, `1 + #if c 2 + 'x' + #end 3` prints `3x3` while folding the head to
	 * `'${2}x'` prints `12x3`. Entering at the first literal makes that question moot.
	 */
	public function testArithmeticHeadIsNotFolded(): Void {
		final src: String = "class C { function f(n:Int) { final a = n + #if flash 1 + 'x' + 'y' + #end 'tail'; } }";
		Assert.equals(1, violations(src).length);
		Assert.equals("'xy'", foldOf(src));
	}

	/** With only ONE operand from the first literal on there is nothing left to merge. */
	public function testArithmeticHeadWithLoneLiteralIsNotACandidate(): Void {
		Assert.equals(0, violations("class C { function f(n:Int) { final a = n + #if flash 1 + 2 + 'x' + #end 'tail'; } }").length);
	}

	/** A run with no literal at all is not a string concatenation — the same refusal a `+` chain gets. */
	public function testRunWithoutLiteralIsNotACandidate(): Void {
		Assert.equals(0, violations('class C { function f(a:Bool, b:Bool) { final c = #if flash a && #end b; } }').length);
	}

	/**
	 * A gap that is not the concatenation operator refuses the run — the operators are
	 * not nodes, so this is the ONLY thing that tells `+` from `==`, `&&`, `||` or a
	 * ternary's `?` / `:` (the same production parses `#if F share ? A : #end B`).
	 *
	 * The pair below differs by ONE token: two regions holding two string-literal
	 * operands and a tail, one joined by `==` and one by `+`.
	 */
	public function testNonConcatOperatorRefusesTheRun(): Void {
		Assert.equals(0, violations("class C { function f(c:Bool) { final a = #if flash 'a\\n' == 'b\\n' && #end c; } }").length);
		Assert.equals("'a\\nb\\n'", foldOf("class C { function f(c:Bool) { final a = #if flash 'a\\n' + 'b\\n' + #end 'c\\n'; } }"));
	}

	/** A comment in a gap fails the same test — its bytes are not the operator, so the run is refused. */
	public function testCommentInAGapRefusesTheRun(): Void {
		Assert.equals(
			0, violations("class C { function f(p:String) { final a = 'h' + #if flash 'b' /* why */ + p + #end 'tail'; } }").length
		);
	}

}
