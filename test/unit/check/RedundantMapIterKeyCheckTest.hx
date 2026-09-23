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

	/** Only a proved drop is recommended; elsewhere the finding describes the discarded key without prescribing the unsafe form. */
	@:pin('control') @:killer('M-MAPITERKEY-MESSAGE-ALWAYS-PROVEN')
	public function testMessageRecommendsTheDropOnlyWhenProved(): Void {
		final proved: Array<Violation> = violations('class C {\n\tfunction f(m:Array<Int>):Void {\n\t\tfor (_ => v in m) g(v);\n\t}\n}');
		final unproved: Array<Violation> =
			violations('class C {\n\tfunction f(m:Map<String, Int>):Void {\n\t\tfor (_ => v in m) g(v);\n\t}\n}');
		Assert.equals(1, proved.length);
		Assert.equals(1, unproved.length);
		if (proved.length != 1 || unproved.length != 1) return;
		Assert.isTrue(proved[0].message.indexOf('for (v in') >= 0);
		Assert.isTrue(unproved[0].message.indexOf('for (v in') < 0);
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

	private function assertDeclined(src: String): Void {
		final check: RedundantMapIterKey = new RedundantMapIterKey();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

}
