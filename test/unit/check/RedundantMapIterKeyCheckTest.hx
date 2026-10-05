package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantMapIterKey;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `redundant-map-iter-key` check: a key-value `for` loop that discards its key
 * (`for (_ => v in m)`) is flagged `Info` and the `_ => ` prefix is dropped. A
 * value-only `for (_ in m)` and a used key (`for (k => v in m)`) are not flagged.
 */
class RedundantMapIterKeyCheckTest extends Test {

	public function testDiscardedKeyFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tfor (_ => v in m) g(v);\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-map-iter-key', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testValueOnlyLoopNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfor (_ in m) g();\n\t}\n}').length);
	}

	public function testUsedKeyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfor (k => v in m) g(v);\n\t}\n}').length);
	}

	public function testPlainValueLoopNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfor (v in m) g(v);\n\t}\n}').length);
	}

	public function testFixDropsKeyPrefix(): Void {
		final src: String = 'class C {\n\tfunction f(m:Array<Int>):Void {\n\t\tfor (_ => v in m) g(v);\n\t}\n}';
		final check: RedundantMapIterKey = new RedundantMapIterKey();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		Assert.equals(1, edits.length);
		Assert.equals('', edits[0].text);
		final cut: Span = edits[0].span;
		Assert.equals('_ => ', src.substring(cut.from, cut.to));
		final applied: String = src.substring(0, cut.from) + edits[0].text + src.substring(cut.to);
		Assert.isTrue(applied.indexOf('for (v in m)') >= 0);
	}

	/**
	 * A `Map`'s `keyValueIterator` re-reads each value by key, so once the body removes an entry it
	 * reads `null` where `iterator()` still yields the stale value: the drop is not behaviour-preserving
	 * over a map, and neither over an iterable of unknown type. The finding stays, report-only, and says why.
	 */
	@:pin('control') @:killer('M-MAPITERKEY-UNPROVEN-DROPPED')
	public function testFixDeclinedOverMapAndUnknownIterable(): Void {
		for (param in ['m:Map<String, Int>', 'm']) {
			final src: String = 'class C {\n\tfunction f($param):Void {\n\t\tfor (_ => v in m) { m.remove("a"); g(v); }\n\t}\n}';
			final check: RedundantMapIterKey = new RedundantMapIterKey();
			final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
			Assert.equals(1, vs.length);
			Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
			Assert.notNull(vs[0].declineReason);
		}
	}

	/** The shared proof refuses a reassigned local and an aliased `List` here exactly as in `unused-loop-binder`. */
	@:pin('control') @:killer('M-ULB-REASSIGNED-LOCAL-BLIND')
	public function testFixDeclinedOverReassignedLocal(): Void {
		assertDeclined('class C {\n\tfunction f(m:Array<Int>):Void {\n\t\tfor (_ => v in m) { m = [7, 8]; g(v); }\n\t}\n}');
	}

	@:pin('control') @:killer('M-ULB-IMPORT-ALIAS-BLIND')
	public function testFixDeclinedOverAliasedList(): Void {
		assertDeclined(
			'import haxe.ds.StringMap as List;\n\nclass C {\n\tfunction f(m:List<Int>):Void {\n\t\tfor (_ => v in m) g(v);\n\t}\n}'
		);
	}

	/**
	 * Only a proved drop is recommended; elsewhere the finding describes the discarded key without prescribing the
	 * unsafe form — over an iterable of unknown type, and over a map, whose drop the report cannot prove (only the
	 * fix asks the reach).
	 */
	@:pin('control') @:killer('M-MAPITERKEY-MESSAGE-ALWAYS-PROVEN')
	public function testMessageRecommendsTheDropOnlyWhenProved(): Void {
		final proved: Array<Violation> = violations('class C {\n\tfunction f(m:Array<Int>):Void {\n\t\tfor (_ => v in m) g(v);\n\t}\n}');
		Assert.equals(1, proved.length);
		if (proved.length == 1) Assert.isTrue(proved[0].message.indexOf('for (v in') >= 0);
		for (param in ['m:Map<String, Int>', 'm']) {
			final unproved: Array<Violation> = violations('class C {\n\tfunction f($param):Void {\n\t\tfor (_ => v in m) g(v);\n\t}\n}');
			Assert.equals(1, unproved.length);
			if (unproved.length == 1) Assert.isTrue(unproved[0].message.indexOf('for (v in') < 0, param);
		}
	}

	/**
	 * A LOCAL map built in place and never handed on, which the loop body neither names nor can reach through another
	 * name, iterates the same values in the same order through `iterator()` (measured on `--interp`, js and hxcpp,
	 * docs/decisions.md): `MemberReach` proves it unchanged and the key goes, a map literal and `new Map()` alike.
	 */
	@:pin('control') @:killer('M-MAPITER-KEYED-NEVER') @:killer('M-TOUCH-NEW-MAP-NOT-FRESH')
	public function testFixDropsKeyOverALocalMapTheLoopLeavesUnchanged(): Void {
		for (init in ['[\'a\' => 1]', 'new Map()']) {
			final src: String = localMap(init, 'g(v);');
			Assert.equals(StringTools.replace(src, 'for (_ => v in m)', 'for (v in m)'), fixed(src), init);
		}
	}

	/**
	 * A body that removes an entry, or replaces the value of one (`m[k] = v`, `m.set(k, v)`), makes the key-value
	 * iterator read what the value iterator does not; one that empties the map through a function holding it changes it
	 * through another name. Each keeps its key, and the finding says what the reach found.
	 */
	@:pin('control') @:killer('M-MAPITER-REACH-SKIPPED') @:killer('M-REACH-LOCAL-TOUCH-BLIND')
	public function testFixDeclinedWhereTheBodyChangesALocalMap(): Void {
		for (body in ['m.remove(\'a\'); g(v);', 'm[\'a\'] = 2; g(v);', 'm.set(\'a\', 2); g(v);'])
			assertDeclined(localMap('[\'a\' => 1]', body));
		final wiped: String = 'class C {\n\tfunction f():Void {\n\t\tfinal m:Map<String, Int> = [\'a\' => 1];\n'
			+ '\t\tfinal wipe = () -> m.clear();\n\t\tfor (_ => v in m) { wipe(); g(v); }\n\t}\n\n\tfunction g(v:Int):Void {}\n}';
		assertDeclined(wiped);
	}

	/** A map local the body reassigns is refused by the same gate as any other local (`NominalTypes.valueIterationProvable`). */
	public function testFixDeclinedOverAReassignedLocalMap(): Void {
		assertDeclined(StringTools.replace(localMap('[\'a\' => 1]', 'm = new Map(); g(v);'), 'final m:', 'var m:'));
	}

	/**
	 * A project type that IS the map name, or that extends a class a `Map` value may be, may iterate anything: a `Map`
	 * of its own rebinds the name, and a subclass of `IntMap` may override `iterator()` and reach a `Map`-typed value
	 * through `@:from`. Either keeps the key.
	 */
	@:pin('control') @:killer('M-MAPITER-SUBTYPE-VETO-OFF')
	public function testFixDeclinedOverANonStandardMap(): Void {
		final own: String = 'class Map<K, V> {\n\tpublic function new() {}\n}';
		final sub: String = 'import haxe.ds.IntMap;\n\nclass Sub<T> extends IntMap<T> {}';
		for (other in [own, sub]) {
			final src: String = localMap('new Map()', 'g(v);');
			final check: RedundantMapIterKey = new RedundantMapIterKey();
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }, { file: 'Other.hx', source: other }], plugin);
			Assert.equals(1, vs.length);
			Assert.equals(0, check.fix(src, vs, plugin).length, other);
		}
	}

	/**
	 * Only a class a `Map` value may BE vetoes it: a library's subclass of `BalancedTree` (tink_macro's `TypeMap`, met
	 * on TM) is no map a `Map` holds, so the key still goes.
	 */
	public function testASubclassOfAClassNoMapHoldsVetoesNothing(): Void {
		final src: String = localMap('new Map()', 'g(v);');
		final tree: String = 'class Tree<K, V> extends haxe.ds.BalancedTree<K, V> {}';
		final check: RedundantMapIterKey = new RedundantMapIterKey();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }, { file: 'Tree.hx', source: tree }], plugin);
		Assert.equals(
			StringTools.replace(src, 'for (_ => v in m)', 'for (v in m)'), CheckFixture.applyEdits(src, check.fix(src, vs, plugin))
		);
	}

	/**
	 * A FIELD map is asked of every function the project holds that may touch it; a run that declared no project roots
	 * cannot say none of them is out of sight, so the key stays and the note says why.
	 */
	public function testFixDeclinedOverAFieldMapTheReachCannotSee(): Void {
		final src: String = 'class C {\n\tvar m:Map<String, Int> = [];\n\n\tfunction f():Void {\n\t\tfor (_ => v in m) g(v);\n\t}\n\n'
			+ '\tfunction g(v:Int):Void {}\n}';
		final check: RedundantMapIterKey = new RedundantMapIterKey();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
		if (vs.length == 1) Assert.isTrue((vs[0].declineReason ?? '').indexOf('project roots') >= 0, vs[0].declineReason);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-map-iter-key'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-map-iter-key'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { for (_ => v in ').length);
	}

	public function testNestedDiscardedKeyLoopsBothFlagged(): Void {
		Assert.equals(2, violations('class C {\n\tfunction f():Void {\n\t\tfor (_ => v in m) for (_ => w in v) g(w);\n\t}\n}').length);
	}

	public function testCommentParenDecoyNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tfor /*(*/ (_ => v in m) g(v);\n\t}\n}').length);
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantMapIterKey().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** A class whose method declares the local map `m` initialised by `init` and runs `body` in a discarded-key loop over it. */
	private static function localMap(init: String, body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tfinal m:Map<String, Int> = $init;\n\t\tfor (_ => v in m) { $body }\n\t}\n\n'
			+ '\tfunction g(v:Int):Void {}\n}';
	}

	private function fixed(src: String): String {
		final check: RedundantMapIterKey = new RedundantMapIterKey();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return CheckFixture.applyEdits(src, check.fix(src, vs, new HaxeQueryPlugin()));
	}

	private function assertDeclined(src: String): Void {
		final check: RedundantMapIterKey = new RedundantMapIterKey();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length, src);
		if (vs.length == 1) Assert.notNull(vs[0].declineReason);
	}

}
