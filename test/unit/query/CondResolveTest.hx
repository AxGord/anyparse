package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.CondResolve;
import anyparse.runtime.Span.Position;
import utest.Assert;
import utest.Test;

/**
 * `CondResolve` — folding a conditional-compilation region a define DECIDES, at the API.
 *
 * These are the OUTCOME pins: for each shape, the exact bytes the fold produces, or the exact
 * refusal. The delimitation underneath them is `CondQuery`'s and pinned there; what is pinned here
 * is the decision (which branch survives), the recursion (a nested region folded into its
 * parent's replacement), the whole-line hygiene (a deleted region takes its own lines), and the
 * three refusals the shared write gate owns.
 *
 * FIXTURES ARE WRITER-CANONICAL, deliberately: a non-canonical fixture would be refused by the
 * input gate and every assertion below would then be about the gate instead of the op. They are
 * canonical under the writer's COMPILED DEFAULTS, because that is what `optsJson: null` selects —
 * the repo's own `hxformat.json` differs from it by one thing that reaches these fixtures, a space
 * after the return-type colon, and a test that read a config off disk would be measuring the
 * discovery walk. `testANonCanonicalInputIsRefusedWithItsRemedy` is the one fixture that breaks
 * canonicality, on purpose, and its `--reformat` twin is what proves the flag is the way through.
 */
@:nullSafety(Strict)
class CondResolveTest extends Test {

	/** A statement region with an `#else`: the pair that shows the polarity picking opposite branches. */
	private static final BRANCHED: String = fn('#if X\n\t\ta();\n\t\t#else\n\t\tb();\n\t\t#end');

	/** The same with a NEGATED condition, so the `#else` is what a defined `X` selects. */
	private static final NEGATED: String = fn('#if !X\n\t\ta();\n\t\t#else\n\t\tb();\n\t\t#end');

	/** A region with no `#else` and a following statement — the shape whole-line deletion is about. */
	private static final NO_ELSE: String = fn('#if X\n\t\ta();\n\t\t#end\n\t\tb();');

	/** A second decided region inside the branch the outer one keeps. */
	private static final NESTED: String = fn('#if X\n\t\ta();\n\t\t#if X\n\t\tinner();\n\t\t#end\n\t\t#else\n\t\tb();\n\t\t#end');

	/** A decided region inside an UNDECIDED one — the shape that reads backwards and still folds. */
	private static final NESTED_IN_MAYBE: String = fn(
		'#if (other && X)\n\t\ta();\n\t\t#if X\n\t\tinner();\n\t\t#else\n\t\touter();\n\t\t#end\n\t\t#end'
	);

	/** A condition a second flag also decides, so the region is undecided however `X` is asserted. */
	private static final COMPOUND: String = fn('#if (X && other)\n\t\ta();\n\t\t#end');

	/** An `#elseif X` whose opener nothing refuted: `maybe`, not live. */
	private static final LATE_BRANCH: String = fn('#if other\n\t\ta();\n\t\t#elseif X\n\t\tb();\n\t\t#end');

	/** Directive text inside a string literal and inside a comment: neither is a directive. */
	private static final QUOTED: String = fn('final s:String = \'#if X a #else b #end\';\n\t\t// #if X\n\t\tg(s);');

	/** A region that IS the brace-less body of an `if` — the slot the shared gate refuses to empty. */
	private static final BODY_SLOT: String = fn('if (flag) #if X\n\t\ta();\n\t\t#end\n\t\tb();');

	/** `BRANCHED` with one byte of drift, so the input gate has something to refuse. */
	private static final DRIFTED: String = fn('#if X\n\t\ta( );\n\t\t#else\n\t\tb();\n\t\t#end');

	/**
	 * The one-line pair the whole op turns on: the same region folds to its `#if` body under the
	 * positive hypothesis and to its `#else` body under the negative one.
	 *
	 * Asserted as a PAIR in one fixture rather than as two tests, because either half alone is
	 * satisfied by an implementation that ignores the polarity and always keeps the first live
	 * branch it finds.
	 */
	public function testTheStatedPolarityPicksTheBranch(): Void {
		Assert.equals(fn('a();'), okText(fold(BRANCHED, false, false)));
		Assert.equals(fn('b();'), okText(fold(BRANCHED, true, false)));
	}

