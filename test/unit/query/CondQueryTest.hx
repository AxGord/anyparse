package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CondQuery;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `CondQuery` — the DIRECTIVE-DELIMITED BRANCH, which answers a question the tree cannot be
 * asked at all.
 *
 * A `#if … #elseif … #else … #end` region projects as ONE node whose span covers every branch and
 * whose children are all the branches' constructs flattened into one sibling list. So a branch is
 * NOT a node: no selector addresses one, and no node span can be sliced into one. `CondQuery`
 * delimits a branch from the region's own DIRECTIVES instead — from the end of its opening
 * directive to the start of the next directive at the same nesting depth — and every fixture here
 * is about a property of that definition rather than of a tree walk.
 *
 * The fixtures state the expected bytes themselves, which is what keeps them from being derived
 * from the same arithmetic they check: `testTheBranchBodiesTileTheRegion` reassembles the region
 * from the parts and compares against the source, so a body that drifted by one byte in either
 * direction — trimmed, or reaching over a directive — fails without anyone having to predict which
 * offsets the implementation would produce.
 */
@:nullSafety(Strict)
class CondQueryTest extends Test {

	/** The Haxe grammar's own vocabulary — what tells `namesIn` which kinds carry literal text. */
	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	/** A flat three-branch region: no nesting, so no body of it may contain any directive at all. */
	private static final FLAT: String = fn('#if nodejs\n\t\ta();\n\t\t#elseif other\n\t\tb();\n\t\t#else\n\t\tc();\n\t\t#end');

	/** The same region with a second `#if nodejs` nested inside its first branch. */
	private static final NESTED: String = fn(
		'#if nodejs\n\t\ta();\n\t\t#if nodejs\n\t\tinner();\n\t\t#end\n\t\t#elseif other\n\t\tc();\n\t\t#else\n\t\td();\n\t\t#end'
	);

	/**
	 * An expression-position region. The grammar parses this and projects a single CHILDLESS
	 * `CondSpliceReturnStmt` — a kind `RefShape.opaqueCondRegionKinds` does not even list — so it
	 * is exactly the shape a node-based reader has nothing to say about.
	 */
	private static final RAW: String = 'class C {\n\tfunction f():Int {\n\t\treturn #if nodejs 1; #else 2; #end\n\t}\n}';

	/** A region whose FIRST branch turns on a flag outside the query, so liveness has to stay unknown. */
	private static final MAYBE: String = fn('#if other\n\t\ta();\n\t\t#elseif nodejs\n\t\tb();\n\t\t#else\n\t\tc();\n\t\t#end');

	/**
	 * Every body of a flat region is exactly the text between two of its directives, so none of
	 * them may contain a `#` at all.
	 *
	 * CONTROL for the delimitation itself. KILLED by arm `M-COND-BODY-SWALLOWS-DIRECTIVES`, which
	 * bounds a body by the two directives' OUTER edges instead of their inner ones — the shape a
	 * reader gets from `source --range` over a guessed window, and the reason that route needs the
	 * guess in the first place.
	 */
	@:pin('control')
	@:killer('M-COND-BODY-SWALLOWS-DIRECTIVES')
	public function testABranchBodyNeverCarriesADirective(): Void {
		final found: Array<CondRegion> = regionsOf(FLAT, 'nodejs');
		Assert.equals(1, found.length);
		final region: CondRegion = found[0];
		Assert.same(['#if', '#elseif', '#else'], [for (branch in region.branches) branch.keyword]);
		Assert.same(['a();', 'b();', 'c();'], [for (branch in region.branches) text(FLAT, branch.body).trim()]);
		for (branch in region.branches)
			Assert.isTrue(text(FLAT, branch.body).indexOf('#') < 0, 'body holds a directive: ${branch.directive}');
	}

