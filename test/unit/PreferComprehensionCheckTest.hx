package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferComprehension;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-comprehension` check: an empty-array local `final a = []`
 * immediately followed by a push-only `for (x in xs) a.push(e);` is flagged
 * `Info` and rewritten to `final a = [for (x in xs) e];`. Key-value and nested
 * `for`s and a single trailing `if` guard transfer verbatim; a second statement,
 * a self-reference, an unread array, a `break`, a non-adjacent loop, a comment in
 * the gap and a non-empty initializer are all safe misses. The raw fix emits tight
 * brackets (`[...]`); the linter's canonicalizing `--fix` spaces them.
 */
class PreferComprehensionCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) out.push(x * 2);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-comprehension', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('array comprehension') != -1);
	}

	public function testTypedDeclKeepsAnnotation(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) x * 2];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) out.push(x * 2);'))
		);
	}

	public function testGuardFormFlaggedAndFixed(): Void {
		Assert.equals(1, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) out.push(x);')).length);
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) if (x > 0) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) out.push(x);'))
		);
	}

	public function testGuardBracedBodyFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) if (x > 0) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) { out.push(x); }'))
		);
	}

	public function testKeyValueFormFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (k => v in m) v];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (k => v in m) out.push(v);'))
		);
	}

	public function testNestedForsFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (a in xs) for (b in xs) a + b];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (a in xs) for (b in xs) out.push(a + b);'))
		);
	}

	public function testVarBecomesFinalInFix(): Void {
		Assert.equals(fnRet('final out = [for (x in xs) x];'), applyFix(fnRet('var out = [];\n\t\tfor (x in xs) out.push(x);')));
	}

	public function testBracedBodyFixed(): Void {
		Assert.equals(
			fnRet('final out:Array<Int> = [for (x in xs) x];'),
			applyFix(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) { out.push(x); }'))
		);
	}

	public function testSecondStatementNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) { out.push(x); trace(x); }')).length);
	}

	public function testSelfReferenceNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) out.push(out.length);')).length);
	}

	public function testUnreadArrayNotFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfinal out:Array<Int> = [];\n\t\tfor (x in xs) out.push(x);\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testBreakInBodyNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) { out.push(x); break; }')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(
			0, violations(fnRet('final out:Array<Int> = [];\n\t\tfor (x in xs) if (x > 0) out.push(x) else out.push(0);')).length
		);
	}

	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [];\n\t\tfinal n = xs.length;\n\t\tfor (x in xs) out.push(x);')).length);
	}

	public function testCommentInGapNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = []; // seed\n\t\tfor (x in xs) out.push(x);')).length);
	}

	public function testNonEmptyInitNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = [0];\n\t\tfor (x in xs) out.push(x);')).length);
	}

	public function testNewArrayInitNotFlagged(): Void {
		Assert.equals(0, violations(fnRet('final out:Array<Int> = new Array();\n\t\tfor (x in xs) out.push(x);')).length);
	}

	public function testApplyFixByteExact(): Void {
		final input: String = 'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\tfinal out:Array<Int> = [];\n\t\tfor (x in xs) out.push(x * 2);\n\t\treturn out;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f(xs:Array<Int>):Array<Int> {\n\t\tfinal out:Array<Int> = [for (x in xs) x * 2];\n\t\treturn out;\n\t}\n}';
		Assert.equals(expected, applyFix(input));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-comprehension'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-comprehension'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { final out = []; for (x in xs) out.push(').length);
	}

	private function fnRet(stmts: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>):Array<Int> {\n\t\t' + stmts + '\n\t\treturn out;\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferComprehension().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		final check: PreferComprehension = new PreferComprehension();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
