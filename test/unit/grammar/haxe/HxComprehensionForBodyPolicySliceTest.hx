package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * ω-comprehension-for-body: `sameLine.comprehensionFor` really places the
 * comprehension BODY, instead of only triggering padded brackets.
 *
 * The key is declared `HxFormatBodyPolicy` and sits in the `sameLine`
 * section next to `forBody` / `expressionIf`, but until this slice its ONLY
 * consumer was `HaxeFormatConfigLoader.applyComprehensionForPadding`, which
 * reads it as a bracket-padding trigger. Measured on the base binary:
 * `same` / `next` / `fitLine` / `keep` gave four BYTE-IDENTICAL outputs for
 * both a flat and a source-broken comprehension, so no config value could
 * move a comprehension body at all.
 *
 * The mechanism was present and switched off, not missing: `HxForExpr.body`
 * and `HxForReif.body` already carry `@:fmt(bodyPolicy('expressionForBody'))`,
 * and `expressionForBody` already lives on `HxModuleWriteOptions` — nothing
 * but `expressionIf`'s Keep/Same fanout ever wrote it, so it stayed at its
 * `Keep` default. The slice is one read in `applySameLine`, placed AFTER
 * `applyExpressionIfFanout` so the SPECIFIC key outranks the general fanout.
 *
 * The four values are the engine's own `BodyPolicy`, so they mean here what
 * they mean on every other body knob: `same` puts the body on the head's
 * line, `next` on its own line one level in, `keep` reproduces the source
 * break, and `fitLine` keeps a body that RENDERS FLAT on the head line while it fits and
 * puts one that cannot render flat on its own line one level in. S78 made that
 * last clause strict: it used to ask only whether the body's FIRST line fits,
 * which glued an if/else head to the `for` and left its `else` below.
 *
 * Bracket padding is NOT part of the change — it stays coupled to
 * `comprehensionFor: fitLine` (fork parity: `MarkSameLine.markArrayComprehension`
 * pads `[ for … ]` in its FitLine arm), so every config here states its
 * padding through `whitespace.bracketConfig.comprehensionBrackets` and the
 * four arms differ in exactly one key.
 */
@:nullSafety(Strict)
final class HxComprehensionForBodyPolicySliceTest extends Test {

	/** Pony-shaped config — padded comprehension brackets, cuddled-open on, `comprehensionFor: same`. */
	private static final CFG_SAME: String = cfg('same', 'next');

	/** The same config with `comprehensionFor: next`. */
	private static final CFG_NEXT: String = cfg('next', 'next');

	/** The same config with `comprehensionFor: fitLine`. */
	private static final CFG_FIT: String = cfg('fitLine', 'next');

	/** The same config with `comprehensionFor: keep`. */
	private static final CFG_KEEP: String = cfg('keep', 'next');

	/**
	 * `comprehensionFor: next` against `expressionIf: same` — the fanout writes
	 * `expressionForBody` for Keep/Same, so this pair discriminates the ORDER of the
	 * two reads: the specific key has to win.
	 */
	private static final CFG_NEXT_OVER_FANOUT: String = cfg('next', 'same');

