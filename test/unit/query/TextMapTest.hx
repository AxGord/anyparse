package unit.query;

import anyparse.query.TextMap;
import utest.Assert;
import utest.Test;

/** `TextMap`: where an offset of a rewritten text stands in the text before the rewrite. */
@:nullSafety(Strict)
class TextMapTest extends Test {

	private static final BEFORE: String = 'a\nfunction f(x) {\n\treturn x;\n}\nz\n';

	@:pin('control') @:killer('M-TEXTMAP-MYERS')
	public function testALineTheRewriteLeftAloneMapsExactly(): Void {
		// two changes, so the line between them is matched by the diff, not by the common head or tail
		final after: String = 'a\n// one\n// two\nfunction f(x) {\n\treturn x;\n}\nzz\n';
		final map: TextMap = TextMap.between(BEFORE, after);
		Assert.equals(BEFORE.indexOf('return'), map.toBefore(after.indexOf('return')));
		Assert.equals(BEFORE.indexOf('}'), map.toBefore(after.indexOf('}')));
		Assert.equals(-1, map.toBefore(after.indexOf('two')));
	}

	@:pin('control') @:killer('M-TEXTMAP-PREFIX')
	public function testAnEditedLineKeepsWhatItsEditLeftAround(): Void {
		final after: String = StringTools.replace(BEFORE, 'f(x) {', 'f(x):Void {');
		final map: TextMap = TextMap.between(BEFORE, after);
		Assert.equals(BEFORE.indexOf('f(x)'), map.toBefore(after.indexOf('f(x)')));
		Assert.equals(BEFORE.indexOf(' {\n\treturn'), map.toBefore(after.indexOf(' {\n\treturn')));
		Assert.equals(-1, map.toBefore(after.indexOf('Void') + 1));
	}

}
