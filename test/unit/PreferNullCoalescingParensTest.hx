package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferNullCoalescing;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * `??` binds tighter than assignment, so a fallback that IS an assignment has to be
 * parenthesized in the rewrite.
 *
 * `_webp != null ? _webp : _webp = f()` became `_webp ?? _webp = f()`, which parses as
 * `(_webp ?? _webp) = f()` — `Invalid assign`, produced from input that compiled. The
 * ternary was already parenthesized for the one other operand that binds looser; the
 * assignment family was missed.
 *
 * The discriminator is the child count, not a new seam: `writeParentKinds` also holds the
 * increments, and those are prefix or postfix (one child) and bind TIGHTER than `??`.
 */
class PreferNullCoalescingParensTest extends Test {

	public function testAnAssignmentFallbackIsParenthesized(): Void {
		Assert.stringContains('_webp ?? (_webp = g())', fixed('return _webp != null ? _webp : _webp = g();'));
	}

	public function testATernaryFallbackIsStillParenthesized(): Void {
		Assert.stringContains('a ?? (c ? x : y)', fixed('return a != null ? a : c ? x : y;'));
	}

	public function testAPlainFallbackTakesNoParens(): Void {
		Assert.stringContains('a ?? b', fixed('return a != null ? a : b;'));
	}

	public function testAPostfixIncrementFallbackTakesNoParens(): Void {
		// One child, and postfix binds tighter than `??` — parenthesising it would be noise.
		Assert.stringContains('a ?? i++', fixed('return a != null ? a : i++;'));
	}

	/** `body` inside a method, run through the check's own fix, returned as the rewritten source. */
	private function fixed(body: String): String {
		final source: String = 'class C {\n\tstatic function f(): Dynamic {\n\t\t$body\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferNullCoalescing = new PreferNullCoalescing();
		final violations: Array<Violation> = check.run([{ file: 'C.hx', source: source }], plugin);
		Assert.equals(1, violations.length, body);
		final edits: Array<{ span: Span, text: String }> = check.fix(source, violations, plugin);
		Assert.equals(1, edits.length, body);
		return edits.length == 1 ? edits[0].text : '';
	}

}