	/**
	 * The directives and the bodies TILE the region: concatenating them back in order reproduces
	 * the region's source byte for byte.
	 *
	 * The invariant behind everything else here, and the one assertion that cannot be satisfied by
	 * a body that is merely plausible — a trimmed body loses bytes, an over-reaching one duplicates
	 * them, and both show up as an inequality against the file's own text.
	 */
	public function testTheBranchBodiesTileTheRegion(): Void {
		for (src in [FLAT, NESTED, RAW, MAYBE]) for (region in regionsOf(src, 'nodejs')) {
			final buf: StringBuf = new StringBuf();
			for (branch in region.branches) {
				buf.add(branch.directive);
				buf.add(text(src, branch.body));
			}
			buf.add('#end');
			Assert.equals(text(src, region.span), buf.toString(), 'the branches do not tile ${region.branches[0].directive}');
		}
	}

	/**
	 * A nested region does not split its parent's branch: the outer first branch runs across the
	 * whole inner `#if … #end`, and the inner region is reported separately, tagged by depth.
	 *
	 * CONTROL for nest-safety. It is free in this model — an inner region's directives are consumed
	 * while its own frame is on top of the stack — which is precisely why nothing else would notice
	 * it going away. KILLED by arm `M-COND-INNERMOST-FRAME`, which routes a branch or closing
	 * directive to the OUTERMOST open region instead of the innermost.
	 */
	@:pin('control')
	@:killer('M-COND-INNERMOST-FRAME')
	public function testANestedRegionRunsInsideItsParentBranch(): Void {
		final found: Array<CondRegion> = regionsOf(NESTED, 'nodejs');
		Assert.equals(2, found.length);
		final outer: CondRegion = found[0];
		final inner: CondRegion = found[1];
		Assert.equals(0, outer.depth);
		Assert.equals(1, inner.depth);
		Assert.equals(3, outer.branches.length);
		Assert.equals(1, inner.branches.length);
		final body: String = text(NESTED, outer.branches[0].body);
		Assert.isTrue(body.indexOf('#if nodejs') > 0, 'the inner region left the outer branch: $body');
		Assert.isTrue(body.indexOf('#end') > 0, 'the inner region left the outer branch: $body');
		Assert.equals('inner();', text(NESTED, inner.branches[0].body).trim());
	}

	/**
	 * An expression-position region keeps its bytes and is FLAGGED, so the caller prints them
	 * verbatim rather than going silent — the one outcome this class must not have, since these are
	 * the sites where the tree has nothing at all.
	 *
	 * CONTROL for the raw flag. KILLED by arm `M-COND-RAW-NEVER-MARKED`, which answers "modelled"
	 * for every body; the bodies survive that, so what dies is the marker and, with it, `--names`
	 * printing a name list for a branch that has no nodes to name.
	 */
	@:pin('control')
	@:killer('M-COND-RAW-NEVER-MARKED')
	public function testARawExpressionSpliceIsFlaggedAndKeepsItsBytes(): Void {
		final found: Array<CondRegion> = regionsOf(RAW, 'nodejs');
		Assert.equals(1, found.length);
		Assert.same([true, true], [for (branch in found[0].branches) branch.raw]);
		Assert.same(['1;', '2;'], [for (branch in found[0].branches) text(RAW, branch.body).trim()]);
		Assert.same([[], []], [
			for (branch in found[0].branches) CondQuery.namesIn(new HaxeQueryPlugin().parseFile(RAW), branch.body, SHAPE)
		]);
		// …and a region the tree DOES model is not flagged, so the flag is about this shape and not
		// about every region.
		Assert.same([false, false, false], [for (branch in regionsOf(FLAT, 'nodejs')[0].branches) branch.raw]);
	}

	/** Without a tree — a file the grammar cannot parse — every non-blank body is raw, and the bodies are still exact. */
	public function testWithoutATreeEveryNonBlankBodyIsRaw(): Void {
		final found: Array<CondRegion> = regionsOf(FLAT, 'nodejs', false);
		Assert.equals(1, found.length);
		Assert.same([true, true, true], [for (branch in found[0].branches) branch.raw]);
		Assert.same(['a();', 'b();', 'c();'], [for (branch in found[0].branches) text(FLAT, branch.body).trim()]);
	}

