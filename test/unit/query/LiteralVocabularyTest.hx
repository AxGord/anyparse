package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.InertRegions;
import anyparse.query.Lit;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The string-literal vocabulary of `RefShape`, read by the two consumers that used to spell one
 * grammar's ctor names themselves.
 *
 * A grammar can spell one string value two ways, and the two do not project alike: Haxe's
 * single-quoted literal is a composite whose text lives in `stringInterpTextKind` CHILD segments,
 * while the double-quoted one is a single `@:rawString` terminal whose own `name` slot is the
 * source slice WITH its quotes. Every reader of literal content therefore has to know BOTH
 * spellings, and both readers here knew one:
 *
 *  - `Lit` (`apq lit` / the third section of `apq mentions`) filtered on the segment kind alone.
 *    Over a directory holding `'needle'` and `"needle"` the command printed the single-quoted hit
 *    and said nothing at all about the other — the auto-widen retry that would have found it fires
 *    only at ZERO hits — and under `--exact` the quoted spelling could never match, quotes and all.
 *  - `InertRegions` hardcoded three kind lists of the Haxe grammar (`SingleStringExpr`,
 *    `DoubleStringExpr` / `RegexLit`, `Literal` / `Dollar` / `LoneDollar`) in a class whose own doc
 *    claimed it "never picks a lexer".
 *
 * What every fixture below asks is whether the answer follows the DECLARATION. That is the half a
 * hardcoded list also satisfies in the positive direction, so the negative direction needs a
 * vocabulary the engine cannot have frozen: hand the masker one that names nothing and the masking
 * has to stop, hand the content set one this grammar does not use and the set has to follow it.
 * Review measured why the second of those is spelled out rather than assumed — every OTHER fixture
 * here reads the Haxe shape, so `contentKinds` replaced by a literal `['Literal',
 * 'DoubleStringExpr']` passed all of them; only `testTheContentSetFollowsTheVocabularyItIsHanded`
 * separates a derivation from a copy.
 */
@:nullSafety(Strict)
class LiteralVocabularyTest extends Test {

	/** The Haxe grammar's own vocabulary — the declaration under test on the positive side. */
	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	/** One needle written in BOTH of the grammar's string spellings, and nowhere else. */
	private static final BOTH_SPELLINGS: String = 'class C {\n\tvar a: String = \'needle\';\n\tvar b: String = "needle";\n}';

	/**
	 * One content query answers BOTH spellings of the literal.
	 *
	 * The mixed case is the sharpest form of the defect and the one no earlier fixture had: with a
	 * hit in each spelling the command was not merely narrow, it was SILENTLY narrow — half the
	 * matches printed, no note, exit 0. Asserted as the ordered pair of KINDS, so a regression that
	 * finds two hits of one kind fails too.
	 *
	 * CONTROL for the derived kind set. KILLED by arm `M-LIT-CONTENT-KINDS-SEGMENT-ONLY`, which
	 * drops every whole-literal kind from `Lit.contentKinds` and leaves the segment kind alone —
	 * exactly the set the command hardcoded.
	 */
	@:pin('control')
	@:killer('M-LIT-CONTENT-KINDS-SEGMENT-ONLY')
	public function testOneContentQueryAnswersBothQuoteSpellings(): Void {
		final kinds: Array<String> = contentHits('needle', BOTH_SPELLINGS, false).map(hit -> hit.kind);
		Assert.same(['Literal', 'DoubleStringExpr'], kinds, 'both spellings of one literal must answer one query: $kinds');
	}

