package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferIndexAccess;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-index-access` check: a `Map`-abstract `m.get(k)` / `m.set(k, v)` call is
 * flagged `Info` and rewritten to `m[k]` / `m[k] = v`. The receiver type is load-bearing —
 * a `StringMap` / `IntMap` / unresolved receiver is a safe miss (only the `Map` abstract has
 * `@:arrayAccess`), while a `Null<Map<…>>` wrapper is flagged. The `set` rewrite lands only
 * in statement position; a `set` used as an expression is flagged but not fixed. Wrong arity
 * (`get(k, d)` / `set(k)`) is left alone.
 */
class PreferIndexAccessCheckTest extends Test {

	public function testGetFlagged(): Void {
		final vs: Array<Violation> = violations(src('var m:Map<String, String> = [];', 'var v = m.get("a");'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-index-access', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('read a map value with map[key] instead of map.get(key)', vs[0].message);
	}

	public function testSetFlagged(): Void {
		final vs: Array<Violation> = violations(src('var m:Map<String, String> = [];', 'm.set("a", "b");'));
		Assert.equals(1, vs.length);
		Assert.equals('set a map value with map[key] = value instead of map.set(key, value)', vs[0].message);
	}

	public function testGetFix(): Void {
		final fixed: String = applyFix(src('var m:Map<String, String> = [];', 'var v = m.get("a");'));
		Assert.isTrue(fixed.indexOf('var v = m["a"];') != -1);
		Assert.equals(-1, fixed.indexOf('m.get'));
	}

	public function testSetFixInStatementPosition(): Void {
		final fixed: String = applyFix(src('var m:Map<String, String> = [];', 'm.set("a", "b");'));
		Assert.isTrue(fixed.indexOf('m["a"] = "b";') != -1);
		Assert.equals(-1, fixed.indexOf('m.set'));
	}

	public function testGetFixInDerefPosition(): Void {
		final fixed: String = applyFix(src('var m:Map<String, String> = [];', 'var n = m.get("a").length;'));
		Assert.isTrue(fixed.indexOf('m["a"].length') != -1);
	}

	public function testSetNotFixedInExpressionPosition(): Void {
		final source: String = src('var m:Map<String, String> = [];', 'var r = m.set("a", "b");');
		Assert.equals(1, violations(source).length);
		Assert.equals(source, applyFix(source));
	}

	public function testStringMapNotFlagged(): Void {
		Assert.equals(0, violations(src('var m:StringMap<String, String> = null;', 'm.set("a", "b");')).length);
	}

	public function testIntMapGetNotFlagged(): Void {
		Assert.equals(0, violations(src('var m:IntMap<String> = null;', 'var v = m.get(0);')).length);
	}

	public function testUnresolvedReceiverNotFlagged(): Void {
		Assert.equals(0, violations(src('var m = makeMap();', 'var v = m.get("a");')).length);
	}

	public function testNullMapReceiverFlagged(): Void {
		Assert.equals(1, violations(src('var m:Null<Map<String, String>> = null;', 'var v = m.get("a");')).length);
	}

	public function testWrongArityGetNotFlagged(): Void {
		Assert.equals(0, violations(src('var m:Map<String, String> = [];', 'var v = m.get("a", "b");')).length);
	}

	public function testWrongAritySetNotFlagged(): Void {
		Assert.equals(0, violations(src('var m:Map<String, String> = [];', 'm.set("a");')).length);
	}

	public function testQualifiedReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfinal m:Map<String, String> = [];\n\tfunction f():Void {\n\t\tvar v = this.m.get("a");\n\t}\n}').length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-index-access'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-index-access'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testUnbracedBranchSetFixed(): Void {
		// An unbraced control-flow branch body is still an ExprStmt (statement position), so the
		// set fix DOES fire there — pinned to a valid `if (true) m[k] = v;` rewrite.
		final source: String = src('var m:Map<String, String> = [];', 'if (true) m.set("a", "b");');
		Assert.equals(1, violations(source).length);
		final fixed: String = applyFix(source);
		Assert.isTrue(fixed.indexOf('if (true) m["a"] = "b";') != -1);
		Assert.equals(-1, fixed.indexOf('m.set'));
	}

	public function testFragileNullGuardKeyNotFlagged(): Void {
		// The key is a null-guard ternary whose fallback is a field access on a for-loop
		// iterator (an unbound monomorph); under active @:nullSafety, `m[k]` types the key in
		// VALUE mode and would flip the fallback's inferred constraint to Null<…> — skipped.
		final source: String = '@:nullSafety class C {\n\tfunction f(it:Iter):Void {\n\t\tfinal m:Map<String, Int> = [];\n\t\tfor (row in it) {\n'
			+ '\t\t\tvar v = m.get(row.a != null ? row.a : row.b);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testFragileCoalesceKeyNotFlagged(): Void {
		// Same fragility with the null guard already spelled `??` in the key.
		final source: String = '@:nullSafety class C {\n\tfunction f(it:Iter):Void {\n\t\tfinal m:Map<String, Int> = [];\n\t\tfor (row in it) {\n'
			+ '\t\t\tvar v = m.get(row.a ?? row.b);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testNullGuardKeyWithoutNullSafetyStillFlagged(): Void {
		// No @:nullSafety anywhere — the flipped binding still compiles, so convert.
		final source: String = 'class C {\n\tfunction f(it:Iter):Void {\n\t\tfinal m:Map<String, Int> = [];\n\t\tfor (row in it) {\n'
			+ '\t\t\tvar v = m.get(row.a != null ? row.a : row.b);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(source).length);
	}


	public function testClosedNullGuardKeyUnderNullSafetyStillFlagged(): Void {
		// Bare-identifier ternary operands are not inference-fragile — still converts.
		final source: String = '@:nullSafety class C {\n\tfunction f(a:Null<String>, b:String):Void {\n\t\tfinal m:Map<String, Int> = [];\n'
			+ '\t\tvar v = m.get(a != null ? a : b);\n\t}\n}';
		Assert.equals(1, violations(source).length);
	}


	private function src(decl: String, body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t' + decl + '\n\t\t' + body + '\n\t}\n}';
	}


	private function violations(source: String): Array<Violation> {
		return new PreferIndexAccess().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}


	private function applyFix(source: String): String {
		final check: PreferIndexAccess = new PreferIndexAccess();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
