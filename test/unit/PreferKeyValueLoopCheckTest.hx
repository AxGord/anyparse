package unit;

import anyparse.check.Check;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferKeyValueLoop;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import utest.Assert;
import utest.Test;

/**
 * The `prefer-keyvalue-loop` check: `for (i in 0...X.length)` whose body opens with
 * `final v = X[i];` is flagged `Info` and rewritten to `for (i => v in X)`. The index stays
 * bound, so an inner `for (j in i + 1...X.length)` is fine. Soundness misses: a second `X[i]`,
 * a body that can change `X`'s length (a method call on it, handing it to a callee, writing
 * it), a write of the key / value, a shadowing re-declaration, a non-zero lower bound, a bound
 * that is not `X.length`, a declaration that is not the first statement, and a body with
 * nothing but that declaration. The FIX additionally needs `X` declared `Array<E>` and the
 * declaration's annotation — if any — to be exactly `E`.
 */
class PreferKeyValueLoopCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(wrapFn('for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-keyvalue-loop', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this indexed loop can be for (i => it in items)', vs[0].message);
	}

	public function testTypedDeclFlagged(): Void {
		Assert.equals(
			1, violations(wrapFn('for (i in 0...items.length) {\n\t\t\tfinal it:Item = items[i];\n\t\t\tuse(it);\n\t\t}')).length
		);
	}

	public function testVarDeclFlagged(): Void {
		Assert.equals(1, violations(wrapFn('for (i in 0...items.length) {\n\t\t\tvar it = items[i];\n\t\t\tuse(it);\n\t\t}')).length);
	}

	public function testInnerLoopReadingIndexFlagged(): Void {
		// The index stays bound by the key-value form, so an inner range over it is untouched.
		final body: String =
			'for (i in 0...items.length) {\n\t\t\tfinal outer = items[i];\n\t\t\tfor (j in i + 1...items.length) use(items[j], outer);\n\t\t}';
		Assert.equals(1, violations(wrapFn(body)).length);
	}

	public function testAlreadyKeyValueNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (i => it in items) use(it);')).length);
	}

	public function testSecondIndexReadNotFlagged(): Void {
		// The second X[i] would have to become the value binder — a rename this rule does not do.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tuse(it, items[i]);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testCollectionMethodCallNotFlagged(): Void {
		// A push would grow the collection, and the key-value form re-asks the iterator each step.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\titems.push(it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testCollectionPassedToCalleeNotFlagged(): Void {
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tconsume(items, it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testCollectionLengthReadFlagged(): Void {
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tuse(it, items.length);\n\t\t}';
		Assert.equals(1, violations(wrapFn(body)).length);
	}

	public function testCollectionWrittenNotFlagged(): Void {
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\titems = [];\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testValueWrittenNotFlagged(): Void {
		final body: String = 'for (i in 0...items.length) {\n\t\t\tvar it = items[i];\n\t\t\tit = null;\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testKeyWrittenNotFlagged(): Void {
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\ti = 0;\n\t\t\tuse(it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testNonZeroLowerBoundNotFlagged(): Void {
		final body: String = 'for (i in 1...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testNonLengthBoundNotFlagged(): Void {
		final body: String = 'for (i in 0...total) {\n\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testDeclarationNotFirstNotFlagged(): Void {
		final body: String = 'for (i in 0...items.length) {\n\t\t\tbefore(i);\n\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testDeclarationOnlyBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t}')).length);
	}

	public function testUnbracedBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrapFn('for (i in 0...items.length) use(items[i]);')).length);
	}

	public function testShadowingNotFlagged(): Void {
		// `use(it, items.length)` keeps every mention of the collection in a stable position, so the
		// re-declaration gate is the only one that can reject this.
		final body: String =
			'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tfinal items = other;\n\t\t\tuse(it, items.length);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testFixRewritesToKeyValueLoop(): Void {
		assertFixCanonical(
			wrapFn('for (i in 0...items.length) {\n\t\t\tfinal it:Item = items[i];\n\t\t\tuse(it);\n\t\t}'), 'for (i => it in items)',
			'items[i]'
		);
	}

	public function testFixRefusesUnresolvedCollection(): Void {
		// No annotation on the binding, so the element type the dropped declaration carried is unprovable.
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\tfinal items = fetch();\n\t\tfor (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}\n\t}\n}';
		assertFixRefused(src);
	}

	public function testProvablyNonArrayNotFlagged(): Void {
		// A resolved non-Array container has no key-value iteration, so the suggestion would not
		// compile — the report-only tolerance is for an UNRESOLVED container, not a wrong one.
		final src: String =
			'class C {\n\tfunction f(items:Vector<Item>):Void {\n\t\tfor (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFieldCollectionFlagged(): Void {
		// A bare identifier that binds to a FIELD resolves through declaredTypes exactly as a
		// parameter does; only a PATH receiver (this.items) is out of reach.
		final src: String =
			'class C {\n\tvar items:Array<Item> = [];\n\n\tfunction f():Void {\n\t\tfor (i in 0...items.length) {\n\t\t\tfinal it:Item = items[i];\n\t\t\tuse(it, i);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testSizeMemberWriteNotFlagged(): Void {
		// `items.length = 0` truncates: a write THROUGH the collection is not a length-preserving read.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\titems.length = 0;\n\t\t\tuse(it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testBoundMethodValueNotFlagged(): Void {
		// Taking `items.pop` as a VALUE hands the callee something that shrinks the collection —
		// the reason the stable-position whitelist names the size member instead of excluding calls.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tsink(items.pop, it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testIndexWriteNotFlagged(): Void {
		// `items[items.length] = it` EXTENDS the array on every Haxe target.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\titems[items.length] = it;\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testNonSizeMemberBoundNotFlagged(): Void {
		final body: String = 'for (i in 0...items.size) {\n\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testCollectionNamedLikeKeyNotFlagged(): Void {
		final body: String = 'for (items in 0...items.length) {\n\t\t\tfinal it = items[items];\n\t\t\tuse(it);\n\t\t}';
		Assert.equals(0, violations(wrapFn(body)).length);
	}

	public function testFixRefusesTrailingComment(): Void {
		// The comment documents the statement the rewrite deletes; the splice would re-attach it to
		// the loop header, so the comment probe reaches to the end of the declaration's LINE.
		assertFixRefused(wrapFn('for (i in 0...items.length) {\n\t\t\tfinal it:Item = items[i]; // the element\n\t\t\tuse(it);\n\t\t}'));
	}

	public function testFixRefusesWideningAnnotation(): Void {
		// Dropping the declaration would drop the widening annotation with it, changing the binder's type.
		assertFixRefused(wrapFn('for (i in 0...items.length) {\n\t\t\tfinal it:Dynamic = items[i];\n\t\t\tuse(it);\n\t\t}'));
	}

	public function testFixRefusesCommentInReplacedRegion(): Void {
		assertFixRefused(
			wrapFn('for (i in 0...items.length) {\n\t\t\t// element of interest\n\t\t\tfinal it:Item = items[i];\n\t\t\tuse(it);\n\t\t}')
		);
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('prefer-keyvalue-loop');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'prefer-keyvalue-loop is opt-in');
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { for (i in 0...items.length) { final it = items[i];').length);
	}

	private function wrapFn(body: String): String {
		return 'class C {\n\tfunction f(items:Array<Item>):Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferKeyValueLoop().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final r = runAndExpectOne(src);
		switch RefactorSupport.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0, 'expected $present in $text');
				Assert.isTrue(text.indexOf(absent) == -1, 'expected no $absent in $text');
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	private function runAndExpectOne(src: String): { check: PreferKeyValueLoop, vs: Array<Violation> } {
		final check: PreferKeyValueLoop = new PreferKeyValueLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

}
