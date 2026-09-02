package unit;

import anyparse.format.comment.CommentInventory;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.InertRegions;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * The differential pin between the THREE answers this project holds to "which bytes of a Haxe
 * file are not code": the hand byte scanner behind the seam (`HaxeLexicalRegions`, reached as
 * `GrammarPlugin.lexicalRegions`), the writer's independent comment lexer
 * (`CommentInventory.scan`), and the GENERATED PARSER's literal nodes. Nothing pinned them
 * against each other before this class, and `RefactorSupport.collectCommentTokens` — most of the
 * tool — reads the first one to gate DELETES.
 *
 * ## The contract, stated before any assertion
 *
 * The three answers are not interchangeable, and a pin that hid the differences would prove
 * nothing. What each one is:
 *
 *  - **The scanner** emits FLAT, non-overlapping, OUTERMOST regions. A `${ … }` interpolation
 *    hole is CODE inside a string literal, but the region model has no way to say so: the whole
 *    `'…'` literal is ONE `StringLit`, holes included, and a literal nested in a hole opens no
 *    region of its own. That flatness is deliberate — `LexicalRegions.regionAt` returns the FIRST
 *    containing region, so nesting could not be expressed anyway.
 *  - **`CommentInventory.scan`** answers only about comments, and it walks INTO an interpolation
 *    hole, because a comment written there is a comment the writer must not delete. It therefore
 *    reports a token the scanner deliberately does not — the one place the two legitimately
 *    disagree, pinned by name in `testCommentInsideAnInterpolationHoleIsTheOneDisagreement`.
 *  - **The tree** carries a node per literal, nested ones included, and carries NO comments at
 *    all (they are trivia). Its literal nodes are `SingleStringExpr` / `DoubleStringExpr` /
 *    `RegexLit`; reduced to the outermost of those, its spans are directly comparable to the
 *    scanner's — same `[from, to)` convention, delimiters included on both sides.
 *
 * ## What is asserted, and why that shape catches the two historical corruptions
 *
 * The load-bearing arm is `testEveryTreeLiteralIsExactlyOneScannerRegion`: every outermost
 * literal NODE must be an EXACTLY-equal scanner region. Exact rather than contained is what makes
 * it a pin on both failure directions the scanner's own doc records:
 *
 *  - `skipStringLiteral` mis-paired the quotes of `'${cond ? '// note' : X}'`, so the region ended
 *    mid-expression and the `//` inside opened a comment region OVER LIVE SOURCE —
 *    `unused-import --fix` then deleted an import that line was using. Under-reaching that way
 *    leaves the outer literal's node span matching NO region.
 *  - a regex body may legally contain a comment opener (`~/[\/*]/`), and without the regex arm
 *    that opener started a phantom block comment running to EOF. Over-reaching that way swallows
 *    every later literal, so their node spans match no region either.
 *
 * Both corruptions are fixed today; this class is what keeps them fixed, and what makes the next
 * divergence visible instead of silent.
 *
 * ## Scope and cost
 *
 * The sweeps run over `src` and `test` — 1553 files, both arms measured at 2.0 s wall together,
 * of which the parse is nearly all. The same two arms were also run once, out of tree, over the
 * haxe-formatter `.hxtest` corpus (1890 sources), Pony, the haxe-formatter sources and the Haxe
 * 4.3.7 standard library: 6784 sources, ZERO comment divergences and ZERO tree literals missing
 * from the scanner. The three classes of literal the tree cannot see are all scanner-ONLY and are
 * pinned as fixtures below, not as a sweep, precisely because they are a property of Haxe rather
 * than of this project's sources.
 */
@:nullSafety(Strict)
class LexicalRegionAgreementTest extends Test {

	/** Divergences quoted in a failure message before it elides the rest. */
	private static inline final REPORTED_DIVERGENCES: Int = 8;

	/** The tree kinds that ARE a literal — `InertRegions` names the same three. */
	private static final LITERAL_KINDS: Array<String> = ['SingleStringExpr', 'DoubleStringExpr', 'RegexLit'];

	/** The roots swept by the two whole-tree arms, relative to the runner's cwd. */
	private static final SWEEP_ROOTS: Array<String> = ['src', 'test'];

