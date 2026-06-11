package unit;

import utest.Test;
import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Regression guard for `lineends/issue_344_conditional_with_line_comment`
 * — `// js` line comment on same line as `#end` round-trips unchanged
 * (slice ω-fold-trailing-stop-at-text).
 *
 * Without the fix, `_foldTrailingIntoBodyGroup` walks past the trail
 * literal `#end` (a `Text("#end")` node at the end of the Conditional
 * decl's Concat) and splices the trailing comment INTO the inner body's
 * BodyGroup, producing `} // js\n#end` instead of `#end // js`.
 */
class ProbeIssue344 extends Test {

	private static final _forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	public function testIssue344(): Void {
		final src: String = '#if js\n'
			+ 'class JS {\n\tvar foo:Int;\n}\n' + '#else\n' + 'class NotJS {\n\tvar foo:Int;\n}\n' + '#end // js\n';
		final m: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(src);
		final opt: HxModuleWriteOptions = Reflect.copy(HaxeFormat.instance.defaultWriteOptions);
		final out: String = HaxeModuleTriviaWriter.write(m, opt);
		Assert.equals(src, out);
	}

}
