package unit.query;

import anyparse.check.NullFlow;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HaxeQueryWalker;
import anyparse.grammar.haxe.HaxeStringFoldSupport;
import anyparse.query.GrammarPlugin.RefShape;
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
 * that way, including two the grammar declares no constant literal. Through
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
	 * nearly every one was missing `HexLit` at the same time and the two that carried a stub hid it
	 * from themselves. `NON_NULL_RHS_KINDS` is asked about the vocabulary MINUS the null literal —
	 * the one member of it whose value IS null — which is a real exclusion and not a gap.
	 *
	 * WHICH ROWS STILL DISCRIMINATE, since three of the consumers are now DERIVED from the shape:
	 * `sideEffectFreeExprKinds` unions `constantLiteralKinds` in by construction, so its two rows are
	 * TAUTOLOGICAL and kept only as a guard on the union's own arithmetic. The rows that can still
	 * fail read a SECOND, independent declaration — `atomExprKinds` (through the two root
	 * vocabularies), `NullFlow.NON_NULL_RHS_KINDS`, `HaxeStringFoldSupport.PRIMARY_KINDS` and the
	 * shape's own `caseLiteralKinds` — and the killer arm cuts one of THOSE.
	 *
	 * CONTROL for the declared direction. KILLED by arm `M-NON-NULL-RHS-DROP-HEX`, which takes one
	 * declared kind back out of the one still-hand-written list.
	 */
	@:pin('control')
	@:killer('M-NON-NULL-RHS-DROP-HEX')
	public function testEveryDeclaredConstantLiteralIsClassifiedByEveryList(): Void {
		final declared: Array<String> = MemberKinds.constantLiteralKinds(SHAPE);
		Assert.isTrue(declared.length > 0, 'the Haxe grammar must declare a literal vocabulary');
		assertClassifies('MemberKinds.sideEffectFreeExprKinds', declared, MemberKinds.sideEffectFreeExprKinds(SHAPE));
		assertClassifies('MemberKinds.atomicRootKinds', declared, MemberKinds.atomicRootKinds(SHAPE));
		assertClassifies('MemberKinds.parenFreeRootKinds', declared, MemberKinds.parenFreeRootKinds(SHAPE));
		assertClassifies('HaxeStringFoldSupport.PRIMARY_KINDS', declared, HaxeStringFoldSupport.PRIMARY_KINDS);
		final nonNull: Array<String> = declared.filter(kind -> kind != SHAPE.nullLiteralKind);
		Assert.equals(declared.length - 1, nonNull.length, 'the null literal must be one member of the declared vocabulary');
		assertClassifies('NullFlow.NON_NULL_RHS_KINDS', nonNull, NullFlow.NON_NULL_RHS_KINDS);
		// The declaration itself drifts the same way: `case 0xFF:` is a literal case arm, and the
		// hex kind was missing from the shape's own case vocabulary while present in numericLiteralKinds.
		final caseable: Array<String> = declared.filter(kind -> !(SHAPE.stringLiteralKinds ?? []).contains(kind));
		assertClassifies('shape.caseLiteralKinds', caseable, SHAPE.caseLiteralKinds ?? []);
		// The predicates that walk a SUBTREE also meet the segments of a plain interpolating literal,
		// so the segment vocabulary is part of the same classification. The text fragment was listed
		// and the two inert triggers were not, which made `'a $$ b'` — a constant by every other
		// reading here — neither side-effect-free nor a pure argument.
		final text: Null<String> = SHAPE.stringInterpTextKind;
		final segments: Array<String> = [];
		if (text != null) segments.push(text);
		for (kind in SHAPE.stringInterpInertSegmentKinds ?? []) segments.push(kind);
		Assert.isTrue(segments.length > 1, 'the Haxe grammar must declare a text fragment and at least one inert trigger');
		assertClassifies('MemberKinds.sideEffectFreeExprKinds (segments)', segments, MemberKinds.sideEffectFreeExprKinds(SHAPE));
	}

	/**
	 * A projected kind whose NAME reads like a literal, but which no shape field declares one, is
	 * refused by the predicate that used to admit it on the strength of its spelling.
	 *
	 * ONE predicate now, where there were two: `InlineMethod` spelled a second copy of the same
	 * vocabulary and carried a second copy of the same stub. Its own end-to-end refusal is asserted
	 * by `testAnAllocatingLiteralIsRefusedByEveryPredicate`, on parsed nodes rather than kind names.
	 *
	 * The kind list comes from the GENERATED projected vocabulary, so this half needs no maintenance
	 * to keep covering the grammar: the convention admitted a handful of projected kinds beyond
	 * what the shape declares, the extras being the regex and object literals.
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
		final safe: Array<String> = [for (kind in undeclared) if (MemberKinds.isSafeKind(kind, SHAPE)) kind];
		Assert.equals('', safe.join(', '), 'kind(s) named like a literal that MemberKinds.isSafeKind admits anyway: [${safe.join(', ')}]');
	}

	/**
	 * An ALLOCATING literal is neither a plain literal nor side-effect-free — the end-to-end form of
	 * the two measured breaks, asked of real parsed nodes rather than of kind names.
	 *
	 * `isSideEffectFree` is the predicate `Inline` gates on, so this is the fixture that stands
	 * between a regex or object initializer and being duplicated once per read; `InlineMethod.isPure`
	 * is the same question asked of a call ARGUMENT, and the one this class asserts end-to-end now
	 * that the kind-by-kind twin of `isSafeKind` is gone from that class.
	 *
	 * The last block asks the half of `isPure` that no vocabulary answers: the WALK. Every row above
	 * is decided by its root kind, so an arm cutting the recursion survives them all; `1 + f()` has a
	 * root the vocabulary calls pure and a call under it, and only the descent sees that.
	 *
	 * CONTROL for the inline-method half of the stub removal. KILLED by arm `M-PURE-ARG-ROOT-ONLY`;
	 * the vocabulary the rows share is cut by `M-SAFE-KINDS-SUFFIX-STUB` beside it.
	 */
	@:pin('control')
	@:killer('M-PURE-ARG-ROOT-ONLY')
	public function testAnAllocatingLiteralIsRefusedByEveryPredicate(): Void {
		for (specimen in SPECIMENS) {
			final node: QueryNode = initializerOf(specimen.expr);
			Assert.equals(
				specimen.plain, MemberKinds.isPlainLiteral(node, SHAPE),
				'${specimen.expr} (${node.kind}) must${specimen.plain ? '' : ' not'} be a plain literal'
			);
			Assert.equals(
				specimen.plain, MemberKinds.isSideEffectFree(node, SHAPE),
				'${specimen.expr} (${node.kind}) must${specimen.plain ? '' : ' not'} be side-effect-free'
			);
			Assert.equals(
				specimen.plain, InlineMethod.isPure(node, SHAPE),
				'${specimen.expr} (${node.kind}) must${specimen.plain ? '' : ' not'} be a pure argument'
			);
		}
		// The refusal side, asked of the SHAPE rather than of a name convention: the allocating
		// literals carry their own fields, and no spelling suffix would catch a renamed one.
		for (kind in [SHAPE.objectLiteralKind, SHAPE.arrayLiteralKind]) if (kind != null)
			Assert.isFalse(MemberKinds.isSafeKind(kind, SHAPE), 'the allocating literal $kind must not be side-effect-free');
		// A pure ROOT over an impure subtree — the one question the kind vocabulary cannot answer,
		// and the only assertion here a walk that never descends would fail.
		final compound: QueryNode = initializerOf('1 + f()');
		Assert.isFalse(InlineMethod.isPure(compound, SHAPE), 'an argument calling a function is not pure, whatever its root kind is');
		Assert.isTrue(MemberKinds.isSafeKind(compound.kind, SHAPE), 'the fixture needs a root kind the vocabulary calls pure');
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

	/**
	 * The two derived ROOT vocabularies follow the shape they are HANDED, and keep the two questions
	 * apart: self-delimiting (`atomicRootKinds`) versus needs-no-parentheses (`parenFreeRootKinds`).
	 *
	 * Both halves are hand-written here, so neither derives from the declaration under test: the
	 * probe shape names an atom and a maximal-precedence root that NO grammar projects, and the
	 * answer has to carry both through — into the wide vocabulary only, for the second. A frozen
	 * list of this grammar's ctor names passes every other fixture in this class and fails here.
	 *
	 * The set difference the two answer is the contract: a call, a field read, an index or a `new`
	 * outranks every operator (so it is substituted bare) while a paren around one is NOT inert in
	 * every position, which is why `redundant-parens` reads only the narrow half.
	 *
	 * CONTROL for the root derivation. KILLED by arm `M-PAREN-FREE-ROOTS-ATOMS-ONLY`.
	 */
	@:pin('control')
	@:killer('M-PAREN-FREE-ROOTS-ATOMS-ONLY')
	public function testTheRootVocabulariesFollowTheShapeTheyAreHanded(): Void {
		final probe: RefShape = new HaxeQueryPlugin().refShape();
		probe.atomExprKinds = ['NoSuchAtom'];
		probe.parenKind = 'NoSuchGroup';
		probe.maximalPrecedenceRootKinds = ['NoSuchPostfix'];
		Assert.same(['NoSuchAtom', 'NoSuchGroup'], MemberKinds.atomicRootKinds(probe), 'the narrow half is atoms plus the group');
		Assert.same(
			['NoSuchAtom', 'NoSuchGroup', 'NoSuchPostfix'],
			MemberKinds.parenFreeRootKinds(probe), 'the wide half adds the maximal-precedence roots and nothing else'
		);
		// On the REAL grammar the two must differ, or the second field declares nothing.
		final narrow: Array<String> = MemberKinds.atomicRootKinds(SHAPE);
		final wide: Array<String> = MemberKinds.parenFreeRootKinds(SHAPE);
		final extra: Array<String> = wide.filter(kind -> !narrow.contains(kind));
		Assert.isTrue(extra.length > 0, 'the Haxe grammar must declare at least one maximal-precedence root beyond its atoms');
		for (kind in extra)
			Assert.isFalse(
				MemberKinds.isSafeKind(kind, SHAPE), 'a maximal-precedence root ($kind) is a precedence answer, never a purity one'
			);
	}

	/**
	 * The side-effect-free vocabulary follows the shape it is HANDED — the half a frozen name
	 * array also satisfied, and the reason two copies of one could drift apart unnoticed for months.
	 *
	 * The operator half is the part no other fixture reaches: `constantLiteralKinds` covers the
	 * literals, and the identifier / grouping kinds are single fields, but the operator names were
	 * spelled THREE times in this engine — `MemberKinds.SAFE_KINDS`, `InlineMethod.PURE_ARG_KINDS`
	 * and `PreferInline.CONST_OP_KINDS` — and the third disagreed with the first two in both
	 * directions at once (it carried `Is`, it lacked `BitNot`).
	 *
	 * CONTROL for the operator derivation. KILLED by arm `M-SIDE-EFFECT-FREE-DROPS-OPERATORS`.
	 */
	@:pin('control')
	@:killer('M-SIDE-EFFECT-FREE-DROPS-OPERATORS')
	public function testTheSideEffectFreeVocabularyFollowsTheOperatorsItIsHanded(): Void {
		final probe: RefShape = new HaxeQueryPlugin().refShape();
		probe.pureOperatorKinds = ['NoSuchOperator'];
		final kinds: Array<String> = MemberKinds.sideEffectFreeExprKinds(probe);
		Assert.isTrue(kinds.contains('NoSuchOperator'), 'a declared operator must reach the vocabulary: $kinds');
		Assert.isFalse(kinds.contains('Add'), 'an operator the handed shape drops must leave it: $kinds');
		Assert.isFalse(MemberKinds.isSideEffectFree(initializerOf('1 + 2'), probe), 'and the subtree walk must follow it');
		Assert.isTrue(MemberKinds.isSideEffectFree(initializerOf('1 + 2'), SHAPE), 'while the real grammar still admits it');
		// Every operator the grammar declares pure must be one the purity predicate admits, and none
		// may be a store: an admitted assignment is the wrong-rewrite direction.
		for (kind in SHAPE.pureOperatorKinds ?? []) {
			Assert.isTrue(MemberKinds.isSafeKind(kind, SHAPE), 'a declared pure operator ($kind) must be side-effect-free');
			Assert.isFalse(kind == SHAPE.assignKind, 'the assignment kind must never be declared a pure operator');
			Assert.isFalse(kind == SHAPE.addAssignKind, 'nor the compound assignment kind');
		}
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
