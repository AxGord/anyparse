package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.PreferForeach;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * The `prefer-foreach` check: a manual all-match `for` loop
 * `for (x in xs) if (cond) return false; return true;` is flagged `Info`, suggesting
 * `xs.foreach(x -> !(cond))` — the inversion a WRAP, never De Morgan, except that an
 * already-negated condition drops its `!` instead of gaining a second one. The GUARDED
 * variant is deliberately NOT claimed (negating the guard is what would lose a null
 * narrowing), and so are the `exists` direction and every shape gate the twin refuses.
 */
class PreferForeachCheckTest extends Test {

	public function testBareFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn true;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-foreach', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('xs.foreach(x -> !(x > 2))') != -1, vs[0].message);
	}

	public function testNegatedConditionDropsItsNot(): Void {
		final vs: Array<Violation> = violations(fn('for (x in xs) if (!keep(x)) return false;\n\t\treturn true;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.foreach(x -> keep(x))') != -1, vs[0].message);
	}

	public function testGuardedFormNotClaimed(): Void {
		// `if (g) for … return false; return true;` needs `!g`, and negating a null-test guard is
		// exactly what strands the narrowing the rest of the expression needs.
		Assert.equals(0, violations(fn('if (n != null) for (x in n) if (x > 2) return false;\n\t\treturn true;')).length);
	}

	public function testExistsDirectionNotClaimed(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\treturn false;')).length);
	}

	public function testSameLiteralTrailingReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn false;')).length);
	}

	public function testNonLiteralFallbackNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn xs.length == 0;')).length);
	}

	public function testKeyValueLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (k => v in m) if (v > 2) return false;\n\t\treturn true;')).length);
	}

	public function testCallIterableNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (k in m.keys()) if (m[k] > 2) return false;\n\t\treturn true;')).length);
	}

	public function testRangeLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (i in 0...xs.length) if (xs[i] > 2) return false;\n\t\treturn true;')).length);
	}

	public function testNonAdjacentTrailingReturnNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\tfinal q = xs.length;\n\t\treturn true;')).length);
	}

	public function testFallThroughFromElseBranchFlagged(): Void {
		final vs: Array<Violation> = violations(
			fn('if (a) {\n\t\t\ttrace(b);\n\t\t} else {\n\t\t\tfor (x in xs) if (x > 2) return false;\n\t\t}\n\t\treturn true;')
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.foreach(x -> !(x > 2))') != -1, vs[0].message);
	}

	public function testFallThroughStopsAtALoopBody(): Void {
		Assert.equals(0, violations(fn('while (a) {\n\t\t\tfor (x in xs) if (x > 2) return false;\n\t\t}\n\t\treturn true;')).length);
	}

	public function testFixWrapsCondition(): Void {
		final out: String = fixResult(file('for (x in xs) if (x > 2) return false;\n\t\treturn true;', false));
		Assert.isTrue(out.indexOf('return xs.foreach(x -> !(x > 2));') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
	}

	public function testFixDropsExistingNot(): Void {
		final out: String = fixResult(file('for (x in xs) if (!keep(x)) return false;\n\t\treturn true;', true));
		Assert.isTrue(out.indexOf('return xs.foreach(x -> keep(x));') != -1, out);
	}

	public function testFixParenthesizesLooseIterable(): Void {
		final out: String = fixResult(file('for (x in a ? xs : xs) if (x > 2) return false;\n\t\treturn true;', true));
		Assert.isTrue(out.indexOf('return (a ? xs : xs).foreach(x -> !(x > 2));') != -1, out);
	}

	private function fn(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>, n:Null<Array<Int>>, a:Bool, b:Bool):Bool {\n\t\t$body\n\t}\n\n'
			+ '\tfunction keep(x:Int):Bool {\n\t\treturn x > 0;\n\t}\n}';
	}

	private function file(body: String, withUsing: Bool): String {
		return 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '') + fn(body);
	}

	private function violations(source: String): Array<Violation> {
		return new PreferForeach().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function fixResult(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferForeach = new PreferForeach();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], plugin);
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, vs, plugin, SymbolIndex.build([{ file: 'C.hx', source: src }], plugin)
		);
		switch RefactorSupport.canonicalize(src, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

}
