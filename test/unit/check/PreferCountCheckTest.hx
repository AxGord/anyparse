package unit.check;

import anyparse.check.Check;
import anyparse.check.JoinReturn;
import anyparse.check.PreferCount;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-count` check: `var n = 0;` immediately followed by a `for` loop that steps `n` once
 * per matching element is flagged `Info` and folds to `final n = xs.count(x -> c);` — or, with no
 * filter, to `xs.length` over a proven `Array` / `List` and to `xs.count()` over anything else.
 *
 * Unlike the twin flag forms of `prefer-exists` / `prefer-foreach`, an EFFECTFUL condition is
 * claimed: `Lambda.count` walks the whole collection and calls the predicate once per element in
 * order, so nothing the condition does stops happening. A proven `Iterator` is refused by type —
 * `for` accepts one, `Lambda.count` does not — for a field as much as for a call.
 */
class PreferCountCheckTest extends Test {

	public function testFilteredFormFlagged(): Void {
		final vs: Array<Violation> = violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-count', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.indexOf('final n = xs.count(x -> x > 2)') != -1, vs[0].message);
	}

	public function testFilteredFixFoldsDeclarationAndLoopAndInsertsUsing(): Void {
		final out: String = fixResult(file('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;', false));
		Assert.isTrue(out.indexOf('final n:Int = xs.count(x -> x > 2);') != -1, out);
		Assert.equals(-1, out.indexOf('for (x in xs)'));
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
	}

	public function testExistingUsingNotDuplicated(): Void {
		final out: String = fixResult(file('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;', true));
		Assert.isTrue(out.indexOf('final n:Int = xs.count(x -> x > 2);') != -1, out);
		Assert.equals(out.indexOf('using Lambda;'), out.lastIndexOf('using Lambda;'));
	}

	public function testUnannotatedCounterStaysUnannotated(): Void {
		final out: String = fixResult(file('var n = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;', true));
		Assert.isTrue(out.indexOf('final n = xs.count(x -> x > 2);') != -1, out);
	}

	public function testUnfilteredArrayBecomesLength(): Void {
		final out: String = fixResult(file('var n:Int = 0;\n\t\tfor (x in xs) n++;\n\t\treturn n;', false));
		Assert.isTrue(out.indexOf('final n:Int = xs.length;') != -1, out);
		// No call, so nothing to import.
		Assert.equals(-1, out.indexOf('using Lambda;'));
	}

	public function testUnfilteredListBecomesLength(): Void {
		final out: String = fixResult(file('var n:Int = 0;\n\t\tfor (x in l) n++;\n\t\treturn n;', true));
		Assert.isTrue(out.indexOf('final n:Int = l.length;') != -1, out);
	}

	public function testUnfilteredIterableBecomesCount(): Void {
		final out: String = fixResult(file('var n:Int = 0;\n\t\tfor (x in it) n++;\n\t\treturn n;', false));
		Assert.isTrue(out.indexOf('final n:Int = it.count();') != -1, out);
		Assert.isTrue(out.indexOf('using Lambda;') != -1, out);
	}

	public function testFilteredArrayStillCounts(): Void {
		// `length` answers only the UNFILTERED question.
		final vs: Array<Violation> = violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;'));
		Assert.equals(-1, vs[0].message.indexOf('length'));
	}

	public function testEveryIncrementSpellingFlagged(): Void {
		for (step in ['n++;', '++n;', 'n += 1;', '{ n++; }'])
			Assert.equals(1, violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) $step\n\t\treturn n;')).length, step);
		Assert.equals(1, violations(fn('var n:Int = 0;\n\t\tfor (x in xs) {\n\t\t\tif (x > 2) n++;\n\t\t}\n\t\treturn n;')).length);
	}

	public function testEffectfulConditionFlagged(): Void {
		// ★ The deliberate difference from the twin flag forms: `Lambda.count` does not
		// short-circuit, so `keep` runs once per element either way.
		final vs: Array<Violation> = violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (keep(x)) n++;\n\t\treturn n;'));
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('xs.count(x -> keep(x))') != -1, vs[0].message);
	}

	public function testIteratorFieldNotFlagged(): Void {
		// The `haxe.xml.Access.elements` shape: a property typed `Iterator<T>`. `for` accepts it,
		// `Lambda.count` does not — `Iterator<Int> has no field count`.
		Assert.equals(0, typedViolations('var n:Int = 0;\n\t\tfor (_ in v.elements) n++;\n\t\treturn n;').length);
		Assert.equals(0, typedViolations('var n:Int = 0;\n\t\tfor (_ in b.elements) n++;\n\t\treturn n;').length);
	}

	public function testIteratorParameterNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (x in walk) if (x > 2) n++;\n\t\treturn n;')).length);
	}

	public function testIteratorClassesNotFlagged(): Void {
		// Structural, not by name: `hasNext` + `next` and no `iterator()` is an Iterator, whether the
		// class declares them (with INFERRED returns, as `haxe.iterators.ArrayIterator` does) or inherits them.
		for (field in ['walker', 'sub'])
			Assert.equals(0, iteratorClassViolations('var n:Int = 0;\n\t\tfor (x in $field) n++;\n\t\treturn n;').length, field);
	}

	public function testIterableClassWithIteratorMembersStillFlagged(): Void {
		// Control: a class that is BOTH (it also declares `iterator()`) is an Iterable, and is claimed.
		Assert.equals(1, iteratorClassViolations('var n:Int = 0;\n\t\tfor (x in both) n++;\n\t\treturn n;').length);
	}

	public function testConstructedIteratorNotFlagged(): Void {
		// The CodepointIndexTest shape: `new haxe.iterators.StringIteratorUnicode(s)` writes its type
		// at the site, and a construction is not something the expression resolver reads.
		Assert.equals(0, iteratorClassViolations('var n:Int = 0;\n\t\tfor (x in new Walker()) n++;\n\t\treturn n;').length);
		Assert.equals(0, iteratorClassViolations('var n:Int = 0;\n\t\tfor (x in new p.Walker()) n++;\n\t\treturn n;').length);
	}

	public function testLengthNeedsAStdSpelling(): Void {
		// `p.List` is a PROJECT type named like the std one: its `length` need not be its element
		// count, so the fold falls back to `count()`, which is right for any `Iterable`.
		final out: String = fixResult(
			'package p;\n\nusing Lambda;\n\nclass C {\n\tfunction f(q:p.List<Int>):Int {\n\t\tvar n:Int = 0;\n\t\tfor (x in q) n++;\n'
			+ '\t\treturn n;\n\t}\n}\n'
		);
		Assert.isTrue(out.indexOf('final n:Int = q.count();') != -1, out);
	}

	public function testBareProjectListGetsCount(): Void {
		// A BARE `List` a project declaration captures — imported, or declared by the file's own
		// package — is not the std one: its `length` compiles and need not count, so `count()` it is.
		// `lib.List` is a library the index does not hold, so only the import itself says so.
		for (header in [
			'package p;\n\n',
			'package r;\n\nimport p.List;\n\n',
			'package r;\n\nimport lib.List;\n\n'
		]) {
			final vs: Array<Violation> = projectListViolations(header);
			Assert.equals(1, vs.length, header);
			Assert.isTrue(vs[0].message.indexOf('final n = q.count()') != -1, vs[0].message);
		}
	}

	public function testUnshadowedBareListStillGetsLength(): Void {
		// Control: the same fixture in a package that neither declares nor imports a `List`.
		final vs: Array<Violation> = projectListViolations('package r;\n\n');
		Assert.isTrue(vs[0].message.indexOf('final n = q.length') != -1, vs[0].message);
	}

	public function testSuperInTheConditionNotFlagged(): Void {
		final src: String = 'class Base {\n\tfunction ok(x:Int):Bool {\n\t\treturn x > 0;\n\t}\n}\n\nclass S extends Base {\n'
			+ '\tfunction f(xs:Array<Int>):Int {\n\t\tvar n:Int = 0;\n\t\tfor (x in xs) if (super.ok(x)) n++;\n\t\treturn n;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testIterableFieldStillFlagged(): Void {
		// Control for the `Iterator` refusal: the same fixture over an `Array` field is claimed — as
		// `count()`, since a field access carries no WRITTEN type the `length` spelling could trust.
		final vs: Array<Violation> = typedViolations('var n:Int = 0;\n\t\tfor (_ in b.all) n++;\n\t\treturn n;');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('final n = b.all.count()') != -1, vs[0].message);
	}

	public function testCallIterableResolvingToIteratorNotFlagged(): Void {
		Assert.equals(0, typedViolations('var n:Int = 0;\n\t\tfor (x in b.walker()) if (x > 2) n++;\n\t\treturn n;').length);
	}

	public function testCallIterableResolvingToMapFlagged(): Void {
		// `m.count(f)` compiles on a `Map` (no map declares `count`), so this direction accepts the
		// maps the `exists` one must refuse.
		final vs: Array<Violation> = typedViolations('var n:Int = 0;\n\t\tfor (x in b.table()) if (x > 2) n++;\n\t\treturn n;');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('b.table().count(x -> x > 2)') != -1, vs[0].message);
	}

	public function testSecondWriteNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\tn = 5;\n\t\treturn n;')).length);
	}

	public function testConditionReadingTheCounterNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > n) n++;\n\t\treturn n;')).length);
	}

	public function testIterableMentioningTheCounterNotFlagged(): Void {
		// The fold moves the iterable into the counter's own initializer: `final n = rows[n].count()`
		// reads whatever OUTER `n` is in scope, silently, and still compiles.
		for (iterable in ['rows[n]', 'row(n)'])
			Assert.equals(
				0, violations(rowsFn('var n:Int = 0;\n\t\tfor (x in $iterable) if (x > 2) n++;\n\t\treturn n;')).length, iterable
			);
	}

	public function testMemberTailAndStringNamedLikeTheCounterFlagged(): Void {
		// `r.n` is a dotted tail and `'n'` an inert literal — neither reads the local `n`.
		for (cond in ['r.n > 0', 'r.name == \'n\''])
			Assert.equals(1, violations(rowsFn('var n:Int = 0;\n\t\tfor (r in recs) if ($cond) n++;\n\t\treturn n;')).length, cond);
	}

	public function testInterpolatedReadOfTheCounterNotFlagged(): Void {
		// A braceless `'$n'` is a read the tree does not index — the text scan still sees it.
		Assert.equals(0, violations(fn("var n:Int = 0;\n\t\tfor (x in xs) if ('$n' != '') n++;\n\t\treturn n;")).length);
	}

	public function testFinalDeclarationNotFlagged(): Void {
		Assert.equals(0, violations(fn('final n:Int = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;')).length);
	}

	public function testNonZeroInitializerNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 1;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;')).length);
	}

	public function testNonIntCounterNotFlagged(): Void {
		for (type in ['Float', 'Null<Int>', 'UInt'])
			Assert.equals(0, violations(fn('var n:$type = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn 0;')).length, type);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) n++ else trace(x);\n\t\treturn n;')).length);
	}

	public function testGapBetweenDeclarationAndLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\ttrace(xs);\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;')).length);
	}

	public function testKeyValueLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (k => v in m) if (v > 2) n++;\n\t\treturn n;')).length);
	}

	public function testRangeLoopNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (i in 0...3) n++;\n\t\treturn n;')).length);
	}

	public function testBodyWithMoreThanTheIncrementNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (x in xs) {\n\t\t\ttrace(x);\n\t\t\tn++;\n\t\t}\n\t\treturn n;')).length);
		Assert.equals(
			0, violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) {\n\t\t\ttrace(x);\n\t\t\tn++;\n\t\t}\n\t\treturn n;')).length
		);
	}

	public function testStepOtherThanOneNotFlagged(): Void {
		for (step in ['n += 2;', 'n--;', 'n = n + 1;'])
			Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) $step\n\t\treturn n;')).length, step);
	}

	public function testLoopBinderShadowingTheCounterNotFlagged(): Void {
		// `n++` steps the loop's own binder here; the declared `n` stays `0`.
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\tfor (n in xs) n++;\n\t\treturn n;')).length);
	}

	public function testConditionalCompilationSplitNotFlagged(): Void {
		Assert.equals(0, violations(fn('var n:Int = 0;\n\t\t#if foo\n\t\tfor (x in xs) n++;\n\t\t#end\n\t\treturn n;')).length);
		// A `#if` region projects its branches as FLAT siblings: pairing inside it would join a
		// declaration in one branch to a loop in the other and fold straight through the `#else`.
		Assert.equals(0, violations(fn('#if foo\n\t\tvar n:Int = 0;\n\t\t#else\n\t\tfor (x in xs) n++;\n\t\t#end\n\t\treturn 0;')).length);
	}

	public function testCommentInDroppedRegionNotFixed(): Void {
		final src: String = file('var n:Int = 0;\n\t\tfor (x in xs) // why\n\t\t\tif (x > 2) n++;\n\t\treturn n;', true);
		Assert.equals(1, violations(src).length);
		Assert.equals(0, new PreferCount().fix(src, violations(src), new HaxeQueryPlugin()).length);
	}

	public function testReceiverDeclaringCountTakesTheQualifiedForm(): Void {
		final filtered: String = fixResult('package p;\n\n' + memberFn('var n:Int = 0;\n\t\tfor (x in m) if (x > 2) n++;\n\t\treturn n;'));
		Assert.isTrue(filtered.indexOf('final n:Int = Lambda.count(m, x -> x > 2);') != -1, filtered);
		Assert.equals(-1, filtered.indexOf('using Lambda;'));
		final bare: String = fixResult('package p;\n\n' + memberFn('var n:Int = 0;\n\t\tfor (x in m) n++;\n\t\treturn n;'));
		Assert.isTrue(bare.indexOf('final n:Int = Lambda.count(m);') != -1, bare);
	}

	public function testRivalUsingSupplyingCountRefusesTheFix(): Void {
		// The inserted `using Lambda;` sits ABOVE `using Other;`, so Other's `count` would win.
		final src: String = 'package p;\n\nusing Other;\n\n' + fn('var n:Int = 0;\n\t\tfor (x in xs) if (x > 2) n++;\n\t\treturn n;');
		final out: String = fixResultWith(
			src, 'class Other {\n\tpublic static function count(xs:Array<Int>, f:Int -> Bool):Int return -1;\n}\n'
		);
		Assert.equals(-1, out.indexOf('.count('));
		Assert.isTrue(out.indexOf('for (x in xs)') != -1, out);
	}

	public function testJoinReturnFinishesTheFold(): Void {
		// The TM `DrillVODrop.countSelected` shape: `prefer-count` folds the pair into a `final`, and
		// `join-return` — not this rule — folds that into the `return`.
		final out: String = fixCascade(
			'package p;\n\nclass C {\n\tprivate final _checkBoxes:Array<Box> = [];\n\n\tfunction countSelected():Int {\n'
			+ '\t\tvar selected:Int = 0;\n\t\tfor (checkBox in _checkBoxes) if (checkBox.value) selected++;\n\t\treturn selected;\n\t}\n'
			+ '}\n\nclass Box {\n\tpublic var value:Bool = false;\n}\n'
		);
		Assert.isTrue(out.indexOf('return _checkBoxes.count(checkBox -> checkBox.value);') != -1, out);
		Assert.equals(-1, out.indexOf('selected'));
	}

	/** The main fixture: `xs` an `Array`, `l` a `List`, `it` an `Iterable`, `walk` an `Iterator`, `m` a `Map`. */
	private function fn(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>, l:List<Int>, it:Iterable<Int>, walk:Iterator<Int>, m:Map<String, Int>):Int {\n'
			+ '\t\t$body\n\t}\n\n\tfunction keep(x:Int):Bool {\n\t\treturn x > 0;\n\t}\n}';
	}

	/** `rows` / `row(i)` to index by the counter, and `recs` of `R`, whose fields share the counter's name. */
	private function rowsFn(body: String): String {
		return 'class C {\n\tvar rows:Array<Array<Int>> = [];\n\n\tfunction f(recs:Array<R>):Int {\n\t\t$body\n\t}\n\n'
			+ '\tfunction row(i:Int):Array<Int> {\n\t\treturn rows[i];\n\t}\n}\n\nclass R {\n\tpublic var n:Int = 0;\n'
			+ '\tpublic var name:String = \'\';\n}';
	}

	/** `C` under `header` counting a bare `List<Int>`, beside a project `p.List` whose `length` is not its count. */
	private function projectListViolations(header: String): Array<Violation> {
		return new PreferCount().run([
			{
				file: 'C.hx',
				source: header
				+ 'class C {\n\tfunction f(q:List<Int>):Int {\n\t\tvar n:Int = 0;\n\t\tfor (x in q) n++;\n\t\treturn n;\n\t}\n}'
			},
			{
				file: 'p/List.hx',
				source: 'package p;\n\nclass List<T> {\n\tpublic var length:Int = 99;\n\n\tpublic function iterator():Iterator<T> {\n'
				+ '\t\treturn [].iterator();\n\t}\n}'
			}
		], new HaxeQueryPlugin());
	}

	/** `walker` a class iterator, `sub` one inheriting it, `both` a class that is also `Iterable`. */
	private function iteratorClassViolations(body: String): Array<Violation> {
		final walker: String = '\tpublic function hasNext() {\n\t\treturn false;\n\t}\n\n\tpublic function next() {\n\t\treturn 0;\n\t}\n';
		return violations(
			'class C {\n\tvar walker:Walker;\n\tvar sub:Sub;\n\tvar both:Both;\n\n\tfunction f():Int {\n\t\t$body\n\t}\n}\n\n'
			+ 'class Walker {\n$walker}\n\nclass Sub extends Walker {}\n\n'
			+ 'class Both {\n$walker\n\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}'
		);
	}

	private function file(body: String, withUsing: Bool): String {
		return 'package p;\n\n' + (withUsing ? 'using Lambda;\n\n' : '') + fn(body);
	}

	/** A receiver whose OWN type declares `count`, so the extension call would bind to it. */
	private function memberFn(body: String): String {
		return 'class C {\n\tfunction f(m:M):Int {\n\t\t$body\n\t}\n}\n\nclass M {\n\tpublic function count(key:Int):Int {\n'
			+ '\t\treturn 0;\n\t}\n\n\tpublic function iterator():Iterator<Int> {\n\t\treturn [].iterator();\n\t}\n}';
	}

	/**
	 * `C` iterates members of an ABSTRACT `V` and a class `B`, indexed alongside it so their written
	 * types answer: `elements` is a `(get, never)` property typed `Iterator<Int>` on both (the
	 * `haxe.xml.Access` shape), `all` an `Array<Int>` field, and `walker()` / `table()` calls
	 * returning an `Iterator` and a `Map`.
	 */
	private function typedViolations(body: String): Array<Violation> {
		return new PreferCount().run([
			{ file: 'C.hx', source: 'class C {\n\tfunction f(v:V, b:B):Int {\n\t\t$body\n\t}\n}' },
			{
				file: 'V.hx',
				source: 'abstract V(Array<Int>) {\n\tpublic var elements(get, never):Iterator<Int>;\n\n'
				+ '\tinline function get_elements():Iterator<Int> {\n\t\treturn this.iterator();\n\t}\n}'
			},
			{
				file: 'B.hx',
				source: 'class B {\n\tpublic var elements(get, never):Iterator<Int>;\n\tpublic var all:Array<Int> = [];\n\n\tfunction '
				+ 'get_elements():Iterator<Int> {\n\t\treturn all.iterator();\n\t}\n\n\tpublic function walker():Iterator<Int> {\n'
				+ '\t\treturn all.iterator();\n\t}\n\n\tpublic function table():Map<String, Int> {\n\t\treturn [];\n\t}\n}'
			}
		], new HaxeQueryPlugin());
	}

	private function violations(source: String): Array<Violation> {
		return new PreferCount().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function fixResult(src: String): String {
		return fixResultWith(src, null);
	}

	/** `source` fixed by this rule, with `other` (when given) indexed beside it as `Other.hx`. */
	private function fixResultWith(source: String, other: Null<String>): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferCount = new PreferCount();
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }];
		if (other != null) files.push({ file: 'Other.hx', source: other });
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run(files, plugin), plugin, SymbolIndex.build(files, plugin)
		);
		switch CanonicalEdit.canonicalize(source, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

	/** `source` run through `prefer-count`, then `join-return`, canonicalized after each. */
	private function fixCascade(source: String): String {
		var out: String = source;
		for (check in ([new PreferCount(), new JoinReturn()]: Array<Check>)) {
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			final text: String = out;
			final edits: Array<{ span: Span, text: String }> = check.fix(
				text, check.run([{ file: 'C.hx', source: text }], plugin), plugin,
				SymbolIndex.build([{ file: 'C.hx', source: text }], plugin)
			);
			Assert.isTrue(edits.length > 0, 'stage ${check.id()} produced no edits');
			switch CanonicalEdit.canonicalize(text, edits, true, plugin) {
				case Ok(next):
					out = next;
				case Err(message):
					Assert.fail('stage ${check.id()} canonicalize Err: $message');
					return out;
			}
		}
		return out;
	}

}