	/** A blank branch is not raw: an empty `#if` arm has no interior to lose. */
	public function testABlankBranchIsNotRaw(): Void {
		final src: String = fn('#if nodejs\n\t\t#else\n\t\ta();\n\t\t#end');
		final found: Array<CondRegion> = regionsOf(src, 'nodejs');
		Assert.equals(1, found.length);
		Assert.same([false, false], [for (branch in found[0].branches) branch.raw]);
	}

	/**
	 * Rawness reads the body's OWN bytes — the two sizes a brace-stripping blank test gets wrong in
	 * opposite directions.
	 *
	 * `SourceText.isBlankSpan` strips the first and last byte of the span it is handed, because its
	 * other callers hand it a `{ … }` block; a directive-delimited body carries no delimiters. Asked
	 * of it, a ZERO-byte body read non-blank — its reversed bounds swap, so it answered about two
	 * bytes of the directive — and a TWO-byte one read blank whatever it held. The second direction
	 * is the damaging one: a raw branch that is not flagged prints `(no named node in this branch)`
	 * under `--names` instead of its bytes, which is the one outcome this class must not have.
	 *
	 * Both arms are parse-free, so the tree cannot decide them and only the blank test can.
	 */
	public function testRawnessReadsTheBodysOwnBytes(): Void {
		Assert.same([false], [
			for (branch in regionsOf(fn('#if nodejs#end'), 'nodejs', false)[0].branches) branch.raw
		]);
		final tight: String = fn('#if nodejs a#else b#end');
		final found: Array<CondRegion> = regionsOf(tight, 'nodejs', false);
		Assert.same([true, true], [for (branch in found[0].branches) branch.raw]);
		Assert.same([' a', ' b'], [for (branch in found[0].branches) text(tight, branch.body)]);
	}

	/**
	 * Liveness is three-valued under the hypothesis that the queried define is set: an unrelated
	 * flag leaves the branch unknown, the define's own branch is proved, and a later `#else` is
	 * refuted by it.
	 */
	public function testLivenessIsThreeValuedUnderTheQueriedDefine(): Void {
		final found: Array<CondRegion> = regionsOf(MAYBE, 'nodejs');
		Assert.equals(1, found.length);
		// The `#elseif` naming the define is MAYBE, not live: it is taken only when `other` is
		// false, and an unlisted flag is never proved false. The `#else` after it IS dead, because
		// the define's own branch would have been taken first whenever it is reached at all.
		Assert.same([null, null, false], [for (branch in found[0].branches) branch.live]);
		// The straight case: the define's own first branch is live and everything after it dead.
		Assert.same([true, false, false], [for (branch in regionsOf(FLAT, 'nodejs')[0].branches) branch.live]);
	}

	/**
	 * A region matches on the define its condition MENTIONS, not on the directive's spelling —
	 * which is the whole difference from a text search: `#if (sys || nodejs)` is a site of both
	 * flags and a hit for neither `#if sys` nor `#if nodejs` as text.
	 */
	public function testACompoundConditionMatchesEitherDefineItMentions(): Void {
		final src: String = fn('#if (sys || nodejs)\n\t\ta();\n\t\t#end');
		Assert.equals(1, regionsOf(src, 'nodejs').length);
		Assert.equals(1, regionsOf(src, 'sys').length);
		Assert.equals(0, regionsOf(src, 'js').length, 'a substring of a flag is not the flag');
	}

	/** An `#else` carries no condition, so it never matches on its own — it is reported as a branch of the region that does. */
	public function testAnElseAloneIsNotAMatch(): Void {
		final src: String = fn('#if other\n\t\ta();\n\t\t#else\n\t\tnodejs();\n\t\t#end');
		Assert.equals(0, regionsOf(src, 'nodejs').length, 'the branch BODY mentioning the name is not a condition');
	}

