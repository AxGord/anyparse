package unit.check.common.nullsafety;

import anyparse.check.Check;
import anyparse.check.Severity;
import anyparse.check.common.nullsafety.PreferNullCoalescing;
import anyparse.check.common.nullsafety.PreferNullGuardedLoop;
import haxe.PosInfos;

using StringTools;

/**
 * The `prefer-null-guarded-loop` check: `for (x in e ?? []) body` is flagged `Info` and rewritten to
 * `if (e != null) for (x in e) body`. A call-bearing or indexed `e`, a non-Array container, an `else` right after the
 * loop and a comment inside the iterable are reported with the reason and not rewritten; another fallback value and a
 * comprehension are not flagged.
 */
class PreferNullGuardedLoopCheckTest extends Test {

	public function testFallbackLoopFlagged(): Void {
		final vs: Array<Violation> = violations(host('var a: Null<Array<Int>>;', 'for (x in a ?? []) trace(x);'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-null-guarded-loop', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('can be a null guard'), vs[0].message);
	}

	@:pin('control')
	@:killer('M-GUARDED-LOOP-FIX')
	public function testFixWritesTheGuard(): Void {
		assertFixed('if (a != null) for (x in a) trace(x);', host('var a: Null<Array<Int>>;', 'for (x in a ?? []) trace(x);'));
	}

	public function testFixKeepsABlockBody(): Void {
		assertFixed('if (a != null) for (x in a) {', host('var a: Null<Array<Int>>;', 'for (x in a ?? []) {\n\t\t\ttrace(x);\n\t\t}'));
	}

	public function testFixNullableParam(): Void {
		assertFixed('if (a != null) for (x in a) trace(x);', host('', 'for (x in a ?? []) trace(x);', 'a: Null<Array<Int>>'));
	}

	@:killer('M-GUARDED-LOOP-PLAIN-FIELD')
	@:pin('control')
	public function testFixFieldChain(): Void {
		final src: String = 'class O {\n\tpublic var items: Null<Array<Int>>;\n}\n\nclass C {\n\tvar o: O;\n\n\tfunction f(): Void {\n'
			+ '\t\tfor (x in o.items ?? []) trace(x);\n\t}\n}';
		assertFixed('if (o.items != null) for (x in o.items) trace(x);', src);
	}

	public function testFixKeyValueLoop(): Void {
		assertFixed('if (a != null) for (i => x in a) trace(i);', host('var a: Null<Array<Int>>;', 'for (i => x in a ?? []) trace(i);'));
	}

	public function testFixNestedLoops(): Void {
		assertFixed(
			'if (a != null) for (x in a) if (b != null) for (y in b) trace(y);',
			host('var a: Null<Array<Int>>; var b: Null<Array<Int>>;', 'for (x in a ?? []) for (y in b ?? []) trace(y);')
		);
	}

	/** A type the typer cannot name is not a proof of another container: the oracle decides that rewrite. */
	public function testUnresolvedTypeRewritten(): Void {
		assertFixed('if (a != null) for (x in a) trace(x);', host('', 'for (x in a ?? []) trace(x);', 'a'));
	}

	/** The guard reads its value twice, the fallback once. */
	@:pin('control')
	@:killer('M-GUARDED-LOOP-TWICE')
	public function testCallReportedNotRewritten(): Void {
		assertRefused('twice', host('function g(): Null<Array<Int>> return null;', 'for (x in g() ?? []) trace(x);'));
	}

	@:pin('control')
	@:killer('M-GUARDED-LOOP-INDEX')
	public function testIndexReadReportedNotRewritten(): Void {
		assertRefused('index read', host('var m: Map<String, Array<Int>> = [];', "for (x in m['k'] ?? []) trace(x);"));
	}

	/** The fallback of a map is an empty map, not a skipped loop the rule may claim. */
	@:pin('control')
	@:killer('M-GUARDED-LOOP-CONTAINER')
	public function testNonArrayContainerReportedNotRewritten(): Void {
		assertRefused('not a container', host('var a: Null<Map<String, Int>>;', 'for (x in a ?? []) trace(x);'));
	}

	@:pin('control')
	@:killer('M-GUARDED-LOOP-ELSE')
	public function testLoopBeforeAnElseReportedNotRewritten(): Void {
		assertRefused('else', host('var a: Null<Array<Int>>;', 'if (c) for (x in a ?? []) trace(x); else trace(0);', 'c: Bool'));
		assertRefused('else', host('var a: Null<Array<Int>>;', 'if (c) while (c) for (x in a ?? []) trace(x); else trace(0);', 'c: Bool'));
	}

	public function testLoopInABracedBranchRewritten(): Void {
		assertFixed(
			'if (a != null) for (x in a) trace(x);',
			host('var a: Null<Array<Int>>;', 'if (c) {\n\t\t\tfor (x in a ?? []) trace(x);\n\t\t} else trace(0);', 'c: Bool')
		);
	}

	@:pin('control')
	@:killer('M-GUARDED-LOOP-COMMENT')
	public function testCommentInsideTheIterableReportedNotRewritten(): Void {
		assertRefused('comment', host('var a: Null<Array<Int>>;', 'for (x in a /* keep */ ?? []) trace(x);'));
	}

	@:pin('control')
	@:killer('M-GUARDED-LOOP-FALLBACK-KIND')
	public function testAnotherFallbackNotFlagged(): Void {
		Assert.equals(0, violations(host('var a: Null<Array<Int>>; var b: Array<Int> = [];', 'for (x in a ?? b) trace(x);')).length);
	}

	@:pin('control')
	@:killer('M-GUARDED-LOOP-FALLBACK-EMPTY')
	public function testNonEmptyFallbackLiteralNotFlagged(): Void {
		Assert.equals(0, violations(host('var a: Null<Array<Int>>;', 'for (x in a ?? [1]) trace(x);')).length);
	}

	public function testComprehensionNotFlagged(): Void {
		Assert.equals(0, violations(host('var a: Null<Array<Int>>;', 'final r: Array<Int> = [for (x in a ?? []) x];')).length);
	}

	/** The guard form is the fixed point: neither this rule nor `prefer-null-coalescing` flags what the fix wrote. */
	public function testFixedFormIsStable(): Void {
		final fixed: String = CheckFixture.fixedSource(
			new PreferNullGuardedLoop(), host('var a: Null<Array<Int>>;', 'for (x in a ?? []) trace(x);')
		);
		Assert.equals(0, violations(fixed).length);
		Assert.equals(0, CheckFixture.violations(new PreferNullCoalescing(), fixed).length);
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('prefer-null-guarded-loop');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'prefer-null-guarded-loop is opt-in');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	@:pin('control')
	@:killer('M-GUARDED-LOOP-SAFE-NAV')
	public function testSafeNavigationReadReportedNotRewritten(): Void {
		final src: String = 'class O {\n\tpublic var items: Null<Array<Int>>;\n}\n\nclass C {\n\tvar o: Null<O>;\n\n'
			+ '\tfunction f(): Void {\n\t\tfor (x in o?.items ?? []) trace(x);\n\t}\n}';
		assertRefused('safe-navigation', src);
	}

	/** A property read runs its getter: twice under the guard, once under the fallback. */
	@:pin('control')
	@:killer('M-GUARDED-LOOP-GETTER')
	public function testGetterBackedValueReportedNotRewritten(): Void {
		final path: String = 'class Q {\n\tpublic var items(get, never): Null<Array<Int>>;\n\n'
			+ '\tfunction get_items(): Null<Array<Int>> return null;\n}\n\nclass C {\n\tvar q: Q;\n\n'
			+ '\tfunction f(): Void {\n\t\tfor (x in q.items ?? []) trace(x);\n\t}\n}';
		assertRefused('getter', path);
		assertRefused(
			'getter',
			host(
				'var prop(get, never): Null<Array<Int>>;\n\n\tfunction get_prop(): Null<Array<Int>> return null;',
				'for (x in prop ?? []) trace(x);'
			)
		);
	}

	/** A step the index cannot resolve is not a proof of a plain read. */
	@:pin('control')
	@:killer('M-GUARDED-LOOP-GETTER')
	public function testUnresolvedStepReportedNotRewritten(): Void {
		assertRefused('getter', host('', 'for (x in u.items ?? []) trace(x);', 'u'));
	}

	private function host(members: String, stmt: String, ?param: String): String {
		return 'class C {\n\t$members\n\n\tfunction f(${param ?? ''}): Void {\n\t\t$stmt\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new PreferNullGuardedLoop(), src);
	}

	/** One finding, rewritten: the fixed source holds `expected`. */
	private function assertFixed(expected: String, src: String, ?pos: PosInfos): Void {
		final fixed: String = CheckFixture.fixedSource(new PreferNullGuardedLoop(), src);
		Assert.isTrue(fixed.contains(expected), fixed, pos);
	}

	/** One finding whose message gives `reason`, and no edit. */
	private function assertRefused(reason: String, src: String, ?pos: PosInfos): Void {
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length, pos);
		if (vs.length == 1) Assert.isTrue(vs[0].message.contains(reason), vs[0].message, pos);
		Assert.equals(0, CheckFixture.edits(new PreferNullGuardedLoop(), src).length, pos);
	}

}
