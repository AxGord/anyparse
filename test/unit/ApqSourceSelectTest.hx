package unit;

import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * `apq source --select <sel>` / `--at <line>:<col>` — resolve a node address to
 * the 1-based inclusive line range spanning it. The clean "read one node's
 * source by name" path (raw source, no S-expr), the read counterpart of
 * `ast --select`.
 *
 * `Cli.resolveNodeLineBounds` is pure over its `content` argument (it parses
 * the passed source, not the path on disk), so it is tested directly via
 * `@:access`; the `Sys.print` rendering wiring is covered by manual e2e.
 */
@:access(anyparse.query.Cli)
@:nullSafety(Strict)
class ApqSourceSelectTest extends Test {

	private static final SRC: String = 'class C {\n\tfunction a(): Void {}\n\tfunction foo(x: Int): Int {\n\t\treturn x + 1;\n\t}\n}';

	/** `--select FnMember:foo` spans the whole multi-line function (lines 3-5). */
	public function testSelectByNameSpansFunction(): Void {
		assertBounds(SRC, 'FnMember:foo', 3, 5);
	}

	/** A single-line function resolves to one line. */
	public function testSelectSingleLineFunction(): Void {
		assertBounds(SRC, 'FnMember:a', 2, 2);
	}

	/**
	 * The window is the MODIFIER-FOLDED span — the one `replace-node` overwrites and the one
	 * `patch` searches, whose own doc already claimed "the same modifier-folded slice `apq
	 * source --select` prints". It did not: the read printed the bare node span, so a
	 * declaration whose annotation sat on its OWN line came back WITHOUT it, and feeding that
	 * text straight back to `replace-node` dropped the `@:keep` at rc 0. A one-line prefix hid
	 * the disagreement, because the window is widened to whole lines anyway.
	 */
	public function testSelectSpansALeadingAnnotationOnItsOwnLine(): Void {
		assertBounds('class C {\n\t@:keep\n\tpublic function f(): Void {}\n}', 'FnMember:f', 2, 3);
	}

	/**
	 * The same for the conditional DECL-KEYWORD prefix S41 taught `declGroupSpan` about: a
	 * replacement copied out of this read used to drop the `enum` of `enum abstract`, which is
	 * a compile-breaking silent edit rather than a lost annotation.
	 */
	public function testSelectSpansAConditionalDeclKeywordPrefix(): Void {
		assertBounds('#if (haxe_ver >= 4.2)\nenum\n#end\nabstract E(Int) {\n\tfinal A = 1;\n}', 'AbstractDecl:E', 1, 6);
	}

	/**
	 * CONTROL, green at base BY CONSTRUCTION: an ANNOTATION addressed on its OWN still prints
	 * alone. `declGroupSpan` stops at one (S36), so the read follows the ops there too — and
	 * a fold that walked forward off it would flip exactly this.
	 */
	public function testSelectOnTheAnnotationItselfStillSpansOnlyIt(): Void {
		assertBounds('class C {\n\t@:keep\n\tpublic function f(): Void {}\n}', 'Meta:@:keep', 2, 2);
	}

	/**
	 * RED at base — the window started at the `public` line — and a CONTROL in the other direction: the
	 * fold stops at the top of the modifier / annotation run and does NOT swallow the DOC block above it.
	 * The doc is trivia outside the node, `replace-node` does not overwrite it, and a read that printed
	 * it would hand back a replacement that duplicates the doc on the way in. Widening the window with
	 * `docExtendedSpan` — the obvious "print the whole element" over-fix — flips exactly this.
	 */
	public function testSelectStopsBelowTheDocBlock(): Void {
		assertBounds('class C {\n\t/**\n\t * About f.\n\t */\n\t@:keep\n\tpublic function f(): Void {}\n}', 'FnMember:f', 5, 6);
	}

	/** No match → null (the CLI maps this to a non-zero exit). */
	public function testSelectNoMatchReturnsNull(): Void {
		Assert.isNull(Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', 'FnMember:nope', null));
	}

	/** An ambiguous selector (two functions) → null. */
	public function testSelectAmbiguousReturnsNull(): Void {
		Assert.isNull(Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', 'FnMember', null));
	}

	/** `--at` resolves the innermost node at the 1-based position. */
	public function testAtPositionResolvesNode(): Void {
		// 2:11 is the `a` name token on line 2.
		final b: Null<{ from: Int, to: Int }> = Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', null, '2:11');
		Assert.notNull(b);
		if (b != null) Assert.equals(2, b.from);
	}

	/** A malformed position → null. */
	public function testAtMalformedReturnsNull(): Void {
		Assert.isNull(Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', null, 'nope'));
	}

	/** A malformed selector → null (caught, not an uncaught throw). */
	public function testSelectMalformedReturnsNull(): Void {
		Assert.isNull(Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', 'A>', null));
	}

	/**
	 * Assert the resolved window for `selector` over `src` is exactly lines `from`..`to`.
	 *
	 * The null re-check is not defensive: `resolveNodeLineBounds` answers `Null<…>` for every
	 * refusal path, and Strict will not narrow the local across the assertion.
	 */
	private function assertBounds(src: String, selector: String, from: Int, to: Int): Void {
		final bounds: Null<{ from: Int, to: Int }> = Cli.resolveNodeLineBounds('t.hx', src, 'haxe', selector, null);
		Assert.notNull(bounds);
		if (bounds == null) return;
		Assert.equals(from, bounds.from);
		Assert.equals(to, bounds.to);
	}

}
