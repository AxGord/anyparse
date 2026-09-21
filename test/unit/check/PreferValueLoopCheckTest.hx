package unit.check;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.PreferValueLoop;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-value-loop` check: `for (i in 0...X.length)` whose index is read ONLY as `X[i]` is
 * flagged `Info` and rewritten to `for (v in X)`, with every `X[i]` re-spelled as the binder.
 * Soundness misses: any other read of the index (an argument, arithmetic, a `$i` inside an
 * interpolated string), a write to it, a body that can change `X`'s length, a container that
 * resolves to something other than `Array`, a path receiver, and anything in the body that BINDS
 * the index or the collection. The FIX additionally needs a binder name — a singular this check
 * can derive and the body does not already spell — and a resolved container.
 */
class PreferValueLoopCheckTest extends Test {

	public function testBlockBodyFlagged(): Void {
		final vs: Array<Violation> = violations(wrapFn('for (i in 0...items.length) {\n\t\t\tuse(items[i]);\n\t\t\tlog(items[i]);\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-value-loop', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this indexed loop can be for (item in items)', vs[0].message);
	}

	public function testSingleStatementBodyFlagged(): Void {
		// No declaration is consumed, so a braced and a bare body are the same case here.
		Assert.equals(1, violations(wrapFn('for (i in 0...items.length) use(items[i]);')).length);
	}

	public function testFieldCollectionFlagged(): Void {
		final src: String =
			'class C {\n\tvar items:Array<Item> = [];\n\n\tfunction f():Void {\n\t\tfor (i in 0...items.length) use(items[i]);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testIndexPassedToBindNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) sink(f.bind(i), items[i]);')).length);
	}

	public function testIndexArithmeticNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) use(items[i], i + 1);')).length);
	}

	public function testIndexTracedNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) {\n\t\t\ttrace(i);\n\t\t\tuse(items[i]);\n\t\t}')).length);
	}

	public function testInterpolatedIndexNotFlagged(): Void {
		// `$i` projects under the string-interp ident kind, a DIFFERENT one from a code identifier,
		// while `${items[i]}` yields an ordinary index access. THREE gates refuse this jointly and
		// no single one of them owns it: the read count sees the `$i` through that seam, the binder
		// scan sees it as a non-read name slot, and the body text scan sees the bytes. Double-quoted
		// fixture keeps `$i` literal in the source under test.
		final src: String =
			"class C {\n\tfunction f(items:Array<Item>):Void {\n\t\tfor (i in 0...items.length) trace('at $i: ${items[i]}');\n\t}\n}";
		Assert.equals(0, violations(src).length);
	}

	public function testStringCollectionNotFlagged(): Void {
		// A String carries a `length` and no iterator, so `for (c in s)` does not compile. The
		// fixture is syntactic — the check never typechecks the body it reads.
		final src: String = 'class C {\n\tfunction f(chars:String):Void {\n\t\tfor (i in 0...chars.length) use(chars[i]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testPathReceiverNotFlagged(): Void {
		// The type gate resolves a BINDING's annotation, which a path has none of.
		Assert.equals(0, violations(wrapFn('for (i in 0...a.b.length) use(a.b[i]);')).length);
	}

	public function testCollectionMutatedNotFlagged(): Void {
		// `0...items.length` evaluates its bound once; the value loop re-asks the iterator.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tuse(items[i]);\n\t\t\titems.push(null);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testIndexWriteIsAlsoAReadNotFlagged(): Void {
		// An assignment TARGET is an identifier occurrence like any other, so read-equality — not a
		// write count — is what refuses this; the rule carries no separate write gate.
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) {\n\t\t\tuse(items[i]);\n\t\t\ti = 0;\n\t\t}')).length);
	}

	@:pin('control') @:killer('M-VALUE-LOOP-INDEX-TEXT-BLIND')
	public function testMacroIndexReadNotFlagged(): Void {
		// A `macro` quotation is an `opaqueKinds` subtree, so every node walk answers "the index is
		// absent" where the honest answer is "unknown" — and this rewrite DELETES the index on that
		// answer. Only the body text scan sees the `$v{i}`.
		Assert.equals(
			0, violations(wrap('fields:Array<String>', "for (i in 0...fields.length) push(fields[i], macro trace($v{i}));")).length
		);
	}

	public function testMacroOnlyIndexAccessNotFlagged(): Void {
		// The `fields[i]` inside the quotation is collected by neither the read count nor the index
		// collector, so the plain one balances them; the splice would leave the quoted copy behind.
		final body: String = "for (i in 0...fields.length) {\n\t\t\tuse(fields[i]);\n\t\t\temit(macro $v{fields[i]});\n\t\t}";
		Assert.equals(0, violations(wrap('fields:Array<String>', body)).length);
	}

	public function testEscapedInterpolationTriggerNotFlagged(): Void {
		// A `${…}` whose `$` was written as a numeric escape projects CHILDLESS, so the index inside
		// it reaches no walk at all — the second shape only a text scan catches. Here the byte before
		// the index is a brace, so the scan needs no escape knowledge; the brace-less form below does.
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) trace(items[i] + \'\\x24{i}\');')).length);
	}

	public function testEscapedBracelessInterpolationNotFlagged(): Void {
		// The brace-less escape decodes to the same trigger, but the byte before the index is now the
		// escape's own trailing digit — an identifier character. Only `OccurrenceScan`'s dollar-escape
		// list makes that a word boundary, so this is the fixture that pins the list.
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) trace(items[i] + \'\\x24i\');')).length);
	}

	public function testBareInterpolatedIndexNotFlagged(): Void {
		// The plain undecorated interpolation: the grammar re-materialises an `Ident` under the
		// string-interp kind, which is the seam the read count reads. Double-quoted fixture keeps the
		// interpolation trigger literal in the source under test.
		Assert.equals(0, violations(wrapFn("for (i in 0...items.length) trace(items[i] + '$i');")).length);
	}

	public function testInertLiteralNamingTheIndexStillFlagged(): Void {
		// A double-quoted Haxe literal never interpolates, so its bytes cannot read the index — the
		// inert mask is what keeps the text scan from counting one as a use. A SINGLE-quoted literal
		// carrying a real interpolation stays visible, which the fixture above pins.
		Assert.equals(1, violations(wrapFn('for (i in 0...items.length) use(items[i], "i");')).length);
	}

	public function testMacroMentionOfTheBinderNameReportedOnly(): Void {
		// The loop IS a value loop — nothing reads the index but `fields[i]` — yet the derived
		// `field` is a name the quotation spells, and writing it would silently reify the loop
		// element in place of the parameter. The finding stands; the name is withheld.
		final src: String = wrap(
			'fields:Array<String>, field:String', "for (i in 0...fields.length) push(fields[i], macro trace($v{field}));"
		);
		Assert.equals('this indexed loop reads only fields[i]; it can be a value loop over fields', violations(src)[0].message);
		assertFixRefused(src);
	}

	public function testReservedWordSingularReportedOnly(): Void {
		// `classes` singularises to `class`, which the parser would reject as a binder name.
		final src: String =
			'class C {\n\tfunction f(classes:Array<Item>):Void {\n\t\tfor (i in 0...classes.length) use(classes[i]);\n\t}\n}';
		Assert.equals('this indexed loop reads only classes[i]; it can be a value loop over classes', violations(src)[0].message);
		assertFixRefused(src);
	}

	public function testStringLiteralNamingTheCollectionStillFlagged(): Void {
		// A literal's `name` slot carries TEXT, not a symbol: `'items'` is a string, not a binding,
		// so it must not silence the rule.
		Assert.equals(1, violations(wrapFn("for (i in 0...items.length) use(items[i], 'items');")).length);
	}

	public function testDeclaringTheElementFirstNotFlagged(): Void {
		// `prefer-keyvalue-loop`'s claim, declined here so no loop is reported by both rules and the
		// rewrite never leaves `final v = item;` behind as a redundant alias.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal v = items[i];\n\t\t\tuse(v);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testCommentNamingTheBinderStillNamesIt(): Void {
		// A phrase like "one at a time" over a loop body is ordinary prose; without the mask it
		// withheld the binder and the fix went silent.
		final body: String = 'for (i in 0...items.length) {\n\t\t\t// one item at a time\n\t\t\tuse(items[i]);\n\t\t}';
		Assert.equals('this indexed loop can be for (item in items)', violations(wrapFn(body))[0].message);
	}

	public function testCommentNamingTheIndexStillFlagged(): Void {
		final body: String = 'for (i in 0...items.length) {\n\t\t\t// step i forward\n\t\t\tuse(items[i]);\n\t\t}';
		Assert.equals(1, violations(wrapFn(body)).length);
	}

	public function testSecondIndexReadUnderTheOpenerFlagged(): Void {
		// The sibling needs EXACTLY one index read, so it declines this; the deferral has to carry
		// that condition or the loop is reported by nobody.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal v = items[i];\n\t\t\tuse(v, items[i]);\n\t\t}';
		Assert.equals(1, violations(wrapFn(body)).length);
	}

	public function testLoneOpenerStatementFlagged(): Void {
		// The sibling needs two statements; this body has one, so the deferral must not fire.
		Assert.equals(1, violations(wrapFn('for (i in 0...items.length) {\n\t\t\tfinal v = items[i];\n\t\t}')).length);
	}

	public function testMultiDeclaratorOpenerFlagged(): Void {
		// Outside the sibling's claim — its rewrite consumes a SINGLE-variable declaration.
		Assert.equals(1, violations(wrapFn('for (i in 0...items.length) var v = items[i], w = 2;')).length);
	}

	public function testUnbracedOpenerFlagged(): Void {
		Assert.equals(1, violations(wrapFn('for (i in 0...items.length) final v = items[i];')).length);
	}

	public function testTwoLoopsInOneFileBothFixed(): Void {
		final body: String = 'for (i in 0...items.length) use(items[i]);\n\t\tfor (k in 0...items.length) log(items[k]);';
		final src: String = wrapFn(body);
		Assert.equals(2, violations(src).length);
		assertAllFixed(src, ['for (item in items) use(item)', 'for (item in items) log(item)'], ['items[i]', 'items[k]']);
	}

	public function testNestedLoopsBothFixedInOnePass(): Void {
		// The outer splice ends at its own range, and the inner header never overlaps the outer
		// index read, so one pass carries both rewrites.
		final body: String = 'for (i in 0...rows.length) for (j in 0...cols.length) use(rows[i], cols[j]);';
		final src: String = wrap('rows:Array<Item>, cols:Array<Item>', body);
		Assert.equals(2, violations(src).length);
		assertAllFixed(src, ['for (row in rows) for (col in cols) use(row, col)'], ['rows[i]', 'cols[j]']);
	}

	public function testNestedIndexBinderNotFlagged(): Void {
		// The inner binder owns the `items[i]` below it, and this rewrite deletes the outer one.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfor (i in 0...other.length) use(items[i]);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testLambdaParameterShadowNotFlagged(): Void {
		// A lambda parameter carries its name on a node the read counter never sees, which is why
		// the binder gate is wider than a read count.
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) queue(i -> use(items[i]));')).length);
	}

	public function testCollectionNamedLikeIndexNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (items in 0...items.length) use(items[items]);')).length);
	}

	public function testNonZeroLowerBoundNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (i in 1...items.length) use(items[i]);')).length);
	}

	public function testNoIndexReadNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) tick();')).length);
	}

	@:pin('control') @:killer('M-VALUE-LOOP-READS-UNSPLICED')
	public function testFixRewritesBlockBody(): Void {
		assertFixCanonical(
			wrapFn('for (i in 0...items.length) {\n\t\t\tuse(items[i]);\n\t\t\tlog(items[i]);\n\t\t}'), ['for (item in items)'],
			['items[i]', '0...items.length']
		);
	}

	public function testFixRewritesSingleStatementBody(): Void {
		assertFixCanonical(wrapFn('for (i in 0...items.length) use(items[i]);'), ['for (item in items)', 'use(item)'], ['items[i]']);
	}

	public function testFixRewritesFieldCollection(): Void {
		final src: String = 'class C {\n\tvar points:Array<Point> = [];\n\n\tfunction f():Void {\n'
			+ '\t\tfor (i in 0...points.length) draw(points[i]);\n\t}\n}';
		assertFixCanonical(src, ['for (point in points)', 'draw(point)'], ['points[i]']);
	}

	public function testNoSingularReportedOnly(): Void {
		// `arr` is not a plural any rule here recognises, so the finding names no binder.
		final src: String = 'class C {\n\tfunction f(arr:Array<Item>):Void {\n\t\tfor (i in 0...arr.length) use(arr[i]);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('this indexed loop reads only arr[i]; it can be a value loop over arr', vs[0].message);
		assertFixRefused(src);
	}

	public function testCandidateUsedInBodyReportedOnly(): Void {
		// The derived `item` is a name the body already spells, so writing it would capture that one.
		final src: String = wrapFn('for (i in 0...items.length) {\n\t\t\tfinal item = pick();\n\t\t\tuse(items[i], item);\n\t\t}');
		Assert.equals('this indexed loop reads only items[i]; it can be a value loop over items', violations(src)[0].message);
		assertFixRefused(src);
	}

	public function testFixRefusesCommentInReplacedRegion(): Void {
		assertFixRefused(wrapFn('for (i in /* from the top */ 0...items.length) use(items[i]);'));
	}

	public function testFixRefusesUnresolvedCollection(): Void {
		// The advice stands without the type; the REWRITE needs it, since a non-Array container
		// would take a different spelling.
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\tfinal items = fetch();\n\t\tfor (i in 0...items.length) use(items[i]);\n\t}\n}';
		assertFixRefused(src);
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('prefer-value-loop');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'prefer-value-loop is opt-in');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { for (i in 0...items.length) { use(items[i]);').length);
	}

	private function wrapFn(body: String): String {
		return wrap('items:Array<Item>', body);
	}

	/** One class with one method, its parameter list and its body spelled by the caller. */
	private function wrap(params: String, body: String): String {
		return 'class C {\n\tfunction f($params):Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferValueLoop().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function assertFixCanonical(src: String, present: Array<String>, absent: Array<String>): Void {
		final r: CheckRun = runAndExpectOne(src);
		switch CanonicalEdit.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				for (p in present) Assert.isTrue(text.indexOf(p) >= 0, 'expected $p in $text');
				for (a in absent) Assert.isTrue(text.indexOf(a) == -1, 'expected no $a in $text');
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r: CheckRun = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	private function runAndExpectOne(src: String): CheckRun {
		final check: PreferValueLoop = new PreferValueLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

	/** Canonicalise the whole edit set of a MULTI-finding file at once — what a `--fix` pass over the file does. */
	private function assertAllFixed(src: String, present: Array<String>, absent: Array<String>): Void {
		final check: PreferValueLoop = new PreferValueLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		switch CanonicalEdit.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				for (p in present) Assert.isTrue(text.indexOf(p) >= 0, 'expected $p in $text');
				for (a in absent) Assert.isTrue(text.indexOf(a) == -1, 'expected no $a in $text');
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

}

/** One `run` over one fixture: the check instance and the findings it produced, kept together so a fix assertion re-uses both. */
private typedef CheckRun = {
	var check: PreferValueLoop;
	var vs: Array<Violation>;
}
