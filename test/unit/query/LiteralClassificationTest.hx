package unit.query;

import anyparse.check.NullFlow;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HaxeQueryWalker;
import anyparse.grammar.haxe.HaxeStringFoldSupport;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Inline;
import anyparse.query.InlineMethod;
import anyparse.query.Lit;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

/**
 * The LITERAL VOCABULARY the grammar declares, held against every list that CONSUMES it —
 * movability, side-effect freedom, argument purity, atomicity, non-nullness.
 *
 * Nothing checked either direction of that before this class, and the class of drift it leaves open
 * produced three defects in a row. `HexLit` stood unlisted in `trivial-getter` while `IntLit` was
 * listed, so `_mask = 0xFF;` took the `@:bypassAccessor` path a byte-equivalent `= 255;` did not,
 * and review — not a test — found it. It was still unlisted in four more lists next door. And the
 * widening that was supposed to make such a gap harmless made a WORSE one: two of the consuming
 * predicates ended with a NAME-CONVENTION stub (`|| kind.endsWith('Lit') ||
 * kind.endsWith('StringExpr')`) that admitted every projected kind whose spelling happens to end
 * that way, including two the grammar declares no constant literal. Measured on `a9efccd4`, through
 * `apq inline`, which DUPLICATES an initializer it is told is side-effect-free:
 *
 *  - `final r = ~/x(\d+)/; return r.match(a) ? r.matched(1) : '';` inlined to
 *    `return (~/x(\d+)/).match(a) ? (~/x(\d+)/).matched(1) : '';` — two `EReg` values where the
 *    source had one, so the second never matched and `matched(1)` throws at runtime.
 *  - `final o = {}; mark(o); return o == o;` inlined to `mark(({})); return ({}) == ({});` — true
 *    becoming false.
 *
 * Both compile, neither is reported, and no fixture saw either: a fail-OPEN guess about the
 * grammar's naming is invisible until a kind arrives that the guess is wrong about.
 *
 * So the differential runs both ways. `MemberKinds.constantLiteralKinds` derives the vocabulary
 * from four `RefShape` fields whose docs each pin them to a value carrying no allocation, and every
 * consuming list must classify all of it (the DECLARED direction). The GENERATED projected
 * vocabulary supplies the other side: a kind whose NAME reads like a literal but which no shape
 * field declares must be refused (the fail-open direction). Neither half is a list this class
 * spells, so the grammar growing a spelling moves both.
 */
@:nullSafety(Strict)
@:access(anyparse.query.Inline)
@:access(anyparse.query.InlineMethod)
@:access(anyparse.query.MemberKinds)
@:access(anyparse.grammar.haxe.HaxeStringFoldSupport)
class LiteralClassificationTest extends Test {

	/** The Haxe grammar's own vocabulary — the declaration under test. */
	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	/**
	 * The name suffixes the two retired stubs read as "this is a literal". Spelled here, and ONLY
	 * here, because the refutation is about them: the fixture takes the kinds the convention would
	 * have admitted and asks the grammar whether each is really a constant.
	 */
	private static final RETIRED_LITERAL_SUFFIXES: Array<String> = ['Lit', 'StringExpr'];

	/**
	 * One initializer expression per literal shape, with the answer the classification owes it.
	 *
	 * A table of SOURCE rather than of kind names, so each row is decided by the parser and not by
	 * this file: `specimenCoversTheDeclaredVocabulary` then asserts the kinds these rows actually
	 * project cover every kind the shape declares, which is what fails when a grammar gains a
	 * literal spelling nobody wrote a row for. The three `false` rows are the shapes that LOOK like
	 * constants and are not — two allocate, one interpolates.
	 */
	private static final SPECIMENS: Array<{ expr: String, plain: Bool }> = [
		{ expr: '1', plain: true },
		{ expr: '1.5', plain: true },
		{ expr: '0xFF', plain: true },
		{ expr: 'true', plain: true },
		{ expr: 'null', plain: true },
		{ expr: '\'lit\'', plain: true },
		{ expr: '"lit"', plain: true },
		{ expr: '\'a $$$$ b\'', plain: true },
		{ expr: '~/x(\\d+)/', plain: false },
		{ expr: '{}', plain: false },
		{ expr: '\'hi $$name\'', plain: false }
	];