	/**
	 * `--exact` reaches the quoted spelling, because the QUOTES come off before the compare.
	 *
	 * The substring form of the query above can match a quoted name by accident — the quotes sit at
	 * the ends — so it is the EXACT form that decides whether the delimiters are actually declared
	 * and read. Escapes are deliberately not decoded either side: the two spellings differ in their
	 * quoting, not in their escaping, and the segment kind carries its own escapes raw.
	 *
	 * CONTROL for the delimiter compare. KILLED by arm `M-LIT-DELIMITERS-IGNORED`, which compares
	 * the raw name slot only.
	 */
	@:pin('control')
	@:killer('M-LIT-DELIMITERS-IGNORED')
	public function testAnExactQueryReachesContentInsideTheQuotes(): Void {
		final kinds: Array<String> = contentHits('needle', BOTH_SPELLINGS, true).map(hit -> hit.kind);
		Assert.same(['Literal', 'DoubleStringExpr'], kinds, 'an exact content query must not depend on the quote spelling: $kinds');
		// The widening is a widening: a query that spells the quotes itself still matches.
		final quoted: Array<String> = contentHits('"needle"', BOTH_SPELLINGS, true).map(hit -> hit.kind);
		Assert.same(['DoubleStringExpr'], quoted, 'the raw name slot stays matchable: $quoted');
	}

	/**
	 * A grammar that declares NO delimiter for a kind gets the raw name slot compared, which is the
	 * pre-field answer and what `@:optional` has to mean here.
	 *
	 * A guard rather than a control: it states the fallback, and narrowing the compare cannot make
	 * it fail.
	 */
	public function testAnUndeclaredDelimiterLeavesTheNameSlotVerbatim(): Void {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(BOTH_SPELLINGS);
		final bare: Array<LitHit> = Lit.find('needle', tree, true, Lit.contentKinds(SHAPE), null);
		Assert.same(['Literal'], bare.map(hit -> hit.kind), 'without a declared delimiter only the segment spelling matches');
	}

	/**
	 * The derived kind set carries the SEGMENT kind and every quoted whole-literal kind, and NOT the
	 * segmented literal's own kind.
	 *
	 * The exclusion is not cosmetic: a segmented literal's own `name` slot is empty, so listing it
	 * would add a kind that can never match and then name it to the user as content they are
	 * missing — which the `--kind` coverage note does verbatim. Read off the shape rather than
	 * spelled here, so this stays a statement about the derivation and not a second copy of the
	 * Haxe vocabulary.
	 */
	public function testTheContentSetExcludesTheSegmentedLiteralsOwnKind(): Void {
		final kinds: Array<String> = Lit.contentKinds(SHAPE);
		final segment: Null<String> = SHAPE.stringInterpTextKind;
		Assert.notNull(segment, 'the Haxe grammar must declare a text-segment kind');
		if (segment != null) Assert.isTrue(kinds.contains(segment), 'the segment kind must be in the content set: $kinds');
		for (segmented in SHAPE.interpolatingStringKinds ?? [])
			Assert.isFalse(kinds.contains(segmented), 'a segmented literal carries no content in its own name slot: $segmented');
		for (whole in (SHAPE.stringLiteralDelimiters ?? []).keys())
			Assert.isTrue(kinds.contains(whole), 'a quoted whole literal carries content and must be in the set: $whole');
	}

	/**
	 * `InertRegions` masks what the grammar DECLARES inert, and nothing else.
	 *
	 * Both halves are needed and only the second one discriminates. The positive half — a
	 * double-quoted literal and the text around an interpolation hole are masked, the hole itself is
	 * not — is equally true of the three hardcoded lists this class used to carry. The negative half
	 * hands the same tree a vocabulary that names NO inert kind and no interpolating kind, and then
	 * only the comment half may remain: a list frozen into the engine keeps masking and fails here.
	 *
	 * CONTROL for reading the vocabulary. KILLED by arm `M-INERT-REGIONS-HARDCODED-KINDS`, which
	 * puts the Haxe kind names back in place of the shape read.
	 */
	@:pin('control')
	@:killer('M-INERT-REGIONS-HARDCODED-KINDS')
	public function testInertRegionsMasksWhatTheGrammarDeclaresInert(): Void {
		final source: String = 'class C {\n\tvar a: String = \'lead $${Dep.x} tail\';\n\tvar b: String = "whole";\n}';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final declared: Array<Span> = InertRegions.of(tree, plugin.lexicalRegions(source), SHAPE);
		Assert.isTrue(covers(declared, source.indexOf('whole')), 'a declared whole-inert literal is masked');
		Assert.isTrue(covers(declared, source.indexOf('lead')), 'the text of a declared interpolating literal is masked');
		Assert.isFalse(covers(declared, source.indexOf('Dep')), 'a name read inside a hole keeps its veto');
		final silent: RefShape = plugin.refShape();
		silent.inertTextLiteralKinds = [];
		silent.interpolatingStringKinds = [];
		final none: Array<Span> = InertRegions.of(tree, plugin.lexicalRegions(source), silent);
		Assert.equals(0, none.length, 'a vocabulary naming nothing inert must mask nothing: ${none.length} span(s)');
	}

