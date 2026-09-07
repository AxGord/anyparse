package unit.check;

import anyparse.check.Check;
import anyparse.check.CommentWidth;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `comment-width` check: a comment line rendered wider than the configured
 * `wrapping.maxLineLength` is flagged `Info`, and its autofix breaks the line back into the
 * width inside the block it already lives in.
 *
 * Every fixture is measured rather than counted by eye — `widestLine` renders a tab at the
 * config's own indent width, the way the writer does — so a threshold assertion cannot drift
 * with the prose it is written in.
 *
 * The width itself is read from the file's OWN `hxformat.json`. The fixtures that use `C.hx`
 * resolve this repository's (140 at tab 4, as the suite runs from the repository root); the
 * one that matters most builds a SECOND config declaring 60 and asserts the same source both
 * ways, since a rule with the number baked in passes every fixture written against one config.
 */
class CommentWidthCheckTest extends Test {

	/** Prose long enough that a `\t * ` doc line carrying it renders at 150 columns. */
	private static inline final LONG: String = 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi '
		+ 'omicron pi rho sigma tau upsilon phi chi psi omega and more words here';

	/** A second prose line, different from `LONG` so the reflow's protection list can tell the two apart. */
	private static inline final LONG_TWO: String = 'iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi '
		+ 'omega alpha beta gamma delta epsilon zeta eta theta and further words';

	/** Prose that overflows a 60-column config and fits a 140-column one — 73 rendered columns as a doc line. */
	private static inline final MEDIUM: String = 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu';

	/** A config declaring a line width no other fixture uses — the SECOND declaration this rule is read against. */
	private static inline final NARROW: String = '{"wrapping": {"maxLineLength": 60}, "indentation": {"character": "tab", "tabWidth": 4}}';

	/** Every fixture directory `makeTree` built, removed in `teardown`; their shared parent is reused across runs. */
	private final _made: Array<String> = [];

	public function teardown(): Void {
		for (dir in _made) removeTree(dir);
		_made.resize(0);
	}

	public function testWideDocLineIsFlagged(): Void {
		final vs: Array<Violation> = violations(doc(LONG));
		Assert.equals(1, vs.length);
		Assert.equals('comment-width', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('150 columns wide, past the configured maximum of 140'), vs[0].message);
	}

	public function testALineInsideTheWidthIsNotFlagged(): Void {
		Assert.equals(0, violations(doc(MEDIUM)).length);
	}

	public function testWideLineCommentIsFlagged(): Void {
		Assert.equals(1, violations('class C {\n\t// $LONG\n\tvar x = 1;\n}').length);
	}

	public function testTwoCommentsOnOneLineAreReportedOnce(): Void {
		Assert.equals(1, violations('class C {\n\t/* $LONG */ /* and */\n\tvar x = 1;\n}').length);
	}

