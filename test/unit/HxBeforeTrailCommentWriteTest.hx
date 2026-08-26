package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * A block comment in the gap between a mandatory `@:trail` Ref field's last token and its own
 * close literal — `switch (subject /* c *\/)`, `if (cond /* c *\/)` — survives the round trip
 * through the `<field>BeforeTrail` slot.
 *
 * That gap had no capture slot at all, so the comment was consumed as whitespace and the writer
 * re-emitted the construct without it; `writeRoundTrip` then refused the whole file. One slot
 * serves every construct built from that field shape, which is why five of them arrive at once.
 *
 * `HxInlineBlockCommentGapTest` owns the seam inventory (which positions capture and which
 * refuse); this file pins the stronger BYTE contract for the ones that now capture.
 */
class HxBeforeTrailCommentWriteTest extends Test {

	public inline function testSwitchSubject(): Void {
		assertFixedPoint('switch (v /* s */) {\n\t\t\tcase 1:\n\t\t\t\trun();\n\t\t}');
	}

	public inline function testIfCondition(): Void {
		assertFixedPoint('if (c /* i */) {\n\t\t\trun();\n\t\t}');
	}

	public inline function testWhileCondition(): Void {
		assertFixedPoint('while (c /* w */) {\n\t\t\trun();\n\t\t}');
	}

	public inline function testDoWhileCondition(): Void {
		assertFixedPoint('do {\n\t\t\trun();\n\t\t} while (c /* d */);');
	}

	public inline function testCatchParam(): Void {
		assertFixedPoint('try {\n\t\t\trun();\n\t\t} catch (e:Dynamic /* c */) {\n\t\t\trun();\n\t\t}');
	}

	public function testGluedCommentGainsItsSeparatingSpace(): Void {
		// The report's own shape — the comment is glued to the subject with no space. The
		// writer canonicalises to one space, which is a layout change, not a loss; the second
		// round trip is what proves the result is a fixed point rather than an oscillation.
		final once: Null<String> = roundTrip(inBody('switch (m/*.toUpperCase()*/) {\n\t\t\tcase _:\n\t\t}'));
		Assert.equals(inBody('switch (m /*.toUpperCase()*/) {\n\t\t\tcase _:\n\t\t}'), once);
		Assert.equals(once, roundTrip(once ?? ''));
	}

	public function testLineCommentIsNotCaptured(): Void {
		// A line comment cannot live before the close literal — re-emitting one there would
		// comment the literal out. `collectTrailingBlock` never takes it, so the seam behaves
		// exactly as it did: the comment is dropped and the guard refuses the file.
		Assert.raises(() -> roundTrip(inBody('if (c // note\n\t\t) {\n\t\t\trun();\n\t\t}')), anyparse.format.comment.CommentLossException);
	}

	/** The statement is already what the writer produces for it — the byte contract a canonical file has. */
	private function assertFixedPoint(statements: String): Void {
		final source: String = inBody(statements);
		Assert.equals(source, roundTrip(source));
	}

	private function inBody(statements: String): String return 'class Foo {\n\tfunction bar() {\n\t\t$statements\n\t}\n}\n';

	private function roundTrip(source: String): Null<String> return new HaxeQueryPlugin().writeRoundTrip(source);

}
