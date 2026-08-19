package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.FieldInitInConstructor;
import anyparse.check.Linter;
import anyparse.check.PreferFinalField;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;

/**
 * The `field-init-in-constructor` check: a private instance field whose CONSTANT declaration
 * default is overwritten by exactly one CONDITIONAL constructor write folds into a single
 * unconditional assignment of a conditional value. `Info`, DEFAULT OFF.
 *
 * The motivating shape writes TWO fields under one `if`; only the assignment OPENING the branch
 * is claimed per pass, and the pair converges over two passes with the `if` disappearing on the
 * second — `testTwoPassesFoldBothFieldsAndDropTheIf` pins exactly that, which is also the proof
 * that the per-pass gate composes rather than merely refusing.
 *
 * The gates fail closed: an `else`, a non-constant default, a static / public / `final` field, a
 * second write anywhere, a read or an early exit before the `if`, a `super(...)` ahead of it, a
 * `#if` region on the path, a self-referencing value, and a comment in a regenerated range are all
 * safe misses. The condition's purity is demanded only when the `if` SURVIVES the fold (it is then
 * evaluated twice) — `testImpureConditionAcceptedWhenTheIfDisappears` is the one-variable partner
 * of `testImpureConditionRefusedWhenTheIfSurvives`.
 */
class FieldInitInConstructorCheckTest extends Test {

	private static inline final FIELDS: String = '\tprivate var _cellsX:Int = 20;\n\tprivate var _cellsY:Int = 12;';
	private static inline final BODY: String = '\t\tif (palette != null) {\n\t\t\t_cellsX = palette.length;\n\t\t\t_cellsY = 1;\n\t\t}';

	/** The one-field shape the constant-extraction arm is exercised on. */
	private static inline final ONE_FIELD: String = '\tprivate var _cellsNumX:Int = 20;';

	private static inline final ONE_GUARD: String = '\t\tif (palette != null) _cellsNumX = palette.length;';

	public function testFlagsConditionalDefault(): Void {
		final vs: Array<Violation> = violations(wrap(FIELDS, BODY));
		Assert.equals(1, vs.length);
		Assert.equals('field-init-in-constructor', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'this field default is overwritten by one conditional constructor write - fold the pair into a single '
			+ 'unconditional assignment of a conditional value',
			vs[0].message
		);
	}

	public function testFixFoldsTheOpeningWriteToATernary(): Void {
		final out: String = applyFixOnce(wrap(FIELDS, BODY));
		Assert.isTrue(out.indexOf('_cellsX = palette != null ? palette.length : 20;') != -1);
		Assert.isTrue(out.indexOf('private var _cellsX:Int;') != -1);
		// The second write is not this pass's business: its `if` and its default both survive.
		Assert.isTrue(out.indexOf('private var _cellsY:Int = 12;') != -1);
		Assert.isTrue(out.indexOf('_cellsY = 1;') != -1);
	}

	public function testTwoPassesFoldBothFieldsAndDropTheIf(): Void {
		final out: String = applyFixOnce(applyFixOnce(wrap(FIELDS, BODY)));
		Assert.isTrue(out.indexOf('_cellsX = palette != null ? palette.length : 20;') != -1);
		Assert.isTrue(out.indexOf('_cellsY = palette != null ? 1 : 12;') != -1);
		Assert.isTrue(out.indexOf('private var _cellsX:Int;') != -1);
		Assert.isTrue(out.indexOf('private var _cellsY:Int;') != -1);
		Assert.equals(-1, out.indexOf('if ('));
	}

	public function testSoleStatementBranchReplacesTheWholeIf(): Void {
		final out: String = applyFixOnce(
			wrap('\tprivate var _cellsX:Int = 20;', '\t\tif (palette != null) {\n\t\t\t_cellsX = palette.length;\n\t\t}')
		);
		Assert.isTrue(out.indexOf('_cellsX = palette != null ? palette.length : 20;') != -1);
		Assert.equals(-1, out.indexOf('if ('));
	}

	public function testBraceLessBranchFlagged(): Void {
		final out: String = applyFixOnce(wrap('\tprivate var _cellsX:Int = 20;', '\t\tif (palette != null) _cellsX = palette.length;'));
		Assert.isTrue(out.indexOf('_cellsX = palette != null ? palette.length : 20;') != -1);
		Assert.equals(-1, out.indexOf('if ('));
	}

