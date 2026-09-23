package unit.check;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedLoopBinder;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `unused-loop-binder` check: a `for` binder the body never reads becomes `_`, and an unread key
 * over an `Array` / `List` is dropped. Every refusal is paired with the finding it would otherwise be:
 * most fixtures SHADOW the binder in the body, so the resolver alone would call it unread and only the
 * gate under test refuses.
 */
@:nullSafety(Strict) class UnusedLoopBinderCheckTest extends Test {

	/** The parameter list every fixture's method declares. */
	private static inline final PARAMS: String = 'xs:Array<Int>, m:Map<String, Int>, l:List<Int>';

	public function testUnreadRangeBinderRenamed(): Void {
		final src: String = wrap('for (i in 0...3) g();');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('unused-loop-binder', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('loop binder \'i\' is never read; rename it to _', vs[0].message);
		Assert.equals(wrap('for (_ in 0...3) g();'), applyFix(src));
	}

	public function testReadBinderNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) g(x);')).length);
		Assert.equals(0, violations(wrap('for (x in xs) x = 1;')).length);
		Assert.equals(0, violations(wrap('for (i in 0...xs.length) g(xs[i]);')).length);
	}

	public function testComprehensionBinderRenamed(): Void {
		Assert.equals(wrap('final ys:Array<Int> = [for (_ in 0...3) 1];'), applyFix(wrap('final ys:Array<Int> = [for (j in 0...3) 1];')));
	}

	public function testNestedUnreadBindersBothRenamed(): Void {
		Assert.equals(wrap('for (_ in xs) for (_ in xs) g();'), applyFix(wrap('for (a in xs) for (b in xs) g();')));
	}

	@:pin('control') @:killer('M-ULB-VALUE-ITERATION-NEVER')
	public function testUnreadKeyOverArrayOrListDropped(): Void {
		Assert.equals(wrap('for (v in xs) g(v);'), applyFix(wrap('for (k => v in xs) g(v);')));
		Assert.equals(wrap('for (v in l) g(v);'), applyFix(wrap('for (k => v in l) g(v);')));
		final vs: Array<Violation> = violations(wrap('for (k => v in xs) g(v);'));
		Assert.equals(1, vs.length);
		if (vs.length == 1) Assert.equals('key binder \'k\' is never read; iterate the values alone: for (v in …)', vs[0].message);
	}

	/**
	 * A `Map`'s `keyValueIterator` re-reads each value by key: an entry the body removes reads `null`
	 * there and the stale value through `iterator()`, so the key is spelled `_`, never dropped. An
	 * iterable of unknown type is the same refusal.
	 */
	@:pin('control') @:killer('M-ULB-VALUE-ITERATION-ALWAYS')
	public function testUnreadKeyOverMapOrUnknownRenamed(): Void {
		Assert.equals(wrap('for (_ => v in m) { m.remove(\'a\'); g(v); }'), applyFix(wrap('for (k => v in m) { m.remove(\'a\'); g(v); }')));
		Assert.equals(wrap('for (_ => v in f()) g(v);'), applyFix(wrap('for (k => v in f()) g(v);')));
	}

	@:pin('control') @:killer('M-ULB-VALUE-ITERATION-SHADOW-BLIND')
	public function testProjectListShadowNotDropped(): Void {
		final own: String =
			'class List<T> {\n\tpublic function new() {}\n\tpublic function keyValueIterator():KeyValueIterator<Int, T> return null;\n}';
		final src: String = wrap('for (k => v in l) g(v);');
		final check: Check = rule();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }, { file: 'List.hx', source: own }], plugin);
		Assert.equals(1, vs.length);
		Assert.equals(wrap('for (_ => v in l) g(v);'), CheckFixture.applyEdits(src, check.fix(src, vs, plugin)));
	}

	public function testUnreadValueRenamed(): Void {
		Assert.equals(wrap('for (k => _ in m) g(k);'), applyFix(wrap('for (k => v in m) g(k);')));
	}

	public function testBothUnreadFollowTheKeyProof(): Void {
		Assert.equals(wrap('for (_ in xs) g();'), applyFix(wrap('for (k => v in xs) g();')));
		Assert.equals(wrap('for (_ => _ in m) g();'), applyFix(wrap('for (k => v in m) g();')));
	}

	public function testCommentInDroppedKeyFallsBackToWildcard(): Void {
		Assert.equals(wrap('for (_ /* k */ => v in xs) g(v);'), applyFix(wrap('for (k /* k */ => v in xs) g(v);')));
	}

	@:pin('control') @:killer('M-ULB-WILDCARD-KEY-ADMITTED')
	public function testWildcardBinderNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (_ in xs) g();')).length);
		// A discarded key belongs to `redundant-map-iter-key`; a read value leaves nothing for this rule.
		Assert.equals(0, violations(wrap('for (_ => v in m) g(v);')).length);
	}

	/** A discarded key is `redundant-map-iter-key`'s, but its unread VALUE is this rule's — renamed, never dropped here. */
	@:pin('control') @:killer('M-ULB-WILDCARD-KEY-VALUE-BLIND')
	public function testWildcardKeyUnreadValueRenamed(): Void {
		Assert.equals(wrap('for (_ => _ in m) g();'), applyFix(wrap('for (_ => v in m) g();')));
		Assert.equals(
			wrap('final ys:Array<Int> = [for (_ => _ in xs) 1];'), applyFix(wrap('final ys:Array<Int> = [for (_ => v in xs) 1];'))
		);
	}

	/**
	 * A value loop over a LOCAL re-reads the local each step, while the key-value iterator captured it
	 * once: a reassignment in the body, or in a closure the body calls, makes the two diverge. A field
	 * is read once into a temporary by both, so its key still goes.
	 */
	@:pin('control') @:killer('M-ULB-REASSIGNED-LOCAL-BLIND')
	public function testReassignedLocalKeyRenamedNotDropped(): Void {
		Assert.equals(wrap('for (_ => v in xs) { xs = [7, 8]; g(v); }'), applyFix(wrap('for (k => v in xs) { xs = [7, 8]; g(v); }')));
		Assert.equals(
			wrap('final re = () -> xs = [7]; for (_ => v in xs) { re(); g(v); }'),
			applyFix(wrap('final re = () -> xs = [7]; for (k => v in xs) { re(); g(v); }'))
		);
		final field: String = 'class C {\n\tvar zs:Array<Int> = [];\n\tfunction f():Void {\n\t\tfor (k => v in zs) g(v);\n\t}\n}';
		Assert.equals('class C {\n\tvar zs:Array<Int> = [];\n\tfunction f():Void {\n\t\tfor (v in zs) g(v);\n\t}\n}', applyFix(field));
	}

	/** `import haxe.ds.StringMap as List;` makes `List` a map: the std-name proof must see through the file's imports. */
	@:pin('control') @:killer('M-ULB-IMPORT-ALIAS-BLIND')
	public function testImportAliasedListNotDropped(): Void {
		for (alias in ['import haxe.ds.StringMap as List;', 'import haxe.ds.StringMap in List;']) {
			final src: String = '$alias\n\n' + wrap('for (k => v in l) g(v);');
			Assert.equals('$alias\n\n' + wrap('for (_ => v in l) g(v);'), applyFix(src));
		}
	}

	@:pin('control') @:killer('M-ULB-IMPORT-REBIND-BLIND')
	public function testImportOfAnotherListNotDropped(): Void {
		Assert.equals(
			'import other.List;\n\n' + wrap('for (_ => v in l) g(v);'),
			applyFix('import other.List;\n\n' + wrap('for (k => v in l) g(v);'))
		);
		Assert.equals(
			'import haxe.ds.List;\n\n' + wrap('for (v in l) g(v);'), applyFix('import haxe.ds.List;\n\n' + wrap('for (k => v in l) g(v);'))
		);
	}

	/** An inherited field `_` is a read the resolver cannot bind; renaming a binder to `_` would capture it. */
	@:pin('control') @:killer('M-ULB-UNBOUND-WILDCARD-ADMITTED')
	public function testUnboundOuterWildcardRefuses(): Void {
		final src: String = 'class Base {\n\tpublic var _:Int = 7;\n}\n\nclass C extends Base {\n\tfunction f(xs:Array<Int>):Void {\n'
			+ '\t\tfor (i in xs) trace(_);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	/** A `case _:` wildcard pattern is unbound too, but it reads nothing. */
	@:pin('control') @:killer('M-ULB-PATTERN-WILDCARD-UNEXEMPT')
	public function testCaseWildcardInBodyStillRenamed(): Void {
		Assert.equals(
			wrap('for (_ in xs) switch h() {\n\t\t\tcase 1: g();\n\t\t\tcase _:\n\t\t}'),
			applyFix(wrap('for (i in xs) switch h() {\n\t\t\tcase 1: g();\n\t\t\tcase _:\n\t\t}'))
		);
	}

	@:pin('control') @:killer('M-ULB-FIELD-NAME-AS-READ')
	public function testObjectLiteralFieldNameIsNoRead(): Void {
		Assert.equals(wrap('for (_ in xs) g({ i: 1 });'), applyFix(wrap('for (i in xs) g({ i: 1 });')));
	}

	/** `_` is a readable binder: renaming `i` would make the inner `trace(_)` read the new binder. */
	@:pin('control') @:killer('M-ULB-OUTER-WILDCARD-BLIND')
	public function testOuterWildcardReadRefuses(): Void {
		final vs: Array<Violation> = violations(wrap('for (_ in xs) for (i in xs) trace(_);'));
		Assert.equals(0, vs.length);
	}

	@:pin('control') @:killer('M-ULB-SHADOW-COUNTED-AS-READ')
	public function testShadowInBodyWithoutReadFlagged(): Void {
		Assert.equals(wrap('for (_ in xs) { final i:Int = 3; g(i); }'), applyFix(wrap('for (i in xs) { final i:Int = 3; g(i); }')));
		Assert.equals(wrap('for (_ in xs) for (i in xs) g(i);'), applyFix(wrap('for (i in xs) for (i in xs) g(i);')));
	}

	@:pin('control') @:killer('M-ULB-OUTER-BINDING-AS-SHADOW')
	public function testShadowAfterRealReadNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (i in xs) { g(i); final i:Int = 3; g(i); }')).length);
	}

	@:pin('control') @:killer('M-ULB-INTERP-BLIND')
	public function testSimpleInterpolationRefuses(): Void {
		Assert.equals(0, violations(wrap('for (i in xs) g(\'$$i\');')).length);
		Assert.equals(0, violations(wrap('for (i in xs) { final i:Int = 3; g(\'$$i\'); }')).length);
	}

	@:pin('control') @:killer('M-ULB-INTERP-LITERAL-BLIND')
	public function testBracedInterpolationRefuses(): Void {
		Assert.equals(0, violations(wrap('for (i in xs) { final i:Int = 3; g(\'$${i}\'); }')).length);
	}

	@:pin('control') @:killer('M-ULB-OPAQUE-COND-BLIND')
	public function testOpaqueCondRegionRefuses(): Void {
		Assert.equals(0, violations(wrap('for (i in xs) { #if js if (c) { g(i); } else #end h(); }')).length);
	}

	@:pin('control') @:killer('M-ULB-COVERAGE-BLIND')
	public function testMacroReificationRefuses(): Void {
		// A splice re-opens ordinary code, so the resolver sees that read on its own.
		Assert.equals(0, violations(wrap('for (i in xs) g(macro $$v{i});')).length);
		// A quoted name projects no hit at all; only the coverage test refuses it.
		Assert.equals(0, violations(wrap('for (i in xs) g(macro trace(i));')).length);
	}

	@:pin('control') @:killer('M-ULB-NATIVE-BLIND')
	public function testNativeCodeRefuses(): Void {
		Assert.equals(0, violations(wrap('for (i in xs) js.Syntax.code(\'console.log(i)\');')).length);
		Assert.equals(0, violations(wrap('for (i in xs) untyped __js__(\'console.log(i)\');')).length);
	}

	@:pin('control') @:killer('M-ULB-UNTYPED-BLIND')
	public function testUntypedMentionRefuses(): Void {
		Assert.equals(0, violations(wrap('for (i in xs) { final i:Int = 3; untyped g(i); }')).length);
	}

	/** A closure mentioning the name is a read, even one whose own parameter shadows the binder. */
	@:pin('control') @:killer('M-ULB-CLOSURE-BLIND')
	public function testClosureMentionCountsAsRead(): Void {
		Assert.equals(0, violations(wrap('for (i in xs) xs.map(i -> i + 1);')).length);
		Assert.equals(0, violations(wrap('for (i in xs) h(() -> i);')).length);
	}

	/** `dead-binder-counter-loop` rewrites the counter and the dead binder together, so it owns the loop. */
	@:pin('control') @:killer('M-ULB-COUNTER-CLAIM-BLIND')
	public function testCounterLoopLeftToItsRule(): Void {
		final src: String = wrap('var c = 0; for (x in xs) { g(); c++; }');
		Assert.equals(0, violations(src).length);
		final counter: Null<Check> = Linter.byId('dead-binder-counter-loop');
		Assert.equals(1, counter == null ? 0 : counter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()).length);
		// Read after the loop, the counter is no counter loop: the dead binder is this rule's again.
		Assert.equals(1, violations(wrap('var c = 0; for (x in xs) { g(); c++; } h(c);')).length);
	}

	public function testDecoyCommentBeforeBinderNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for /* i */ (i in xs) g();')).length);
	}

	public function testRegisteredInBuiltinsAndOffByDefault(): Void {
		final check: Null<Check> = Linter.byId('unused-loop-binder');
		Assert.notNull(check);
		Assert.isTrue(check is DefaultOff);
		Assert.isTrue(check is UnusedLoopBinder);
	}

	private function rule(): Check {
		return new UnusedLoopBinder();
	}

	private function violations(src: String): Array<Violation> {
		return rule().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		return CheckFixture.fixedSource(rule(), src);
	}

	private static function wrap(body: String): String {
		return 'class C {\n\tfunction f($PARAMS):Void {\n\t\t$body\n\t}\n}';
	}

}
