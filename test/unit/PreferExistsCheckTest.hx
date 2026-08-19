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
		Assert.equals(0, violations(fn('if (a) for (x in xs) if (x > 2) return true; else return false;\n\t\treturn false;')).length);
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
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return true;\n\t\tfinal q = xs.length;\n\t\treturn false;')).length);
	}

	public function testForeachDirectionNotClaimed(): Void {
		Assert.equals(0, violations(fn('for (x in xs) if (x > 2) return false;\n\t\treturn true;')).length);
	}

	public function testExtraLoopBodyStatementNotFlagged(): Void {
		Assert.equals(0, violations(fn('for (x in xs) { trace(x); if (x > 2) return true; }\n\t\treturn false;')).length);
	}

	public function testFallThroughFromElseBranchFlagged(): Void {
		final vs: Array<Violation> = violations(
			fn('if (a) {\n\t\t\ttrace(b);\n\t\t} else {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t}\n\t\treturn false;')
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testFallThroughAcrossTwoIfLevelsFlagged(): Void {
		Assert.equals(
			1,
			violations(fn('if (a) {\n\t\t\tif (b) {\n\t\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t\t}\n\t\t}\n\t\treturn false;'))
				.length
		);
	}

	public function testFallThroughStopsAtALoopBody(): Void {
		// Falling off the end of a `while` body starts the NEXT ITERATION, so the trailing
		// `return false;` is not what follows the loop — the successor must not cross it.
		Assert.equals(0, violations(fn('while (a) {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t}\n\t\treturn false;')).length);
	}

	public function testFallThroughStopsAtATryBody(): Void {
		Assert.equals(
			0, violations(fn('try {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t} catch (e:Dynamic) {}\n\t\treturn false;')).length
		);
	}

	public function testFallThroughStopsAtASwitchArm(): Void {
		// The arm body is BRACED on purpose: an unbraced arm's statements are not a statement list
		// at all, so the pairing never happens and the fixture would pass behind that gate instead
		// of this one. With a block there, only the successor rule can refuse it.
		Assert.equals(
			0,
			violations(
				fn('switch (a) {\n\t\t\tcase _: {\n\t\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t\t}\n\t\t}\n\t\treturn false;')
			).length
		);
	}

	public function testConditionalRegionIsNotAStatementList(): Void {
		// Pins a DIFFERENT gate from the three above, and says so: a `#if` region projects its
		// branches as FLATTENED siblings and is deliberately absent from `blockKinds`, so nothing
		// inside one is ever paired with a sibling outside it — with or without a successor.
		Assert.equals(0, violations(fn('#if js\n\t\tfor (x in xs) if (x > 2) return true;\n\t\t#end\n\t\treturn false;')).length);
	}

	public function testGuardedBracedFormReportedOnce(): Void {
		// `if (g) { for … }` + the fallback matches BOTH readings — the guarded merge and the bare
		// fall-through inside the braces. One site, one finding: the merge.
		final vs: Array<Violation> = violations(fn('if (a) { for (x in xs) if (x > 2) return true; }\n\t\treturn false;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('a && xs.exists(x -> x > 2)') != -1, vs[0].message);
	}

	public function testFallThroughFixKeepsTheTrailingReturn(): Void {
		final out: String = fixResult(
			file('if (a) {\n\t\t\ttrace(b);\n\t\t} else {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t}\n\t\treturn false;', true)
		);
		Assert.isTrue(out.indexOf('return xs.exists(x -> x > 2);') != -1, out);
		Assert.isTrue(out.indexOf('return false;') != -1, out);
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
		Assert.equals(0, new PreferExists().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	public function testInsertedUsingIsAtomicWithItsRewrites(): Void {
		// Reverting the rewrite while KEEPING the inserted `using` leaves a file that still
		// compiles, so the verifier could not tell that subset was wrong — measured as an orphaned
		// `using Lambda;` on a Map-receiver fixture before the grouping landed.
		final src: String = file('for (x in xs) if (x > 2) return true;\n\t\treturn false;', false);
		final edits: Array<GroupedEdit> = grouped(src);
		Assert.equals(2, edits.length);
		Assert.notNull(edits[0].group);
		Assert.equals(edits[0].group, edits[1].group);
	}

	public function testEditsStayIndependentWhenTheUsingIsAlreadyThere(): Void {
		final src: String = file(
			'if (a) {\n\t\t\tfor (x in xs) if (x > 2) return true;\n\t\t} else {\n\t\t\tfor (x in xs) if (x < 0) return true;\n\t\t}\n'
			+ '\t\treturn false;',
			true
		);
		final edits: Array<GroupedEdit> = grouped(src);
		Assert.equals(2, edits.length);
		for (e in edits) Assert.isNull(e.group);
	}

	private function grouped(src: String): Array<GroupedEdit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferExists = new PreferExists();
		return check.fixGrouped(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
	}

	private function fn(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, m:Map<String, Int>, n:Null<Array<Int>>, a:Bool, b:Bool):Bool {\n\t\t${body}\n\t}\n}';
	}

	private function file(body: String, withUsing: Bool): String {
		return 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '') + fn(body);
	}

	private function violations(source: String): Array<Violation> {
		return new PreferExists().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function fixResult(src: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferExists = new PreferExists();
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
