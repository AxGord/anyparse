package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.MemberOrder;
import anyparse.check.MemberSpacing;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import haxe.io.Path;
import unit.ConfigTrees;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `member-order` asks the WRITER's member-gap policy (`GrammarPlugin.memberGapPolicy`) before its own: a blank the
 * writer forces between two members is demanded, never reported, and a blank it removes is never demanded. Each
 * fixture runs under its own `hxformat.json` (a `ConfigTrees` tree), and each canonical fixture is asserted to BE
 * what the writer writes under that config, so the check and `fmt` are compared on the same bytes.
 */
@:nullSafety(Strict)
class MemberOrderWriterGapTest extends Test {

	/**
	 * the client's width and its `aroundMultilineFields: 1` - the config
	 * under which the client findings of this shape could never be fixed.
	 */
	private static inline final AROUND_MULTILINE: String =
		'{"wrapping": {"maxLineLength": 140}, "emptyLines": {"aroundMultilineFields": 1}}';

	/** The same width with the multi-line rule off - the control config. */
	private static inline final WIDTH_ONLY: String = '{"wrapping": {"maxLineLength": 140}}';

	/** The defaults: a doc-commented member is set off by one blank line before and after it. */
	private static inline final DEFAULTS: String = '{}';

	/** The doc-comment rule switched off on both sides, so a doc-commented slot keeps its source gaps. */
	private static inline final DOC_IGNORED: String =
		'{"emptyLines": {"afterFieldsWithDocComments": "ignore", "beforeDocCommentEmptyLines": "ignore"}}';

	/** No blank line before a doc-commented member - the before-policy is the gap's last write, so it beats the after-doc blank. */
	private static inline final BEFORE_DOC_NONE: String = '{"emptyLines": {"beforeDocCommentEmptyLines": "none"}}';

	/** `BEFORE_DOC_NONE` with the multi-line rule on. */
	private static inline final BEFORE_DOC_NONE_MULTILINE: String =
		'{"emptyLines": {"beforeDocCommentEmptyLines": "none", "aroundMultilineFields": 1}}';

	/**
	 * client `src/api/namespace/Help.hx` (without its package, imports and `@:nullSafety`): two same-rank
	 * fields, the second written over two lines, set off by the blank `aroundMultilineFields: 1`
	 * writes there - one of the client findings whose fix the canonical round-trip dropped every time.
	 */
	private static final HELP: String = 'class Help {\n\tpublic final faqs:GetDocs = new GetDocs();\n\n'
		+ '\tpublic final sendSupportEmail:NetEntity2<ResponseRoot2, ErrorResponse> =\n'
		+ '\t\tnew NetEntity2<ResponseRoot2, ErrorResponse>(\'help/SendSupportEmail\');\n\n\tpublic function new() {}\n}\n';

	/** A hand-written doc-commented field between two plain ones, no blank anywhere. */
	private static final DOC_TIGHT: String =
		'class C {\n\tprivate var a:Int;\n\t/** Doc. */\n\tprivate var b:Int;\n\tprivate var c:Int;\n}\n';

	/** `DOC_TIGHT` as the writer writes it under `DEFAULTS`. */
	private static final DOC_SET_OFF: String =
		'class C {\n\tprivate var a:Int;\n\n\t/** Doc. */\n\tprivate var b:Int;\n\n\tprivate var c:Int;\n}\n';

	private final _trees: ConfigTrees = new ConfigTrees('apq-member-order-writer-gap-test');

	public function teardown(): Void {
		_trees.removeAll();
	}

	/**
	 * The blank around a field the writer renders over two lines is the writer's, so it is not a finding - and the
	 * multi-line rule is what decides it: with the knob off the same blank is the check's to remove, as before.
	 * RED before N21 (the finding came back after every `--fix`). Killed by `M-MO-WRITER-REPORT-UNREAD` and
	 * `M-MO-WRITER-MULTILINE-IGNORED`.
	 */
	@:pin('control')
	@:killer('M-MO-WRITER-REPORT-UNREAD', 'M-MO-WRITER-MULTILINE-IGNORED')
	public function testTheWritersBlankAroundAMultiLineFieldIsNotReported(): Void {
		Assert.equals(HELP, formatted(HELP, AROUND_MULTILINE), 'the writer keeps the blank');
		Assert.equals(0, violations(fileUnder(AROUND_MULTILINE), HELP).length);
		final off: Array<Violation> = violations(fileUnder(WIDTH_ONLY), HELP);
		Assert.equals(1, off.length, 'with the knob off the blank is the check\'s to remove');
		if (off.length == 1) Assert.equals('members of one rank group are separated by a blank line', off[0].message);
	}

