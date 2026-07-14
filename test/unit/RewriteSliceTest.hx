package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.Rewrite;

using StringTools;

/**
 * Probe for `apq rewrite` — structural search-and-replace, the fusion of
 * `search` and a span-replace. Drives `Rewrite.rewrite` directly on in-memory
 * sources (pure, JS-native) with `reformat = true`. Covers verbatim metavar
 * substitution, the `${x+N}` / `${x-N}` integer shift (the col-bump
 * capability), multi-match one-pass rewriting, and the refusal cases.
 */
class RewriteSliceTest extends Test {

	/** Verbatim metavar substitution, reordering captured args. */
	public function testVerbatimSubstitution(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfoo(a, b);\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "foo($x, $y)", "bar($y, $x)", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('bar(b, a)'));
		Assert.isFalse(text.contains('foo('));
	}

	/** `${c+1}` shifts an integer-literal metavar up (the col-bump). */
	public function testIntShiftUp(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(3, 12);\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "g($l, $c)", "g($l, ${c+1})", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('g(3, 13)'));
	}

	/** `${c-1}` shifts an integer-literal metavar down. */
	public function testIntShiftDown(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(3, 12);\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "g($l, $c)", "g($l, ${c-1})", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('g(3, 11)'));
	}

	/** Every match is rewritten in one pass. */
	public function testRewritesAllMatches(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\th(1);\n\t\th(2);\n\t\th(3);\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "h($x)", "k($x)", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('k(1)'));
		Assert.isTrue(text.contains('k(2)'));
		Assert.isTrue(text.contains('k(3)'));
		Assert.isFalse(text.contains('h('));
	}

	/** No match is an error. */
	public function testNoMatchIsError(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfoo(a);\n\t}\n}';
		Assert.isTrue(isErr(Rewrite.rewrite(src, "nope($x)", 'x', true, new HaxeQueryPlugin())));
	}

	/** An integer shift on a non-integer metavar is refused. */
	public function testNonIntegerShiftIsError(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfoo(a, b);\n\t}\n}';
		Assert.isTrue(isErr(Rewrite.rewrite(src, "foo($x, $y)", "foo(${x+1}, $y)", true, new HaxeQueryPlugin())));
	}

	/** A replacement referencing an unbound metavar is refused. */
	public function testUnknownMetavarIsError(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfoo(a, b);\n\t}\n}';
		Assert.isTrue(isErr(Rewrite.rewrite(src, "foo($x, $y)", "foo($x, $z)", true, new HaxeQueryPlugin())));
	}

	private function okText(res: EditResult): String {
		return switch res {
			case Ok(text): text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
	}

	private function isErr(res: EditResult): Bool {
		return switch res {
			case Ok(_): false;
			case Err(_): true;
		};
	}

}
