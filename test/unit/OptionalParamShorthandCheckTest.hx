package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.OptionalParamShorthand;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `optional-param-shorthand` check: a parameter written `name:Null<T> = null` is
 * flagged `Info` and rewritten to the `?name:T` shorthand — one `Null<>` layer
 * unwrapped, the ` = null` dropped, and a `?` prepended. A non-null default, a plain
 * `T = null`, an already-`?` parameter, and a `Null<T>` with no default are safe
 * misses. Covers class methods, constructors, and local functions; generic, nested
 * `Null<Null<T>>` (one layer only), and function-type inner types unwrap correctly.
 * Note: parameter metadata is not representable — the grammar does not parse `@:m` on a
 * parameter — so there is no metadata-preservation case to assert here.
 */
class OptionalParamShorthandCheckTest extends Test {

	public function testFlagged(): Void {
		final source: String = fn('a:Null<String> = null');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('optional-param-shorthand', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('prefer ?a:String over a:Null<String> = null', vs[0].message);
		Assert.equals('a:Null<String> = null', source.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testBasicFix(): Void {
		Assert.equals(fn('?a:String'), applyFix(fn('a:Null<String> = null')));
	}

	public function testNonNullDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('a:Null<Int> = 3')).length);
	}

	public function testPlainTypeNullDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('a:String = null')).length);
	}

	public function testAlreadyOptionalNotFlagged(): Void {
		Assert.equals(0, violations(fn('?a:String')).length);
		// `?name:Null<T> = null` is a distinct, already-optional shape — left alone in v1.
		Assert.equals(0, violations(fn('?a:Null<String> = null')).length);
	}

	public function testNoDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('a:Null<String>')).length);
	}

	public function testGenericUnwrapFix(): Void {
		Assert.equals(fn('?a:Map<String, Int>'), applyFix(fn('a:Null<Map<String, Int>> = null')));
	}

	public function testNestedNullUnwrapsOneLayer(): Void {
		Assert.equals(fn('?a:Null<Int>'), applyFix(fn('a:Null<Null<Int>> = null')));
	}

	public function testFunctionTypeUnwrapFix(): Void {
		Assert.equals(fn('?cb:Int->Void'), applyFix(fn('cb:Null<Int->Void> = null')));
	}

	public function testMultipleParamsOneFixedCommasIntact(): Void {
		final source: String = fn('a:Null<String> = null, ?b:Int, c:Int = 5');
		Assert.equals(1, violations(source).length);
		Assert.equals(fn('?a:String, ?b:Int, c:Int = 5'), applyFix(source));
	}

	public function testConstructorParam(): Void {
		final source: String = 'class C {\n\tpublic function new(a:Null<String> = null) {}\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(applyFix(source).indexOf('new(?a:String)') != -1);
	}

	public function testLocalFunctionParam(): Void {
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tfunction g(a:Null<Int> = null):Void {}\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(applyFix(source).indexOf('g(?a:Int)') != -1);
	}

	public function testApplyFixByteExact(): Void {
		Assert.equals('class C {\n\tfunction f(?a:String):Void {}\n}', applyFix(fn('a:Null<String> = null')));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('optional-param-shorthand'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('optional-param-shorthand'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(').length);
	}

	private function fn(params: String): String {
		return 'class C {\n\tfunction f(' + params + '):Void {}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new OptionalParamShorthand().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		final check: OptionalParamShorthand = new OptionalParamShorthand();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
