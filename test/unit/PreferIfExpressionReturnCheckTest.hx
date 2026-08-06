package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferIfExpressionReturn;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `prefer-if-expression-return` check: an `if / else if / … / else` CHAIN whose every
 * branch is a valued `return` is flagged `Info`, and `fix` collapses it to
 * `return if (c1) a else if (c2) b … else n;`. Disjoint from `prefer-ternary-return`
 * (which handles the if/return + fall-through-return shape): only a chain with at least
 * one `else if` terminating in a plain `else`, of single valued-`return` branches,
 * qualifies. A bare `return;` in any branch disqualifies.
 */
class PreferIfExpressionReturnCheckTest extends Test {

	public function testBasicChainFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-if-expression-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this if/else-if return chain can be a single if-expression return', vs[0].message);
	}

	public function testFixThreeBranch(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	public function testFixFourBranch(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse if (c) return 3;\n\t\telse return 4;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else if (c) 3 else 4;', es[0].text);
	}

	public function testBracedBranchesFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\treturn 1;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn 3;\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	/** A chain with no terminal `else` is not collapsible. */
	public function testNoTerminalElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) return 2;')).length);
	}

	/** A bare `return;` is a distinct node kind (no value) — it disqualifies the chain. */
	public function testBareReturnNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) return;\n\t\telse return 3;')).length);
	}

	public function testNonReturnBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\telse if (b) g();\n\t\telse return 3;')).length);
	}

	public function testMultiStatementBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tg();\n\t\t\treturn 1;\n\t\t} else if (b) return 2;\n\t\telse return 3;'))
			.length);
	}

	/**
	 * A comment between a branch's condition and its value sits in a region holding nothing but
	 * the closing `)`, an opening `{` and the dropped `return ` — no keyword that could make it
	 * belong to a neighbouring branch — so the collapse CARRIES it into that branch's leading
	 * slot, where it keeps the position the author gave it.
	 */
	public function testCommentBetweenConditionAndValueCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1;\n\t\telse if (b) /* keep */ return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) /* keep */ 2 else 3;', es[0].text);
	}

	/** A leading comment the author put on its OWN line keeps it — welded onto the `if (…)` line it would re-read as being about the CONDITION. */
	public function testOwnLineLeadingCommentKeepsItsLine(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a)\n\t\t\t// why one\n\t\t\treturn 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a)\n// why one\n1 else if (b) 2 else 3;', es[0].text);
	}

	/** A comment at the END of a branch's own line rides that branch's value, and the ` else ` moves to the next line — the only legal layout after a `//`. */
	public function testTrailingLineCommentRidesItsBranch(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1; // why one\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 // why one\nelse if (b) 2 else 3;', es[0].text);
	}

	/** A comment sitting on its own line BEFORE the `else` still describes the branch that ends there — it rides the trailing slot and keeps its line. */
	public function testOwnLineCommentBeforeElseCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return 1;\n\t\t// which branch?\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1\n// which branch?\nelse if (b) 2 else 3;', es[0].text);
	}

	/** Layout does not decide the trailing slot — only what PRECEDES the comment does, so a same-line block comment before the `else` rides it too. */
	public function testSameLineCommentBeforeElseCarried(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) return 1; /* x */ else if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 /* x */ else if (b) 2 else 3;', es[0].text);
	}

	/**
	 * The trailing slot's region runs on THROUGH the `else` that opens the next branch, and the
	 * parser projects no node for that keyword — so a comment written after it describes the
	 * branch that FOLLOWS, and emitting it in front of the rebuilt ` else ` would re-read it as
	 * being about the branch before. The gate is what SEPARATES the comment from the value
	 * (whitespace / `;` / `}` only), never how the author broke the lines.
	 */
	public function testCommentAfterElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return 1; else // about the b branch\n\t\tif (b) return 2;\n\t\telse return 3;')).length);
	}

	/** A comment outside every branch seat — here in front of the head condition — has no slot and still fails the site closed. */
	public function testCommentBeforeHeadConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (/* x */ a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;')).length);
	}

	/** End-to-end through the canonical writer: the emitted file holds the collapsed return, valid Haxe (canonicalize re-parses it). */
	public function testFixOutputCollapsesChain(): Void {
		final out: String = applyFixOnce(wrap('if (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.isTrue(out.indexOf('return if (a) 1 else if (b) 2 else 3;') != -1);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-if-expression-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-if-expression-return'));
	}

	/**
	 * A NON-terminal branch value ending in an else-less `if` would ABSORB the emitted ` else `:
	 * the collapse of this chain reads `return if (a) if (q) 1 else if (b) 2 else 3;`, where the
	 * outer condition has LOST its else and `else if (b) 2 else 3` has become `if (q)`'s else
	 * branch. The braces are what let the source `else` bind outward; the single-statement
	 * unwrap re-exposes the else-less tail, and the result re-parses, so only this gate catches it.
	 */
	public function testElseLessConditionalInBranchValueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('if (a) {\n\t\t\treturn if (q) 1;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn 3;\n\t\t}'))
				.length
		);
	}

	/** An `if` WITH its else cannot absorb another one, so the branch is accepted — the gate is arity, not kind. */
	public function testCompleteConditionalInBranchValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\treturn if (q) 1 else 9;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn 3;\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('return if (a) if (q) 1 else 9 else if (b) 2 else 3;', es[0].text);
	}

	/**
	 * The TERMINAL value is exempt from the else-less gate: nothing the rebuild emits follows it
	 * but the closing `;`, so there is no ` else ` for it to absorb. The else-less `if` sits in a
	 * delimited interior here, which is the shape the whole-subtree scan would otherwise refuse —
	 * a bare `if (q) 3` terminal hits a SEPARATE pre-existing defect (its span swallows the
	 * statement's own `;`, so the rebuild emits `;;`, which Haxe rejects).
	 */
	public function testElseLessConditionalInTerminalFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('if (a) {\n\t\t\treturn 1;\n\t\t} else if (b) {\n\t\t\treturn 2;\n\t\t} else {\n\t\t\treturn g(if (q) 3);\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else g(if (q) 3);', es[0].text);
	}

	/**
	 * A comment the parser folded into a returned value's TRAILING trivia is cut out of the kept
	 * span by `IfExpressionChain.tokenSpan` — which is exactly what lets the carry SEE it and ride
	 * it into the branch slot. Without the trim the raw value span SWALLOWS `// why`, the guard
	 * reads it as kept, and the emitted text welds it in front of the ` else `, commenting the
	 * rest of the chain out.
	 */
	public function testTrailingLineCommentInsideValueSpanCarried(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('if (a) return u + v // why\n\t\t\t;\n\t\telse if (b) return 2;\n\t\telse return 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) u + v // why\nelse if (b) 2 else 3;', es[0].text);
	}

	/**
	 * An else-less conditional at the TERMINAL value's ROOT is refused for a SPAN reason, not a
	 * re-parenting one: the parser folds the statement's own `;` into it, so the copied text is
	 * `if (q) k();` and the rebuild appends another, writing `return … else if (q) k();;`. That
	 * re-parses under anyparse, so the `--fix` gate passes it, but `haxe --interp` 4.3.7 rejects
	 * it with `Expected }` — while the INPUT compiles and runs whenever the carrier is
	 * `Void`-typed (verified). So without this gate the fix turns working code into code that
	 * does not compile.
	 */
	public function testElseLessConditionalAtTerminalRootNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) return g();\n\t\telse if (b) return h();\n\t\telse return if (q) k();')).length);
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch RefactorSupport.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new PreferIfExpressionReturn().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferIfExpressionReturn = new PreferIfExpressionReturn();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