	/** A comprehension whose body is an if/else, written flat on one source line. */
	private static final FLAT_IF_ELSE: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue > offsetValue) elementValue else offsetValue ];\n\t}\n}';

	/** `same`: the body keeps the head line, which keeps the `for` head glued to its own `[`. */
	private static final SAME_IF_ELSE: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName) if (elementValue > offsetValue)\n\t\t\telementValue\n\t\telse\n'
		+ '\t\t\toffsetValue\n\t\t];\n\t}\n}';

	/** `next`: the `if` head leaves the `for` line and the `else` aligns with it — the user-reported ask. */
	private static final NEXT_IF_ELSE: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName)\n\t\t\tif (elementValue > offsetValue)\n\t\t\t\telementValue\n\t\t\telse\n'
		+ '\t\t\t\toffsetValue\n\t\t];\n\t}\n}';

	/** A plain-bodied comprehension the SOURCE broke after the `for` head. */
	private static final BROKEN_PLAIN: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [\n\t\t\tfor (elementValue in '
		+ 'sourceCollectionValueName)\n\t\t\t\tcomputeEntryValueFrom(elementValue)\n\t\t];\n\t}\n}';

	/** The same comprehension flat — what `same` and `fitLine` make of the broken source. */
	private static final FLAT_PLAIN: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName) computeEntryValueFrom(elementValue) ];\n\t}\n}';

	/** The body on its own line under the cuddled head — what `next` produces, and what `keep` reads back. */
	private static final NEXT_PLAIN: String = 'class C {\n\tfunction test() {\n\t\tfinal r = [ for (elementValue in '
		+ 'sourceCollectionValueName)\n\t\t\tcomputeEntryValueFrom(elementValue)\n\t\t];\n\t}\n}';

	public function new(): Void {
		super();
	}

	/** `same` on a body the source already wrote on the head line: byte-identical to the base binary. */
	@:pin('control')
	@:killer('M-ALWAYS-NEXT')
	public function testSameKeepsAFlatBodyOnTheHeadLine(): Void {
		Assert.equals(SAME_IF_ELSE, HxWriteFixture.triviaWrite(FLAT_IF_ELSE, CFG_SAME));
	}

	/** `same` OVERRIDES a source break — the byte that proves the key is no longer an alias for `keep`. */
	@:pin('control')
	@:killer('M-NO-WIRE')
	public function testSamePullsTheBodyUpOntoTheHeadLine(): Void {
		Assert.equals(FLAT_PLAIN, HxWriteFixture.triviaWrite(BROKEN_PLAIN, CFG_SAME));
	}

	/** `next` puts the if/else body on its own line under the `for`, `else` aligned with its own `if`. */
	@:pin('control')
	@:killer('M-NO-WIRE')
	public function testNextPutsTheBodyOnItsOwnLine(): Void {
		Assert.equals(NEXT_IF_ELSE, HxWriteFixture.triviaWrite(FLAT_IF_ELSE, CFG_NEXT));
	}

	/**
	 * `fitLine` asks whether the WHOLE body renders flat, not whether its FIRST line fits (S78) — an if/else
	 * body never does, so it leaves the head line. On THIS input that is byte-identical to `next`, which is
	 * why the pair is discriminated one arm down, on a body that DOES render flat:
	 * `testFitLinePullsUpABodyThatFits` collapses it, `testNextPutsTheBodyOnItsOwnLine`'s value would not.
	 */
	@:pin('control')
	@:killer('M-FIRST-LINE-FIT')
	public function testFitLineMovesANonFlatBodyOffTheHeadLine(): Void {
		Assert.equals(NEXT_IF_ELSE, HxWriteFixture.triviaWrite(FLAT_IF_ELSE, CFG_FIT));
	}

	/** `fitLine` on a flat-fitting body collapses the source break, like `same`. */
	@:pin('control')
	@:killer('M-NO-WIRE')
	public function testFitLinePullsUpABodyThatFits(): Void {
		Assert.equals(FLAT_PLAIN, HxWriteFixture.triviaWrite(BROKEN_PLAIN, CFG_FIT));
	}

	/** `keep` reproduces the source break — the pre-slice behaviour, now the value that ASKS for it. */
	@:pin('control')
	@:killer('M-ALWAYS-SAME')
	public function testKeepReadsTheSourceBreak(): Void {
		Assert.equals(NEXT_PLAIN, HxWriteFixture.triviaWrite(BROKEN_PLAIN, CFG_KEEP));
	}

	/** The `next` layout is a fixed point — a second write changes nothing. */
	@:pin('control')
	@:killer('M-ALWAYS-SAME')
	public function testNextLayoutIsIdempotent(): Void {
		Assert.equals(NEXT_IF_ELSE, HxWriteFixture.triviaWrite(NEXT_IF_ELSE, CFG_NEXT));
	}

	/** `comprehensionFor` is read AFTER the `expressionIf` fanout, so the specific key outranks it. */
	@:pin('control')
	@:killer('M-FANOUT-FIRST')
	public function testTheSpecificKeyOutranksTheExpressionIfFanout(): Void {
		Assert.equals(NEXT_PLAIN, HxWriteFixture.triviaWrite(FLAT_PLAIN, CFG_NEXT_OVER_FANOUT));
	}

	/** Pony-shaped config text with `comprehensionFor` and `expressionIf` as the only variables. */
	private static function cfg(comprehensionFor: String, expressionIf: String): String {
		return '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "comprehensionCuddledOpen": true},'
			+ ' "whitespace": {"bracketConfig": {"comprehensionBrackets": {"openingPolicy": "onlyAfter", "closingPolicy": "before"}}},'
			+ ' "sameLine": {"ifBody": "fitLine", "expressionIf": "$expressionIf", "comprehensionFor": "$comprehensionFor"}}';
	}

}