	/** A negated condition is read, not matched: a defined `X` refutes `!X` and the `#else` is live. */
	public function testANegatedConditionSelectsTheElse(): Void {
		Assert.equals(fn('b();'), okText(fold(NEGATED, false, false)));
	}

	/**
	 * A region with nothing live is DELETED, and it takes its own LINES with it.
	 *
	 * The narrower edit — replacing just the `#if … #end` bytes with nothing — leaves the blank
	 * line those directives sat on, and no writer pass removes it: a blank line is layout the
	 * writer preserves, so the drift would land in the file and stay there.
	 */
	public function testADeadRegionWithNoElseTakesItsLinesWithIt(): Void {
		Assert.equals(fn('b();'), okText(fold(NO_ELSE, true, false)));
	}

	/**
	 * An EXPRESSION-position region folds into the statement around it.
	 *
	 * The shape a node-based reader cannot see at all — the grammar projects one childless
	 * `CondSplice*` node — and the reason this op is a byte splice over directive-delimited spans
	 * rather than a tree rewrite.
	 */
	public function testAnExpressionPositionRegionFoldsIntoItsStatement(): Void {
		Assert.equals(
			'class C {\n\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n\n}\n',
			okText(fold('class C {\n\n\tfunction f():Int {\n\t\treturn #if X 1; #else 2; #end\n\t}\n\n}\n', false, false))
		);
	}

	/**
	 * The shape that motivated the op: a region whose live branch is the FIRST TWO THIRDS of a
	 * ternary, `#end` sitting between the `:` and the else-value on the next line.
	 *
	 * Copied from the real site (`popups/fileDialog/FileDialog.hx` in the reporting project), and
	 * it is the case where nothing but a byte splice plus a writer pass can produce the answer: the
	 * replacement is a syntactically incomplete fragment, and the expression only becomes whole
	 * once the region's own bytes are gone.
	 */
	public function testTheMidExpressionTernaryShapeFoldsToOneExpression(): Void {
		Assert.equals(
			fn('x = c ? new A() : new B();'),
			okText(fold(fn('x = #if X\n\t\t\tc\n\t\t\t\t? new A()\n\t\t\t\t:\n\t\t\t#end\n\t\tnew B();'), false, false))
		);
	}

	/**
	 * A decided region inside the branch a decided region KEEPS is folded by recursion, and counted.
	 *
	 * Recursion rather than a second edit because `applyEdits` splices non-overlapping spans and a
	 * nested span is not one — an outer edit would simply overwrite the inner one's result.
	 */
	public function testANestedDecidedRegionIsFoldedByRecursion(): Void {
		final answer: CondResolveResult = fold(NESTED, false, false);
		Assert.equals(fn('a();\n\t\tinner();'), okText(answer));
		Assert.equals(2, answer.resolved, 'the nested region counts as its own fold');
	}

	/**
	 * A decided region inside an UNDECIDED one is folded ON ITS OWN, and the parent is left and
	 * reported.
	 *
	 * The shape that reads backwards: the parent contributes no edit at all, so the nested one
	 * collides with nothing. `at` is the parent's OPENING directive, which is what a caller renders
	 * as `file:line:col` — pinned by position here so a shift to the region's end or to a later
	 * branch fails.
	 */
	public function testADecidedRegionInsideAnUndecidedOneIsFoldedAlone(): Void {
		final answer: CondResolveResult = fold(NESTED_IN_MAYBE, false, false);
		Assert.equals(fn('#if (other && X)\n\t\ta();\n\t\tinner();\n\t\t#end'), okText(answer));
		Assert.equals(1, answer.resolved);
		Assert.equals(1, answer.undecided.length);
		Assert.equals('#if (other && X)', answer.undecided[0].directive);
		final at: Position = answer.undecided[0].at.lineCol(NESTED_IN_MAYBE);
		Assert.equals(4, at.line);
		Assert.equals(3, at.col);
	}

