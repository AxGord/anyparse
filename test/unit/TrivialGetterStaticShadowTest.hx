package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.TrivialGetter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * Trivial-getter `--fix`, static-method shadow case: collapsing `x(get, null)` +
 * `get_x` + `_x` and rewriting a backing-field write `_x = param` inside a STATIC
 * method that binds a parameter named `x` must qualify the write with the enclosing
 * CLASS name (`C.x = x`), never `this.x` — `this` is illegal in a static function.
 * Instance methods keep `this.x` (covered elsewhere).
 */
class TrivialGetterStaticShadowTest extends Test {

	public function testStaticShadowedParamUsesClassName(): Void {
		final src: String = 'class C {\n\tpublic static var level(get, null):Int;\n\tstatic var _level:Int = 0;\n\tstatic function get_level():Int return _level;\n\tpublic static function configure(level:Int):Void { _level = level; }\n}';
		assertFixContains(src, 'C.level = level', 'this.level');
	}

	private function assertFixContains(src: String, present: String, absent: String): Void {
		final check: TrivialGetter = new TrivialGetter();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

}
