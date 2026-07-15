package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.FoldStringLiterals;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The `fold-adjacent-string-literals` check: a `+` chain of adjacent plain
 * string literals of the same quote is flagged (`Info`) and folded into one
 * literal; interpolated, mixed-quote, and non-literal operands are left alone. A
 * chain folds in a single pass; a partially-foldable chain folds its inner pair.
 * The fix's merged text is asserted directly, plus one applied round-trip
 * through `RefactorSupport.canonicalize`.
 */
class FoldStringLiteralsCheckTest extends Test {

	public function testDoubleLiteralPairFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f() { final a = "a" + "b"; } }');
		Assert.equals(1, vs.length);
		Assert.equals('fold-adjacent-string-literals', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixMergesDoublePair(): Void {
		Assert.equals('"ab"', foldOf('class C { function f() { final a = "a" + "b"; } }'));
	}

	public function testChainFoldsInOnePass(): Void {
		final src: String = 'class C { function f() { final a = "x" + "y" + "z"; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"xyz"', foldOf(src));
	}

	public function testSingleQuotedPlainFolds(): Void {
		final src: String = "class C { function f() { final a = 'p' + 'q'; } }";
		Assert.equals(1, violations(src).length);
		Assert.equals("'pq'", foldOf(src));
	}

	public function testInterpolatedNotFolded(): Void {
		Assert.equals(0, violations("class C { function f(name:String) { final a = 'lead $name' + 'tail'; } }").length);
	}

	public function testMixedQuotesNotFolded(): Void {
		Assert.equals(0, violations("class C { function f() { final a = \"m\" + 'n'; } }").length);
	}

	public function testNonLiteralOperandNotFolded(): Void {
		Assert.equals(0, violations('class C { function f(name:String) { final a = "a" + name + "b"; } }').length);
		Assert.equals(0, violations('class C { function f() { final a = "z" + 1; } }').length);
	}

	public function testPartialChainFoldsInnerPair(): Void {
		final src: String = 'class C { function f(name:String) { final a = "a" + "b" + name; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"ab"', foldOf(src));
	}

	public function testFixAppliedResult(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = "a" + "b";\n\t}\n}';
		final check: FoldStringLiterals = new FoldStringLiterals();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.contains('"ab"'));
				Assert.isFalse(text.contains('"a" + "b"'));
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('fold-adjacent-string-literals'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('fold-adjacent-string-literals'));
	}

	public function testDollarEscapedSingleQuotedFolds(): Void {
		// '$$' is an escaped literal $ (a `Dollar` fragment, not interpolation) — plain, so it folds.
		Assert.equals("'a$$bc'", foldOf("class C { function f() { final a = 'a$$b' + 'c'; } }"));
	}

	/**
	 * A foldable chain formatted ACROSS source lines is deliberate width layout —
	 * silent; its same-line inner prefix (left-assoc subtree) still folds.
	 */
	public function testCrossLineChainSkipped(): Void {
		Assert.equals(0, violations('class C { function f() { final a = "long message "\n\t\t+ "split for width"; } }').length);
	}

	/** The same-line prefix of a cross-line chain is flagged and folds on its own. */
	public function testSameLinePrefixOfCrossLineChainFolds(): Void {
		final src: String = 'class C { function f() { final a = "a" + "b"\n\t\t+ "tail"; } }';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('"ab"', foldOf(src));
	}


	private function violations(src: String): Array<Violation> {
		return new FoldStringLiterals().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The merged-literal text the fix emits for `src`'s foldable concat (empty if none). */
	private function foldOf(src: String): String {
		final check: FoldStringLiterals = new FoldStringLiterals();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		return edits.length > 0 ? edits[0].text : '';
	}

}