	/**
	 * Every kind the grammar declares a constant literal is classified by EVERY consuming list.
	 *
	 * One assertion per list, each naming the kinds it is missing, because the lists are what drift:
	 * five of the six were missing `HexLit` at the same time and the two that carried a stub hid it
	 * from themselves. `NON_NULL_RHS_KINDS` is asked about the vocabulary MINUS the null literal —
	 * the one member of it whose value IS null — which is a real exclusion and not a gap.
	 *
	 * CONTROL for the declared direction. KILLED by arm `M-SAFE-KINDS-DROP-HEX`, which takes one
	 * declared kind back out of one list.
	 */
	@:pin('control')
	@:killer('M-SAFE-KINDS-DROP-HEX')
	public function testEveryDeclaredConstantLiteralIsClassifiedByEveryList(): Void {
		final declared: Array<String> = MemberKinds.constantLiteralKinds(SHAPE);
		Assert.isTrue(declared.length > 0, 'the Haxe grammar must declare a literal vocabulary');
		assertClassifies('MemberKinds.SAFE_KINDS', declared, MemberKinds.SAFE_KINDS);
		assertClassifies('InlineMethod.PURE_ARG_KINDS', declared, InlineMethod.PURE_ARG_KINDS);
		assertClassifies('InlineMethod.ATOMIC_ROOT_KINDS', declared, InlineMethod.ATOMIC_ROOT_KINDS);
		assertClassifies('Inline.ATOMIC_ROOT_KINDS', declared, Inline.ATOMIC_ROOT_KINDS);
		assertClassifies('HaxeStringFoldSupport.PRIMARY_KINDS', declared, HaxeStringFoldSupport.PRIMARY_KINDS);
		final nonNull: Array<String> = declared.filter(kind -> kind != SHAPE.nullLiteralKind);
		Assert.equals(declared.length - 1, nonNull.length, 'the null literal must be one member of the declared vocabulary');
		assertClassifies('NullFlow.NON_NULL_RHS_KINDS', nonNull, NullFlow.NON_NULL_RHS_KINDS);
		// The declaration itself drifts the same way: `case 0xFF:` is a literal case arm, and the
		// hex kind was missing from the shape's own case vocabulary while present in numericLiteralKinds.
		final caseable: Array<String> = declared.filter(kind -> !(SHAPE.stringLiteralKinds ?? []).contains(kind));
		assertClassifies('shape.caseLiteralKinds', caseable, SHAPE.caseLiteralKinds ?? []);
		// The two predicates above that walk a SUBTREE also meet the segments of a plain
		// interpolating literal, so the segment vocabulary is part of the same classification. The
		// text fragment was listed and the two inert triggers were not, which made `'a $$ b'` — a
		// constant by every other reading here — neither side-effect-free nor a pure argument.
		final text: Null<String> = SHAPE.stringInterpTextKind;
		final segments: Array<String> = [];
		if (text != null) segments.push(text);
		for (kind in SHAPE.stringInterpInertSegmentKinds ?? []) segments.push(kind);
		Assert.isTrue(segments.length > 1, 'the Haxe grammar must declare a text fragment and at least one inert trigger');
		assertClassifies('MemberKinds.SAFE_KINDS (segments)', segments, MemberKinds.SAFE_KINDS);
		assertClassifies('InlineMethod.PURE_ARG_KINDS (segments)', segments, InlineMethod.PURE_ARG_KINDS);
	}

	/**
	 * A projected kind whose NAME reads like a literal, but which no shape field declares one, is
	 * refused by both predicates that used to admit it on the strength of its spelling.
	 *
	 * The kind list comes from the GENERATED projected vocabulary, so this half needs no maintenance
	 * to keep covering the grammar: measured on `a9efccd4` the convention admitted nine of 238
	 * projected kinds and the shape declares seven of those, the two extras being the regex and
	 * object literals.
	 *
	 * CONTROL for the fail-open direction. KILLED by arm `M-SAFE-KINDS-SUFFIX-STUB`.
	 */
	@:pin('control')
	@:killer('M-SAFE-KINDS-SUFFIX-STUB')
	public function testAKindNamedLikeALiteralIsNotClassifiedAsOne(): Void {
		final declared: Array<String> = MemberKinds.constantLiteralKinds(SHAPE);
		final undeclared: Array<String> = HaxeQueryWalker.projectedKinds()
			.filter(kind -> !declared.contains(kind) && RETIRED_LITERAL_SUFFIXES.exists(suffix -> kind.endsWith(suffix)));
		Assert.isTrue(undeclared.length > 0, 'the refutation needs at least one kind the convention admits and the shape does not');
		// Both predicates are `inline`, so Haxe refuses a closure on either and the loop is the only
		// spelling available: `undeclared.filter(MemberKinds.isSafeKind)` does not compile.
		final safe: Array<String> = [];
		final pure: Array<String> = [];
		for (kind in undeclared) {
			if (MemberKinds.isSafeKind(kind)) safe.push(kind);
			if (InlineMethod.isPureKind(kind)) pure.push(kind);
		}
		Assert.equals('', safe.join(', '), 'kind(s) named like a literal that MemberKinds.isSafeKind admits anyway: [${safe.join(', ')}]');
		Assert.equals('', pure.join(', '), 'kind(s) named like a literal that InlineMethod.isPureKind admits anyway: [${pure.join(', ')}]');
	}

