package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * Slice ω-typedef-trailOpt — `@:trailOpt(';')` on `HxDecl.TypedefDecl`.
 *
 * Real Haxe accepts both `typedef Foo = Int;` and `typedef Foo = Int`
 * (and `typedef T = { x:Int }` is the dominant convention for anon
 * typedefs). The `;` is now optional on parse — the Lit strategy's new
 * `:trailOpt` meta annotates `lit.trailText` plus `lit.trailOptional`,
 * and Lowering's Case 3 emits `matchLit` instead of `expectLit` when
 * the optional flag is set.
 *
 * Writer behavior is unchanged in this slice — `;` is always emitted as
 * canonical output. Source-fidelity (preserving `;`-presence on input)
 * is a separate slice.
 */
@:nullSafety(Strict)
final class HxTypedefSemiSliceTest extends Test {

	public function new():Void {
		super();
	}

	// ---- Parser accepts typedefs without trailing `;` ----

	public function testTypedefIntNoSemiParses():Void {
		assertParses('typedef Foo = Int');
	}

	public function testTypedefAnonNoSemiParses():Void {
		assertParses('typedef Foo = { x:Int }');
	}

	public function testTypedefArrowNoSemiParses():Void {
		assertParses('typedef Cb = Int->Void');
	}

	public function testTwoTypedefsNoSemi():Void {
		assertParses('typedef A = Int\ntypedef B = String');
	}

	public function testTypedefAnonFollowedByClass():Void {
		assertParses('typedef Bar = { x:Int }\nclass C {}');
	}

	// ---- Regression — `;` form still parses ----

	public function testTypedefIntWithSemiStillParses():Void {
		assertParses('typedef Foo = Int;');
	}

	public function testTypedefAnonWithSemiStillParses():Void {
		assertParses('typedef Foo = { x:Int };');
	}

	public function testMixedSemiAndNoSemiParse():Void {
		assertParses('typedef A = Int;\ntypedef B = String\ntypedef C = Float;');
	}

	// ---- Writer canonicalises `;` (current behavior; preserve-presence is a future slice) ----

	public function testWriterEmitsSemiAfterNoSemiInput():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('typedef Foo = Int'));
		Assert.isTrue(out.indexOf('typedef Foo = Int;') != -1, 'expected canonical `;` in: <$out>');
	}

	public function testWriterEmitsSemiAfterAnonNoSemiInput():Void {
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse('typedef Bar = { x:Int }'));
		Assert.isTrue(out.indexOf('typedef Bar = {x:Int};') != -1, 'expected canonical `;` in: <$out>');
	}

	// ---- Helpers ----

	private inline function assertParses(src:String):Void {
		try {
			final ast:HxModule = HaxeModuleParser.parse(src);
			Assert.notNull(ast);
		} catch (exception:Exception) {
			Assert.fail('parse failed for <$src>: ${exception.message}');
		}
	}
}
