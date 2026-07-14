package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice apq-P5-L2: EReg regex literal `~/pattern/flags`.
 *
 * New `HxExpr.RegexLit(v:HxRegexLit)` ctor backed by an
 * `@:re @:rawString` transparent `abstract HxRegexLit(String)` —
 * exact mirror of `HxDoubleStringLit`. The matched slice is stored
 * verbatim (opener, body, closing slash, flags) so a regex pattern
 * round-trips byte-perfect. `~/` is unambiguous against the
 * `@:prefix('~')` bitwise-not ctor (the literal ctor is declared
 * first; its pattern requires `/` after `~`).
 *
 * Asserts the raw slice value, flags, escaped slash, the real
 * dogfood-corpus patterns, the `~x` bitwise-not regression, and
 * round-trip idempotency.
 */
class HxRegexLitSliceTest extends HxTestHelpers {

	public function testSimpleRegex(): Void {
		Assert.equals('~/foo/', regexOf('class C { var x = ~/foo/; }'));
	}

	public function testEmptyBodyRegex(): Void {
		// `~/^/` — appears verbatim in the dogfood corpus.
		Assert.equals('~/^/', regexOf('class C { var x = ~/^/; }'));
	}

	public function testRegexWithFlags(): Void {
		Assert.equals('~/abc/gi', regexOf('class C { var x = ~/abc/gi; }'));
	}

	public function testEscapedSlash(): Void {
		Assert.equals('~/a\\/b/', regexOf('class C { var x = ~/a\\/b/; }'));
	}

	public function testCorpusNumberPattern(): Void {
		final src: String = 'class C { var x = ~/^-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/; }';
		Assert.equals('~/^-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/', regexOf(src));
	}

	public function testBitNotRegressionUnaffected(): Void {
		// `~y` must still parse as the bitwise-not prefix, not a regex.
		final decl: HxVarDecl = parseSingleVarDecl('class C { var x = ~y; }');
		switch decl.init {
			case BitNot(IdentExpr(v)):
				Assert.equals('y', (v: String));
			case null, _:
				Assert.fail('expected BitNot(IdentExpr(y)), got ${decl.init}');
		}
	}

	public function testRegexRoundTrip(): Void {
		roundTrip('class C { var x = ~/^-?(?:0|[1-9][0-9]*)/; var y = ~/a\\/b/gi; }', 'L2-regex-lit');
	}

	private function regexOf(source: String): String {
		final decl: HxVarDecl = parseSingleVarDecl(source);
		return switch decl.init {
			case RegexLit(v): (v: String);
			case null, _: throw 'expected RegexLit, got ${decl.init}';
		}
	}

}
