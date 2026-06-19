package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.UnnecessaryBlock;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `unnecessary-block` check: a bare `{ … }` statement block, declaring no
 * local, nested in another block is flagged `Info` and unwrapped by `--fix`. A
 * control-flow body, and a block that declares a local (a real scope), are left
 * alone.
 */
class UnnecessaryBlockCheckTest extends Test {

	public function testBareBlockFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('{\n\t\t\ttrace(1);\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('unnecessary-block', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** The block is an `if` body — its parent is the `if`, not a block container. */
	public function testIfBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (c) {\n\t\t\ttrace(1);\n\t\t}')).length);
	}

	/** A block that declares a local is a real scope and is left alone. */
	public function testBlockWithLocalNotFlagged(): Void {
		Assert.equals(0, violations(wrap('{\n\t\t\tvar x = 1;\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testFixUnwraps(): Void {
		final fixed: String = fixedSource(wrap('{\n\t\t\ttrace(1);\n\t\t}'));
		Assert.isTrue(fixed.indexOf('trace(1);') >= 0);
		Assert.equals(-1, fixed.indexOf('{\n\t\t\t'));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unnecessary-block'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unnecessary-block'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + body + '\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new UnnecessaryBlock().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function fixedSource(src: String): String {
		final check: UnnecessaryBlock = new UnnecessaryBlock();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		final sorted: Array<{ span: Span, text: String }> = edits.copy();
		sorted.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in sorted) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	/** A block declaring a local function is a real scope (unwrapping would hoist it) — left alone. */
	public function testBlockWithLocalFunctionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('{\n\t\t\tfunction h():Void {}\n\t\t\th();\n\t\t}')).length);
	}

}