	/**
	 * The inert SEGMENT kinds beside the text fragment are read from the shape too.
	 *
	 * Their spans hold trigger characters only, so no identifier match can start inside one and no
	 * fixture can discriminate them by their effect on a name scan — which is why the assertion is
	 * about the span COUNT and not about a masked name. What it protects is the exhaustiveness of
	 * the segment split: drop them and the enumeration reads as if an escaped trigger were code.
	 *
	 * CONTROL for the THIRD vocabulary — the one `textSegmentKinds` builds, which the multi-pair
	 * arm on `collectLiterals` does not reach. KILLED by arm `M-INERT-SEGMENT-KINDS-HARDCODED`.
	 */
	@:pin('control')
	@:killer('M-INERT-SEGMENT-KINDS-HARDCODED')
	public function testTheInertSegmentKindsComeFromTheShapeToo(): Void {
		final source: String = 'class C {\n\tvar a: String = \'a $$$$ b\';\n}';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final withSegments: Int = InertRegions.of(tree, plugin.lexicalRegions(source), SHAPE).length;
		final silent: RefShape = plugin.refShape();
		silent.stringInterpInertSegmentKinds = [];
		final without: Int = InertRegions.of(tree, plugin.lexicalRegions(source), silent).length;
		Assert.isTrue(withSegments > without, 'the declared inert segments must contribute spans: $withSegments vs $without');
	}

	/**
	 * The content set follows whatever vocabulary it is HANDED — the half a frozen list also
	 * satisfies, and the one every other fixture here leaves unproved.
	 *
	 * Measured in review: `contentKinds` replaced by a literal `['Literal', 'DoubleStringExpr']` —
	 * exactly the defect this slice removes — passes every other fixture in this class, because all
	 * of them read the Haxe shape and that frozen pair is wide enough for it. Only a vocabulary this
	 * grammar does not use separates a derivation from a copy.
	 *
	 * CONTROL for the derivation itself. KILLED by arm `M-LIT-CONTENT-KINDS-FROZEN`.
	 */
	@:pin('control')
	@:killer('M-LIT-CONTENT-KINDS-FROZEN')
	public function testTheContentSetFollowsTheVocabularyItIsHanded(): Void {
		final other: RefShape = new HaxeQueryPlugin().refShape();
		other.stringInterpTextKind = 'QuotedFragment';
		other.stringLiteralKinds = ['QuotedWhole', 'QuotedSegmented'];
		other.interpolatingStringKinds = ['QuotedSegmented'];
		final kinds: Array<String> = Lit.contentKinds(other);
		Assert.same(['QuotedFragment', 'QuotedWhole'], kinds, 'the set must follow the handed vocabulary: $kinds');
	}

	/** `Lit.find` over `source` with the grammar's own content vocabulary and its declared delimiters. */
	private static function contentHits(target: String, source: String, exact: Bool): Array<LitHit> {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		return Lit.find(target, tree, exact, Lit.contentKinds(SHAPE), SHAPE.stringLiteralDelimiters);
	}

	/** Whether any span of `spans` covers `offset`. */
	private static function covers(spans: Array<Span>, offset: Int): Bool {
		return spans.exists(span -> offset >= span.from && offset < span.to);
	}

}