	/**
	 * The same gap glued is a finding naming the multi-line rule, and the fix lands the writer's blank itself - in
	 * the raw rebuild, not only after the canonical round-trip re-adds it. Killed by
	 * `M-MO-WRITER-MULTILINE-IGNORED` and `M-MO-INLINE-SEPARATOR-DROPPED`.
	 */
	@:pin('control')
	@:killer('M-MO-WRITER-MULTILINE-IGNORED', 'M-MO-INLINE-SEPARATOR-DROPPED')
	public function testAGluedMultiLineFieldIsReportedAndTheFixLandsTheWritersBlank(): Void {
		final glued: String = HELP.replace('new GetDocs();\n\n', 'new GetDocs();\n');
		final file: String = fileUnder(AROUND_MULTILINE);
		final vs: Array<Violation> = violations(file, glued);
		Assert.equals(1, vs.length);
		if (vs.length == 1)
			Assert.equals(
				'a member written over several lines is not separated from its neighbour by one blank line, as the formatter writes it',
				vs[0].message
			);
		final raw: String = rawFix(file, glued);
		Assert.equals(1, blanksBetween(raw, 'new GetDocs();', 'public final sendSupportEmail'), raw);
		Assert.equals(HELP, canonicalFix(file, glued, AROUND_MULTILINE));
	}

	/**
	 * The user's shape: a doc-commented field glued between two plain ones is REPORTED - before `fmt` ever runs -
	 * and the fix lands exactly the blanks the writer writes, before AND after it. RED before N21 (a comment-led slot
	 * was exempt either way). Killed by `M-MO-WRITER-DOC-IGNORED`, `M-MO-WRITER-FIX-UNREAD` and
	 * `M-MO-INLINE-SEPARATOR-DROPPED`.
	 */
	@:pin('control')
	@:killer('M-MO-WRITER-DOC-IGNORED', 'M-MO-WRITER-FIX-UNREAD', 'M-MO-INLINE-SEPARATOR-DROPPED')
	public function testADocCommentedFieldIsSetOffAsTheWriterSetsItOff(): Void {
		final file: String = fileUnder(DEFAULTS);
		final vs: Array<Violation> = violations(file, DOC_TIGHT);
		Assert.equals(1, vs.length);
		if (vs.length == 1)
			Assert.equals(
				'a doc-commented member is not separated from its neighbour by one blank line, as the formatter writes it', vs[0].message
			);
		final raw: String = rawFix(file, DOC_TIGHT);
		Assert.equals(1, blanksBetween(raw, 'private var a:Int;', '/** Doc. */'), raw);
		Assert.equals(1, blanksBetween(raw, 'private var b:Int;', 'private var c:Int;'), raw);
		Assert.equals(DOC_SET_OFF, formatted(DOC_TIGHT, DEFAULTS), 'the writer\'s own blanks');
		final fixed: String = canonicalFix(file, DOC_TIGHT, DEFAULTS);
		Assert.equals(DOC_SET_OFF, fixed);
		Assert.equals(0, violations(file, fixed).length, 'converges');
	}

	/** With the doc-comment rule off, the writer keeps the slot's source gaps, and so does the check. */
	public function testADocCommentedFieldIsLeftToTheSourceWhenTheRuleIsOff(): Void {
		Assert.equals(DOC_TIGHT, formatted(DOC_TIGHT, DOC_IGNORED));
		Assert.equals(DOC_SET_OFF, formatted(DOC_SET_OFF, DOC_IGNORED));
		Assert.equals(0, violations(fileUnder(DOC_IGNORED), DOC_TIGHT).length);
		Assert.equals(0, violations(fileUnder(DOC_IGNORED), DOC_SET_OFF).length);
	}

