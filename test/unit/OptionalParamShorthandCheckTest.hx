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
 * The `optional-param-shorthand` check: a parameter written `name:Null<T> = null` or
 * `name:T = null` is flagged `Info` and rewritten to the `?name:T` shorthand — one
 * `Null<>` layer unwrapped when present (else the type text kept as-is), the ` = null`
 * dropped, and a `?` prepended. An already-`?` parameter with a redundant `= null`
 * default is flagged too — its type stays verbatim (no unwrap) and only the ` = null`
 * goes. A non-null default, an already-`?` parameter without a `null` default, an
 * untyped `a = null` / `?a = null` (no type annotation), and a decorated `Null<T>` the
 * unwrapper rejects (a comment between the type and the `=`) are safe misses. Covers
 * class methods, constructors, and local functions; generic, nested `Null<Null<T>>`
 * (one layer only), and function-type inner types unwrap correctly for both the
 * `Null<T>`-wrapped and bare-type forms. Note: parameter metadata is not representable
 * — the grammar does not parse `@:m` on a parameter — so there is no
 * metadata-preservation case to assert here.
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

	public function testPlainTypeNullDefaultFlagged(): Void {
		final source: String = fn('a:String = null');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('prefer ?a:String over a:String = null', vs[0].message);
		Assert.equals(fn('?a:String'), applyFix(source));
	}

	public function testBareTypeGenericFix(): Void {
		Assert.equals(fn('?a:Map<String, Int>'), applyFix(fn('a:Map<String, Int> = null')));
	}

	public function testBareTypeFunctionTypeFix(): Void {
		Assert.equals(fn('?cb:Int->Void'), applyFix(fn('cb:Int->Void = null')));
	}

	public function testNoTypeAnnotationNotFlagged(): Void {
		Assert.equals(0, violations(fn('a = null')).length);
	}

	public function testDecoratedNullTypeNotFlagged(): Void {
		// A `Null<T>` the unwrapper rejects (a comment between the type and the `=`) must
		// stay a safe miss, not fall through to the bare-type arm without unwrapping.
		Assert.equals(0, violations(fn('a:Null<Int> /* note */ = null')).length);
	}

	public function testMultipleParamsBareTypeFixedCommasIntact(): Void {
		final source: String = fn('a:String = null, ?b:Int, c:Int = 5');
		Assert.equals(1, violations(source).length);
		Assert.equals(fn('?a:String, ?b:Int, c:Int = 5'), applyFix(source));
	}

	public function testAlreadyOptionalNoDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('?a:String')).length);
		Assert.equals(0, violations(fn('?a:Null<String>')).length);
	}

	public function testAlreadyOptionalNonNullDefaultNotFlagged(): Void {
		Assert.equals(0, violations(fn('?a:Int = 5')).length);
	}

	public function testAlreadyOptionalUntypedNotFlagged(): Void {
		Assert.equals(0, violations(fn('?a = null')).length);
	}

	public function testAlreadyOptionalRedundantNullDefaultFlagged(): Void {
		final source: String = fn('?a:Float = null');
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('prefer ?a:Float over ?a:Float = null', vs[0].message);
		Assert.equals(fn('?a:Float'), applyFix(source));
	}

	public function testAlreadyOptionalNullWrappedDropsDefaultKeepsType(): Void {
		// No unwrap on an already-optional parameter — only the redundant default goes.
		final source: String = fn('?a:Null<String> = null');
		Assert.equals(1, violations(source).length);
		Assert.equals(fn('?a:Null<String>'), applyFix(source));
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
		return 'class C {\n\tfunction f($params):Void {}\n}';
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