	/**
	 * The COMMENT has to be what puts the line over. Code already past the width would still be
	 * over with the comment deleted, and its width is the formatter's business, not this rule's.
	 *
	 * This gate is the whole difference between 470 over-width comment lines in this tree and the
	 * 468 the rule reports: the two it drops are `// noqa` markers riding 160-column string-literal
	 * fixtures in `FoldStringLiteralsWidthCheckTest`. Asserted beside the narrow-code case, which
	 * IS a finding, so a rule that dropped every trailing comment would fail the pair.
	 * Killed by arm `M-COMMENT-WIDTH-CODE-BLIND`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-CODE-BLIND')
	public function testATrailingCommentBehindOverWideCodeIsNotThisRulesFinding(): Void {
		final wide: String = 'class C {\n\tfunction f() {\n\t\tfinal s: String = "' + rep('x', 130) + '"; // short\n\t}\n}';
		Assert.isTrue(widestLine(wide, 'C.hx') > 140, 'the fixture code must itself be over-width');
		Assert.equals(0, violations(wide).length);
		Assert.equals(1, violations('class C {\n\tfunction f() {\n\t\tvar x = 1; // $LONG\n\t}\n}').length);
	}

	/**
	 * A comment trailing after code is report-only: its continuation would be a NEW own-line
	 * comment, which the writer then relocates — the shape `wrapCommentBody` refuses for the same
	 * reason. Killed by arm `M-COMMENT-WIDTH-TRAILING-WRAPPED`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-TRAILING-WRAPPED')
	public function testATrailingCommentIsReportOnly(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar x = 1; // $LONG\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('it trails after code'), vs[0].message);
		Assert.equals(0, new CommentWidth().fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * The interior of a ``` fence is a code sample whatever its first character looks like, and
	 * `SourceComments.reflowRefusal` is per-line and cannot see the fence that opened above it.
	 * The prose line OUTSIDE the fence in the same block is asserted fixable in the same fixture,
	 * so a rule that refused the whole block would fail it too.
	 * Killed by arm `M-COMMENT-WIDTH-FENCE-BLIND`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-FENCE-BLIND')
	public function testAFencedCodeSampleIsReportOnly(): Void {
		final src: String = 'class C {\n\t/**\n\t * $LONG_TWO\n\t *\n\t * ```haxe\n\t * $LONG\n\t * ```\n\t */\n\tfunction f() {}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(2, vs.length);
		Assert.isFalse(vs[0].message.contains('not reflowed'), vs[0].message);
		Assert.isTrue(vs[1].message.contains('inside a fenced code block'), vs[1].message);
	}

	/**
	 * The per-line shapes are `SourceComments.reflowRefusal`'s, shared with the reflow itself so
	 * the rule can never decline a line the reflow would have wrapped. A table row is one of them,
	 * and its reason travels in the message. Killed by arm `M-COMMENT-REFLOW-UNSAFE-LINES`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-REFLOW-UNSAFE-LINES')
	public function testATableRowIsReportOnlyAndSaysSo(): Void {
		final vs: Array<Violation> = violations(doc('| $LONG |'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('not reflowed: a table row'), vs[0].message);
	}

	/**
	 * The fix breaks the line back into the width, inside the block it already lives in, and the
	 * PROSE comes back word for word — nothing is joined and nothing is cut mid-word.
	 * Killed by arm `M-COMMENT-REFLOW-ABSENT`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-REFLOW-ABSENT')
	public function testTheFixReflowsIntoTheWidthWordForWord(): Void {
		final src: String = doc(LONG);
		final text: String = fixed(src);
		Assert.isTrue(widestLine(text, 'C.hx') <= 140, 'no line past the width: ' + widestLine(text, 'C.hx') + ' in $text');
		Assert.equals(prose(src), prose(text));
	}

	/** Running the check over its own output proposes nothing — the fix is a fixed point. */
	public function testTheFixIsAFixedPoint(): Void {
		Assert.equals(0, violations(fixed(doc(LONG))).length);
	}

	/**
	 * The width comes from the file's own `hxformat.json`, not from a number in this rule.
	 *
	 * The SECOND declaration is what makes this discriminate: a 73-column doc line is a finding
	 * under a config declaring 60 and no finding under this repository's 140, and both halves are
	 * asserted on the SAME source, so a rule with 140 baked in fails the first and a rule that
	 * flagged every comment fails the second. Killed by arm `M-COMMENT-WIDTH-CONFIG-BLIND`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-CONFIG-BLIND')
	public function testTheConfiguredWidthIsRead(): Void {
		final dir: String = makeTree('narrow');
		File.saveContent(Path.join([dir, 'hxformat.json']), NARROW);
		final src: String = doc(MEDIUM);
		Assert.equals(1, violations(src, Path.join([dir, 'A.hx'])).length);
		Assert.equals(0, violations(src, 'C.hx').length);
	}

	/**
	 * The fix reflows only the lines THESE violations name; every other line of the same block
	 * goes to `wrapCommentBody` as one it must leave byte-identical.
	 *
	 * Without it a whole-body edit would carry lines no surviving finding asked for — the
	 * justification rule on `Check.fix`, and the shape `noqa` on one line of a two-line block
	 * would silently defeat. Killed by arm `M-COMMENT-WIDTH-PROTECTION-OFF`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-PROTECTION-OFF')
	public function testOnlyTheLinesTheViolationsNameAreReflowed(): Void {
		final src: String = 'class C {\n\t/**\n\t * $LONG\n\t * $LONG_TWO\n\t */\n\tfunction f() {}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(2, vs.length);
		final text: String = applyEdits(src, new CommentWidth().fix(src, [vs[0]], new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('\t * $LONG_TWO\n'), text);
		Assert.isFalse(text.contains('\t * $LONG\n'), text);
	}

	/**
	 * Two IDENTICAL over-width lines in one block are two lines, and naming one wraps ONE.
	 *
	 * The shape the reflow's own `was` channel cannot express: it protects by matching a line's
	 * TEXT, so each twin would protect the other, the line the finding named would come back
	 * unwrapped, and `--fix` would report an edit that never happened with nothing to say why.
	 * `wrapAt` names indices instead. Both halves are asserted on one text — the wrapped form has
	 * to appear AND the untouched twin has to still stand — so neither is satisfiable alone.
	 * Killed by arm `M-COMMENT-WIDTH-PROTECTION-BY-TEXT`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-PROTECTION-BY-TEXT')
	public function testTwoIdenticalWideLinesAreTwoLines(): Void {
		final src: String = 'class C {\n\t/**\n\t * $LONG\n\t * $LONG\n\t */\n\tfunction f() {}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(2, vs.length);
		final text: String = applyEdits(src, new CommentWidth().fix(src, [vs[0]], new HaxeQueryPlugin()));
		Assert.equals(src.split('\n').length + 1, text.split('\n').length);
		Assert.isTrue(text.contains('\t * $LONG\n\t */'), text);
	}

	/**
	 * The code gate reads BOTH sides of the comment.
	 *
	 * A short banner between a call head and a long argument leaves nothing to its left and
	 * everything to its right: measuring only the left called a 162-column line the comment's
	 * doing, when deleting the comment leaves 154. The same line with a LONG comment IS a finding,
	 * asserted beside it, so a rule that dropped every shared line would fail the pair.
	 * Killed by arm `M-COMMENT-WIDTH-CODE-BLIND`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-CODE-BLIND')
	public function testCodeOnBothSidesOfAShortCommentIsNotThisRulesFinding(): Void {
		final wide: String = 'class C {\n\tfunction f() {\n\t\tg(\n\t\t\t/* n */ "' + rep('z', 140) + '"\n\t\t);\n\t}\n}';
		Assert.isTrue(widestLine(wide, 'C.hx') > 140, 'the fixture line must itself be over-width');
		Assert.equals(0, violations(wide).length);
		Assert.equals(1, violations('class C {\n\tfunction f() {\n\t\tg(\n\t\t\t/* $LONG */ "z"\n\t\t);\n\t}\n}').length);
	}

	/**
	 * A prose line whose identical twin sits inside a fenced block is still prose.
	 *
	 * The reflow probe used to wrap every open line of the block at once and look for each line's
	 * text in the result, which read the surviving fenced twin as evidence that THIS line could not
	 * be broken — a false `no break point` on a line full of spaces, recorded as the decline reason.
	 * Killed by arm `M-COMMENT-WIDTH-PROTECTION-BY-TEXT`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-PROTECTION-BY-TEXT')
	public function testAProseLineWithATwinInsideAFenceIsStillFixable(): Void {
		final src: String = 'class C {\n\t/**\n\t * $LONG\n\t *\n\t * ```haxe\n\t * $LONG\n\t * ```\n\t */\n\tfunction f() {}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(2, vs.length);
		Assert.isFalse(vs[0].message.contains('not reflowed'), vs[0].message);
		Assert.equals(1, new CommentWidth().fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/**
	 * A one-line block whose `*\/` shares the line is over-width by exactly the closer, which
	 * `wrapCommentBody` measures nothing of — it reads a 141-column line as 139 and leaves it.
	 * The rule says THAT rather than "no break point", which the same silence would otherwise be
	 * reported as. Twenty lines of this tree are in this state, all at 141 or 142 columns.
	 * Killed by arm `M-COMMENT-WIDTH-CLOSER-UNSEEN`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-CLOSER-UNSEEN')
	public function testAOneLineBlockOverByItsCloserNamesTheCloser(): Void {
		final src: String = 'class C {\n\t/** ' + rep('word ', 26).rtrim() + 'z */\n\tfunction f() {}\n}';
		Assert.equals(141, widestLine(src, 'C.hx'));
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('the block closer shares this line'), vs[0].message);
	}

	/**
	 * Nothing inside a raw `#if` region projects, so no edit there can be corroborated by the tree
	 * — the rule reports and declines, as every mutating op does over one.
	 * Killed by arm `M-COMMENT-WIDTH-OPAQUE-OPEN`.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WIDTH-OPAQUE-OPEN')
	public function testACommentInARawCondRegionIsReportOnly(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\t#if sys if (c) { g(); } else\n\t\t// $LONG\n\t\t#end h();\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('conditional-compilation region the parser captured raw'), vs[0].message);
		Assert.equals(0, new CommentWidth().fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/** A source that does not parse cannot rule a raw `#if` region out, so every finding in it declines. */
	public function testAnUnparseableSourceDeclinesFailClosed(): Void {
		final vs: Array<Violation> = violations('class C { function f( {\n\t// $LONG\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('does not parse'), vs[0].message);
	}

	/** `fix` writes the gate that declined onto the finding, which is what `--fix`'s unfixed ledger reads. */
	public function testFixWritesTheDeclineReason(): Void {
		final src: String = doc('| $LONG |');
		final vs: Array<Violation> = violations(src);
		new CommentWidth().fix(src, vs, new HaxeQueryPlugin());
		Assert.equals('a table row', vs[0].declineReason);
	}

	/** The MEASURED width is masked out of the finding key; the CONFIGURED maximum after it is a threshold and stays. */
	public function testMessageIdentityMasksTheMeasurementAndKeepsTheThreshold(): Void {
		final check: CommentWidth = new CommentWidth();
		Assert.equals(
			'comment line is # columns wide, past the configured maximum of 140', check.messageIdentity(violations(doc(LONG))[0].message)
		);
	}

	public function testRegisteredAndOffByDefault(): Void {
		final check: Null<Check> = Linter.byId('comment-width');
		Assert.notNull(check);
		Assert.isTrue(check is DefaultOff);
	}

	/** Run the check over `src` as if it were `file`, whose own `hxformat.json` supplies the width. */
	private function violations(src: String, file: String = 'C.hx'): Array<Violation> {
		return new CommentWidth().run([{ file: file, source: src }], new HaxeQueryPlugin());
	}

	/** `src` with every edit the check's own fix proposes for every finding it reports. */
	private function fixed(src: String, file: String = 'C.hx'): String {
		final check: CommentWidth = new CommentWidth();
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		return applyEdits(src, check.fix(src, check.run([{ file: file, source: src }], plugin), plugin));
	}

	/** A class carrying one doc block whose single content line is `line`. */
	private function doc(line: String): String {
		return 'class C {\n\t/**\n\t * $line\n\t */\n\tfunction f() {}\n}';
	}

	/** The widest line of `text` in rendered columns, a tab worth `file`'s own configured indent width. */
	private function widestLine(text: String, file: String): Int {
		final layout: LayoutMetrics = metricsOf(file);
		var best: Int = 0;
		for (line in text.split('\n')) {
			var cols: Int = 0;
			for (i in 0...line.length) cols += line.fastCodeAt(i) == '\t'.code ? layout.indentWidth : 1;
			if (cols > best) best = cols;
		}
		return best;
	}

	/** The layout `file` resolves — this repository's own config for a bare name, a fixture's for a built one. */
	private function metricsOf(file: String): LayoutMetrics {
		final layout: Null<LayoutMetrics> = new HaxeQueryPlugin().layoutMetrics(FormatConfigDiscovery.discover(file));
		if (layout == null) throw new Exception('no layout metrics resolved for $file');
		return layout;
	}

	/** Every comment line of `text` with its marker stripped, folded into one whitespace-normalised run. */
	private function prose(text: String): String {
		final words: Array<String> = [];
		for (line in text.split('\n')) {
			var rest: String = line.ltrim();
			for (marker in ['/**', '/*', '*/', '//', '*']) if (rest.startsWith(marker)) {
				rest = rest.substring(marker.length);
				break;
			}
			for (word in rest.split(' ')) {
				final trimmed: String = word.trim();
				if (trimmed != '') words.push(trimmed);
			}
		}
		return words.join(' ');
	}

	/** A uniquely named temporary directory, removed in `teardown`. */
	private function makeTree(name: String): String {
		final root: String = Path.join([Sys.getEnv('TMPDIR') ?? '/tmp', 'apq-comment-width-test']);
		if (!FileSystem.exists(root)) FileSystem.createDirectory(root);
		final dir: String = Path.join([root, 'apq-cw-$name-${Std.random(0x7FFFFFFF)}']);
		FileSystem.createDirectory(dir);
		_made.push(dir);
		return dir;
	}

	/** `src` with `edits` spliced in, last first, so an earlier span keeps its offsets. */
	private static function applyEdits(src: String, edits: Array<{ span: Span, text: String }>): String {
		final ordered: Array<{ span: Span, text: String }> = edits.copy();
		ordered.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (edit in ordered) out = out.substring(0, edit.span.from) + edit.text + out.substring(edit.span.to);
		return out;
	}

	/** `unit` repeated `times` over. */
	private static function rep(unit: String, times: Int): String {
		final buf: StringBuf = new StringBuf();
		for (_ in 0...times) buf.add(unit);
		return buf.toString();
	}

	/** Remove `dir` and everything under it. */
	private static function removeTree(dir: String): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(path))
				removeTree(path);
			else
				FileSystem.deleteFile(path);
		}
		FileSystem.deleteDirectory(dir);
	}

}
