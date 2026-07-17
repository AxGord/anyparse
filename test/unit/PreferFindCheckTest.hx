package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferFind;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `prefer-find` check: a manual first-match `for` loop — Form A
 * `for (x in xs) if (cond) return x; return null;` and Form B
 * `var r = null; for (x in xs) if (cond) { r = x; break; }` — is flagged `Info`,
 * report-only, suggesting `xs.find(x -> cond)`. A non-null Form-A fallback appends
 * `?? <fallback>`; a transformed return, an `else`, a Form-B `continue` (last match,
 * not first), an extra Form-B statement, a key-value loop and a non-adjacent trailing
 * return are all safe misses.
 */
class PreferFindCheckTest extends Test {

	public function testBasicReturnFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-find', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2)') != -1);
	}

	public function testBracedReturnFormFlagged(): Void {
		Assert.equals(1, violations(fn('for (x in xs) if (x > 2) { return x; }\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testNonNullFallbackFlaggedWithCoalesce(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn 0;', 'Int'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2) ?? 0') != -1);
	}

	public function testBreakFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn(
			'var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;', 'Null<Int>'
		));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-find', vs[0].rule);
		Assert.isTrue(vs[0].message.indexOf('xs.find(x -> x > 2)') != -1);
	}

	public function testBreakFormWithContinueNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; continue; }\n\t\treturn r;', 'Null<Int>')).length
		);
	}

	public function testBreakFormExtraStatementNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; trace(x); break; }\n\t\treturn r;', 'Null<Int>')).length
		);
	}

	public function testTransformedReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return x + 1;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return x; else return 0;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testKeyValueLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (k => v in m) if (v > 2) return v;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testCallIterableNotFlagged(): Void {
		// A `.keys()` / any call iterable may yield an Iterator, not an Iterable — Lambda.find
		// would not compile, so a call-expression iterable is skipped.
		Assert.equals(0, violations(fn('for (k in m.keys()) if (m[k] > 2) return k;\n\t\treturn null;', 'Null<Int>')).length);
	}

	public function testRangeIndexLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (i in 0...xs.length) if (xs[i] > 2) return i;\n\t\treturn -1;', 'Int')).length);
	}

	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('for (x in xs) if (x > 2) return x;\n\t\tfinal n = xs.length;\n\t\treturn null;', 'Null<Int>')).length
		);
	}

	public function testMessageContainsConditionExcerpt(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('x > 2') != -1);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-find'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-find'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { for (x in xs) if (x > 2) return').length);
	}

	public function testFixReturnFormRewritesAndInsertsUsing(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>', false));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2);') != -1);
		Assert.isTrue(out.indexOf('using Lambda;') != -1);
		Assert.isTrue(out.indexOf('for (') == -1);
	}

	public function testFixAccessorCallCondRewrites(): Void {
		final out: String = fixResult(file('for (x in xs) if (node.fmtHasFlag(x)) return x;\n\t\treturn null;', 'Null<Int>', true));
		Assert.isTrue(out.indexOf('return xs.find(x -> node.fmtHasFlag(x));') != -1);
	}


	public function testFixNonNullFallbackCoalesces(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn 0;', 'Int', true));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2) ?? 0;') != -1);
	}

	public function testFixBreakFormRewritesAndDeletesLoop(): Void {
		final out: String = fixResult(file(
			'var r:Null<Int> = null;\n\t\tfor (x in xs) if (x > 2) { r = x; break; }\n\t\treturn r;', 'Null<Int>', true
		));
		Assert.isTrue(out.indexOf('var r:Null<Int> = xs.find(x -> x > 2);') != -1);
		Assert.isTrue(out.indexOf('for (') == -1);
		Assert.isTrue(out.indexOf('break') == -1);
	}

	public function testFixAlreadyUsingNoDuplicate(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>', true));
		Assert.isTrue(out.indexOf('using Lambda;') != -1);
		Assert.equals(out.indexOf('using Lambda;'), out.lastIndexOf('using Lambda;'));
	}

	public function testFixEffectfulCondNotRewritten(): Void {
		final out: String = fixResult(file('for (x in xs) if (bump(x) > 2) return x;\n\t\treturn null;', 'Null<Int>', false));
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
		Assert.isTrue(out.indexOf('using Lambda;') == -1);
	}

	public function testFixNewInCondNotRewritten(): Void {
		final out: String = fixResult(file('for (x in xs) if (new Foo(x).ok) return x;\n\t\treturn null;', 'Null<Int>', false));
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
	}

	public function testFixNonNullableBreakDeclNotRewritten(): Void {
		final out: String = fixResult(file(
			'var found:Int = null;\n\t\tfor (x in xs) if (x > 2) { found = x; break; }\n\t\treturn found;', 'Int', true
		));
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
	}

	public function testFixExtraBodyStatementNotRewritten(): Void {
		final out: String = fixResult(file(
			'for (x in xs) if (x > 2) { Assert.fail("bad"); return x; }\n\t\treturn null;', 'Null<Int>', false
		));
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
	}

	public function testFixInsideBranchKeepsControlFlow(): Void {
		final out: String = fixResult(file(
			'if (node != null) {\n\t\t\tfor (x in xs) if (x > 2) return x;\n\t\t\treturn null;\n\t\t} else return -1;', 'Null<Int>', false
		));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2);') != -1);
		Assert.isTrue(out.indexOf('return -1;') != -1);
		Assert.isTrue(out.indexOf('else') != -1);
	}

	public function testFixTernaryFallbackParenthesized(): Void {
		// `??` binds tighter than `?:`, so a ternary fallback must be wrapped.
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn node != null ? 1 : 2;', 'Int', true));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2) ?? (node != null ? 1 : 2);') != -1);
	}

	public function testFixOrFallbackNotParenthesized(): Void {
		// `+` (and `||`/`&&`/`==`) bind tighter than `??`, so no wrapping parens.
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\treturn a + b;', 'Int', true));
		Assert.isTrue(out.indexOf('return xs.find(x -> x > 2) ?? a + b;') != -1);
	}

	public function testFixTernaryIterableParenthesized(): Void {
		final out: String = fixResult(
			file('for (x in (node != null ? xs : xs)) if (x > 2) return x;\n\t\treturn null;', 'Null<Int>', true)
		);
		Assert.isTrue(out.indexOf('(node != null ? xs : xs).find(x -> x > 2)') != -1);
	}

	public function testFixCommentBeforeFallbackRefused(): Void {
		// A comment in the dropped region would be lost — refuse, keep the finding.
		final out: String = fixResult(file('for (x in xs) if (x > 2) return x;\n\t\t// keep me\n\t\treturn null;', 'Null<Int>', false));
		Assert.isTrue(out.indexOf('.find(') == -1);
		Assert.isTrue(out.indexOf('for (') != -1);
		Assert.isTrue(out.indexOf('// keep me') != -1);
	}


	private function fn(body: String, ret: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>):' + ret + ' {\n\t\t' + body + '\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferFind().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function file(body: String, ret: String, withUsing: Bool): String {
		final head: String = 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '');
		return head + 'class C {\n\tfunction f(xs:Array<Int>, node:Node, a:Int, b:Int):' + ret + ' {\n\t\t' + body + '\n\t}\n}';
	}

	private function fixResult(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferFind = new PreferFind();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, plugin);
		switch RefactorSupport.canonicalize(src, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
