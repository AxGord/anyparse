package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.PreferExists;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `prefer-exists` check: a manual any-match `for` loop — bare
 * `for (x in xs) if (cond) return true; return false;` and the GUARDED
 * `if (g) for (x in xs) if (cond) return true; return false;` — is flagged `Info`,
 * suggesting `xs.exists(x -> cond)` / `g && xs.exists(x -> cond)`. A non-literal
 * fallback, a matching (rather than opposite) trailing literal, an `else` on either
 * `if`, a key-value / range / call iterable, a non-adjacent trailing return and the
 * opposite (`foreach`) direction are all safe misses.
 */
class PreferExistsCheckTest extends Test {

	public function testBareFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return true;\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-exists', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('xs.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testGuardedFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('if (n != null) for (x in n) if (x > 2) return true;\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('n != null && n.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testBracedThenBranchFlagged(): Void {
		Assert.equals(1, violations(fn('for (x in xs) if (x > 2) { return true; }\n\t\treturn false;')).length);
	}

	public function testBracedLoopBodyFlagged(): Void {
		Assert.equals(1, violations(fn('for (x in xs) { if (x > 2) return true; }\n\t\treturn false;')).length);
	}

	public function testBracedGuardBodyFlagged(): Void {
		Assert.equals(1, violations(fn('if (a) { for (x in xs) if (x > 2) return true; }\n\t\treturn false;')).length);
	}

	public function testSameLiteralTrailingReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\treturn true;')).length);
	}

	public function testNonLiteralFallbackNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\treturn xs.length == 0;')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true; else return false;\n\t\treturn false;')).length);
	}

	public function testGuardWithElseNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('if (a) for (x in xs) if (x > 2) return true; else return false;\n\t\treturn false;')).length
		);
	}

	public function testKeyValueLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (k => v in m) if (v > 2) return true;\n\t\treturn false;')).length);
	}

	public function testCallIterableNotFlagged(): Void {
		// A call iterable may yield an Iterator, not an Iterable — `Lambda.exists` would not compile.
		Assert.equals(0, violations(fn('for (k in m.keys()) if (m[k] > 2) return true;\n\t\treturn false;')).length);
	}

	public function testRangeLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (i in 0...xs.length) if (xs[i] > 2) return true;\n\t\treturn false;')).length);
	}

	public function testNonAdjacentTrailingReturnNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\tfinal q = xs.length;\n\t\treturn false;')).length
		);
	}

	public function testForeachDirectionNotClaimed(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn true;')).length);
	}

	public function testExtraLoopBodyStatementNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) { trace(x); if (x > 2) return true; }\n\t\treturn false;')).length);
	}

	public function testFixBareRewritesAndInsertsUsing(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return true;\n\t\treturn false;', false));
		Assert.isTrue(out.indexOf('return xs.exists(x -> x > 2);') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
	}

	public function testFixGuardedKeepsGuard(): Void {
		final out: String = fixResult(file('if (n != null) for (x in n) if (x > 2) return true;\n\t\treturn false;', true));
		Assert.isTrue(out.indexOf('return n != null && n.exists(x -> x > 2);') != -1, out);
	}

	public function testFixParenthesizesLooseGuard(): Void {
		final out: String = fixResult(file('if (a || b) for (x in xs) if (x > 2) return true;\n\t\treturn false;', true));
		Assert.isTrue(out.indexOf('return (a || b) && xs.exists(x -> x > 2);') != -1, out);
	}

	public function testFixKeepsSingleUsing(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return true;\n\t\treturn false;', true));
		final first: Int = out.indexOf('using Lambda;');
		Assert.isTrue(first != -1, out);
		Assert.equals(-1, out.indexOf('using Lambda;', first + 1));
	}

	public function testCommentInDroppedRegionNotFixed(): Void {
		final src: String = file('for (x in xs) // why\n\t\t\tif (x > 2) return true;\n\t\treturn false;', true);
		Assert.equals(0, new PreferExists().fix(src, violationsOf(src), new HaxeQueryPlugin()).length);
	}

	private function fn(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>, n:Null<Array<Int>>, a:Bool, b:Bool):Bool {\n\t\t${body}\n\t}\n}';
	}

	private function file(body: String, withUsing: Bool): String {
		return 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '') + fn(body);
	}

	private function violations(source: String): Array<Violation> {
		return violationsOf(source);
	}

	private function violationsOf(source: String): Array<Violation> {
		return new PreferExists().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function fixResult(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferExists = new PreferExists();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin, SymbolIndex.build([{ file: 'C.hx', source: src }], plugin));
		switch RefactorSupport.canonicalize(src, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
