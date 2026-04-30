package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-case-blank-line-keep — `Trivial<T>` splits the single
 * `blankBefore:Bool` channel into two slots: `blankBefore` for blanks
 * preceding any captured leading comments, and
 * `blankAfterLeadingComments` for blanks between the last leading
 * comment and the node itself. Without the split, source like
 * `\n\n// comment\n\nstmt` collapsed into one bool — writer chose to
 * emit the blank only on the pre-comment side, dropping the post-
 * comment one. Probe target: issue_254 family
 * (`stmt-switch \n\n // But: \n\n var-switch`).
 */
@:nullSafety(Strict)
final class HxBlankAfterLeadingCommentSliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testBlankBeforeAndAfterLeadingComment():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tfoo();\n\n\t\t// note\n\n\t\tbar();\n\t}\n}';
		final out:String = format(src);
		final cut:Int = out.indexOf('// note');
		Assert.notEquals(-1, cut, 'expected leading comment in: <$out>');
		final after:String = out.substr(cut);
		Assert.isTrue(after.indexOf('// note\n\n\t\tbar();') != -1, 'expected blank line between // note and bar() in: <$out>');
		Assert.isTrue(out.indexOf('foo();\n\n\t\t// note') != -1, 'expected blank line between foo() and // note in: <$out>');
	}

	public function testNoBlankAfterCommentWhenAbsent():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tfoo();\n\n\t\t// note\n\t\tbar();\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('// note\n\t\tbar();') != -1, 'expected NO blank between // note and bar() in: <$out>');
	}

	public function testBlankBeforeOnlyWhenNoLeadingComment():Void {
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tfoo();\n\n\t\tbar();\n\t}\n}';
		final out:String = format(src);
		Assert.isTrue(out.indexOf('foo();\n\n\t\tbar();') != -1, 'expected single blank between foo() and bar() in: <$out>');
	}

	private inline function format(src:String):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