	/**
	 * A slot led by a LINE comment is no doc-commented member: the writer keeps its gaps glued or open, and the
	 * check leaves them alone. Killed by `M-GAP-DOCLED-ANY-COMMENT` (every comment counted as a doc comment, in
	 * the writer and the check alike).
	 */
	@:pin('control')
	@:killer('M-GAP-DOCLED-ANY-COMMENT')
	public function testALineCommentLedSlotIsLeftToTheSource(): Void {
		final tight: String = 'class C {\n\tprivate var a:Int;\n\t// Note.\n\tprivate var b:Int;\n\tprivate var c:Int;\n}\n';
		final open: String = 'class C {\n\tprivate var a:Int;\n\n\t// Note.\n\tprivate var b:Int;\n\n\tprivate var c:Int;\n}\n';
		Assert.equals(tight, formatted(tight, DEFAULTS));
		Assert.equals(open, formatted(open, DEFAULTS));
		Assert.equals(0, violations(fileUnder(DEFAULTS), tight).length);
		Assert.equals(0, violations(fileUnder(DEFAULTS), open).length);
	}

	/**
	 * The writer's doc blank is a MINIMUM: it fills an empty gap and keeps a fuller one as the source has it (here up
	 * to `maxAnywhereInFile: 2`), so two blank lines before a doc-commented method are no finding - the check's own
	 * rule leaves same-rank methods alone, and the writer asks for nothing more. Killed by
	 * `M-MO-WRITER-MINIMUM-AS-EXACT`.
	 */
	@:pin('control')
	@:killer('M-MO-WRITER-MINIMUM-AS-EXACT')
	public function testTheWritersDocBlankIsAMinimum(): Void {
		final config: String = '{"emptyLines": {"maxAnywhereInFile": 2}}';
		final src: String = 'class C {\n\tfunction a():Void {}\n\n\n\t/** B. */\n\tfunction b():Void {}\n}\n';
		Assert.equals(src, formatted(src, config), 'the writer keeps both blanks');
		Assert.equals(0, violations(fileUnder(config), src).length);
		final glued: String = src.replace('{}\n\n\n', '{}\n');
		Assert.equals(1, violations(fileUnder(config), glued).length, 'an empty gap is still reported');
	}

	/**
	 * `beforeDocCommentEmptyLines: none` removes the blank before a doc-commented member even where a rank boundary
	 * or an after-doc blank would put one: the check demands none there and accepts the writer's output. Killed by
	 * `M-GAP-DOC-PRECEDENCE`.
	 */
	@:pin('control')
	@:killer('M-GAP-DOC-PRECEDENCE')
	public function testTheBeforeDocNonePolicyRemovesTheBlankAndWins(): Void {
		final open: String =
			'class C {\n\tpublic var a:Int;\n\n\t/** B. */\n\tprivate var b:Int;\n\n\t/** C. */\n\tprivate var c:Int;\n}\n';
		final glued: String = 'class C {\n\tpublic var a:Int;\n\t/** B. */\n\tprivate var b:Int;\n\t/** C. */\n\tprivate var c:Int;\n}\n';
		final file: String = fileUnder(BEFORE_DOC_NONE);
		final vs: Array<Violation> = violations(file, open);
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.equals('a doc-commented member is separated by a blank line the formatter removes', vs[0].message);
		Assert.equals(glued, formatted(open, BEFORE_DOC_NONE));
		Assert.equals(0, violations(file, glued).length);
	}

	/**
	 * The multi-line rule runs after the doc-comment rule and tops an EMPTY gap up, so a doc-commented member the
	 * writer renders over several lines still gets its blank under `beforeDocCommentEmptyLines: none`. Killed by
	 * `M-GAP-MULTILINE-AFTER-NOBLANK`.
	 */
	@:pin('control')
	@:killer('M-GAP-MULTILINE-AFTER-NOBLANK')
	public function testAMultiLineMemberStillGetsItsBlankUnderBeforeDocNone(): Void {
		final glued: String = 'class C {\n\tvar a:Int = 0;\n\t/** B. */\n\tvar b:Array<String> = [\'${'a'.lpad('a', 60)}\', \'${'b'.lpad('b', 60)}\', \'${'c'.lpad('c', 60)}\'];\n}\n';
		final file: String = fileUnder(BEFORE_DOC_NONE_MULTILINE);
		final out: String = formatted(glued, BEFORE_DOC_NONE_MULTILINE);
		Assert.isTrue(out.contains('var a:Int = 0;\n\n\t/** B. */'), out);
		Assert.equals(0, violations(file, out).length);
		Assert.equals(1, violations(file, glued).length);
	}