	/**
	 * An ALLOCATING literal is neither a plain literal nor side-effect-free — the end-to-end form of
	 * the two measured breaks, asked of real parsed nodes rather than of kind names.
	 *
	 * `isSideEffectFree` is the predicate `Inline` gates on, so this is the fixture that stands
	 * between a regex or object initializer and being duplicated once per read.
	 *
	 * CONTROL for the inline-method half of the stub removal. KILLED by arm
	 * `M-PURE-ARG-KINDS-SUFFIX-STUB` (and by the `MemberKinds` one beside it).
	 */
	@:pin('control')
	@:killer('M-PURE-ARG-KINDS-SUFFIX-STUB')
	public function testAnAllocatingLiteralIsRefusedByEveryPredicate(): Void {
		for (specimen in SPECIMENS) {
			final node: QueryNode = initializerOf(specimen.expr);
			Assert.equals(
				specimen.plain, MemberKinds.isPlainLiteral(node, SHAPE),
				'${specimen.expr} (${node.kind}) must${specimen.plain ? '' : ' not'} be a plain literal'
			);
			Assert.equals(
				specimen.plain, MemberKinds.isSideEffectFree(node),
				'${specimen.expr} (${node.kind}) must${specimen.plain ? '' : ' not'} be side-effect-free'
			);
			Assert.equals(
				specimen.plain, InlineMethod.isPureKind(node.kind) && node.children.foreach(c -> InlineMethod.isPureKind(c.kind)),
				'${specimen.expr} (${node.kind}) must${specimen.plain ? '' : ' not'} be a pure argument'
			);
		}
		// The refusal side, asked of the SHAPE rather than of a name convention: the allocating
		// literals carry their own fields, and no spelling suffix would catch a renamed one.
		for (kind in [SHAPE.objectLiteralKind, SHAPE.arrayLiteralKind]) if (kind != null) {
			Assert.isFalse(MemberKinds.isSafeKind(kind), 'the allocating literal $kind must not be side-effect-free');
			Assert.isFalse(InlineMethod.isPureKind(kind), 'the allocating literal $kind must not be a pure argument');
		}
	}

	/**
	 * The specimen table covers every kind the shape declares.
	 *
	 * The gate that keeps this class from going stale the way the lists it guards did: a grammar
	 * gaining a literal spelling adds a kind to `constantLiteralKinds`, and no row projects it, so
	 * the fixture names the kind rather than silently classifying one fewer.
	 */
	public function testTheSpecimenTableCoversTheDeclaredVocabulary(): Void {
		final projected: Array<String> = [for (specimen in SPECIMENS) initializerOf(specimen.expr).kind];
		final uncovered: Array<String> = MemberKinds.constantLiteralKinds(SHAPE).filter(kind -> !projected.contains(kind));
		Assert.equals('', uncovered.join(', '), 'declared literal kind(s) no specimen projects: [${uncovered.join(', ')}]');
	}