	/**
	 * The else branch writes a DIFFERENT field on purpose: with a second write of the same one the
	 * whole-file write scan would refuse the site first, and the fixture would pass with the else gate
	 * ripped out - proving nothing. Here the gate is the only thing standing between the fold and an
	 * edit that replaces the whole if statement, silently deleting the else branch with it.
	 */
	public function testElseBranchRefused(): Void {
		Assert.equals(0, violations(wrap(FIELDS, '\t\tif (palette != null) _cellsX = palette.length;\n\t\telse _cellsY = 4;')).length);
	}

	public function testImpureConditionRefusedWhenTheIfSurvives(): Void {
		Assert.equals(
			0,
			violations(wrap(
				FIELDS, '\t\tif (probe()) {\n\t\t\t_cellsX = 3;\n\t\t\t_cellsY = 1;\n\t\t}', '',
				'\n\n\tprivate function probe():Bool return true;'
			)).length
		);
	}

	public function testImpureConditionAcceptedWhenTheIfDisappears(): Void {
		Assert.equals(
			1,
			violations(wrap(
				'\tprivate var _cellsX:Int = 20;', '\t\tif (probe()) {\n\t\t\t_cellsX = 3;\n\t\t}', '',
				'\n\n\tprivate function probe():Bool return true;'
			)).length
		);
	}

	public function testNonConstantDefaultRefused(): Void {
		Assert.equals(0, violations(wrap('\tprivate var _cells:Array<Int> = [];', '\t\tif (palette != null) _cells = palette;')).length);
	}

	public function testStaticFieldRefused(): Void {
		Assert.equals(
			0, violations(wrap('\tprivate static var _cellsX:Int = 20;', '\t\tif (palette != null) _cellsX = palette.length;')).length
		);
	}

	public function testPublicFieldRefused(): Void {
		Assert.equals(0, violations(wrap('\tpublic var cellsX:Int = 20;', '\t\tif (palette != null) cellsX = palette.length;')).length);
	}

	public function testFinalFieldRefused(): Void {
		Assert.equals(
			0, violations(wrap('\tprivate final _cellsX:Int = 20;', '\t\tif (palette != null) _cellsX = palette.length;')).length
		);
	}

