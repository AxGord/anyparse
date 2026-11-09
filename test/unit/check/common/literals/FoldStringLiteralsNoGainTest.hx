package unit.check.common.literals;

import anyparse.query.CanonicalEdit;
import anyparse.query.FormatConfigDiscovery;

/**
 * A split of `fold-adjacent-string-literals` is worth making only when the writer lays the
 * pieces on SEPARATE lines: a `'a' + 'b'` the writer keeps on one line adds an operator and
 * gains nothing, and is the very shape the rule's own merge finding would undo.
 */
class FoldStringLiteralsNoGainTest extends FoldStringLiteralsCheckTestBase {

	/**
	 * The call's second argument is a 141-column line the writer will not wrap; cutting its literal
	 * only makes the writer wrap the CALL, and both pieces stay on one line of the result.
	 */
	@:pin('control')
	@:killer('M-FOLD-SPLIT-ONE-LINE-ACCEPTED')
	public function testSplitWhosePiecesStayOnOneLineIsRefused(): Void {
		final src: String = unbreakableSource();
		Assert.equals(0, violations(src).length);
		Assert.equals('', foldOf(src));
	}

	/** A literal past the width whose pieces the writer DOES put on separate lines still splits. */
	@:pin('control')
	@:killer('M-FOLD-SPLIT-ALWAYS-REFUSED')
	public function testSplitThatLandsOnSeparateLinesIsKept(): Void {
		final src: String = splittableSource();
		Assert.equals(1, violations(src).length);
		final fixed: String = fixedText(src);
		Assert.isTrue(fixed.indexOf("\n\t\t\t+ '") != -1, fixed);
	}

	/** The fix of either fixture is a fixed point: applied again it changes nothing and reports nothing. */
	@:pin('guard')
	public function testFixTwiceIsFixOnce(): Void {
		for (src in [unbreakableSource(), splittableSource()]) {
			final once: String = fixedText(src);
			Assert.equals(once, fixedText(once));
			Assert.equals(0, violations(once).length);
		}
	}

	/** A boundary the source already had stays on one line when its pieces cannot merge (a trigraph cut), and that is no refusal. */
	@:pin('control')
	@:killer('M-FOLD-SPLIT-KEPT-BOUNDARY-ASKED')
	public function testABoundaryTheSourceHadIsNotRefused(): Void {
		Assert.equals("'a?' + '?=b'", foldOf(wrap("'a?' + '?=' + 'b'")));
	}

	/** A call argument holding a long literal at three tabs, as a test's `Assert.equals(…)` writes it. */
	private function unbreakableSource(): String {
		final literal: String = "'final x = new Gadget(); final y = new otherlib.Thing(); new V().toTarget(\"_l\", d._m);'";
		return 'class C {\n\tfunction f() {\n\t\tAssert.equals(\n\t\t\t0,\n\t\t\timportAsTakes(\'import somelib.Gadget;\', $literal),\n'
			+ '\t\t\t\'a type\'\n\t\t);\n\t}\n}';
	}

	/** An over-long literal with a `${ … }` seam, alone in a call. */
	private function splittableSource(): String {
		return 'class C {\n\tfunction f() {\n\t\tg(\'${''.rpad('h', 100)}$${a.b()}${''.rpad('t', 60)}\');\n\t}\n}';
	}

	private function fixedText(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = CheckFixture.edits(new FoldStringLiterals(), src, plugin);
		switch CanonicalEdit.canonicalize(src, edits, true, plugin, FormatConfigDiscovery.discover('C.hx')) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
				return '';
		}
	}

}
