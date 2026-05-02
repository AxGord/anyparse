package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-trailopt-source-track — preserve source presence of `@:trailOpt(';')`
 * in trivia mode. The synth pair grows a positional `trailPresent:Bool`
 * arg on bearing Alt ctors; the parser captures `matchLit`'s result; the
 * writer emits the trail literal only when the source had it.
 *
 * Plain mode is unaffected — those parsers / writers retain the original
 * arity and fall back to `@:fmt(trailOptShapeGate(...))` AST-shape gating
 * (covered by `HxVarTrailOptShapeSliceTest`).
 *
 * Targets corpus fixtures `issue_59_compress_parens_without_semicolon`
 * (statement-level `var` / `final` with no trailing `;`) and the first
 * byte-diff of `issue_586_type_hints` (top-level `typedef` with no `;`).
 */
@:nullSafety(Strict)
final class HxTrailOptSourceTrackSliceTest extends Test {

	public function new():Void {
		super();
	}

	// ---- VarStmt (statement-level) ----

	public function testVarObjectLitNoSemiPreserved():Void {
		// issue_59 motivator. Pre-slice: shape gate KEEPs `;` for ObjectLit
		// rhs. Post-slice: source had no `;`, output preserves absence.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = {i: 0}\n\t}\n}';
		final out:String = format(src);
		Assert.equals(-1, out.indexOf('};'), 'unexpected stray `;` after `}` in: <$out>');
	}

	public function testVarObjectLitWithSemiPreserved():Void {
		// Source has `;`, output keeps `;`. Symmetric counterpart.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = {i: 0};\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('var x = {i: 0};') != -1,
			'expected `;` retained when source had it, got: <$out>');
	}

	public function testFinalIntNoSemiPreserved():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tfinal x = 5\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('final x = 5\n') != -1 || out.indexOf('final x = 5\n\t}') != -1,
			'expected `final x = 5` without `;`, got: <$out>');
	}

	public function testVarSwitchRhsNoSemiPreserved():Void {
		// Source omits `;` after switch close; shape gate already drops
		// it. Source-tracking agrees.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = switch (true) { case _: 1; }\n\t}\n}';
		final out:String = format(src);
		Assert.equals(-1, out.indexOf('};'), 'unexpected stray `;` after `}` in: <$out>');
	}

	public function testVarSwitchRhsWithSemiPreserved():Void {
		// Source has explicit `;` after switch close; with source-tracking
		// the writer preserves it (was previously dropped by the shape
		// gate). Verifies the trivia path now defers to source presence
		// over the AST-shape gate.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x = switch (true) { case _: 1; };\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('};') != -1,
			'expected `;` retained when source had it, got: <$out>');
	}

	// ---- TypedefDecl (top-level) ----

	public function testTypedefAnonNoSemiPreserved():Void {
		// First byte-diff of issue_586. Source: `typedef Type = {f:Int}`;
		// expected: same. Pre-slice: writer always emits `;`.
		final src:String = 'typedef T = {f:Int}';
		final out:String = format(src);
		Assert.equals(-1, out.indexOf('};'), 'unexpected `;` after typedef close brace in: <$out>');
	}

	public function testTypedefAnonWithSemiPreserved():Void {
		final src:String = 'typedef T = {f:Int};';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('};') != -1,
			'expected `;` retained when source had it, got: <$out>');
	}

	public function testTypedefIntNoSemiPreserved():Void {
		final src:String = 'typedef Foo = Int';
		final out:String = format(src);
		Assert.equals(-1, out.indexOf('Int;'), 'unexpected `;` in: <$out>');
	}

	public function testTypedefIntWithSemiPreserved():Void {
		final src:String = 'typedef Foo = Int;';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('Int;') != -1, 'expected `;` retained, got: <$out>');
	}

	// ---- VarDecl (top-level `var`) ----

	public function testTopLevelVarWithSemiPreserved():Void {
		final src:String = 'var x:Int = 5;';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('var x:Int = 5;') != -1,
			'expected `;` retained, got: <$out>');
	}

	private inline function format(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
