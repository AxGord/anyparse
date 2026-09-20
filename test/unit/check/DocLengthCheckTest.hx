package unit.check;

import anyparse.check.Check;
import anyparse.check.DocLength;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `doc-length` check: a doc block longer than the maximum the project declares is flagged
 * `Info`, and nothing else is — a line-comment run and a plain block banner are never measured
 * whatever their length, and the threshold is read per file from `apqlint.json`.
 *
 * Every fixture builds its block from a LINE COUNT rather than from typed-out prose, so an
 * assertion about the threshold cannot drift with the text it happens to be written in, and the
 * config every fixture runs under is passed in, so none of them depends on where the suite runs.
 */
class DocLengthCheckTest extends Test {

	/** An empty document: no rule declares a maximum, so the check's own default stands. */
	private static inline final DEFAULT: String = '{}';

	/** A document declaring a maximum far below the default, so a fixture cannot pass on either by luck. */
	private static inline final SHORT: String = '{"rules":{"doc-length":{"max":5}}}';

	/** The default this project's config does not override, spelled where a fixture asserts against it. */
	private static inline final DEFAULT_MAX: Int = 40;

	public function testABlockPastTheDefaultIsFlagged(): Void {
		final vs: Array<Violation> = violations(DEFAULT, docBlock(DEFAULT_MAX + 5));
		Assert.equals(1, vs.length);
		Assert.equals('doc-length', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.startsWith('doc block is 45 lines long'), vs[0].message);
		Assert.isTrue(vs[0].message.contains('maximum of 40'), vs[0].message);
	}

	public function testABlockAtTheMaximumIsClean(): Void {
		Assert.equals(0, violations(DEFAULT, docBlock(DEFAULT_MAX)).length);
	}

	public function testTheFindingSpansTheBlockItNames(): Void {
		final src: String = docBlock(DEFAULT_MAX + 5);
		final vs: Array<Violation> = violations(DEFAULT, src);
		final span: Null<Span> = vs[0].span;
		Assert.notNull(span);
		Assert.isTrue(src.substring((span: Span).from, (span: Span).to).startsWith('/**'), 'the span opens the block');
		Assert.isTrue(src.substring((span: Span).from, (span: Span).to).endsWith('*/'), 'the span closes the block');
	}

	/**
	 * The maximum belongs to the PROJECT and is read per file. The same block is asked twice —
	 * once under a document declaring a shorter contract, once under none — so a rule with the
	 * number built in fails one half of the pair whichever number it built in.
	 * Killed by arm `M-DOC-LENGTH-CONFIG-BLIND`.
	 */
	@:pin('control')
	@:killer('M-DOC-LENGTH-CONFIG-BLIND')
	public function testTheDeclaredMaximumIsRead(): Void {
		final src: String = docBlock(6);
		Assert.equals(1, violations(SHORT, src).length);
		Assert.equals(0, violations(DEFAULT, src).length);
		Assert.equals(0, violations(SHORT, docBlock(5)).length);
	}

	/**
	 * Only a DOC BLOCK is measured. A run of line comments and a plain block banner carry prose
	 * belonging to the statements they stand over, which other rules own; reporting all three
	 * under one id would leave a reader unable to tell which answer applies to what.
	 * Killed by arm `M-DOC-LENGTH-ANY-COMMENT`.
	 */
	@:pin('control')
	@:killer('M-DOC-LENGTH-ANY-COMMENT')
	public function testOnlyADocBlockIsMeasured(): Void {
		Assert.equals(0, violations(SHORT, lineRun(12)).length);
		Assert.equals(0, violations(SHORT, banner(12)).length);
		Assert.equals(1, violations(SHORT, docBlock(12)).length);
	}

	/**
	 * The block's own length is masked out of the finding IDENTITY and the declared maximum is
	 * not: a block that gained a line is the same standing finding, while a project that
	 * shortened its contract has changed one. Pinned against a message `run` produced, as
	 * `Check.VolatileMessage` requires, and asserted idempotent as the interface demands.
	 */
	public function testTheIdentityMasksTheLengthAndKeepsTheThreshold(): Void {
		final check: DocLength = new DocLength();
		final message: String = violations(DEFAULT, docBlock(DEFAULT_MAX + 5))[0].message;
		final identity: String = check.messageIdentity(message);
		Assert.isTrue(identity.startsWith('doc block is # lines long'), identity);
		Assert.isTrue(identity.contains('maximum of 40'), identity);
		Assert.equals(identity, check.messageIdentity(identity));
	}

	public function testFixReturnsEmptyAndTheReasonSaysWhy(): Void {
		final check: DocLength = new DocLength();
		final src: String = docBlock(DEFAULT_MAX + 5);
		final found: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, found, new HaxeQueryPlugin()).length);
		Assert.isTrue(check.noAutofixReason().indexOf('prose') >= 0, check.noAutofixReason());
	}

	public function testRegisteredInBuiltinsAsDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('doc-length');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'doc-length is opt-in');
		Assert.equals(184, Linter.builtins().length);
	}

	/** The check's findings on `src` under the `apqlint.json` document `configJson`. */
	private function violations(configJson: String, src: String): Array<Violation> {
		final check: DocLength = new DocLength();
		final cfg: LintConfig = LintConfig.parse(configJson);
		check.setConfigResolver((_) -> cfg);
		return check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** A class whose member carries a doc block spanning exactly `lines` physical lines. */
	private function docBlock(lines: Int): String {
		return 'class C {\n\t/**\n${body(lines - 2, ' * prose')}\n\t */\n\tfunction f() {}\n}';
	}

	/** A class whose member carries a run of `lines` contiguous line comments. */
	private function lineRun(lines: Int): String {
		return 'class C {\n${body(lines, '// prose')}\n\tfunction f() {}\n}';
	}

	/** A class whose member carries a plain block banner spanning exactly `lines` physical lines. */
	private function banner(lines: Int): String {
		return 'class C {\n\t/*\n${body(lines - 2, 'prose')}\n\t */\n\tfunction f() {}\n}';
	}

	/** `count` indented copies of `text`, one per line. */
	private function body(count: Int, text: String): String {
		return [for (i in 0...count) '\t$text'].join('\n');
	}

}
