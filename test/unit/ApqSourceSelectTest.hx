package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;

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

	private static final SRC: String = 'class C {\n' + '\tfunction a(): Void {}\n' + '\tfunction foo(x: Int): Int {\n'
		+ '\t\treturn x + 1;\n' + '\t}\n' + '}';

	/** `--select FnMember:foo` spans the whole multi-line function (lines 3-5). */
	public function testSelectByNameSpansFunction(): Void {
		final b: Null<{ from: Int, to: Int }> = Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', 'FnMember:foo', null);
		Assert.notNull(b);
		if (b != null) {
			Assert.equals(3, b.from);
			Assert.equals(5, b.to);
		}
	}

	/** A single-line function resolves to one line. */
	public function testSelectSingleLineFunction(): Void {
		final b: Null<{ from: Int, to: Int }> = Cli.resolveNodeLineBounds('t.hx', SRC, 'haxe', 'FnMember:a', null);
		Assert.notNull(b);
		if (b != null) {
			Assert.equals(2, b.from);
			Assert.equals(2, b.to);
		}
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

}
