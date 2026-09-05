package unit.check;

import anyparse.check.Check;
import anyparse.check.DeadBinderCounterLoop;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import utest.Assert;
import utest.Test;

/**
 * The `dead-binder-counter-loop` check: `var i = 0;` followed by `for (x in coll) { … i++; }`
 * with an unread binder is flagged `Info` and rewritten to a range `for` — `0...coll.length`
 * for a container that has one, `0...coll.count()` (plus a `using Lambda;`) for a map.
 * Soundness misses: a body that reads the binder, an extra write of the counter, a missing or
 * misplaced increment, a `continue` (which skips the increment), a counter read after the loop
 * or captured by a closure, a `final` counter, a non-zero initializer, a non-adjacent
 * declaration, a body that can change the collection, and a container whose element count this
 * rule cannot spell (unannotated, an `Iterator`).
 */
class DeadBinderCounterLoopCheckTest extends Test {

	public function testArrayFlagged(): Void {
		final vs: Array<Violation> = violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('dead-binder-counter-loop', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this loop discards its binder and counts by hand — it can be for (i in 0...items.length)', vs[0].message);
	}

	public function testTypedCounterFlagged(): Void {
		Assert.equals(1, violations(wrapArray('var i:Int = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testMapFlaggedWithCount(): Void {
		final vs: Array<Violation> = violations(wrapMap('var i = 0;\n\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('this loop discards its binder and counts by hand — it can be for (i in 0...table.count())', vs[0].message);
	}

	public function testBinderReadNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\twork(x);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testNoTrailingIncrementNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\ti++;\n\t\t\twork(i);\n\t\t}')).length);
	}

	public function testExtraCounterWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\ti = 0;\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testContinueNotFlagged(): Void {
		// A continue SKIPS the increment in the for-in form but advances the range binder.
		Assert.equals(
			0, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\tif (skip(i)) continue;\n\t\t\ti++;\n\t\t}')).length
		);
	}

	public function testBreakFlagged(): Void {
		Assert.equals(1, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\tif (done(i)) break;\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testCounterReadAfterNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(items:Array<Item>):Int {\n\t\tvar i = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n'
			+ '\t\t\ti++;\n\t\t}\n\t\treturn i;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFinalCounterNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('final i = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testNonZeroInitNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('var i = 1;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testNonAdjacentNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapArray('var i = 0;\n\t\tsetup();\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length
		);
	}

	public function testFloatCounterNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('var i:Float = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testEmptyBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testShadowedCounterNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\tvar i = 5;\n\t\t\ttrace(i);\n\t\t\ti++;\n\t\t}')).length
		);
	}

	public function testClosureCapturingCounterNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\tqueue(() -> i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testCollectionMutatedNotFlagged(): Void {
		Assert.equals(0, violations(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\titems.push(i);\n\t\t\ti++;\n\t\t}')).length);
	}

	public function testUnresolvedCollectionNotFlagged(): Void {
		// The replacement text depends on the container, so an unresolved one is not reported at all.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfinal items = fetch();\n\t\tvar i = 0;\n\t\tfor (x in items) {\n'
			+ '\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testIteratorCollectionNotFlagged(): Void {
		// Lambda.count would CONSUME an Iterator, leaving the rewritten loop with nothing to run.
		final src: String = 'class C {\n\tfunction f(cursor:Iterator<Item>):Void {\n\t\tvar i = 0;\n\t\tfor (x in cursor) {\n'
			+ '\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFixRewritesArrayLoop(): Void {
		assertFixCanonical(
			wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'), ['for (i in 0...items.length)'],
			['var i = 0', 'i++']
		);
	}

	@:pin('control') @:killer('M-SHADOWEXT-TRUE')
	public function testFixRewritesMapLoopAndInsertsUsing(): Void {
		assertFixCanonical(
			wrapMap('var i = 0;\n\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'),
			['for (i in 0...table.count())', 'using Lambda;'], ['var i = 0']
		);
	}

	public function testFixReusesExistingUsing(): Void {
		final src: String = 'package p;\n\nusing Lambda;\n\nclass C {\n\tfunction f(table:Map<Int, Item>):Void {\n\t\tvar i = 0;\n'
			+ '\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t}\n}';
		final r = runAndExpectOne(src);
		switch CanonicalEdit.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.equals(1, countOccurrences(text, 'using Lambda;'));
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	public function testFixRefusesCommentBeforeLoop(): Void {
		assertFixRefused(wrapArray('var i = 0;\n\t\t// counting\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'));
	}

	public function testFixRefusesCommentAfterIncrement(): Void {
		assertFixRefused(wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t\t// done\n\t\t}'));
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('dead-binder-counter-loop');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'dead-binder-counter-loop is opt-in');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(items:Array<Item>) { var i = 0; for (x in items) { work(i); i++; }').length);
	}

	public function testInterpolatedBinderReadNotFlagged(): Void {
		// A bare `'$x'` read lives under a string-literal ctor no node walk matches, and a missed
		// mention here would DELETE the binder — which is why the proof is a text scan.
		final body: String = "var i = 0;\n\t\tfor (x in items) {\n\t\t\ttrace('item $x');\n\t\t\ti++;\n\t\t}";
		Assert.equals(0, violations(wrapArray(body)).length);
	}

	public function testMacroBinderReadNotFlagged(): Void {
		// A reification subtree is opaque to every node walk for the same reason.
		final body: String = "var i = 0;\n\t\tfor (x in items) {\n\t\t\tout.push(macro $i{x});\n\t\t\ti++;\n\t\t}";
		Assert.equals(0, violations(wrapArray(body)).length);
	}

	public function testListFlaggedWithLength(): Void {
		final vs: Array<Violation> = violations(
			wrapParam('items:List<Item>', 'var i = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('0...items.length') >= 0, vs[0].message);
	}

	public function testHashMapNotFlagged(): Void {
		// haxe.ds.HashMap iterates in a `for` but is an abstract that does not unify with Iterable,
		// so Lambda.count does not apply to it.
		final src: String = wrapParam(
			'table:haxe.ds.HashMap<Key, Item>', 'var i = 0;\n\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testVectorNotFlagged(): Void {
		// `Vector` is off the whitelist: a geometry Vector's `length` is a magnitude, not a count.
		final src: String = wrapParam('items:Vector<Item>', 'var i = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}');
		Assert.equals(0, violations(src).length);
	}

	public function testQualifiedProjectContainerNotFlagged(): Void {
		// The whitelist matches a SIMPLE nominal, so a qualified non-`haxe.` spelling is refused
		// rather than admitted by its last segment alone.
		final src: String = wrapParam(
			'table:mygame.Map<Int, Item>', 'var i = 0;\n\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}'
		);
		Assert.equals(0, violations(src).length);
	}

	public function testConditionalRegionNotFlagged(): Void {
		// A `#if` region holds every branch's statements as FLAT siblings, so pairing across it would
		// splice through the `#else` and delete it — the pair scan runs over statement lists only.
		final body: String = '#if debug\n\t\tvar i = 0;\n\t\t#else\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}\n\t\t#end';
		Assert.equals(0, violations(wrapArray(body)).length);
	}

	public function testContainerDeclaringCountTakesTheQualifiedForm(): Void {
		// The `count()` arm emits a `using Lambda;` call, and a real MEMBER beats a `using`. The
		// whitelist matches a SIMPLE nominal, so a project type named after a std container is the
		// residual this rule's own doc names — and the count survives in the QUALIFIED spelling,
		// which routes around that member and needs no `using` at all.
		final src: String = wrapMap('var i = 0;\n\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')
			+ '\n\nclass Map {\n\tpublic function count():Int {\n\t\treturn 0;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('for (i in 0...Lambda.count(table))') != -1, vs[0].message);
		assertFixCanonical(src, ['for (i in 0...Lambda.count(table))'], ['using Lambda;', 'var i = 0;']);
	}

	public function testShadowedLambdaModuleRefusesTheQualifiedCount(): Void {
		// `Lambda` may itself be shadowed — a project declaring its own `Lambda.hx`. The qualified
		// count would then reach THAT type, so the container keeps its old refusal.
		final src: String = wrapMap('var i = 0;\n\t\tfor (x in table) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')
			+ '\n\nclass Map {\n\tpublic function count():Int {\n\t\treturn 0;\n\t}\n}'
			+ '\n\nclass Lambda {\n\tpublic function count(it:Int):Int {\n\t\treturn 0;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testLengthContainerDeclaringCountStillFlagged(): Void {
		// The `length` arm needs no `Lambda` at all, so a same-file `count` member is irrelevant to
		// it — the gate is scoped to the name the rewrite actually emits.
		final src: String = wrapArray('var i = 0;\n\t\tfor (x in items) {\n\t\t\twork(i);\n\t\t\ti++;\n\t\t}')
			+ '\n\nclass Array2 {\n\tpublic function count():Int {\n\t\treturn 0;\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	private inline function wrapArray(body: String): String {
		return wrapParam('items:Array<Item>', body);
	}

	private inline function wrapMap(body: String): String {
		return wrapParam('table:Map<Int, Item>', body);
	}

	/** One method taking `param`, with `body` as its statements — the shape every fixture here has. */
	private function wrapParam(param: String, body: String): String {
		return 'class C {\n\tfunction f($param):Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new DeadBinderCounterLoop().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function countOccurrences(text: String, needle: String): Int {
		var count: Int = 0;
		var at: Int = text.indexOf(needle);
		while (at != -1) {
			count++;
			at = text.indexOf(needle, at + needle.length);
		}
		return count;
	}

	private function assertFixCanonical(src: String, present: Array<String>, absent: Array<String>): Void {
		final r = runAndExpectOne(src);
		switch CanonicalEdit.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				for (p in present) Assert.isTrue(text.indexOf(p) >= 0, 'expected $p in $text');
				for (a in absent) Assert.isTrue(text.indexOf(a) == -1, 'expected no $a in $text');
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	private function runAndExpectOne(src: String): { check: DeadBinderCounterLoop, vs: Array<Violation> } {
		final check: DeadBinderCounterLoop = new DeadBinderCounterLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

}