	public function testSecondWriteElsewhereRefused(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'\tprivate var _cellsX:Int = 20;', '\t\tif (palette != null) _cellsX = palette.length;', '',
				'\n\n\tprivate function reset():Void _cellsX = 20;'
			)).length
		);
	}

	public function testFieldReadBeforeGuardRefused(): Void {
		Assert.equals(
			0,
			violations(
				wrap('\tprivate var _cellsX:Int = 20;', '\t\tfinal seen:Int = _cellsX;\n\t\tif (palette != null) _cellsX = palette.length;')
			).length
		);
	}

	public function testEarlyReturnBeforeGuardRefused(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'\tprivate var _cellsX:Int = 20;', '\t\tif (palette == null) return;\n\t\tif (palette != null) _cellsX = palette.length;'
			)).length
		);
	}

	public function testSuperCallBeforeGuardRefused(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'\tprivate var _cellsX:Int = 20;', '\t\tsuper();\n\t\tif (palette != null) _cellsX = palette.length;', ' extends Panel'
			)).length
		);
	}

	public function testSuperCallAfterGuardFlagged(): Void {
		Assert.equals(
			1,
			violations(wrap(
				'\tprivate var _cellsX:Int = 20;', '\t\tif (palette != null) _cellsX = palette.length;\n\t\tsuper();', ' extends Panel'
			)).length
		);
	}

	public function testConditionalCompilationInConstructorRefused(): Void {
		Assert.equals(
			0,
			violations(wrap(
				'\tprivate var _cellsX:Int = 20;',
				'\t\t#if debug\n\t\ttrace(1);\n\t\t#end\n\t\tif (palette != null) _cellsX = palette.length;'
			)).length
		);
	}

	public function testSelfReferencingValueRefused(): Void {
		Assert.equals(0, violations(wrap('\tprivate var _cellsX:Int = 20;', '\t\tif (palette != null) _cellsX = _cellsX + 1;')).length);
	}

	public function testCommentInRebuiltRegionRefused(): Void {
		Assert.equals(
			0,
			violations(wrap('\tprivate var _cellsX:Int = 20;', '\t\tif (palette != null) // why\n\t\t\t_cellsX = palette.length;')).length
		);
	}

	public function testFoldedFormIsWriterIdempotent(): Void {
		final once: String = applyFixOnce(applyFixOnce(wrap(FIELDS, BODY)));
		Assert.equals(once, canonicalize(once, []));
		Assert.equals(once, canonicalize(canonicalize(once, []), []));
	}

	/**
	 * The composition the rule exists for: `prefer-final-field` is silent BEFORE the fold (the
	 * initializer plus the constructor write are two, and its gate is exactly one) and claims both
	 * fields AFTER it. Asserting both halves in one test is what makes it discriminate — the
	 * "after" count alone would pass for a rule that was never silent.
	 */
	public function testPreferFinalFieldIsSilentBeforeAndClaimsBothAfter(): Void {
		final before: String = wrap(FIELDS, BODY);
		Assert.equals(0, finalFieldNames(before).length);
		final after: String = applyFixOnce(applyFixOnce(before));
		Assert.equals(2, finalFieldNames(after).length);
	}

	/**
	 * The DEFAULT the fold moves is EXTRACTED into a named constant rather than left inline. The
	 * name is DERIVED from the field (`_cellsNumX` -> `CELLS_NUM_X_DEFAULT`), which is what makes
	 * this a mechanical step rather than the naming judgement `magic-number` correctly declines.
	 * The reference and the moved value are asserted in ONE string, so an input that never folded
	 * at all - it still holds the literal, the `if` and the initialised field - cannot satisfy it.
	 */
	public function testExtractsTheMovedDefaultIntoANamedConstant(): Void {
		final out: String = applyIndexedFixOnce(wrap(ONE_FIELD, ONE_GUARD));
		Assert.isTrue(out.indexOf('private static inline final CELLS_NUM_X_DEFAULT:Int = 20;') != -1);
		Assert.isTrue(out.indexOf('_cellsNumX = palette != null ? palette.length : CELLS_NUM_X_DEFAULT;') != -1);
		Assert.isTrue(out.indexOf('private var _cellsNumX:Int;') != -1);
	}

	/** A plain string default extracts too, with its quote style and content carried verbatim. */
	public function testStringDefaultExtracted(): Void {
		final out: String = applyIndexedFixOnce(wrap("\tprivate var _tag:String = 'none';", "\t\tif (palette != null) _tag = 'set';"));
		Assert.isTrue(out.indexOf("private static inline final TAG_DEFAULT:String = 'none';") != -1);
		Assert.isTrue(out.indexOf("_tag = palette != null ? 'set' : TAG_DEFAULT;") != -1);
	}

	/**
	 * Placement honours `member-order`: the emitted `private static inline final` lands after the
	 * type's other constants and BEFORE the instance field, not merely somewhere in the type. The
	 * assertions are ORDERINGS rather than presence tests, so an insertion at the wrong rank fails.
	 */
	public function testConstantLandsInTheConstantsRank(): Void {
		final out: String = applyIndexedFixOnce(wrap(
			"\tpublic static final TAG:String = 'p';\n\tprivate static inline final HEADER_HEIGHT:Float = 30.0;\n"
			+ '\tprivate var _cellsNumX:Int = 20;',
			ONE_GUARD
		));
		Assert.isTrue(out.indexOf("TAG:String = 'p';") < out.indexOf('HEADER_HEIGHT:Float = 30.0;'));
		Assert.isTrue(out.indexOf('HEADER_HEIGHT:Float = 30.0;') < out.indexOf('CELLS_NUM_X_DEFAULT:Int = 20;'));
		Assert.isTrue(out.indexOf('CELLS_NUM_X_DEFAULT:Int = 20;') < out.indexOf('private var _cellsNumX:Int;'));
	}

	/**
	 * A constant the type ALREADY declares for that exact value is REUSED, not duplicated under a
	 * second name. Paired with the absence of the derived name so it cannot pass on an input that
	 * got no constant at all.
	 */
	public function testReusesAnExistingConstantOfTheSameValue(): Void {
		final out: String = applyIndexedFixOnce(
			wrap('\tprivate static inline final CELL_COUNT:Int = 20;\n\tprivate var _cellsNumX:Int = 20;', ONE_GUARD)
		);
		Assert.isTrue(out.indexOf('_cellsNumX = palette != null ? palette.length : CELL_COUNT;') != -1);
		Assert.equals(-1, out.indexOf('CELLS_NUM_X_DEFAULT'));
	}

	/**
	 * A default that is not a BARE literal stays inline. `-5` is a negation over a numeric literal:
	 * move-safe, so the FOLD still applies - which is what makes this a test of the extraction gate
	 * rather than of the fold's own whitelist.
	 */
	public function testNegatedLiteralDefaultStaysInline(): Void {
		final out: String = applyIndexedFixOnce(wrap('\tprivate var _cellsNumX:Int = -5;', ONE_GUARD));
		Assert.isTrue(out.indexOf('_cellsNumX = palette != null ? palette.length : -5;') != -1);
		Assert.equals(-1, out.indexOf('CELLS_NUM_X_DEFAULT'));
	}

	/** A dotted constant default is already named - extracting it would mint a second name for one value. */
	public function testDottedConstantDefaultStaysInline(): Void {
		final out: String = applyIndexedFixOnce(wrap('\tprivate var _cellsNumX:Int = Defaults.CELLS;', ONE_GUARD));
		Assert.isTrue(out.indexOf('_cellsNumX = palette != null ? palette.length : Defaults.CELLS;') != -1);
		Assert.equals(-1, out.indexOf('CELLS_NUM_X_DEFAULT'));
	}

	/**
	 * A derived name the type already DECLARES leaves the literal inline rather than minting a
	 * variant spelling: a redefinition does not compile, and one value under two names is worse than
	 * an unnamed default. Reverting the whole-file occurrence scan does NOT flip this one — the
	 * supertype-closure proof refuses it first, since a type declaring the name is exactly what that
	 * proof reports. `testDerivedNameBoundElsewhereLeavesTheLiteralInline` is the fixture the
	 * occurrence scan alone decides.
	 */
	public function testCollidingDerivedNameLeavesTheLiteralInline(): Void {
		final out: String = applyIndexedFixOnce(
			wrap('\tprivate static inline final CELLS_NUM_X_DEFAULT:Int = 7;\n\tprivate var _cellsNumX:Int = 20;', ONE_GUARD)
		);
		Assert.isTrue(out.indexOf('_cellsNumX = palette != null ? palette.length : 20;') != -1);
		Assert.isTrue(out.indexOf('CELLS_NUM_X_DEFAULT:Int = 7;') != -1);
	}

	/**
	 * Two fields of ONE type deriving the SAME constant name: only one claims it this pass. Without
	 * the claim ledger both insertions would land and the file would not compile - the exact bug
	 * this project already shipped once from two edits of one pass claiming one name.
	 */
	public function testTwoFieldsDerivingOneNameClaimItOnce(): Void {
		final out: String = applyIndexedFixOnce(wrap(
			'\tprivate var _cells:Int = 20;\n\tprivate var cells:Int = 30;',
			'\t\tif (palette != null) _cells = palette.length;\n\t\tif (palette == null) cells = 3;'
		));
		Assert.equals(1, occurrences(out, 'CELLS_DEFAULT:Int'));
	}

	/**
	 * Two folds in ONE pass emit two constants at the SAME insertion offset. They are merged into a
	 * single insertion: two zero-width edits sharing an offset are contained in one another, so
	 * emitting them separately loses one.
	 */
	public function testTwoFoldsInOnePassEmitBothConstants(): Void {
		final out: String = applyIndexedFixOnce(wrap(
			'\tprivate var _cellsNumX:Int = 20;\n\tprivate var _cellsNumY:Int = 12;',
			'\t\tif (palette != null) _cellsNumX = palette.length;\n\t\tif (palette == null) _cellsNumY = 1;'
		));
		Assert.isTrue(out.indexOf('private static inline final CELLS_NUM_X_DEFAULT:Int = 20;') != -1);
		Assert.isTrue(out.indexOf('private static inline final CELLS_NUM_Y_DEFAULT:Int = 12;') != -1);
	}

	/**
	 * With NO index the extraction arm is OFF - the inherited-member proof has nothing to ask, and
	 * Haxe rejects a static whose name matches an inherited INSTANCE field. Both arms of the SAME
	 * input are asserted here: without an index the literal, with one the constant. The negative half
	 * alone would pass on a build where the whole feature is absent.
	 */
	public function testNoIndexLeavesTheLiteralInline(): Void {
		final src: String = wrap(ONE_FIELD, ONE_GUARD);
		final bare: String = applyFixOnce(src);
		Assert.isTrue(bare.indexOf('_cellsNumX = palette != null ? palette.length : 20;') != -1);
		Assert.equals(-1, bare.indexOf('CELLS_NUM_X_DEFAULT'));
		Assert.isTrue(applyIndexedFixOnce(src).indexOf('CELLS_NUM_X_DEFAULT') != -1);
	}

	/**
	 * An UNRESOLVABLE supertype leaves the literal inline: Haxe rejects a static whose name matches an
	 * inherited INSTANCE field, and a closure the index cannot walk cannot rule one out. The fold
	 * itself is unaffected - `testSuperCallAfterGuardFlagged` folds the same `extends` shape.
	 */
	public function testUnresolvableSupertypeLeavesTheLiteralInline(): Void {
		final out: String = applyIndexedFixOnce(wrap(ONE_FIELD, ONE_GUARD, ' extends Panel'));
		Assert.isTrue(out.indexOf('_cellsNumX = palette != null ? palette.length : 20;') != -1);
		Assert.equals(-1, out.indexOf('CELLS_NUM_X_DEFAULT'));
	}

	/**
	 * A type the language forbids statics on (`@:generic`) leaves the literal inline. Nothing else
	 * would notice: the emitted member re-parses, and the supertype closure has nothing to say about
	 * a member the compiler rejects for the type's own annotation.
	 */
	public function testGenericTypeLeavesTheLiteralInline(): Void {
		final out: String = applyIndexedFixOnce(
			'@:generic class Picker<T> {\n\n$ONE_FIELD\n\n\tpublic function new(?palette:Array<Int>) {\n$ONE_GUARD\n\t}\n\n}\n'
		);
		Assert.isTrue(out.indexOf('_cellsNumX = palette != null ? palette.length : 20;') != -1);
		Assert.equals(-1, out.indexOf('CELLS_NUM_X_DEFAULT'));
	}

	/**
	 * The derived name occurring anywhere ELSE in the file leaves the literal inline. Here it is a
	 * LOCAL in another method, which no member proof can see: a static of that name would compile
	 * and silently read as the local's twin at every other site. The absence assertion names the
	 * EMITTED member text rather than the bare name, which the local itself carries.
	 */
	public function testDerivedNameBoundElsewhereLeavesTheLiteralInline(): Void {
		final out: String = applyIndexedFixOnce(wrap(
			ONE_FIELD, ONE_GUARD, '',
			'\n\n\tprivate function probe():Int {\n\t\tfinal CELLS_NUM_X_DEFAULT:Int = 7;\n\t\treturn CELLS_NUM_X_DEFAULT;\n\t}'
		));
		Assert.isTrue(out.indexOf('_cellsNumX = palette != null ? palette.length : 20;') != -1);
		Assert.equals(-1, out.indexOf('private static inline final CELLS_NUM_X_DEFAULT:Int = 20;'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new FieldInitInConstructor() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('field-init-in-constructor'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('field-init-in-constructor'));
	}

	/** A minimal parseable class: `fields`, then a constructor holding `body`, then `tail`. */
	private function wrap(fields: String, body: String, extendsClause: String = '', tail: String = ''): String {
		return 'class Picker$extendsClause {\n\n$fields\n\n\tpublic function new(?palette:Array<Int>) {\n$body\n\t}$tail\n\n}\n';
	}

	private function violations(src: String): Array<Violation> {
		return new FieldInitInConstructor().run([{ file: 'Picker.hx', source: src }], new HaxeQueryPlugin());
	}

	/** The `prefer-final-field` findings over `src`, as the flagged declaration texts. */
	private function finalFieldNames(src: String): Array<String> {
		final vs: Array<Violation> = new PreferFinalField().run([{ file: 'Picker.hx', source: src }], new HaxeQueryPlugin());
		return [
			for (v in vs) {
				final span: Null<Span> = v.span;
				span == null ? '' : src.substring(span.from, span.to);
			}
		];
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: FieldInitInConstructor = new FieldInitInConstructor();
		return check.fix(src, check.run([{ file: 'Picker.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return canonicalize(src, edits(src));
	}

	/**
	 * The same pass driven WITH a `SymbolIndex`, which is what `lint --fix` always hands a check —
	 * and what the constant-extraction arm needs for its inherited-member proof. One check instance
	 * per call, so its same-pass claim ledger spans every violation of the file.
	 */
	private function applyIndexedFixOnce(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [{ file: 'Picker.hx', source: src }];
		final check: FieldInitInConstructor = new FieldInitInConstructor();
		return canonicalize(src, check.fix(src, check.run(files, plugin), plugin, SymbolIndex.build(files, plugin)));
	}

	/** How many times `needle` occurs in `haystack`. */
	private function occurrences(haystack: String, needle: String): Int {
		var found: Int = 0;
		var at: Int = haystack.indexOf(needle);
		while (at >= 0) {
			found++;
			at = haystack.indexOf(needle, at + needle.length);
		}
		return found;
	}

	private function canonicalize(src: String, es: Array<{ span: Span, text: String }>): String {
		return switch RefactorSupport.canonicalize(src, es, true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
