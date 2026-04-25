package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice ω-pad-split — `@:fmt(padBoundaries)` split into independent
 * `@:fmt(padLeading)` / `@:fmt(padTrailing)` flags so a bare-Star field
 * can opt into a leading-only space without forcing a trailing one.
 *
 * The motivating consumer is `HxAbstractDecl.clauses`, which sits
 * between `(UnderlyingType)` and `{ members }`. Pre-slice the bare-Star
 * writer emitted no leading space, producing `(Bar)from Int` for
 * fixtures `issue_143_abstract_from_anon_struct.hxtest` and
 * `issue_167_abstract_with_multiple_froms.hxtest`. After tagging
 * `clauses` with `@:fmt(padLeading)` the writer prepends a single space
 * before the first `from`/`to` clause when the clause list is non-empty,
 * yielding `(Bar) from Int`. No trailing space — the next field
 * (`members`) carries `@:lead('{')`, a spaced lead whose own separator
 * covers the gap.
 *
 * `HxConditionalMod.body` continues to use BOTH flags together
 * (`@:fmt(padLeading, padTrailing)`) — its surrounding tokens are
 * `#if cond` and `#end`, neither of which carries a separator into the
 * Star.
 */
@:nullSafety(Strict)
final class HxAbstractClauseSpacingTest extends Test {

	public function new():Void {
		super();
	}

	public function testFromClauseHasLeadingSpace():Void {
		final out:String = write('abstract Foo(Bar) from Int {}');
		Assert.isTrue(out.indexOf('(Bar) from Int') != -1, 'expected `(Bar) from Int` in: <$out>');
	}

	public function testToClauseHasLeadingSpace():Void {
		final out:String = write('abstract Foo(Bar) to Int {}');
		Assert.isTrue(out.indexOf('(Bar) to Int') != -1, 'expected `(Bar) to Int` in: <$out>');
	}

	public function testMultipleClausesPreserveSpacing():Void {
		final out:String = write('abstract Foo(Bar) from Int from Float to String to Bool {}');
		Assert.isTrue(
			out.indexOf('(Bar) from Int from Float to String to Bool') != -1,
			'expected `(Bar) from Int from Float to String to Bool` in: <$out>'
		);
	}

	public function testNoClausesDoesNotAddStraySpace():Void {
		final out:String = write('abstract Foo(Bar) {}');
		Assert.isTrue(out.indexOf('(Bar) {') != -1, 'expected `(Bar) {` (single space) in: <$out>');
		Assert.equals(-1, out.indexOf('(Bar)  '), 'unexpected double space after `(Bar)` in: <$out>');
	}

	public function testFromClauseWithAnonTypeArg():Void {
		final out:String = write('abstract Foo(Bar) from {a:String} {}');
		Assert.isTrue(out.indexOf('(Bar) from {a:String}') != -1, 'expected `(Bar) from {a:String}` in: <$out>');
	}

	private inline function write(src:String):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), HaxeFormat.instance.defaultWriteOptions);
	}
}