	/**
	 * The scanner and the writer's own comment lexer must report the SAME comment tokens, byte
	 * for byte, over every file this project carries. Two independent hand lexers answering one
	 * question is the drift risk this class exists for; the corruption both of them gate is a
	 * silent delete, so the sweep is over the real tree rather than over fixtures.
	 */
	public function testScannerAndCommentInventoryAgreeOverTheProjectTree(): Void {
		#if (sys || nodejs)
		final diverged: Array<String> = [];
		var swept: Int = 0;
		for (path in sweepPaths()) {
			final source: String = File.getContent(path);
			swept++;
			final mismatch: Null<String> = firstMismatch(scannerCommentSpans(source), inventoryCommentSpans(source));
			if (mismatch != null) diverged.push('$path: $mismatch');
		}
		Assert.isTrue(swept > 1000, 'the sweep must cover the project tree, saw $swept files');
		Assert.equals(0, diverged.length, 'comment lexers disagree:\n  ${elide(diverged)}');
		#else
		Assert.fail('this sweep needs a filesystem — it must not compile to a silent pass');
		#end
	}

	/**
	 * Every OUTERMOST literal node of a parsed file must be an exactly-equal scanner literal
	 * region. The direction that matters: a scanner region ending early or running long makes the
	 * node span match nothing, which is how both recorded corruptions present. The reverse
	 * direction — a scanner region with no node — is legitimate and is pinned separately by
	 * `testTheTreeCannotSeeAStringLiteralInThreePositions`.
	 */
	public function testEveryTreeLiteralIsExactlyOneScannerRegion(): Void {
		#if (sys || nodejs)
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final orphans: Array<String> = [];
		var parsed: Int = 0;
		for (path in sweepPaths()) {
			final source: String = File.getContent(path);
			final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: Exception) null;
			if (tree == null) continue;
			parsed++;
			for (orphan in literalsWithoutARegion(source, tree)) orphans.push('$path: $orphan');
		}
		Assert.isTrue(parsed > 1000, 'the sweep must parse the project tree, parsed $parsed files');
		Assert.equals(0, orphans.length, 'tree literals the scanner does not report exactly:\n  ${elide(orphans)}');
		#else
		Assert.fail('this sweep needs a filesystem — it must not compile to a silent pass');
		#end
	}

	/**
	 * The comparator both sweeps run on must REPORT a planted divergence. Without this the two
	 * green sweeps above are equally consistent with a comparator that can only say "same".
	 */
	public function testTheComparatorReportsAPlantedDivergence(): Void {
		final truth: Array<Span> = [new Span(10, 20), new Span(30, 40)];
		Assert.isNull(firstMismatch(truth, [new Span(10, 20), new Span(30, 40)]), 'identical inputs must compare equal');
		Assert.notNull(firstMismatch(truth, [new Span(10, 21), new Span(30, 40)]), 'a shifted end must be reported');
		Assert.notNull(firstMismatch(truth, [new Span(10, 20)]), 'a dropped region must be reported');
		Assert.notNull(firstMismatch(truth, truth.concat([new Span(50, 60)])), 'an extra region must be reported');
	}

	/**
	 * The same audit for the literal arm: `literalsWithoutARegion` must name a literal whose
	 * region is absent. A source the scanner deliberately reports as ONE region while the tree
	 * splits it would be the failure shape, so the probe plants it by asking the helper to
	 * compare a real tree against a region set the scanner never produced.
	 */
	public function testTheLiteralAuditReportsAPlantedOrphan(): Void {
		final source: String = "class C { var a = 'x'; }";
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		Assert.equals(0, literalsWithoutARegion(source, tree).length, 'the real pair must agree');
		Assert.equals(1, orphansAgainst(tree, ['0:1']).length, 'a planted region set must leave the literal orphaned');
	}

	/**
	 * The four shapes whose mis-lexing produced, or would produce, a region over live source. Each
	 * must be ONE region covering the whole literal — the interpolation hole is code, but the
	 * region model says the literal, not the hole.
	 */
	public function testAnInterpolationHoleStaysInsideOneStringRegion(): Void {
		assertSingleRegion("class C { var a = '${cond ? '// note' : x}'; var b = 1; }", "'${cond ? '// note' : x}'");
		assertSingleRegion("class C { var a = '/* not a comment'; var b = 1; }", "'/* not a comment'");
		assertSingleRegion('class C { var a = ~/[\\/*]/; var b = 1; }', '~/[\\/*]/');
		assertSingleRegion("class C { var a = '$$$$ {not a hole}'; var b = 1; }", "'$$$$ {not a hole}'");
	}

	/**
	 * The ONE construct on which the two comment lexers legitimately differ, pinned with both
	 * answers so a future reader does not "fix" either.
	 *
	 * A comment inside a `${ … }` hole IS a comment for the writer — `CommentInventory` exists to
	 * refuse a round trip that would delete it — and is NOT one for the scanner, whose flat region
	 * model cannot nest a comment inside a string and whose consumers must never see a comment
	 * region opened inside a literal. Both answers are correct for their reader. The construct
	 * does not occur in any of the 6784 sources measured, which is why the sweeps above are green.
	 */
	public function testCommentInsideAnInterpolationHoleIsTheOneDisagreement(): Void {
		final block: String = "class C { var a = '${ /* c */ x }'; }";
		assertSingleRegion(block, "'${ /* c */ x }'");
		Assert.equals(0, scannerCommentSpans(block).length, 'the scanner must open no comment inside a literal');
		Assert.equals(1, inventoryCommentSpans(block).length, 'the writer audit must see the comment it has to preserve');

		final line: String = "class C { var a = '${ x // c\n }'; }";
		assertSingleRegion(line, "'${ x // c\n }'");
		Assert.equals(0, scannerCommentSpans(line).length, 'the scanner must open no comment inside a literal');
		Assert.equals(1, inventoryCommentSpans(line).length, 'the writer audit must see the comment it has to preserve');
	}

	/**
	 * Three positions where Haxe allows a string literal and the query tree carries no node for
	 * it: a conditional-compilation CONDITION, a `#error` message — both are directive text, which
	 * survives only as trivia — and a quoted object-literal KEY, which the projection folds into
	 * the field node's name slot. The scanner sees all three.
	 *
	 * This is the measured reason a tree-derived `lexicalRegions` cannot replace the scan: over
	 * the haxe-formatter corpus 34 of 1775 PARSED sources carry such a literal, and over Pony plus
	 * the Haxe 4.3.7 standard library 83 of 3340. The direction is uniformly scanner-only, which
	 * is the safe one — an unmasked region costs a refusal, never a delete.
	 */
	public function testTheTreeCannotSeeAStringLiteralInThreePositions(): Void {
		assertScannerOnlyLiteral("package p;\n#if (haxe_ver >= '4.0.0')\nclass C {}\n#end", "'4.0.0'");
		assertScannerOnlyLiteral('package p;\n#if !js\n#error "only js"\n#end\nclass C {}', '"only js"');
		assertScannerOnlyLiteral('class C { var o = {"key": 1}; }', '"key"');
	}

	/**
	 * The other half of the same crux: the ops run this scan on RAW, possibly mid-edit text, and
	 * a parse has NO answer there — `RefactorSupport.nameBoundInRange` says so in code, falling
	 * back to the pure text scan the moment `classifyOccurrences` reports a parse failure. Both
	 * fixtures here fail to parse and both are answered by the scanner. Measured over the corpus,
	 * 115 of 1890 sources (6.1 %) do not parse at all.
	 */
	public function testTheScannerAnswersWhereNoParseCan(): Void {
		assertUnparseableButScanned('class C { /* open\nvar a = 1;', 1);
		assertUnparseableButScanned("class C { var a = 'oops;\n }", 1);
	}

	/**
	 * The scanner's delimiters must be the ones the grammar's own format class DECLARES. The two
	 * are spelled twice today — `HaxeFormat.lineComment` / `blockComment` / `stringQuote` are read
	 * at MACRO time into `FormatReader.commentPatterns`, while `HaxeLexicalRegions` hardcodes the
	 * same characters — so this is what keeps the copies honest. Fixtures are BUILT from the
	 * declaration rather than compared to constants: change the declaration and this arm reports
	 * that the scanner did not follow.
	 */
	public function testTheScannerUsesTheDelimitersHaxeFormatDeclares(): Void {
		final format: HaxeFormat = HaxeFormat.instance;
		final line: Null<String> = format.lineComment;
		Assert.notNull(line, 'the Haxe format must declare a line comment');
		if (line != null) assertSingleRegion('class C {}\n$line note\n', '$line note');
		final block: Null<{ open: String, close: String }> = format.blockComment;
		Assert.notNull(block, 'the Haxe format must declare a block comment');
		if (block != null) assertSingleRegion('class C {}\n${block.open} note ${block.close}\n', '${block.open} note ${block.close}');
		Assert.isTrue(format.stringQuote.length > 0, 'the Haxe format must declare a string quote');
		for (quote in format.stringQuote) assertSingleRegion('class C { var a = ${quote}x$quote; var b = 1; }', '${quote}x$quote');
	}

	/**
	 * `InertRegions` is the fourth reader of the same question and had no test at all. It is not a
	 * fourth lexer: its comment half comes off the SEAM (`RefactorSupport.collectCommentRegions`,
	 * hence `HaxeLexicalRegions`) and its literal half off the tree, segment by segment. This pins
	 * both halves against the scanner — every comment span it returns is exactly a scanner comment
	 * region, and every literal span it returns lies INSIDE a scanner literal region.
	 */
	public function testInertRegionsAgreesWithTheScannerOnBothHalves(): Void {
		final source: String = "class C {\n\t// note\n\tvar a = 'text ${x} tail';\n\tvar b = \"whole\";\n\tvar c = ~/re/g;\n}";
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final inert: Array<Span> = InertRegions.of(source, tree);
		final comments: Array<Span> = scannerCommentSpans(source);
		final literals: Array<Span> = scannerLiteralSpans(source);
		Assert.isTrue(inert.length > comments.length, 'the literal half must contribute spans');
		for (span in inert) {
			final isComment: Bool = holdsSpan(comments, span);
			final insideLiteral: Bool = enclosedBy(literals, span);
			Assert.isTrue(
				isComment || insideLiteral, 'inert span [${span.from},${span.to}) is neither a comment region nor inside a literal region'
			);
		}
	}

	/**
	 * The two `InertRegions` answers its one reader (`TypeRefPrinter.canAddImport`) depends on: a
	 * `${ … }` hole is a real reference and must NOT be masked, while the text around it must be —
	 * masking a hole would let an import be added over a name that is read right there. With no
	 * tree the comment half stands alone, which is the conservative reading a caller with no parse
	 * gets.
	 */
	public function testInertRegionsLeavesAnInterpolationHoleUnmasked(): Void {
		final source: String = "class C { var a = 'lead ${Dep.x} tail'; }";
		final holeAt: Int = source.indexOf('Dep');
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final inert: Array<Span> = InertRegions.of(source, tree);
		Assert.isFalse(coversOffset(inert, holeAt), 'a name read inside a hole must keep its veto');
		final leadAt: Int = source.indexOf('lead');
		Assert.isTrue(coversOffset(inert, leadAt), 'the text around a hole is inert');
		Assert.equals(0, InertRegions.of(source, null).length, 'without a tree only the comment half remains, and this source has none');
	}

	/**
	 * The two comment lexers on the shapes that DISCRIMINATE them. The whole-tree sweep above is
	 * green on 6784 real sources and stays green when `CommentInventory`'s regex arm is deleted —
	 * measured, an explicit mutation arm — because no real file carries a regex body holding a
	 * comment opener. A sweep that cannot fail on a mutation is not pinning it, so the adversarial
	 * shapes are named here: each is one where a lexer missing an arm opens a comment over live
	 * source, which is the corruption class this whole class exists for.
	 */
	public function testTheTwoCommentLexersAgreeOnTheAdversarialShapes(): Void {
		for (source in [
			'class C { var r = ~/[\\/*]/; }\n// real\n',
			"class C { var s = '/* not a comment'; }\n// real\n",
			"class C { var s = '${cond ? '// note' : x}'; }\n// real\n",
			"class C { var s = '$$$${still text}'; }\n// real\n",
			'class C { var s = "// not a comment"; }\n/* real */\n',
			'class C { }\n/* unterminated\n'
		]) {
			final mismatch: Null<String> = firstMismatch(scannerCommentSpans(source), inventoryCommentSpans(source));
			Assert.isNull(mismatch, 'the two comment lexers disagree on `$source`: $mismatch');
		}
	}

	/** The scanner's COMMENT regions of `source`, in source order. */
	private function scannerCommentSpans(source: String): Array<Span> {
		final out: Array<Span> = [];
		for (region in HaxeLexicalRegions.scan(source)) switch region.kind {
			case LineComment, BlockComment:
				out.push(new Span(region.from, region.to));
			case StringLit, RegexLit:
		}
		return out;
	}

	/** The scanner's LITERAL regions of `source` — string and regex — in source order. */
	private function scannerLiteralSpans(source: String): Array<Span> {
		final out: Array<Span> = [];
		for (region in HaxeLexicalRegions.scan(source)) switch region.kind {
			case StringLit, RegexLit:
				out.push(new Span(region.from, region.to));
			case LineComment, BlockComment:
		}
		return out;
	}

	/** The writer audit's comment tokens of `source`, in source order. */
	private function inventoryCommentSpans(source: String): Array<Span> {
		final out: Array<Span> = [];
		CommentInventory.scan(source, (start: Int, end: Int) -> out.push(new Span(start, end)));
		return out;
	}

	/**
	 * The first position at which `actual` differs from `expected`, or null when the two span
	 * lists are identical. Kept as a pure comparator so
	 * `testTheComparatorReportsAPlantedDivergence` can audit it for vacuity.
	 */
	private function firstMismatch(expected: Array<Span>, actual: Array<Span>): Null<String> {
		final shared: Int = expected.length < actual.length ? expected.length : actual.length;
		for (i in 0...shared) if (expected[i].from != actual[i].from || expected[i].to != actual[i].to)
			return 'at #$i expected [${expected[i].from},${expected[i].to}) got [${actual[i].from},${actual[i].to})';
		return expected.length == actual.length ? null : 'count ${expected.length} vs ${actual.length}';
	}

	/** Every outermost literal node of `tree` that `source`'s scanner regions do not report exactly. */
	private function literalsWithoutARegion(source: String, tree: QueryNode): Array<String> {
		final keys: Array<String> = [for (span in scannerLiteralSpans(source)) '${span.from}:${span.to}'];
		return orphansAgainst(tree, keys);
	}

	/** `literalsWithoutARegion` against an explicit region key set — the seam its vacuity audit plants into. */
	private function orphansAgainst(tree: QueryNode, regionKeys: Array<String>): Array<String> {
		final out: Array<String> = [];
		collectOutermostLiterals(tree, (node: QueryNode, span: Span) -> {
			if (!regionKeys.contains('${span.from}:${span.to}')) out.push('${node.kind} [${span.from},${span.to})');
		});
		return out;
	}

	/** Visit every literal node of `node`'s subtree that no literal node encloses. */
	private function collectOutermostLiterals(node: QueryNode, visit: (node:QueryNode, span:Span) -> Void): Void {
		final span: Null<Span> = node.span;
		if (span != null && LITERAL_KINDS.contains(node.kind)) {
			visit(node, span);
			return;
		}
		for (child in node.children) collectOutermostLiterals(child, visit);
	}

	/** `source` must lex to exactly one non-code region, and its text must be `expected`. */
	private function assertSingleRegion(source: String, expected: String): Void {
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.equals(1, regions.length, 'expected one region in `$source`, got ${regions.length}');
		if (regions.length != 1) return;
		Assert.equals(expected, source.substring(regions[0].from, regions[0].to));
	}

	/** The scanner must report `expected` as a literal region while the parsed tree carries no literal node. */
	private function assertScannerOnlyLiteral(source: String, expected: String): Void {
		final literals: Array<Span> = scannerLiteralSpans(source);
		Assert.equals(1, literals.length, 'expected one literal region in `$source`, got ${literals.length}');
		if (literals.length != 1) return;
		Assert.equals(expected, source.substring(literals[0].from, literals[0].to));
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		var nodes: Int = 0;
		collectOutermostLiterals(tree, (_: QueryNode, _: Span) -> nodes++);
		Assert.equals(0, nodes, 'the tree is expected to carry no literal node for `$expected`');
	}

	/** `source` must fail to parse while the scanner still reports `regions` non-code regions. */
	private function assertUnparseableButScanned(source: String, regions: Int): Void {
		var parsed: Bool = true;
		try
			new HaxeQueryPlugin().parseFile(source)
		catch (exception: Exception)
			parsed = false;
		Assert.isFalse(parsed, 'this fixture must be unparseable — it is the crux of the derivation question');
		Assert.equals(regions, HaxeLexicalRegions.scan(source).length);
	}

	/** The first `REPORTED_DIVERGENCES` entries of `lines`, with a count of what was elided. */
	private function elide(lines: Array<String>): String {
		if (lines.length <= REPORTED_DIVERGENCES) return lines.join('\n  ');
		final head: Array<String> = lines.slice(0, REPORTED_DIVERGENCES);
		return head.join('\n  ') + '\n  … and ${lines.length - REPORTED_DIVERGENCES} more';
	}

	/** Whether `spans` holds a span byte-identical to `probe`. */
	private function holdsSpan(spans: Array<Span>, probe: Span): Bool {
		return spans.exists(span -> span.from == probe.from && span.to == probe.to);
	}

	/** Whether some span of `spans` encloses `probe` whole. */
	private function enclosedBy(spans: Array<Span>, probe: Span): Bool {
		return spans.exists(span -> probe.from >= span.from && probe.to <= span.to);
	}

	/** Whether some span of `spans` contains `offset`. */
	private function coversOffset(spans: Array<Span>, offset: Int): Bool {
		return spans.exists(span -> offset >= span.from && offset < span.to);
	}

	#if (sys || nodejs)
	/** Every `.hx` under the swept roots, in ascending path order. */
	private function sweepPaths(): Array<String> {
		final paths: Array<String> = [];
		for (root in SWEEP_ROOTS) {
			Assert.isTrue(FileSystem.exists(root) && FileSystem.isDirectory(root), '$root is not reachable from the runner cwd');
			for (path in SourceTree.collect(root)) paths.push(path);
		}
		return paths;
	}
	#end

}
