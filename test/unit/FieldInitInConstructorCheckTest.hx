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

	private function canonicalize(src: String, es: Array<{ span: Span, text: String }>): String {
		return switch RefactorSupport.canonicalize(src, es, true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