	/**
	 * A region a flag OUTSIDE the query also decides is left byte-identical and reported — both the
	 * compound-condition form and the `#elseif` after an unrefuted opener.
	 *
	 * No condition SIMPLIFICATION: `(X && other)` does not become `other`. That is a rewrite of the
	 * condition text with its own failure modes, and mixing it in would make a refusal
	 * indistinguishable from a partial edit.
	 */
	public function testAnUndecidedRegionIsLeftUntouchedAndReported(): Void {
		final compound: CondResolveResult = fold(COMPOUND, false, false);
		Assert.equals(COMPOUND, okText(compound));
		Assert.equals(0, compound.resolved);
		Assert.equals('#if (X && other)', compound.undecided[0].directive);
		final late: CondResolveResult = fold(LATE_BRANCH, false, false);
		Assert.equals(LATE_BRANCH, okText(late));
		Assert.equals(0, late.resolved);
		Assert.equals('#if other', late.undecided[0].directive, 'the region is reported by its OPENING directive');
	}

	/**
	 * Directive text inside a string literal or a comment is not a directive, so neither is folded
	 * nor reported.
	 *
	 * Not this class's own gate: `CondDirectives.scan` masks non-code regions through the engine's
	 * one lexer. Pinned here because the failure would be a rewrite of a string's CONTENTS — the
	 * one damage class no re-parse, no lint rule and no `fmt --list` can report.
	 */
	public function testDirectiveTextInAStringOrCommentIsNotARegion(): Void {
		final answer: CondResolveResult = fold(QUOTED, false, false);
		Assert.equals(QUOTED, okText(answer));
		Assert.equals(0, answer.resolved);
		Assert.equals(0, answer.undecided.length);
	}

	/**
	 * A region that is the whole body of a brace-less `if` and folds to NOTHING is refused.
	 *
	 * The one structural question a re-parse cannot ask: the result parses, because the `if` pulls
	 * the FOLLOWING statement into its emptied slot. `BodySlotGuard` owns it and every writer-emit
	 * op inherits it — this fixture is what proves the op reaches the shared gate instead of
	 * splicing on its own.
	 */
	public function testABracelessBodySlotIsRefused(): Void {
		Assert.stringContains('empty body', errMessage(fold(BODY_SLOT, true, false)));
	}

	/**
	 * A non-canonical input is refused with the remedy the whole tool shares, and `--reformat` is
	 * the way through.
	 *
	 * The pair is the point: the same bytes fail and then succeed on the flag alone, so neither
	 * half can pass while the gate is bypassed.
	 */
	public function testANonCanonicalInputIsRefusedWithItsRemedy(): Void {
		Assert.stringContains('apq fmt --write', errMessage(fold(DRIFTED, false, false)));
		Assert.equals(fn('a();'), okText(fold(DRIFTED, false, true)));
	}

	/** `body` as the one statement run of a canonical single-method class. */
	private static inline function fn(body: String): String {
		return 'class C {\n\n\tfunction f():Void {\n\t\t$body\n\t}\n\n}\n';
	}

	/** The op over one in-memory source, with the polarity and the reformat flag the fixture is about. */
	private static function fold(source: String, undefined: Bool, reformat: Bool): CondResolveResult {
		return CondResolve.resolve(source, new HaxeQueryPlugin(), 'X', undefined, reformat);
	}

	/** The rewritten source, failing the assertion with the refusal text when the op declined. */
	private static function okText(answer: CondResolveResult): String {
		return switch answer.result {
			case Ok(text, _):
				text;
			case Err(message):
				Assert.fail('expected a rewrite, got: $message');
				'';
		}
	}

	/** The refusal text, failing the assertion when the op wrote instead of declining. */
	private static function errMessage(answer: CondResolveResult): String {
		return switch answer.result {
			case Ok(_, _):
				Assert.fail('expected a refusal, got a rewrite');
				'';
			case Err(message):
				message;
		}
	}

}
