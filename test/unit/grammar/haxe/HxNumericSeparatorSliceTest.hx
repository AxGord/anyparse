package unit.grammar.haxe;

import anyparse.grammar.haxe.HxVarDecl;
import utest.Assert;

/**
 * Slice 47 — Haxe 5 numeric literal extensions: digit-separator `_`
 * between digits, and typed numeric suffixes (`i8`/`i16`/`i32`/`i64`/
 * `u8`/`u16`/`u32`/`u64` on int and hex forms; `f32`/`f64` on float
 * forms).
 *
 * Coverage:
 *  - `12_0`, `1_2_0` — underscore separator in decimal int.
 *  - `0x12_0`, `0x1_2_0` — underscore separator in hex.
 *  - `12_0i32`, `12_0_i32` — int with typed suffix (with or without
 *    underscore before suffix).
 *  - `12.3_4`, `.3_4`, `1_2e3_4`, `12f64`, `1_2.3_4f64` — float
 *    forms (full / leading-dot / exp-no-dot / f-suffix-only).
 *  - Round-trip preserves source bytes, the `_` before a suffix
 *    included — `1_2_0_i32` stays `1_2_0_i32`.
 *
 * Closes `other/numeric_separator.hxtest` (SKIP→PASS, single-fixture
 * Δpass +1 in the sweep).
 */
class HxNumericSeparatorSliceTest extends HxTestHelpers {

	// ======== Writer: a literal is written as its source spelling ========

	public inline function testWriterKeepsIntSuffixUnderscore(): Void {
		writerEquals(
			'class C { var f:Int = 1_2_0_i32; }', 'class C {\n\tvar f:Int = 1_2_0_i32;\n}\n',
			'`1_2_0_i32` keeps the underscore before its suffix'
		);
	}

	public inline function testWriterKeepsFloatSuffixUnderscore(): Void {
		writerEquals(
			'class C { var f:Float = 1_2.3_4_f64; }', 'class C {\n\tvar f:Float = 1_2.3_4_f64;\n}\n',
			'`1_2.3_4_f64` keeps the underscore before its suffix'
		);
	}

	public inline function testWriterKeepsHexSuffixUnderscore(): Void {
		writerEquals(
			'class C { var f:Int = 0xFF_FF_i32; }', 'class C {\n\tvar f:Int = 0xFF_FF_i32;\n}\n',
			'`0xFF_FF_i32` keeps the underscore before its suffix'
		);
	}

	public inline function testWriterPreservesInteriorUnderscores(): Void {
		writerEquals(
			'class C { var f:Int = 1_2_3_4_5_6; }', 'class C {\n\tvar f:Int = 1_2_3_4_5_6;\n}\n', 'interior `_` separators preserved'
		);
	}

	public inline function testWriterPreservesBareSuffix(): Void {
		// `12i32` has no underscore to strip — emit verbatim.
		writerEquals('class C { var f:Int = 12i32; }', 'class C {\n\tvar f:Int = 12i32;\n}\n', 'bare-suffix `12i32` unchanged');
	}

	public function testIntUnderscoreParse(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Int = 1_000_000; }');
		switch decl.init {
			case IntLit(v):
				Assert.equals(1000000, (v: Int));
			case null, _:
				Assert.fail('expected IntLit(1_000_000)');
		}
	}

	public function testIntTypedSuffixParse(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Int = 12_0i32; }');
		switch decl.init {
			case IntLit(v):
				Assert.equals(120, (v: Int));
			case null, _:
				Assert.fail('expected IntLit(12_0i32)');
		}
	}

	public function testHexUnderscoreParse(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Int = 0xDE_AD_BE_EF; }');
		switch decl.init {
			case HexLit(v):
				Assert.equals('0xDE_AD_BE_EF', (v: String));
			case null, _:
				Assert.fail('expected HexLit');
		}
	}

	public function testFloatFullSuffixParse(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Float = 1_2.3_4f64; }');
		switch decl.init {
			case FloatLit(v):
				Assert.floatEquals(12.34, (v: Float));
			case null, _:
				Assert.fail('expected FloatLit(1_2.3_4f64)');
		}
	}

	public function testFloatLeadingDotParse(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Float = .3_4_5; }');
		switch decl.init {
			case FloatLit(v):
				Assert.floatEquals(0.345, (v: Float));
			case null, _:
				Assert.fail('expected FloatLit(.3_4_5)');
		}
	}

	public function testFloatExpNoDotParse(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Float = 1_2e3_4; }');
		switch decl.init {
			case FloatLit(v):
				Assert.floatEquals(12e34, (v: Float));
			case null, _:
				Assert.fail('expected FloatLit(1_2e3_4)');
		}
	}

	public function testFloatFSuffixOnlyParse(): Void {
		// `12f64` — no `.`, no `e`, just digits + f-suffix.
		final decl: HxVarDecl = parseSingleVarDecl('class C { var f:Float = 1_2f64; }');
		switch decl.init {
			case FloatLit(v):
				Assert.floatEquals(12.0, (v: Float));
			case null, _:
				Assert.fail('expected FloatLit(1_2f64)');
		}
	}

}
