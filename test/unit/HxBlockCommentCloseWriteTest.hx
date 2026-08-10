package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * A multi-line block comment whose CONTENT-BEARING close line (`}*\/`,
 * `tail text*\/`) must be round-trip STABLE. `BlockCommentNormalizer.normalize`
 * used to preserve the close line's source ws verbatim while the renderer's
 * hardline added the surrounding nest to every line — the nest re-absorbed
 * into the token on each reparse and the close column drifted one indent
 * level deeper per write, without bound (observed live on three Pony files,
 * `}*\/` six tabs deep and climbing).
 */
class HxBlockCommentCloseWriteTest extends Test {

	/** The drifting shape: opener alone on its line, `}`-led close outdented to column 0. */
	private static final BRACE_CLOSE: String =
		'class C {\n\tfunction f(): Void {\n\t\t/*\n\t\tif (a)\n\t\t{\n\t\t\tb = true;\n}*/\n\t\ttrace("z");\n\t}\n}\n';

	/** Non-`}` content close, outdented to column 0: with no residue beyond the interior frame it settles AT the wrap column (one bake-flip pass allowed), then is a fixed point. */
	private static final TEXT_CLOSE: String =
		'class C {\n\tfunction f(): Void {\n\t\t/*\n\t\ttext one\n\t\t\ttext two\ntail text*/\n\t\ttrace("z");\n\t}\n}\n';

	public function testBraceCloseLandsAtWrapColumnAndIsStable(): Void {
		final once: Null<String> = roundTrip(BRACE_CLOSE);
		Assert.notNull(once);
		final first: String = once;
		// The close re-emits at the wrap column (the statement's two tabs) ...
		Assert.isTrue(first.indexOf('\n\t\t}*/') >= 0);
		// ... and the SECOND round trip is byte-identical: the old code re-absorbed
		// the renderer's nest into the close ws and grew it every write.
		Assert.equals(first, roundTrip(first));
	}

	public function testTextCloseSettlesAndIsStable(): Void {
		final once: Null<String> = roundTrip(TEXT_CLOSE);
		Assert.notNull(once);
		final second: Null<String> = roundTrip(once);
		Assert.notNull(second);
		final settled: String = second;
		// One settling pass is allowed (the bake decision re-derives on the
		// normalized frame); from there the form is a fixed point.
		Assert.equals(settled, roundTrip(settled));
	}

	/**
	 * No interior content line → no frame (`commonPrefix` null): the close used to
	 * keep its ABSOLUTE ws and re-absorb the renderer's nest every write (0→2→4→6
	 * tabs, unbounded). It must land at the wrap column and stay.
	 */
	public function testTwoLineCommentCloseIsStable(): Void {
		final twoLine: String = 'class C {\n\tfunction f(): Void {\n\t\t/*\n\t\tnote*/\n\t\ttrace("z");\n\t}\n}\n';
		final once: Null<String> = roundTrip(twoLine);
		Assert.notNull(once);
		final first: String = once;
		Assert.isTrue(first.indexOf('\n\t\tnote*/') >= 0);
		Assert.equals(first, roundTrip(first));
	}

	/**
	 * The non-`}` branch's RELATIVE formula: a close authored two levels deeper
	 * than the interior frame keeps that residue — only the interior formula can
	 * produce a settled NON-EMPTY close ws, so a `closeLineWs` collapsed to a bare
	 * `return ''` fails here while still passing the wrap-column fixtures.
	 */
	public function testDeepCloseKeepsResidueViaInteriorFormula(): Void {
		final deep: String =
			'class C {\n\tfunction f(): Void {\n\t\t/*\n\t\ttext one\n\t\ttext two\n\t\t\t\tdeep tail*/\n\t\ttrace("z");\n\t}\n}\n';
		final once: Null<String> = roundTrip(deep);
		Assert.notNull(once);
		final first: String = once;
		Assert.isTrue(first.indexOf('\n\t\t\t\tdeep tail*/') >= 0);
		Assert.equals(first, roundTrip(first));
	}

	/**
	 * `firstInlineRebuildDoc`: a `**\/` deco close is excluded from the interior
	 * common prefix, and its mismatched ws used to fall back to the ABSOLUTE source
	 * ws — a period-3 oscillation, so `fmt` diffed a clean tree on every run.
	 */
	public function testFirstInlineDecoCloseDoesNotOscillate(): Void {
		final deco: String = 'class C {\n\tfunction f(): Void {\n\t\t/* head\n\t\t\tbody\n\t\t**/\n\t\ttrace("z");\n\t}\n}\n';
		final once: Null<String> = roundTrip(deco);
		Assert.notNull(once);
		final first: String = once;
		Assert.equals(first, roundTrip(first));
	}

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
