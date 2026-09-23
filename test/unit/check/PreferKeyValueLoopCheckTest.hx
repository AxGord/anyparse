package unit.check;

import anyparse.check.Check;
import anyparse.check.ElementLoopRewrite;
import anyparse.check.Linter;
import anyparse.check.PreferKeyValueLoop;
import anyparse.check.PreferValueLoop;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
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
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal outer = items[i];\n'
			+ '\t\t\tfor (j in i + 1...items.length) use(items[j], outer);\n\t\t}';
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

	public function testDeclarationNotFirstIsTheNoOpenerShape(): Void {
		// Not the opener arm's (the binding is not the first statement), so it is the no-opener arm's:
		// every `items[i]` becomes the binder. The bare `before(i)` call leaves it report-only.
		final src: String = wrapFn('for (i in 0...items.length) {\n\t\t\tbefore(i);\n\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}');
		final r: CheckRun = runAndExpectOne(src);
		Assert.equals('this indexed loop can be for (i => item in items)', r.vs[0].message);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
		// Through a receiver instead, the same loop is fixed.
		final text: String = fixedText(
			wrapSink('for (i in 0...items.length) {\n\t\t\tsink.before(i);\n\t\t\tfinal it = items[i];\n\t\t\tsink.use(it);\n\t\t}')
		);
		Assert.isTrue(text.indexOf('for (i => item in items) {\n\t\t\tsink.before(i);\n\t\t\tfinal it = item;') >= 0, text);
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
			wrapSink('for (i in 0...items.length) {\n\t\t\tfinal it:Item = items[i];\n\t\t\tsink.use(it);\n\t\t}'),
			'for (i => it in items)', 'items[i]'
		);
	}

	public function testFixRefusesUnresolvedCollection(): Void {
		// No annotation on the binding, so the element type the dropped declaration carried is unprovable.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfinal items = fetch();\n\t\tfor (i in 0...items.length) {\n'
			+ '\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}\n\t}\n}';
		assertFixRefused(src);
	}

	public function testProvablyNonArrayNotFlagged(): Void {
		// A resolved non-Array container has no key-value iteration, so the suggestion would not
		// compile — the report-only tolerance is for an UNRESOLVED container, not a wrong one.
		final src: String = 'class C {\n\tfunction f(items:Vector<Item>):Void {\n\t\tfor (i in 0...items.length) {\n'
			+ '\t\t\tfinal it = items[i];\n\t\t\tuse(it);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testFieldCollectionFlagged(): Void {
		// A bare identifier that binds to a FIELD resolves through declaredTypes exactly as a
		// parameter does; only a PATH receiver (this.items) is out of reach.
		final src: String = 'class C {\n\tvar items:Array<Item> = [];\n\n\tfunction f():Void {\n\t\tfor (i in 0...items.length) {\n'
			+ '\t\t\tfinal it:Item = items[i];\n\t\t\tuse(it, i);\n\t\t}\n\t}\n}';
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

	@:pin('control') @:killer('M-KV-NOOPENER-UNDERSCORE') @:killer('M-VALUE-LOOP-READS-UNSPLICED')
	public function testNoOpenerFieldLoopRewritten(): Void {
		// No `final p = X[i];` to consume and the index feeds a second array, so neither the opener arm
		// nor prefer-value-loop claims it; every `_points[i]` becomes the binder, `value[i]` stays.
		final text: String = fixedText(fieldSource());
		Assert.isTrue(text.indexOf('for (i => point in _points) {\n\t\t\tpoint.pos = value[i].clone();\n') >= 0, text);
		Assert.isTrue(text.indexOf('_pointsScale[i].pos = value[i].clone();') >= 0, text);
		Assert.isTrue(text.indexOf('_points[i]') == -1, text);
	}

	public function testNoOpenerMessageNamesBinder(): Void {
		final vs: Array<Violation> = violations(fieldSource());
		Assert.equals(1, vs.length);
		Assert.equals('this indexed loop can be for (i => point in _points)', vs[0].message);
	}

	public function testNoOpenerShapeIsNotAValueLoop(): Void {
		Assert.equals(0, new PreferValueLoop().run([{ file: 'C.hx', source: fieldSource() }], new HaxeQueryPlugin()).length);
	}

	@:pin('control') @:killer('M-KV-NOOPENER-INDEX-ONLY')
	public function testIndexOnlyLoopLeftToValueLoop(): Void {
		// Every read of `i` is an `items[i]`: prefer-value-loop's loop, so this rule stays silent on it.
		final src: String = wrapSink('for (i in 0...items.length) {\n\t\t\tsink.use(items[i]);\n\t\t\tsink.use(items[i]);\n\t\t}');
		Assert.equals(0, violations(src).length);
		Assert.equals(1, new PreferValueLoop().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length);
	}

	@:pin('control') @:killer('M-KV-NOOPENER-OPENER-CLAIM')
	public function testOpenerWithSecondReadStaysUnclaimed(): Void {
		// The opener arm owns a body that opens by binding `items[i]`, and declines this one for its
		// second read; the no-opener arm must not pick it up and rename the opener's own initializer.
		final body: String = 'for (i in 0...items.length) {\n\t\t\tfinal it = items[i];\n\t\t\tsink.use(it, items[i], i);\n\t\t}';
		Assert.equals(0, violations(wrapSink(body)).length);
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-UNSTABLE')
	public function testNoOpenerSlotWriteNotFlagged(): Void {
		// `items[i]` as a write target: the binder is a copy, so the write would land nowhere.
		Assert.equals(0, violations(wrapSink('for (i in 0...items.length) {\n\t\t\titems[i] = sink.make(i);\n\t\t}')).length);
		Assert.equals(0, violations(wrapSink('for (i in 0...items.length) {\n\t\t\titems[i] += i;\n\t\t}')).length);
		Assert.equals(0, violations(wrapSink('for (i in 0...items.length) {\n\t\t\titems[i]++;\n\t\t\tsink.use(i);\n\t\t}')).length);
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-UNSTABLE')
	public function testNoOpenerLengthChangeNotFlagged(): Void {
		// The key-value iterator re-reads the length every step; the range bound was read once.
		Assert.equals(
			0, violations(wrapSink('for (i in 0...items.length) {\n\t\t\tsink.use(items[i], i);\n\t\t\titems.push(null);\n\t\t}')).length
		);
	}

	@:pin('control') @:killer('M-KV-NOOPENER-INDEX-WRITE')
	public function testNoOpenerIndexWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapSink('for (i in 0...items.length) {\n\t\t\tsink.use(items[i]);\n\t\t\ti = 0;\n\t\t}')).length);
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-REBIND')
	public function testNoOpenerShadowedIndexNotFlagged(): Void {
		// The inner loop's `i` is a different binding, so the `items[i]` under it is not this loop's element.
		final body: String =
			'for (i in 0...items.length) {\n\t\t\tsink.use(items[i], i);\n\t\t\tfor (i in 0...2) sink.use(items[i]);\n\t\t}';
		Assert.equals(0, violations(wrapSink(body)).length);
		final rebound: String = 'for (i in 0...items.length) {\n\t\t\tsink.use(items[i], i);\n\t\t\tfinal items = sink.all();\n'
			+ '\t\t\tsink.use(items.length);\n\t\t}';
		Assert.equals(0, violations(wrapSink(rebound)).length);
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-CLOSURE') @:killer('M-KV-NOOPENER-BODY-GATES')
	public function testNoOpenerClosureReadNotFlagged(): Void {
		// A closure reads `items[i]` when it RUNS, the binder holds the element of the iteration that made
		// it: a slot written after the loop is seen by the one and not the other.
		Assert.equals(
			0, violations(wrapSink('for (i in 0...items.length) {\n\t\t\tsink.defer(() -> items[i]);\n\t\t\tsink.use(i);\n\t\t}')).length
		);
		final local: String = 'for (i in 0...items.length) {\n\t\t\tfunction get() return items[i];\n\t\t\tsink.defer(get, i);\n\t\t}';
		Assert.equals(0, violations(wrapSink(local)).length);
	}

	@:pin('control') @:killer('M-KV-NOOPENER-SELF-CALL')
	public function testNoOpenerSelfCallIsReportOnly(): Void {
		// A callee reached through the instance can replace `items[i]` after the binder was read, or grow
		// a field collection the key-value iterator would then follow.
		for (call in ['refresh(i)', 'this.refresh(i)', 'super.refresh(i)']) {
			final src: String = wrapSink('for (i in 0...items.length) {\n\t\t\t$call;\n\t\t\tsink.use(items[i]);\n\t\t}');
			final r: CheckRun = runAndExpectOne(src);
			Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length, call);
		}
	}

	public function testNoOpenerOtherReceiverCallRewritten(): Void {
		final text: String = fixedText(wrapSink('for (i in 0...items.length) sink.use(items[i], i);'));
		Assert.isTrue(text.indexOf('for (i => item in items) sink.use(item, i);') >= 0, text);
	}

	@:pin('control') @:killer('M-KV-NOOPENER-NON-ARRAY')
	public function testNoOpenerNonArrayNotFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f(items:Vector<Item>, sink:Sink):Void {\n\t\tfor (i in 0...items.length) sink.use(items[i], i);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNoOpenerUnresolvedIsReportOnly(): Void {
		assertFixRefused(
			'class C {\n\tfunction f(sink:Sink):Void {\n\t\tfinal items = sink.all();\n'
			+ '\t\tfor (i in 0...items.length) sink.use(items[i], i);\n\t}\n}'
		);
	}

	@:pin('control') @:killer('M-KV-NOOPENER-TAKEN-SCOPE')
	public function testNoOpenerBinderTakenInFunctionIsReportOnly(): Void {
		// The body never mentions `item`, but the parameter does: the binder would shadow it for the loop.
		final src: String = 'class C {\n\tfunction f(items:Array<Item>, item:Item, sink:Sink):Void {\n'
			+ '\t\tfor (i in 0...items.length) sink.use(items[i], i);\n\t}\n}';
		final r: CheckRun = runAndExpectOne(src);
		Assert.equals('this indexed loop reads items[i]; it can be a key-value loop over items', r.vs[0].message);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	@:pin('control') @:killer('M-KV-NOOPENER-TAKEN-MEMBER')
	public function testNoOpenerBinderTakenByFieldIsReportOnly(): Void {
		final src: String = 'class C {\n\tvar item:Item;\n\n\tfunction f(items:Array<Item>, sink:Sink):Void {\n'
			+ '\t\tfor (i in 0...items.length) sink.use(items[i], i);\n\t}\n}';
		assertFixRefused(src);
	}

	public function testNoOpenerInterpolatedIndexIsAnotherUse(): Void {
		final text: String = fixedText(wrapSink('for (i in 0...items.length) sink.log(\'$$i: $${items[i]}\');'));
		Assert.isTrue(text.indexOf('for (i => item in items) sink.log(\'$$i: $${item}\');') >= 0, text);
	}

	public function testNoOpenerRewritesEveryConditionalBranch(): Void {
		// Both branches of a `#if` region are in the tree, so each branch's `items[i]` is re-spelled and
		// whichever configuration compiles still reads the element.
		final body: String = 'for (i in 0...items.length) {\n\t\t\t#if debug\n\t\t\tsink.log(i, items[i]);\n\t\t\t#else\n'
			+ '\t\t\tsink.use(items[i]);\n\t\t\t#end\n\t\t}';
		final text: String = fixedText(wrapSink(body));
		Assert.isTrue(text.indexOf('sink.log(i, item);\n\t\t\t#else\n\t\t\tsink.use(item);') >= 0, text);
	}

	public function testNoOpenerHeaderMismatchNotFlagged(): Void {
		Assert.equals(0, violations(wrapSink('for (i in 1...items.length) sink.use(items[i], i);')).length);
		Assert.equals(0, violations(wrapSink('for (i in 0...other.length) sink.use(items[i], i);')).length);
	}

	public function testReportOnlyFindingsNameTheirReason(): Void {
		Assert.equals(
			ElementLoopRewrite.SELF_CALL_DECLINE,
			declineOf(wrapSink('for (i in 0...items.length) {\n\t\t\trefresh(i);\n\t\t\tsink.use(items[i]);\n\t\t}'))
		);
		Assert.equals(
			'no singular of `stuff` names the element',
			declineOf(
				'class C {\n\tfunction f(stuff:Array<Item>, sink:Sink):Void {\n\t\tfor (i in 0...stuff.length) sink.use(stuff[i], i);\n'
				+ '\t}\n}'
			)
		);
		Assert.equals(
			'the element name `item` is already spelled in the enclosing function',
			declineOf(
				'class C {\n\tfunction f(items:Array<Item>, item:Item, sink:Sink):Void {\n'
				+ '\t\tfor (i in 0...items.length) sink.use(items[i], i);\n\t}\n}'
			)
		);
		Assert.equals(
			'the element name `item` is declared as a member or a module-level value',
			declineOf(
				'class C {\n\tvar item:Item;\n\n\tfunction f(items:Array<Item>, sink:Sink):Void {\n'
				+ '\t\tfor (i in 0...items.length) sink.use(items[i], i);\n\t}\n}'
			)
		);
		Assert.equals(
			'the type of `items` is not resolved, so it is not provably an Array',
			declineOf(
				'class C {\n\tfunction f(sink:Sink):Void {\n\t\tfinal items = sink.all();\n'
				+ '\t\tfor (i in 0...items.length) sink.use(items[i], i);\n\t}\n}'
			)
		);
		Assert.equals(
			ElementLoopRewrite.COMMENT_DECLINE, declineOf(wrapSink('for (i in 0...items.length) sink.use(items[i /* x */], i);'))
		);
		Assert.equals(
			'the collection is not a declared `Array<E>` whose `E` the dropped declaration carries, so dropping it could change the '
			+ 'value binder\'s type',
			declineOf(wrapFn('for (i in 0...items.length) {\n\t\t\tfinal it:Dynamic = items[i];\n\t\t\tuse(it);\n\t\t}'))
		);
		Assert.equals(
			'a trailing comment on the dropped declaration\'s line would move onto the loop header',
			declineOf(wrapFn('for (i in 0...items.length) {\n\t\t\tfinal it:Item = items[i]; // the element\n\t\t\tuse(it);\n\t\t}'))
		);
		Assert.equals(
			ElementLoopRewrite.COMMENT_DECLINE,
			declineOf(wrapFn('for (i in 0...items.length) {\n\t\t\t// the element\n\t\t\tfinal it:Item = items[i];\n\t\t\tuse(it);\n\t\t}'))
		);
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-NESTED-BINDER')
	public function testNestedLoopsDerivingOneBinderAreReportOnly(): Void {
		// Each loop's checks read the original source, so both would be fixed in one pass and the inner
		// `val` would shadow the outer one: `for (i => val in vals) for (j => val in vals)`.
		final nested: String = 'for (i in 0...vals.length) for (j in 0...vals.length) sink.use(i, j, vals[i], vals[j]);';
		Assert.same([nestedDecline('val'), nestedDecline('val')], declines(withVals(nested)));
		// The leading underscore is dropped before singularizing, so `_vals` derives `val` too.
		final underscored: String = 'for (i in 0...vals.length) for (j in 0..._vals.length) sink.use(i, j, vals[i], _vals[j]);';
		Assert.same([nestedDecline('val'), nestedDecline('val')], declines(withVals(underscored)));
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-NESTED-BINDER')
	public function testNestedBinderClashAcrossTheTwoRules(): Void {
		// The outer loop is this rule's (`i` read on its own), the inner one prefer-value-loop's; both derive `key`.
		final src: String = withVals('for (i in 0...keys.length) for (j in 0...keys.length) sink.use(i, keys[i], keys[j]);');
		Assert.same([nestedDecline('key')], declines(src));
		final value: PreferValueLoop = new PreferValueLoop();
		final vs: Array<Violation> = value.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, value.fix(src, vs, new HaxeQueryPlugin()).length);
		Assert.equals(nestedDecline('key'), vs[0].declineReason);
	}

	public function testSiblingLoopsDerivingOneBinderAreBothFixed(): Void {
		final text: String = fixedAll(
			wrapSink('for (i in 0...items.length) sink.use(i, items[i]);\n\t\tfor (j in 0...items.length) sink.log(j, items[j]);')
		);
		Assert.isTrue(
			text.indexOf('for (i => item in items) sink.use(i, item);\n\t\tfor (j => item in items) sink.log(j, item);') >= 0, text
		);
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-TYPE-CALLEE')
	public function testStaticCallOnATypeIsReportOnly(): Void {
		// `Main.grow()` can push onto a static collection the key-value iterator would then follow.
		for (call in ['Main.grow()', 'pkg.Main.grow()']) {
			final src: String = wrapSink('for (i in 0...items.length) {\n\t\t\tsink.use(i, items[i]);\n\t\t\t$call;\n\t\t}');
			Assert.equals(ElementLoopRewrite.SELF_CALL_DECLINE, declineOf(src), call);
		}
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-NEW-EXPR')
	public function testConstructorCallIsReportOnly(): Void {
		final src: String = wrapSink('for (i in 0...items.length) {\n\t\t\tsink.use(i, items[i]);\n\t\t\tnew Grower();\n\t\t}');
		Assert.equals(ElementLoopRewrite.SELF_CALL_DECLINE, declineOf(src));
	}

	@:pin('control') @:killer('M-KV-OPENER-SELF-CALL')
	public function testOpenerSelfCallIsReportOnly(): Void {
		// The binder is read where the declaration was, but `grow()` can still extend the collection,
		// which the key-value iterator follows and the once-read range bound does not.
		final src: String = wrapSink(
			'for (i in 0...items.length) {\n\t\t\tfinal it:Item = items[i];\n\t\t\tsink.use(i, it);\n\t\t\tgrow();\n\t\t}'
		);
		Assert.equals(ElementLoopRewrite.SELF_CALL_DECLINE, declineOf(src));
	}

	@:pin('control') @:killer('M-ELEMENT-LOOP-REBIND')
	public function testThisQualifiedCollectionNotFlagged(): Void {
		// `this.items[i] = …` writes the collection through a path the stable-collection scan does not
		// follow; the name-slot gate refuses it, which is what keeps a `this.X` body out of both rewrites.
		final write: String = 'for (i in 0...items.length) {\n\t\t\tthis.items[i] = sink.make(i);\n\t\t\tsink.use(i, items[i]);\n\t\t}';
		Assert.equals(0, violations(wrapSink(write)).length);
		final push: String = 'for (i in 0...items.length) {\n\t\t\tsink.use(i, items[i]);\n\t\t\tthis.items.push(null);\n\t\t}';
		Assert.equals(0, violations(wrapSink(push)).length);
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
		final r: CheckRun = runAndExpectOne(src);
		switch CanonicalEdit.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0, 'expected $present in $text');
				Assert.isTrue(text.indexOf(absent) == -1, 'expected no $absent in $text');
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function assertFixRefused(src: String): Void {
		final r: CheckRun = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
	}

	private function runAndExpectOne(src: String): CheckRun {
		final check: PreferKeyValueLoop = new PreferKeyValueLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		return { check: check, vs: vs };
	}

	/** The shape `GridScale.set_basePoints` carries in the TM corpus: two field arrays, one bound, no opener. */
	private function fieldSource(): String {
		return 'class C {\n\tfinal _points:Array<Item> = [];\n\tfinal _pointsScale:Array<Item> = [];\n\n'
			+ '\tfunction set(value:Array<Pos>):Void {\n\t\tfor (i in 0..._points.length) {\n\t\t\t_points[i].pos = value[i].clone();\n'
			+ '\t\t\t_pointsScale[i].pos = value[i].clone();\n\t\t}\n\t}\n}';
	}

	private function wrapSink(body: String): String {
		return 'class C {\n\tfunction f(items:Array<Item>, sink:Sink):Void {\n\t\t$body\n\t}\n}';
	}

	/** The canonical text after this rule's fix, expecting exactly one finding. */
	private function fixedText(src: String): String {
		final r: CheckRun = runAndExpectOne(src);
		return switch CanonicalEdit.canonicalize(src, r.check.fix(src, r.vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): 'fix canonicalize Err: $message';
		};
	}

	/** The `declineReason` the fix writes on the single finding of `src`, asserting the fix withheld its edits. */
	private function declineOf(src: String): Null<String> {
		final r: CheckRun = runAndExpectOne(src);
		Assert.equals(0, r.check.fix(src, r.vs, new HaxeQueryPlugin()).length);
		return r.vs.length == 1 ? r.vs[0].declineReason : null;
	}

	/** The `declineReason` of every finding of `src`, in order, asserting the fix withheld every edit. */
	private function declines(src: String): Array<Null<String>> {
		final check: PreferKeyValueLoop = new PreferKeyValueLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
		return [for (v in vs) v.declineReason];
	}

	/** A class with a `_vals` field around a method taking `vals`, `keys` and a sink. */
	private function withVals(body: String): String {
		return
			'class C {\n\tvar _vals:Array<Int> = [];\n\n\tfunction f(vals:Array<Int>, keys:Array<Int>, sink:Sink):Void {\n\t\t$body\n\t}\n}';
	}

	/** The canonical text after this rule's fix over every finding of `src`. */
	private function fixedAll(src: String): String {
		final check: PreferKeyValueLoop = new PreferKeyValueLoop();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return switch CanonicalEdit.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): 'fix canonicalize Err: $message';
		};
	}

	private static inline function nestedDecline(name: String): String {
		return 'an enclosing or nested indexed loop derives the same element name `$name`';
	}

}

/** A run of the check over one source that reported exactly one finding, kept for the fix call. */
private typedef CheckRun = {
	var check: PreferKeyValueLoop;
	var vs: Array<Violation>;
}
