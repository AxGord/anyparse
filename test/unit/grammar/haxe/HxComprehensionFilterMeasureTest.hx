package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * omega-comprehension-body-measure: an array comprehension whose generator body is a
 * FILTER `if` must weigh that body when the bracket cascade asks how wide the item is.
 * The defect: such an element parks its then-branch behind a `BodyGroup`, which every
 * static width measure defers to width 0 (`Renderer.fitsFlat` and
 * `DocMeasure.flatTokenWidthStep` both, deliberately - a `BodyGroup` decides its own
 * flat/break later). So `wrapping.arrayWrap` saw only `for (x in xs)`, landed the item in
 * `totalItemLength <= n` and answered NoWrap, pinning a comprehension whose line runs past
 * `maxLineLength`. The only wrap left was the filter's own `conditionWrapping`, which
 * breaks INSIDE the `if (` and strands the closing paren, the body and `];` on lines of
 * their own - the same line count as the unbroken form, and it reads worse.
 * The re-tag that makes the width visible (`WrapList.groupifyInlineBodies`) already
 * existed but was gated on `comprehensionFitMeasure`, i.e. on
 * `sameLine.comprehensionFor: fitLine`, the padded-bracket flavour. The under-measure is
 * not a property of that cascade: `arrayWrap`'s `totalItemLength <= n` is exactly as
 * width-only as `defaultComprehensionWrap`'s `exceedsMaxLineLength`. `comprehensionMeasure`
 * carries the re-tag to every comprehension; the rest probe stays with the fit cascade.
 * Ground truth is haxe-formatter, which opens the bracket for these items under the same
 * config - verified file by file on the Pony tree, where `tools/src/module/CfgModule.hx`,
 * `tools/src/module/Build.hx`, `tools/src/module/Run.hx` and
 * `tools/nodesrc/module/Bmfont.hx` all reach byte-identical output after the fix.
 */
@:nullSafety(Strict)
final class HxComprehensionFilterMeasureTest extends Test {

	/** The `maxLineLength` both configs carry, so the width assertion below cannot drift away from them. */
	private static inline final MAX_LINE: Int = 140;

	/**
	 * `wrapping.arrayWrap` left at the compiled default cascade, plus the `conditionWrapping`
	 * rule set that turns the under-measure into the visible `if (`-strand symptom.
	 */
	private static final CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": $MAX_LINE, "conditionWrapping": {"defaultWrap": "fillLineWithLeadingBreak", "rules": ['
		+ '{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}, "whitespace": '
		+ '{"typeHintColonPolicy": "after"}, "sameLine": {"ifBody": "fitLine", "comprehensionFor": "same"}}';

	/** `sameLine.comprehensionFor: fitLine` - the flavour that already carried the re-tag, pinned so the split keeps it byte-identical. */
	private static final FIT_CFG: String = '{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {'
		+ '"maxLineLength": $MAX_LINE}, "sameLine": {"comprehensionFor": "fitLine"}}';

	/** The reported source: a filtered comprehension whose one-line form is 152 columns at the 140 limit below. */
	private static final FILTERED: String = 'class M {\n\tfunction f() {\n\t\tfor (cfgs in allcfgs) {\n'
		+ '\t\t\tfinal actual: Array<T> = [for (cfg in cfgs) if (cfg.before == before && cfg.section == section'
		+ ' && modules.checkAllowGroups(cfg.group)) cfg];\n\t\t}\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * The reported shape: the bracket opens and the whole generator sits on one
	 * continuation line - the filter's condition is NOT broken inside its own parens.
	 */
	public function testFilteredComprehensionOpensBracketInsteadOfSplittingTheFilter(): Void {
		final out: String = HxWriteFixture.triviaWrite(FILTERED, CFG);
		Assert.isTrue(
			out.indexOf(
				'= [\n\t\t\t\tfor (cfg in cfgs) if (cfg.before == before && cfg.section == section'
				+ ' && modules.checkAllowGroups(cfg.group)) cfg\n\t\t\t];'
			) != -1,
			'expected the comprehension bracket to open, got:\n<$out>'
		);
		Assert.equals(-1, out.indexOf('if (\n'), 'the filter condition must not break inside its own parens, got:\n<$out>');
	}

	/** No line may exceed the configured `maxLineLength`, and a second pass must move nothing. */
	public function testFilteredComprehensionFitsTheLimitAndIsIdempotent(): Void {
		final out: String = HxWriteFixture.triviaWrite(FILTERED, CFG);
		for (line in out.split('\n')) Assert.isTrue(width(line) <= MAX_LINE, 'line over $MAX_LINE: <$line>');
		Assert.equals(out, HxWriteFixture.triviaWrite(out, CFG));
	}

	/**
	 * The measure is what moved, not the cascade: a comprehension with a plain (non-filter)
	 * body parks nothing behind a `BodyGroup`, so its item was already measured honestly and
	 * already cleared `totalItemLength <= n`. It opened its bracket before the fix and still does.
	 */
	public function testPlainBodiedComprehensionIsUnchanged(): Void {
		final src: String = 'class M {\n\tfunction f() {\n\t\tfor (cfgs in allcfgs) {\n\t\t\tfinal actual: Array<T> = ['
			+ 'for (cfg in cfgs) transformTheConfigValue(cfg, before, section, modules, group, extra)];\n\t\t}\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, CFG);
		Assert.isTrue(
			out.indexOf('= [\n\t\t\t\tfor (cfg in cfgs) transformTheConfigValue(cfg, before, section, modules, group, extra)\n\t\t\t];')
				!= -1,
			'expected the plain-bodied comprehension to keep opening its bracket, got:\n<$out>'
		);
	}

	/**
	 * The fit cascade keeps its own answer: a FITTING filter comprehension under
	 * `comprehensionFor: fitLine` stays on one padded line, as it did before the split.
	 */
	public function testFitCascadeFilteredComprehensionStillStaysFlat(): Void {
		final src: String = 'class M {\n\tfunction f() {\n'
			+ '\t\t_kept = [for (k in 0...values.length) if (values[k] != null) new Vector(values[k], k)];\n\t}\n}';
		final out: String = HxWriteFixture.triviaWrite(src, FIT_CFG);
		Assert.isTrue(
			out.indexOf('[ for (k in 0...values.length) if (values[k] != null) new Vector(values[k], k) ]') != -1,
			'expected the fitting fit-cascade comprehension to stay flat, got:\n<$out>'
		);
	}

	/** Rendered width of `line` with tabs counted at the configured `tabWidth` of 4. */
	private static function width(line: String): Int {
		var w: Int = 0;
		for (i in 0...line.length) w += line.charAt(i) == '\t' ? 4 : 1;
		return w;
	}

}