	/**
	 * The shared predicate follows the vocabulary it is HANDED — the half a frozen list also
	 * satisfies, and the one every other fixture here leaves unproved.
	 *
	 * The lesson is `LiteralVocabularyTest`'s, one slice old: a predicate replaced by this grammar's
	 * own ctor names passes every fixture that reads this grammar's shape, so only a vocabulary the
	 * grammar does not use separates a derivation from a copy. `IntLit` is renamed out of the handed
	 * shape and a name nothing projects is put in its place, so a frozen answer gets both rows wrong.
	 *
	 * CONTROL for the derivation. KILLED by arm `M-PLAIN-LITERAL-FROZEN`.
	 */
	@:pin('control')
	@:killer('M-PLAIN-LITERAL-FROZEN')
	public function testThePlainLiteralPredicateFollowsTheVocabularyItIsHanded(): Void {
		final other: RefShape = new HaxeQueryPlugin().refShape();
		other.numericLiteralKinds = ['WholeNumber'];
		other.stringLiteralKinds = [];
		other.interpolatingStringKinds = [];
		final kinds: Array<String> = MemberKinds.constantLiteralKinds(other);
		Assert.same(['WholeNumber', 'BoolLit', 'NullLit'], kinds, 'the vocabulary must follow the handed shape: $kinds');
		Assert.isFalse(MemberKinds.isPlainLiteral(initializerOf('1'), other), 'a kind the handed shape drops is no longer plain');
		Assert.isFalse(MemberKinds.isPlainLiteral(initializerOf('\'lit\''), other), 'a string kind the handed shape drops either');
		Assert.isTrue(MemberKinds.isPlainLiteral(initializerOf('true'), other), 'a kind the handed shape keeps still is');
		// The segmented branch must not bypass the vocabulary: a kind the shape still calls
		// interpolating but no longer calls a string literal is not plain either.
		final interpOnly: RefShape = new HaxeQueryPlugin().refShape();
		interpOnly.stringLiteralKinds = [];
		Assert.isFalse(
			MemberKinds.isPlainLiteral(initializerOf('\'lit\''), interpOnly),
			'a segmented kind the shape no longer declares a string literal is no longer plain'
		);
	}

	/**
	 * The string-VALUE seam answers both quote spellings, and off the shape rather than off a frozen
	 * pair of ctor names.
	 *
	 * The narrow twin of the classification above: `isPlainLiteral` says a literal is constant,
	 * `Lit.plainStringValue` says what its text IS, and only the second needs the declared delimiters —
	 * a quoted literal's `name` slot is the raw slice WITH its quotes, and no kind name says which
	 * quotes. Three consumers spelled that arithmetic themselves, one of them hardcoding a
	 * one-character quote width.
	 *
	 * The last two assertions are the derivation: handed a shape declaring NO delimiter for the quoted
	 * spelling, the seam must read the name verbatim rather than keep taking a quote off each end.
	 *
	 * CONTROL for the delimiter read. KILLED by arm `M-PLAIN-STRING-VALUE-NO-DELIMITERS`.
	 */
	@:pin('control')
	@:killer('M-PLAIN-STRING-VALUE-NO-DELIMITERS')
	public function testTheStringValueSeamAnswersBothSpellingsFromTheShape(): Void {
		Assert.equals('lit', Lit.plainStringValue(initializerOf('\'lit\''), SHAPE), 'the segmented spelling');
		Assert.equals('lit', Lit.plainStringValue(initializerOf('"lit"'), SHAPE), 'the quoted spelling');
		Assert.equals('', Lit.plainStringValue(initializerOf('\'\''), SHAPE), 'an empty literal IS empty');
		Assert.isNull(Lit.plainStringValue(initializerOf('\'hi $$name\''), SHAPE), 'an interpolation is no constant text');
		Assert.isNull(Lit.plainStringValue(initializerOf('\'$$\''), SHAPE), 'an inert trigger carries no name slot to read');
		final bare: RefShape = new HaxeQueryPlugin().refShape();
		bare.stringLiteralDelimiters = [];
		Assert.equals('"lit"', Lit.plainStringValue(initializerOf('"lit"'), bare), 'no declared delimiter reads the name verbatim');
	}

	/** Assert `classifying` holds every kind of `kinds`, naming the ones it does not under the label `list`. */
	private static function assertClassifies(list: String, kinds: Array<String>, classifying: Array<String>): Void {
		final missing: Array<String> = kinds.filter(kind -> !classifying.contains(kind));
		Assert.equals('', missing.join(', '), 'declared literal kind(s) $list does not classify: [${missing.join(', ')}]');
	}

	/** The initializer node of `var v = <expr>;` parsed as the single member of a class. */
	private static function initializerOf(expr: String): QueryNode {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile('class C {\n\tvar v = $expr;\n}');
		final cls: Null<QueryNode> = tree.children.find(c -> c.kind == 'ClassDecl');
		if (cls == null) throw 'specimen "$expr" did not project a class declaration';
		final member: Null<QueryNode> = cls.children.find(c -> c.kind == 'VarMember');
		if (member == null || member.children.length == 0) throw 'specimen "$expr" did not project a var member with an initializer';
		return member.children[member.children.length - 1];
	}

}