	/** A region left open at the end of the file is not reported: a slice ending where nobody chose is worse than none. */
	public function testAnUnclosedRegionIsNotReported(): Void {
		Assert.equals(0, regionsOf('class C {\n\t#if nodejs\n\tvar x:Int = 0;\n', 'nodejs', false).length);
	}

	/** The scan shares the engine's lexer, so a `#if` written inside a comment is not a directive. */
	public function testADirectiveInsideACommentIsNotARegion(): Void {
		Assert.equals(0, regionsOf(fn('// #if nodejs\n\t\ta();'), 'nodejs').length);
	}

	/** `namesIn` answers the distinct `<Kind> <name>` rows of the branch, in document order — what `--names` prints. */
	public function testNamesInAnswersTheBranchesNamedNodes(): Void {
		final src: String = fn('#if nodejs\n\t\tvar v:Int = 1;\n\t\tuse(v);\n\t\t#else\n\t\tother();\n\t\t#end');
		final found: Array<CondRegion> = regionsOf(src, 'nodejs');
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(src);
		final first: Array<String> = CondQuery.namesIn(tree, found[0].branches[0].body, SHAPE);
		Assert.isTrue(first.indexOf('VarStmt v') >= 0, 'the declaration is missing: $first');
		Assert.isTrue(first.indexOf('IdentExpr use') >= 0, 'the call target is missing: $first');
		Assert.same(['IdentExpr other'], CondQuery.namesIn(tree, found[0].branches[1].body, SHAPE));
	}

	/**
	 * `namesIn` reports SYMBOLS, and the two spellings of ONE string literal answer alike.
	 *
	 * A guarded import's whole dotted path is a row; a literal's content is not. That has to be asked
	 * by KIND rather than of the text: `'probe.hx'` IS a dotted pair of identifiers, so the shape
	 * filter alone reported it as a `Literal probe.hx` row while the double-quoted twin was kept out
	 * only because its raw `name` still carries the quote marks. Two spellings, two answers, and
	 * neither of them the symbol list the flag promises.
	 *
	 * The `$dir` read is what keeps the kind filter from being a blanket subtree skip: an interpolation
	 * is a real reference and stays. One `Assert.same` over the whole ordered list, so no half of this
	 * can pass on its own.
	 *
	 * Both directions were wrong at first in the earlier fixture. Filtering to a bare identifier
	 * dropped the import path and left a guarded import block reporting nothing; not filtering at all
	 * put half a diagnostic message and a file extension in a list of symbols.
	 *
	 * CONTROL for the kind filter. KILLED by arm `M-COND-NAMES-LITERAL-TEXT-KEPT`, which answers "no
	 * literal text here" for every kind — the pre-seam behaviour, and what a grammar declaring no `stringInterpTextKind` still gets.
	 */
	@:pin('control')
	@:killer('M-COND-NAMES-LITERAL-TEXT-KEPT')
	public function testNamesInReportsSymbolsAndNotLiteralContent(): Void {
		final src: String = 'package pkg;\n\n#if nodejs\nimport js.node.ChildProcess;\n#end\n\nclass C {\n\tfunction f():Void {\n'
			+ '\t\t#if nodejs\n\t\tsave(dir + \'/probe.hx\');\n\t\tlog(\'probe.hx\');\n\t\tlog("probe.hx");\n'
			+ '\t\tlog(\'at $$dir/probe.hx\');\n\t\t#end\n\t}\n}';
		final found: Array<CondRegion> = regionsOf(src, 'nodejs');
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(src);
		Assert.same(['ImportDecl js.node.ChildProcess'], CondQuery.namesIn(tree, found[0].branches[0].body, SHAPE));
		final call: Array<String> = CondQuery.namesIn(tree, found[1].branches[0].body, SHAPE);
		Assert.same(
			['IdentExpr save', 'IdentExpr dir', 'IdentExpr log', 'Ident dir'],
			call, 'a literal\'s content is not a symbol, in either spelling, and an interpolation still is: $call'
		);
	}

