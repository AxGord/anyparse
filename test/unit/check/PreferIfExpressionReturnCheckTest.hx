package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.CheckScan;
import anyparse.check.Linter;
import anyparse.check.PreferIfExpressionReturn;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.QueryNode;
import anyparse.query.SourceComments;
import anyparse.runtime.Span;
import haxe.Exception;
import utest.Assert;
import utest.Test;

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
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tg();\n\t\t\treturn 1;\n\t\t} else if (b) return 2;\n\t\telse return 3;')).length);
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

	/**
	 * A trailing `// …` after a branch's `;` rides that branch's slot into the rebuilt chain.
	 *
	 * S46 briefly REFUSED this site, on a probe that had no `hxformat.json` beside it: under compiled
	 * defaults the rebuilt chain fits one line, the writer cannot keep a `//` there, and `--fix`
	 * answered `the edit cannot be applied without losing the comment`. Under a config that WRAPS the
	 * branches - this project's own - the same edit lands and the comment survives, so the refusal was
	 * config-blindness, not a writer limit. The gate is gone; the review that caught it ran every probe
	 * with the project config beside the fixture.
	 */
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

	/**
	 * The FALL-THROUGH spelling of the same control flow is claimed too: a run of no-`else` `if`s
	 * each returning a value, plus the sibling return past the run. `redundant-else-after-return`
	 * rewrites the chain INTO this shape, so the rule that owns one has to own the other or the
	 * de-nest hands the code to a pairwise march this rule exists to replace.
	 *
	 * The pair is one test: a two-`if` cascade is claimed, a one-`if` one is not - two leaf values
	 * are a ternary and belong to `prefer-ternary-return`.
	 */
	public function testFallThroughCascadeClaimed(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;'));
		Assert.equals(1, vs.length);
		Assert.equals('this if/return cascade can be a single if-expression return', vs[0].message);
		Assert.equals(0, violations(wrap('if (a) return 1;\n\t\treturn 3;')).length, 'two leaf values are a ternary, not a chain');
		// The collector is GREEDY, so every later index of one run would collect a shorter cascade of
		// its own: only the index whose predecessor is NOT a rung is a head. A two-`if` cascade cannot
		// show that (its tail index collects one branch, below the rung minimum); a three-`if` one can.
		Assert.equals(
			1, violations(wrap('if (a) return 1;\n\t\tif (b) return 2;\n\t\tif (c) return 3;\n\t\treturn 4;')).length,
			'a longer cascade is reported ONCE, at its head'
		);
	}

	/** The cascade collapses to the same text the else-linked chain does, in ONE edit. */
	public function testFallThroughCascadeFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	/**
	 * A terminal value that is itself a ternary spine becomes rungs of the chain, which is what
	 * makes ONE edit land where the composed `--fix` needed the ternary the chain rule condemns.
	 * The head here writes a single `if`, so without the fold there would be one rung and no claim.
	 */
	public function testTerminalTernaryFoldedIntoRungs(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if (a) return 1;\n\t\treturn p ? q : r;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (p) q else r;', es[0].text);
	}

	/**
	 * The march gate: this rule may not claim a cascade `prefer-ternary-return` would refuse, or the
	 * claim silences that rule and CHANGES the fixed point - a guard cascade nobody asked to fold
	 * becomes one expression. A bool-literal rung is the gate's largest class (`cond ? true : <not
	 * provably Bool>` is what that rule calls a stuck collapse); the value pair is the control.
	 */
	public function testBoolLiteralRungNotClaimed(): Void {
		Assert.equals(
			0, violations(wrap('if (a) return false;\n\t\tif (b) return g();\n\t\treturn h();')).length,
			'a bool-literal rung is left to the pairwise march'
		);
		Assert.equals(
			1, violations(wrap('if (a) return e();\n\t\tif (b) return g();\n\t\treturn h();')).length,
			'the same cascade with value rungs is claimed'
		);
	}

	/**
	 * The other two halves of the march gate, each with its own control, because a rung value the
	 * pairwise march refuses is a rung this rule may not claim either: a STATEMENT-LIKE value (a
	 * `switch` / `if` / `try` / block used as a value) reads no better as a chain rung than as the
	 * two statements it replaced, and a ternary with exactly ONE bool-literal branch is a collapse
	 * `simplify-boolean-ternary` is mid-way through - burying it one level deeper loses its licence.
	 */
	public function testMarchRefusedRungValuesNotClaimed(): Void {
		Assert.equals(
			0, violations(wrap('if (a) return switch x {\n\t\t\tcase _: 1;\n\t\t};\n\t\tif (b) return g();\n\t\treturn h();')).length,
			'a switch used as a rung value is left to the pairwise march'
		);
		Assert.equals(
			0, violations(wrap('if (a) return c ? true : g();\n\t\tif (b) return g();\n\t\treturn h();')).length,
			'so is a boolean ternary mid-reduction'
		);
		Assert.equals(
			1, violations(wrap('if (a) return c ? e() : g();\n\t\tif (b) return g();\n\t\treturn h();')).length,
			'the same shape with a VALUE ternary is claimed'
		);
	}

	/**
	 * A rung condition is copied paren-UNWRAPPED, the way `PreferIfExpressionChain.spine` unwraps its
	 * own: the emitted `if (` … `)` supplies the delimiters, so a copied pair only draws a
	 * `redundant-parens` finding on the result. Measured on openfl\'s `Tile.__findTileset`, where a
	 * source `(parent is Tilemap)` reached the rebuilt chain with both pairs while the pairwise route
	 * emitted it bare - the same input, two spellings of the output.
	 */
	public function testRungConditionParensDropped(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('if ((a)) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return if (a) 1 else if (b) 2 else 3;', es[0].text);
	}

	/**
	 * A cascade inside a conditional-compilation region is seen, because this rule reads the
	 * BRANCH-AWARE projection. It has to: `prefer-ternary-return` reads that projection and now defers
	 * to this one, and in the plain projection a `#if` region is ONE node whose branches are flattened
	 * children with no statement list at all - so the pair would be deferred to a walk that never saw
	 * it. Measured on openfl\'s `Lib.isXMLName`, whose three-`return` cascade under `#end` lost its
	 * only finding that way.
	 */
	public function testCascadeInsideConditionalRegionClaimed(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Int {\n\t\t#if js\n\t\tif (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;\n\t\t#end\n\t}\n}'
			).length,
			'the branch-aware projection gives the region its own statement list'
		);
		Assert.equals(
			1,
			edits(
				'class C {\n\tfunction f():Int {\n\t\t#if js\n\t\tif (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;\n\t\t#end\n\t}\n}'
			).length,
			'and `fix` reads the same projection, or the finding would have no edit'
		);
	}

	/**
	 * The head of a run is the index whose predecessor is not a rung THIS rule would collect, and
	 * "rung" has to mean a valued `return`, not just a no-`else` `if` with one statement. A leading
	 * `if (x) g();` is a rung by shape alone, and the shape-only test skipped the index behind it -
	 * hiding the whole cascade that followed, while the longer run starting at the leading statement
	 * was refused for not returning. The control is the same cascade with nothing in front of it.
	 */
	public function testNonReturnStatementDoesNotHideTheCascade(): Void {
		Assert.equals(
			1, violations(wrap('if (x) g();\n\t\tif (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;')).length,
			'a leading non-return guard does not swallow the cascade behind it'
		);
		Assert.equals(
			1, violations(wrap('if (a) return 1;\n\t\tif (b) return 2;\n\t\treturn 3;')).length,
			'and the same cascade alone is reported once'
		);
	}

	/**
	 * The terminal-ternary fold is refused when a comment sits inside that spine, asked of the parsed
	 * comment TOKENS rather than a text scan: a `//` inside a STRING literal is not a comment, and a
	 * raw scan blocked the fold on a URL.
	 */
	public function testStringLiteralSlashesDoNotBlockTheFold(): Void {
		Assert.equals(
			1, violations(wrap('if (a) return "x";\n\t\treturn b ? "http://example.com" : "y";')).length,
			'a `//` inside a string literal is not a comment'
		);
		Assert.equals(
			0, violations(wrap('if (a) return "x";\n\t\treturn b ? /* why */ "p" : "y";')).length,
			'a real comment inside the folded spine still refuses'
		);
	}

	/**
	 * The march gate governs the CHAIN arm too, and `redundant-else-after-return` keeps its finding
	 * when it refuses - the claim is what silences that rule, so a chain this one will not rewrite
	 * must not be claimed. Same fixture both ways: bool-literal rungs are refused, value rungs are
	 * claimed.
	 */
	public function testBoolLiteralElseChainNotClaimed(): Void {
		Assert.isFalse(
			claims('if (a) return false;\n\t\telse if (b) return g();\n\t\telse return h();'),
			'a bool-literal rung is left to the pairwise march, so the de-nest keeps its finding'
		);
		Assert.isTrue(
			claims('if (a) return e();\n\t\telse if (b) return g();\n\t\telse return h();'), 'the same chain with value rungs is claimed'
		);
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return switch CanonicalEdit.canonicalize(src, edits(src), true, new HaxeQueryPlugin(), null) {
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

	/** Whether the rule CLAIMS the chain headed by the first `if` of `body` - the question the two deferring rules ask. */
	private function claims(body: String): Bool {
		final source: String = wrap(body);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		// Both nulls are "cannot happen" for a fixture this file wrote, and a quiet `false` would make
		// every `isFalse` assertion pass vacuously the day one stops parsing.
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) throw new Exception('fixture does not parse: $source');
		final head: Null<QueryNode> = firstIf(tree, plugin.refShape().ifStatementKinds ?? []);
		if (head == null) throw new Exception('fixture holds no if statement: $source');
		return PreferIfExpressionReturn.claimsChain(
			head, source, SourceComments.collectCommentTokens(plugin.lexicalRegions(source)), plugin.refShape()
		);
	}

	/** The first `if` STATEMENT in document order, or null. */
	private function firstIf(node: QueryNode, ifKinds: Array<String>): Null<QueryNode> {
		if (ifKinds.contains(node.kind)) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstIf(c, ifKinds);
			if (hit != null) return hit;
		}
		return null;
	}

}
