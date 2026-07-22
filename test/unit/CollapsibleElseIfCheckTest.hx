package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.CollapsibleElseIf;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.query.RefactorSupport;

/**
 * The `collapsible-else-if` check: an `else` whose body is a block holding exactly one
 * statement, and that statement is an `if`, is flagged `Info` — provided the enclosing `if`
 * sits where no trailing `else` can re-bind, and nothing but whitespace precedes the inner
 * `if` inside the braces. The autofix strips the block's braces — one edit whose text is
 * the interior, so a trailing comment survives — and leaves the collapsed chain's bodies
 * exactly as written: restoring brace symmetry belongs to the writer (`SingleStmtBraces`,
 * gate 7), whose chain scan braces every bare branch of a chain in which any branch keeps
 * them — the collapsed `if`'s own body, never the `else if` link itself, which is exempt
 * so the wrap cannot rebuild the `else { if … }` the collapse removed. A multi-statement block, a non-`if` sole statement, an
 * already-collapsed `else if`, a `#if` region inside the braces, a leading comment inside
 * the braces, and a dangling-exposed position are all safe misses; an `else if` chain is not.
 */
class CollapsibleElseIfCheckTest extends Test {

	/**
	 * `hxformat.json` with `whitespace.bracesConfig.singleStatementBraces: "remove"` — the
	 * policy the collapse's brace symmetry depends on; the `sameLine` knobs only pin the
	 * layout so the assertions can name exact lines. `RefactorSupport.canonicalize`'s
	 * DEFAULT options leave it off (the writer then neither drops nor adds braces), so an
	 * end-to-end assertion about braces must pass this explicitly or it passes vacuously.
	 * The real `lint --fix` path threads the project's discovered config the same way.
	 */
	private static final REMOVE_BRACES_CONFIG: String = '{ "whitespace": { "bracesConfig": { "singleStatementBraces": "remove" } },'
		+ ' "sameLine": { "ifBody": "same", "elseBody": "same" } }';

	public function testElseBlockWrappingIfFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) p(); else {\n\t\t\tif (b) q();\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('collapsible-else-if', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this else block wraps a single if — collapse it to else if', vs[0].message);
	}

	public function testInnerElseStillFlagged(): Void {
		Assert.equals(1, violations(wrap('if (a) p(); else {\n\t\t\tif (b) q(); else r();\n\t\t}')).length);
	}

	public function testMultiStatementBlockNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) p(); else {\n\t\t\tq();\n\t\t\tif (b) r();\n\t\t}')).length);
	}

	/**
	 * The `if` FIRST in a multi-statement block: pins `isSingleIfBlock`'s exact-one-child
	 * requirement, which a block whose `if` comes second never exercises (its first child
	 * is not an `if` at all). Relaxing the count to `>= 1` would hoist `s()` out of the
	 * `else`.
	 */
	public function testIfFirstInMultiStatementBlockNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) p(); else {\n\t\t\tif (b) q();\n\t\t\ts();\n\t\t}')).length);
	}

	/**
	 * The dangling-`else` hazard: the flagged `if` is the brace-less then-branch of an
	 * enclosing `if` that carries a trailing `else`, so collapsing would rebind that
	 * `else` to the inner `if` (`r()` from `!x` to `x && !a && !b`).
	 */
	public function testDanglingElseThenBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (x)\n\t\t\tif (a) p();\n\t\t\telse {\n\t\t\t\tif (b) q();\n\t\t\t}\n\t\telse r();')).length);
	}

	/** The same hazard reached through a loop body rather than a bare then-branch. */
	public function testDanglingElseLoopBodyNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('if (x)\n\t\t\tfor (i in 0...1) if (a) p();\n\t\t\telse {\n\t\t\t\tif (b) q();\n\t\t\t}\n\t\telse r();')).length
		);
	}

	/**
	 * An `else if` chain: the flagged `if` is another `if`'s else branch, not a direct
	 * block child, and is still flagged — an else branch inherits its chain head's
	 * position, and no trailing `else` can follow the head.
	 */
	public function testElseIfChainFlagged(): Void {
		Assert.equals(1, violations(wrap('if (a) p();\n\t\telse if (b) q();\n\t\telse {\n\t\t\tif (c) r();\n\t\t}')).length);
	}

	public function testNonIfStatementNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) p(); else {\n\t\t\tq();\n\t\t}')).length);
	}

	public function testAlreadyCollapsedNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) p(); else if (b) q();')).length);
	}

	public function testConditionalCompilationRegionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) p(); else {\n\t\t\t#if sys\n\t\t\tif (b) q();\n\t\t\t#end\n\t\t}')).length);
	}

	public function testFixEmitsSingleInteriorEdit(): Void {
		final src: String = wrap('if (a) p(); else {\n\t\t\tif (b) q();\n\t\t}');
		final edits: Array<{ span: Span, text: String }> = fixEdits(src);
		Assert.equals(1, edits.length);
		Assert.equals('if (b) q();', edits[0].text);
	}

	/**
	 * The interior is emitted BARE even opposite a brace-keeping then-branch — restoring
	 * brace symmetry is the writer's job (`SingleStmtBraces`, gate 7), not this edit's.
	 */
	public function testBlockThenBranchInteriorStaysBare(): Void {
		final edits: Array<{ span: Span, text: String }> =
			fixEdits(wrap('if (a) {\n\t\t\tp();\n\t\t\tp2();\n\t\t} else {\n\t\t\tif (b) q();\n\t\t}'));
		Assert.equals(1, edits.length);
		Assert.equals('if (b) q();', edits[0].text);
	}

	/** Same, with the collapsed chain carrying its own trailing `else`. */
	public function testBlockThenBranchWholeChainStaysBare(): Void {
		final edits: Array<{ span: Span, text: String }> =
			fixEdits(wrap('if (a) {\n\t\t\tp();\n\t\t\tp2();\n\t\t} else {\n\t\t\tif (b) q(); else r();\n\t\t}'));
		Assert.equals(1, edits.length);
		Assert.equals('if (b) q(); else r();', edits[0].text);
	}

	/**
	 * A LEADING line comment inside the braces is a safe miss — collapsing would strand it
	 * between `else` and `if` and push the `if` onto its own unindented line.
	 */
	public function testLeadingLineCommentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) p(); else {\n\t\t\t// note\n\t\t\tif (b) q();\n\t\t}')).length);
	}

	/** The block-comment form of the same stranded-comment hazard. */
	public function testLeadingBlockCommentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) p(); else {\n\t\t\t/* note */\n\t\t\tif (b) q();\n\t\t}')).length);
	}

	/** A comment AFTER the inner `if` only trails the collapsed statement, so it stays flagged. */
	public function testTrailingCommentStillFlagged(): Void {
		final src: String = wrap('if (a) p(); else {\n\t\t\tif (b) q(); // note\n\t\t}');
		Assert.equals(1, violations(src).length);
		final edits: Array<{ span: Span, text: String }> = fixEdits(src);
		Assert.equals(1, edits.length);
		Assert.equals('if (b) q(); // note', edits[0].text);
	}

	/**
	 * End-to-end: the emitted file, not just the edit, keeps a trailing interior comment.
	 */
	public function testFixOutputKeepsInteriorComment(): Void {
		final out: String = applyFixOnce(wrap('if (a) p(); else {\n\t\t\tif (b) q(); // note\n\t\t}'));
		Assert.isTrue(out.indexOf('// note') != -1);
		Assert.isTrue(out.indexOf('if (b) q();') != -1);
	}

	/** End-to-end: a bare then-branch collapses onto the `else` line, no braces introduced. */
	public function testFixOutputCollapsesOntoElseLine(): Void {
		final out: String = applyFixOnce(wrap('if (a) p(); else {\n\t\t\tif (b) q();\n\t\t}'), REMOVE_BRACES_CONFIG);
		Assert.isTrue(out.indexOf('else if (b) q();') != -1);
		Assert.equals(-1, out.indexOf('else if (b) {'));
	}

	/**
	 * The motivating `CrashDumper` shape under `singleStatementBraces: "remove"`: the
	 * then-branch is a brace-KEEPING block, so the collapsed chain's body must be braced
	 * too. The check no longer emits those braces — the WRITER does, on the canonicalizing
	 * round-trip (`SingleStmtBraces`, gate 7's repair direction). Without it the asymmetry
	 * would be permanent, and `fmt` would report it as canonical.
	 */
	public function testFixOutputKeepsBracesOppositeBlockThenBranch(): Void {
		final out: String = applyFixOnce(
			wrap('if (a) {\n\t\t\tp();\n\t\t\tp2();\n\t\t} else {\n\t\t\tif (b) q();\n\t\t}'), REMOVE_BRACES_CONFIG
		);
		Assert.isTrue(out.indexOf('} else if (b) {') != -1);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('collapsible-else-if'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('collapsible-else-if'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new CollapsibleElseIf().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/**
	 * Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one
	 * pass, with `reformat` on so the minimal `wrap` fixture need not be canonical itself.
	 */
	private function applyFixOnce(src: String, ?optsJson: String): String {
		final edits: Array<{ span: Span, text: String }> = fixEdits(src);
		return switch RefactorSupport.canonicalize(src, edits, true, new HaxeQueryPlugin(), optsJson) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	private function fixEdits(src: String): Array<{ span: Span, text: String }> {
		final check: CollapsibleElseIf = new CollapsibleElseIf();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
