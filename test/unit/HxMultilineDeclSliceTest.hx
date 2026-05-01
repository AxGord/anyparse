package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-after-multiline — predicate-gated blank-line rules around top-level
 * type / function decls. Drives haxe-formatter's `emptyLines.betweenTypes`
 * vs `emptyLines.betweenSingleLineTypes` discrimination via two new
 * runtime fields:
 *  - `opt.afterMultilineDecl:Int` — exact blank-line count emitted after
 *    a multi-line type/fn decl.
 *  - `opt.beforeMultilineDecl:Int` — exact blank-line count emitted
 *    before a multi-line type/fn decl whose previous element wasn't
 *    multi-line.
 *
 * Per-Star wiring is two `@:fmt(blankLines{After,Before}CtorIf(...,
 * 'multiline', …))` entries on `HxModule.decls`; the `multiline`
 * predicate is grammar-derived at compile time by
 * `WriterLowering.buildMultilinePredicate` from
 * `@:fmt(multilineWhenFieldNonEmpty(...))` /
 * `@:fmt(multilineWhenFieldShape(...))` /
 * `@:fmt(multilineCtor)` typedef- and ctor-level annotations on the
 * relevant grammar types. Zero runtime reflection — the macro emits
 * direct `Array.length > 0` / enum-`switch` checks.
 *
 * Override semantics, not floor — like the existing `afterPackage` /
 * `beforeUsing` knobs the source-captured blank-line count is replaced
 * with the option value when the gate fires.
 */
@:nullSafety(Strict)
class HxMultilineDeclSliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultsMatchUpstream():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(1, defaults.afterMultilineDecl);
		Assert.equals(1, defaults.beforeMultilineDecl);
	}

	public function testBlankAfterMultilineClass():Void {
		final out:String = write('class Foo {\n\tvar x:Int;\n}\nfunction bar() {}');
		Assert.equals('class Foo {\n\tvar x:Int;\n}\n\nfunction bar() {}\n', out);
	}

	public function testBlankBeforeMultilineFn():Void {
		final out:String = write('function a() {}\nfunction b() {\n\ttrace(1);\n}');
		Assert.equals('function a() {}\n\nfunction b() {\n\ttrace(1);\n}\n', out);
	}

	public function testEmptyClassesStayFlat():Void {
		final out:String = write('class A {}\nclass B {}\nclass C {}');
		Assert.equals('class A {}\nclass B {}\nclass C {}\n', out, 'empty-body classes are single-line — predicate gate kept inert');
	}

	public function testEmptyFnsStayFlat():Void {
		final out:String = write('function a() {}\nfunction b() {}\nfunction c() {}');
		Assert.equals('function a() {}\nfunction b() {}\nfunction c() {}\n', out);
	}

	public function testMultiToMultiSingleBlank():Void {
		final out:String = write('class A {\n\tvar x:Int;\n}\nclass B {\n\tvar y:Int;\n}');
		Assert.equals('class A {\n\tvar x:Int;\n}\n\nclass B {\n\tvar y:Int;\n}\n', out, 'multi→multi takes afterMultilineDecl, before* does not double up');
	}

	public function testZeroStripsBlankAfterMultiline():Void {
		final out:String = writeWithCounts('class Foo {\n\tvar x:Int;\n}\n\nfunction bar() {}', 0, 1);
		Assert.equals('class Foo {\n\tvar x:Int;\n}\nfunction bar() {}\n', out);
	}

	public function testZeroStripsBlankBeforeMultiline():Void {
		final out:String = writeWithCounts('function a() {}\n\nfunction b() {\n\ttrace(1);\n}', 1, 0);
		Assert.equals('function a() {}\nfunction b() {\n\ttrace(1);\n}\n', out);
	}

	public function testTwoEmitsTwoBlanksAfterMultiline():Void {
		final out:String = writeWithCounts('class Foo {\n\tvar x:Int;\n}\nfunction bar() {}', 2, 1);
		Assert.equals('class Foo {\n\tvar x:Int;\n}\n\n\nfunction bar() {}\n', out);
	}

	public function testEnumWithCtorsTreatedMultiline():Void {
		final out:String = write('enum E {\n\tA;\n\tB;\n}\nclass C {}');
		Assert.equals('enum E {\n\tA;\n\tB;\n}\n\nclass C {}\n', out);
	}

	public function testEmptyEnumStaysFlat():Void {
		final out:String = write('enum E {}\nclass C {}');
		Assert.equals('enum E {}\nclass C {}\n', out);
	}

	public function testFnExprBodyTreatedSingleLine():Void {
		// Force functionBody=Same so ExprBody renders flat; the predicate
		// classifies ExprBody as kind=0 regardless, so the gap stays
		// source-driven (no blank inserted).
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.functionBody = anyparse.format.BodyPolicy.Same;
		final src:String = 'function a() trace(1);\nfunction b() trace(2);';
		final out:String = HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
		Assert.equals('function a() trace(1);\nfunction b() trace(2);\n', out, 'ExprBody is kind=0 (single-line)');
	}

	public function testFnNoBodyTreatedSingleLine():Void {
		final out:String = write('function a() {}\nfunction b() {}');
		Assert.equals('function a() {}\nfunction b() {}\n', out);
	}

	public function testInteractionWithAfterPackage():Void {
		final out:String = write('package;\nclass Foo {\n\tvar x:Int;\n}\nfunction bar() {}');
		Assert.equals('package;\n\nclass Foo {\n\tvar x:Int;\n}\n\nfunction bar() {}\n', out);
	}

	private inline function write(src:String):String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson('{}'));
	}

	private inline function writeWithCounts(src:String, after:Int, before:Int):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.afterMultilineDecl = after;
		opts.beforeMultilineDecl = before;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
