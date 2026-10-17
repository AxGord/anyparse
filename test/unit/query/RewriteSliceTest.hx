package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.Rewrite;
import utest.Assert;
import utest.Test;

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

	/**
	 * A metavariable in a NAME slot splices bare. `new (A)()` parses — as a call of an
	 * identifier `new` — so the paren guard read the type name after `new` as a hole it could
	 * and had to wrap, and `new $C()` came back as `new(A)()`; the braced spelling gave
	 * `new Zz(A)()`. A name capture is one identifier or a dotted path, and nothing an
	 * operator around it can re-read.
	 */
	@:pin('control')
	@:killer('M-REWRITE-NAME-CAPTURE-HOLE')
	public function testANameSlotCaptureSplicesBare(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a:A = new A();\n\t\trun(new pkg.B(), 1);\n\t}\n}';
		final made: String = okText(Rewrite.rewrite(src, "new $C()", "make(new $C())", true, new HaxeQueryPlugin()));
		Assert.isTrue(made.contains('final a:A = make(new A());'), made);
		Assert.isTrue(made.contains('run(make(new pkg.B()), 1);'), made);
		final braced: String = okText(Rewrite.rewrite(src, "new $C()", "new Zz${C}()", true, new HaxeQueryPlugin()));
		Assert.isTrue(braced.contains('final a:A = new ZzA();'), braced);
		Assert.isFalse(braced.contains('(A)'), braced);
	}

	/**
	 * One `try` pattern now matches a statement and a value, and their spans end differently:
	 * the statement owns its `;`, the value does not. Each expansion is aligned to its own site,
	 * whichever form the template was written for — without it a `;`-terminated template left
	 * `final r = parseOrNull(p, s);;` (Haxe: `Expected }`) and a bare one cost the statement its `;`.
	 */
	@:pin('control')
	@:killer('M-REWRITE-TRAILER-UNALIGNED')
	public function testATemplateIsAlignedToEachSitesTerminator(): Void {
		final src: String = 'class C {\n\tfunction f(p:P, s:String) {\n\t\ttry p.parseFile(s) catch (exception:Exception) null;\n'
			+ '\t\tfinal r = try p.parseFile(s) catch (exception:Exception) null;\n\t\treturn r;\n\t}\n}';
		final expected: String =
			'class C {\n\tfunction f(p:P, s:String) {\n\t\tparseOrNull(p, s);\n\t\tfinal r = parseOrNull(p, s);\n\t\treturn r;\n\t}\n}\n';
		final pattern: String = "try $p.parseFile($s) catch (exception: Exception) null";
		Assert.equals(expected, okText(Rewrite.rewrite(src, pattern, "parseOrNull($p, $s)", true, new HaxeQueryPlugin())));
		Assert.equals(expected, okText(Rewrite.rewrite(src, pattern, "parseOrNull($p, $s);", true, new HaxeQueryPlugin())));
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

	/**
	 * The search kind-equivalence is also the REWRITE relation — `Rewrite` splices
	 * over the MATCHED node's span — so a group may hold only kinds whose span
	 * carries nothing but the family keyword. `FinalModifiedMember` and
	 * `LocalInlineFnStmt` swallow their modifier, and a `function $n(…)` pattern
	 * reaching them would turn `final function` into `function` and an `inline
	 * function` into a plain one: silent, re-parseable, semantics-changing. They are
	 * kept out of `HaxeQueryPlugin.SEARCH_KIND_EQUIVALENCE`; this pins the
	 * consequence rather than the constant, so widening the group fails HERE.
	 */
	public function testModifierBearingFunctionKindsAreNotRewritten(): Void {
		final src: String = 'class C {\n\tfinal function sealed():Void {}\n\tpublic function plain():Void {}\n'
			+ '\tstatic function host():Void {\n\t\tinline function helper():Void {}\n\t\thelper();\n\t}\n}';
		final text: String = okText(
			Rewrite.rewrite(src, "function $n():Void {}", "function $n():Void { trace(1); }", true, new HaxeQueryPlugin())
		);
		Assert.isTrue(text.contains('final function sealed'), 'the `final` modifier must survive — got:\n$text');
		Assert.isTrue(text.contains('inline function helper'), 'the local `inline` modifier must survive — got:\n$text');
		Assert.equals(1, text.split('trace(1)').length - 1, 'only the modifier-free member is rewritten — got:\n$text');
	}

	/**
	 * A starred pattern is REFUSED by `rewrite`. The star does not bind, so the
	 * replacement template has no way to name the children it absorbed, and the
	 * span-replace would delete them: `rewrite 'g(...)' 'g()'` reads as "leave
	 * the arguments alone" and would in fact drop every one of them. `search`
	 * and the `--match` locator keep working - only the text-producing op is
	 * gated, and it names the reason.
	 */
	public function testStarPatternIsRefusedByRewrite(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(1, 2, 3);\n\t}\n}';
		final res: EditResult = Rewrite.rewrite(src, 'g(...)', 'k()', true, new HaxeQueryPlugin());
		Assert.isTrue(isErr(res), 'a `...` pattern must not reach the span-replace');
		switch res {
			case Err(message):
				Assert.isTrue(message.contains('...'), 'the refusal must name the ellipsis - got: $message');
				Assert.isTrue(message.contains('rewrite'), 'the refusal must say which op refused - got: $message');
			case Ok(_):
		}
	}

	/** The gate is on the PATTERN, not on the word: an unstarred pattern is untouched. */
	public function testUnstarredPatternStillRewrites(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(1);\n\t}\n}';
		Assert.isTrue(okText(Rewrite.rewrite(src, "g($x)", "k($x)", true, new HaxeQueryPlugin())).contains('k(1)'));
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

	/**
	 * A value metavariable never captures a TYPE argument. `new $C($b, $a)` over `new Map<String, Int>()`
	 * used to bind the two type arguments as values and write `new Map(Int, String)`, re-parseably; the
	 * construction now has no value argument to bind, so only `new Pair(1, 2)` is rewritten. A template
	 * cannot keep type arguments its pattern did not write, so such a match is refused, and writing them
	 * (`new $C<$T>($a)`) rewrites it.
	 */
	@:pin('control')
	@:killer('M-MATCH-ONE-FLAT-RUN') @:killer('M-MATCH-UNWRITTEN-DROPPED') @:killer('M-REWRITE-UNWRITTEN-IGNORED')
	public function testAValueCaptureNeverTakesATypeArgument(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tvar m = new Map<String, Int>();\n\t\tvar p = new Pair(1, 2);\n\t}\n}';
		final swapped: String = okText(Rewrite.rewrite(src, "new $C($a, $b)", "new $C($b, $a)", true, new HaxeQueryPlugin()));
		Assert.isTrue(swapped.contains('var m = new Map<String, Int>();'), swapped);
		Assert.isTrue(swapped.contains('var p = new Pair(2, 1);'), swapped);
		final boxed: String = 'class C {\n\tfunction f() {\n\t\tvar b = new Box<Int>(1);\n\t}\n}';
		Assert.isTrue(isErr(Rewrite.rewrite(boxed, "new $C($a)", "make($a)", true, new HaxeQueryPlugin())));
		final kept: String = okText(Rewrite.rewrite(boxed, "new $C<$T>($a)", "new $C<$T>($a, 0)", true, new HaxeQueryPlugin()));
		Assert.isTrue(kept.contains('var b = new Box<Int>(1, 0);'), kept);
	}

}
