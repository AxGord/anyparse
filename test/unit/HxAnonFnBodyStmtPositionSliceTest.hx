package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-anon-fn-body-stmt-position — statements inside an anonymous
 * `function() { … }` body (and the named `function foo() { … }`
 * expression form) are STATEMENT-position, exactly like an arrow
 * `() -> { … }` block body or a class-method body. A statement `if`
 * there must consult `sameLine.ifBody`, never `sameLine.expressionIf`.
 *
 * Before the fix the `_inExprPosition` frame inherited from the
 * enclosing expression context (call arg / var init) leaked into the
 * anon-fn body — `HxFnBlock.stmts` (shared by method and anon-fn
 * bodies) did not carry `@:fmt(clearExprPositionNonTail)` the way
 * `HxExpr.BlockExpr` does — so `if (c) a();` inside `foo(function() {
 * … })` dispatched through `expressionIf:next` and broke onto two lines
 * while the identical arrow / method form stayed inline.
 *
 * Config mirrors TM's hxformat.json: `ifBody:fitLine`,
 * `expressionIf:next`. Trivia pair (matches `hxq fmt`).
 */
@:nullSafety(Strict)
final class HxAnonFnBodyStmtPositionSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testAnonFnBodyNonTailIfStaysInline(): Void {
		final out: String = writeTm('class M { function f():Void { foo(function():Void { if (c) a(); b(); }); } }');
		Assert.isTrue(out.indexOf('if (c) a();') != -1, 'anon-fn body non-tail if must stay inline (ifBody:fitLine): <$out>');
		Assert.isTrue(out.indexOf('if (c)\n') == -1, 'anon-fn body if must NOT break (expressionIf leak): <$out>');
	}

	public function testAnonFnBodyTailIfStaysInline(): Void {
		final out: String = writeTm('class M { function f():Void { foo(function():Void { b(); if (c) a(); }); } }');
		Assert.isTrue(out.indexOf('if (c) a();') != -1, 'anon-fn body tail if must stay inline: <$out>');
		Assert.isTrue(out.indexOf('if (c)\n') == -1, 'anon-fn body tail if must NOT break: <$out>');
	}

	public function testNamedFnExprBodyIfStaysInline(): Void {
		final out: String = writeTm('class M { function f():Void { foo(function baz():Void { if (c) a(); b(); }); } }');
		Assert.isTrue(out.indexOf('if (c) a();') != -1, 'named-fn-expr body if must stay inline: <$out>');
		Assert.isTrue(out.indexOf('if (c)\n') == -1, 'named-fn-expr body if must NOT break: <$out>');
	}

	public function testArrowBodyIfStaysInlineParity(): Void {
		// Parity anchor: the arrow block body already inlines the if —
		// the anon-fn form must match it.
		final out: String = writeTm('class M { function f():Void { foo(() -> { if (c) a(); b(); }); } }');
		Assert.isTrue(out.indexOf('if (c) a();') != -1, 'arrow body if inline (parity anchor): <$out>');
	}

	public function testMethodBodyIfStaysInline(): Void {
		// Sanity: statement-position method body if already inlines.
		final out: String = writeTm('class M { function f():Void { if (c) a(); b(); } }');
		Assert.isTrue(out.indexOf('if (c) a();') != -1, 'method body if inline (sanity): <$out>');
	}

	public function testReturnSwitchCaseIfStillBreaks(): Void {
		// Exclusivity guard: a genuine expression-position if (inner if in
		// a return-switch case body) must STILL break under
		// expressionIf:next — the fix clears the leaked frame only inside
		// function bodies (HxFnBlock), never a value-yielded case body.
		final out: String = writeTm('class M { function f():Bool { return switch (t) { case A: if (c) a(); }; } }');
		Assert.isTrue(out.indexOf('if (c) a();') == -1, 'value-position case if must still break under expressionIf:next: <$out>');
	}

	private inline function writeTm(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.ifBody = BodyPolicy.FitLine;
		opts.expressionIfBody = BodyPolicy.Next;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

}