	/**
	 * The members of an `#if` body are written with their source gaps - no doc-comment rule there - so the check
	 * applies none either. Killed by `M-MO-WRITER-CONDITIONAL`.
	 */
	@:pin('control')
	@:killer('M-MO-WRITER-CONDITIONAL')
	public function testAnIfBodyKeepsItsSourceGaps(): Void {
		final src: String = 'class C {\n\t#if X\n\tvar a:Int;\n\t/** B. */\n\tvar b:Int;\n\t#end\n}\n';
		Assert.equals(src, formatted(src, DEFAULTS));
		Assert.equals(0, violations(fileUnder(DEFAULTS), src).length);
	}

	/**
	 * Whatever the writer writes is a fixed point of the spacing rule: over a type holding every slot shape the
	 * rule distinguishes - plain, doc-commented, line- and block-comment-led, multi-line, annotated, methods - and
	 * every doc / multi-line policy combination, `fmt`'s output draws no finding.
	 */
	public function testFormattedOutputIsAFixedPointOfTheSpacingRule(): Void {
		final long: String = [for (c in ['a', 'b', 'c']) '\'${c.lpad(c, 50)}\''].join(', ');
		final src: String = 'class C {\n\tvar a:Int = 0;\n\t/** B. */\n\tvar b:Int = 0;\n\tvar c:Array<String> = [$long];\n'
			+ '\tvar d:Int = 0;\n\t// E.\n\tvar e:Int = 0;\n\t/* F. */\n\tvar f:Int = 0;\n\t@:keep\n\tvar g:Int = 0;\n\tvar '
			+ 'h:Int = 0;\n\n\tpublic function new() {}\n\t/** M. */\n\tfunction m():Void {}\n\tfunction n():Void {}\n}\n';
		for (config in [
			DEFAULTS,
			AROUND_MULTILINE,
			DOC_IGNORED,
			BEFORE_DOC_NONE,
			BEFORE_DOC_NONE_MULTILINE,
			'{"emptyLines": {"afterFieldsWithDocComments": "none", "aroundMultilineFields": 1}}'
		]) {
			final out: String = formatted(src, config);
			Assert.equals(out, formatted(out, config), 'canonical under $config');
			final vs: Array<Violation> = violations(fileUnder(config), out);
			Assert.equals(0, vs.length, '$config: ${[for (v in vs) v.message]}\n$out');
		}
	}

	/** `C.hx` in a fresh tree whose `hxformat.json` is `config`. */
	private function fileUnder(config: String): String {
		return Path.join([_trees.withFormatConfig('tree', config), 'C.hx']);
	}

	/** The `member-order` findings of `src` read as `file`. */
	private function violations(file: String, src: String): Array<Violation> {
		return CheckFixture.violationsIn(new MemberOrder(), [{ file: file, source: src }], null, emptyConfig());
	}

	/** `src` with the fix's edits for its own findings spliced raw - the rebuild before the canonical round-trip. */
	private function rawFix(file: String, src: String): String {
		return CanonicalEdit.applyEdits(
			src, CheckFixture.fixRun(new MemberOrder(), [{ file: file, source: src }], null, null, emptyConfig()).edits
		);
	}

	/** `src` after the fix and the production canonicalisation under `config`. */
	private function canonicalFix(file: String, src: String, config: String): String {
		final edits: Array<{ span: Span, text: String }> = CheckFixture.fixRun(
			new MemberOrder(), [{ file: file, source: src }], null, null, emptyConfig()
		)
			.edits;
		return switch CanonicalEdit.canonicalize(src, edits, true, new HaxeQueryPlugin(), config) {
			case Ok(text): text;
			case Err(message):
				Assert.fail(message);
				src;
		};
	}

	/** The blank lines between the first `before` in `text` and the `after` following it. */
	private static function blanksBetween(text: String, before: String, after: String): Int {
		final from: Int = text.indexOf(before) + before.length;
		return MemberSpacing.blankLineCount(text.substring(from, text.indexOf(after, from)));
	}

	/** `src` as the writer writes it under `config`. */
	private static function formatted(src: String, config: String): String {
		return new HaxeQueryPlugin().writeRoundTrip(src, config) ?? '';
	}

	/** The EMPTY lint config, so no `apqlint.json` discovered from the process cwd decides a verdict. */
	private static function emptyConfig(): (String) -> LintConfig {
		final cfg: LintConfig = LintConfig.parse('{}');
		return _ -> cfg;
	}

}
