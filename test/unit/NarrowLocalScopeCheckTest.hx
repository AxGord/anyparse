package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.NarrowLocalScope;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `narrow-local-scope` check: a bare local declaration whose every occurrence sits inside one
 * nested block is flagged `Info`, and `fix` moves the declaration into that block, above the plain
 * assignment that is its first occurrence. An initialized declaration, an occurrence outside the
 * block, a first occurrence that is a read or a nested write, a re-binding of the name inside the
 * block, a closure or a conditional-compilation region on the way, and a comment on the moved line
 * are all safe misses.
 */
class NarrowLocalScopeCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(loopCase());
		Assert.equals(1, vs.length);
		Assert.equals('narrow-local-scope', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('local \'m\' is used only inside a nested block; move its declaration there', vs[0].message);
	}

	/** The declaration lands inside the loop, above its first assignment, and leaves the outer list. */
	public function testFixSinksIntoLoop(): Void {
		final out: String = applyFixOnce(loopCase());
		Assert.isTrue(out.indexOf('while (i > 0) {\n\t\t\tvar m:Int;\n\t\t\tm = i;') != -1);
		Assert.equals(-1, out.indexOf('\t\tvar m:Int;\n\t\twhile'));
	}

	/** The keyword and the `:type` ride along verbatim -- `prefer-final` owns the upgrade. */
	public function testFixKeepsKeywordAndType(): Void {
		final out: String = applyFixOnce(wrap('final m:Map<Int, String>;\n\t\twhile (i > 0) {\n\t\t\tm = null;\n\t\t\tg(m);\n\t\t}'));
		Assert.isTrue(out.indexOf('final m:Map<Int, String>;') != -1);
		Assert.isTrue(out.indexOf('while (i > 0) {\n\t\t\tfinal m:Map<Int, String>;') != -1);
	}

	/** A plain `{ … }` block is a sink target like any other. */
	public function testBareBlockFlagged(): Void {
		Assert.equals(1, violations(wrap('var m:Int;\n\t\t{\n\t\t\tm = 1;\n\t\t\tg(m);\n\t\t}')).length);
	}

	/** An initializer would have its evaluation moved -- a different rewrite, not this one. */
	public function testInitializedNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int = 0;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tg(m);\n\t\t}')).length);
	}

	/** Nothing reads it -- that is `unused-local`'s finding, and its fix is a deletion. */
	public function testNeverReferencedNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) g(i);')).length);
	}

	/** One occurrence outside the block keeps the declaration where it is. */
	public function testReadAfterBlockNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t}\n\t\tg(m);')).length);
	}

	/** Occurrences straddling two siblings have no single block to sink into. */
	public function testOccurrencesInTwoSiblingsNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t}\n\t\twhile (i > 1) {\n\t\t\tg(m);\n\t\t}')).length
		);
	}

	/**
	 * SOUNDNESS PIN. The first occurrence must be a write that is a DIRECT statement of the block:
	 * only then can no read of the sunk binding run before it in the same iteration. Here the write
	 * is nested in an `if`, so the read below it may observe the PREVIOUS iteration's value -- which
	 * a per-iteration binding would lose. The same body with the write unnested flags
	 * (`testBasicFlagged`).
	 */
	public function testConditionalFirstWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tif (i > 1) m = i;\n\t\t\tg(m);\n\t\t}')).length);
	}

	/** A read before the first write reads the previous iteration -- same hazard, other spelling. */
	public function testReadBeforeWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tg(m);\n\t\t\tm = i;\n\t\t}')).length);
	}

	/** A compound assignment reads the old value -- not a whole-variable write. */
	public function testCompoundFirstWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm += i;\n\t\t\tg(m);\n\t\t}')).length);
	}

	/** `m = m + 1;` reads the name it binds -- the joined form would be a self-reference. */
	public function testSelfReferencingFirstWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = m + i;\n\t\t\tg(m);\n\t\t}')).length);
	}

	/** The block already binds the name -- sinking would redeclare it. */
	public function testRedeclaredInBlockNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tvar m:Int = 2;\n\t\t\tg(m);\n\t\t}')).length
		);
	}

	/** A `for` iterator of the same name is a binding too, and `Refs` reports it as a `Decl`. */
	public function testForIteratorShadowNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tfor (m in 0...3) g(m);\n\t\t}')).length);
	}

	/** A closure captures ONE binding today and a fresh per-iteration one after the sink. */
	public function testOccurrenceInsideLambdaNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\th(() -> g(m));\n\t\t}')).length);
	}

	/** Sinking into a local function would re-create the declaration per call. */
	public function testBlockInsideLocalFunctionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\tfunction q() {\n\t\t\tm = i;\n\t\t\tg(m);\n\t\t}\n\t\tq();')).length);
	}

	/** The declaration would exist only in the configurations the region compiles. */
	public function testConditionalRegionNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('var m:Int;\n\t\t#if debug\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tg(m);\n\t\t}\n\t\t#end')).length
		);
	}

	/** The occurrences sit in the loop HEADER, not in a block -- there is nothing to sink into. */
	public function testHeaderOnlyOccurrenceNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile ((m = i) > 0) g(m);')).length);
	}

	/** A multi-declarator projects as one node but must never be moved. */
	public function testMultiDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int, n:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tg(m + n);\n\t\t}')).length);
	}

	/** The fix deletes the declaration's line whole, so a comment on it blocks the move. */
	public function testTrailingCommentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int; // keep\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tg(m);\n\t\t}')).length);
	}

	public function testLeadingCommentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('// keep\n\t\tvar m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tg(m);\n\t\t}')).length);
	}

	/**
	 * A macro-reification `$m` splice is not indexed by `Refs`, so the textual completeness scan is
	 * the only thing that sees the read past the block.
	 */
	public function testUnindexedMentionOutsideBlockNotFlagged(): Void {
		Assert.equals(0, violations(wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tg(m);\n\t\t}\n\t\tk(macro $$m);')).length);
	}

	/** Two sinkable declarations of one list produce two independent, non-overlapping edit pairs. */
	public function testTwoDeclarationsBothSink(): Void {
		final src: String = wrap('var m:Int;\n\t\tvar n:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tn = m;\n\t\t\tg(n);\n\t\t}');
		Assert.equals(2, violations(src).length);
		final out: String = applyFixOnce(src);
		Assert.isTrue(out.indexOf('while (i > 0) {\n\t\t\tvar m:Int;\n\t\t\tm = i;\n\t\t\tvar n:Int;\n\t\t\tn = m;') != -1);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('narrow-local-scope'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('narrow-local-scope'));
	}

	/** The motivating shape: a bare declaration feeding a binary-search loop. */
	private inline function loopCase(): String {
		return wrap('var m:Int;\n\t\twhile (i > 0) {\n\t\t\tm = i;\n\t\t\tg(m);\n\t\t}');
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f(i:Int) {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new NarrowLocalScope().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: NarrowLocalScope = new NarrowLocalScope();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer -- the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
