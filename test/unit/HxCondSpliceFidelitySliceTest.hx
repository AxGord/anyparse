package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Source-fidelity polish for conditional-compilation splices:
 *
 *  - ω-postfix-op-space: the gap between a splice-tail operand and its
 *    `#if` operator round-trips verbatim (`f()#if …` stays glued,
 *    `f() #if …` keeps its space) via the `opSpaceBefore` synth slot.
 *  - ω-cond-end-call-glue: a call whose callee ends with `#end`
 *    (`#if a X #elseif b Y #end (args)`) keeps the space before the
 *    open paren instead of the tight `callee(` glue.
 */
@:nullSafety(Strict)
final class HxCondSpliceFidelitySliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testGluedSpliceTailStaysGlued(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal w:Int = totalWidth()#if mobile - 120 #end;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testSpacedSpliceTailKeepsSpace(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal w:Int = totalWidth() #if mobile - 120 #end;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testCondEndCalleeKeepsSpaceBeforeCallParen(): Void {
		final src: String = "class C {\n\tfunction f() {\n\t\tvar process = #if sys new sys.io.Process #elseif nodejs js.node.ChildProcess.spawn #end ('curl', []);\n\t}\n}";
		Assert.equals(src, triviaWrite(src));
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