	/**
	 * The `stringLiteralKinds` half of the drop is asked of a SECOND vocabulary, because the Haxe one
	 * cannot exhibit it: `DoubleStringExpr`'s raw `name` always keeps its quote marks, so in this
	 * grammar that half is invisible either way and no Haxe fixture can tell it from its absence.
	 *
	 * A grammar whose whole string literal carries its content UNQUOTED in its own name slot is the case it exists for,
	 * and a synthetic node plus a six-field shape is what states it — which is also the strongest thing this class can
	 * say about `namesIn` being grammar-agnostic: nothing here is read back out of the declaration under test.
	 *
	 * The second half pins what OPTIONAL means, since the seam claims it: hand the same tree a shape naming no literal kind at all
	 * and both rows come back. That half is a guard rather than a control — no arm makes it fail, and narrowing the drop cannot.
	 *
	 * CONTROL for the whole-literal half. KILLED by arm `M-COND-NAMES-WHOLE-LITERAL-KEPT`, which
	 * narrows the drop to `stringInterpTextKind` alone.
	 */
	@:pin('control')
	@:killer('M-COND-NAMES-WHOLE-LITERAL-KEPT')
	public function testAWholeStringLiteralKindIsDroppedByItsDeclaration(): Void {
		final body: Span = new Span(0, 40);
		final tree: QueryNode = new QueryNode('Root', null, [
			new QueryNode('Str', 'looks.like.a.symbol', [], new Span(0, 20)),
			new QueryNode('Call', 'realCall', [], new Span(20, 30))
		], body);
		final declared: Array<String> = CondQuery.namesIn(tree, body, minimalShape(['Str']));
		Assert.same(['Call realCall'], declared, 'a whole-literal kind carries content, not a symbol: $declared');
		// …and OPTIONAL means exactly this: declare neither kind and the content comes back, which is
		// the answer every grammar that has not named its literal vocabulary still gets.
		final undeclared: Array<String> = CondQuery.namesIn(tree, body, minimalShape());
		Assert.same(['Str looks.like.a.symbol', 'Call realCall'], undeclared, 'an undeclared vocabulary must drop nothing: $undeclared');
	}

	/** A source with no `#if` at all yields nothing, and a grammar declaring no opener keyword cannot yield anything either. */
	public function testASourceWithNoRegionYieldsNothing(): Void {
		Assert.equals(0, regionsOf('class C {\n\tvar x:Int = 0;\n}', 'nodejs').length);
		Assert.equals(0, regionsOf(FLAT, '').length, 'an empty define matches nothing rather than everything');
	}

	private static inline function fn(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	private static inline function text(source: String, span: Span): String {
		return source.substring(span.from, span.to);
	}

	/**
	 * The regions of `source` mentioning `define`. `withTree` off is the parse-free arm — what the
	 * command falls back to on a file the grammar cannot parse, and the only arm the unparseable
	 * fixtures can use at all.
	 */
	private static function regionsOf(source: String, define: String, withTree: Bool = true): Array<CondRegion> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: Null<QueryNode> = withTree ? plugin.parseFile(source) : null;
		return CondQuery.regionsMentioning(source, tree, plugin.refShape(), plugin.lexicalRegions.bind(source), define);
	}

	/**
	 * A `RefShape` carrying only the six fields the typedef requires, plus whichever whole-literal
	 * kinds the caller names — the smallest SECOND vocabulary this class can hand `namesIn`, and the
	 * only way to exercise a grammar that declares none.
	 */
	private static function minimalShape(?stringLiteralKinds: Array<String>): RefShape {
		return {
			identKind: 'Ident',
			declHostKinds: [],
			moduleValueDeclKinds: [],
			scopeKinds: [],
			writeParentKinds: [],
			selfScopeDeclKinds: [],
			stringLiteralKinds: stringLiteralKinds
		};
	}

}
