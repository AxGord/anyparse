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

	public function testThisPathFlagged(): Void {
		// A `this.<field>` path receiver resolving to Map is now flagged (path support).
		Assert.equals(
			1,
			violations('class C {\n\tfinal m:Map<String, String> = [];\n\tfunction f():Void {\n\t\tvar v = this.m.get("a");\n\t}\n}').length
		);
	}

	public function testThisPathFix(): Void {
		final fixed: String = applyFix(
			'class C {\n\tfinal m:Map<String, String> = [];\n\tfunction f():Void {\n\t\tvar v = this.m.get("a");\n\t}\n}'
		);
		Assert.isTrue(fixed.indexOf('this.m["a"]') != -1);
		Assert.equals(-1, fixed.indexOf('.get'));
	}

	public function testObjectPathFieldFlagged(): Void {
		// obj.field where the field type resolves (same file) to Map.
		Assert.equals(1, violations(holderUser('h.m.get("a")')).length);
	}

	public function testObjectPathFieldFlaggedAcrossFiles(): Void {
		// The declaring type is in a SEPARATE file — resolution needs the cross-file SymbolIndex.
		final holder: String = 'class Holder {\n\tpublic var m:Map<String, Int>;\n}';
		final user: String = 'class C {\n\tfunction f(h:Holder):Void {\n\t\tvar v = h.m.get("a");\n\t}\n}';
		Assert.equals(1, violationsAcross([holder, user]).length);
	}

	public function testThreeLevelPathFlaggedAcrossFiles(): Void {
		// s.h.m across THREE files: root Svc, mid Holder, leaf Map<...>.
		final holder: String = 'class Holder {\n\tpublic var m:Map<String, Int>;\n}';
		final svc: String = 'class Svc {\n\tpublic var h:Holder;\n}';
		final user: String = 'class C {\n\tfunction f(s:Svc):Void {\n\t\tvar v = s.h.m.get("a");\n\t}\n}';
		Assert.equals(1, violationsAcross([holder, svc, user]).length);
	}

	public function testObjectPathGetFix(): Void {
		final fixed: String = applyFix(holderUser('var v = h.m.get("a")'));
		Assert.isTrue(fixed.indexOf('var v = h.m["a"];') != -1);
		Assert.equals(-1, fixed.indexOf('.get'));
	}

	public function testPathNullMapFlagged(): Void {
		Assert.equals(1, violations(holderUserField('nm:Null<Map<String, Int>>', 'var v = h.nm.get("a")')).length);
	}

	public function testPathStringMapNotFlagged(): Void {
		// StringMap has get/set but no @:arrayAccess — a path to it is a safe miss.
		Assert.equals(0, violations(holderUserField('sm:StringMap<Int>', 'var v = h.sm.get("a")')).length);
	}

	public function testUnresolvablePathNotFlagged(): Void {
		// Untyped root -> path unresolvable -> skip (never flag without positive Map proof).
		Assert.equals(0, violations('class C {\n\tfunction f(h):Void {\n\t\tvar v = h.m.get("a");\n\t}\n}').length);
	}

	public function testAnonStructPathNotFlagged(): Void {
		// An anon-struct receiver has no nominal for the SymbolIndex to resolve — conservative miss.
		Assert.equals(0, violations('class C {\n\tfunction f(o:{ m:Map<String, Int> }):Void {\n\t\tvar v = o.m.get("a");\n\t}\n}').length);
	}

	public function testCallInPathNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f(h:Dynamic):Void {\n\t\tvar v = h.f().get("a");\n\t}\n}').length);
	}

	public function testNullSafeLinkInPathNotFlagged(): Void {
		// A `?.` link is not a plain path segment — skipped even when the type is Map.
		Assert.equals(0, violations(holderUser('var v = h?.m.get("a")')).length);
	}

	public function testPathSetFixInStatementPosition(): Void {
		final fixed: String = applyFix(holderUserField('m:Map<String, String>', 'h.m.set("a", "b")'));
		Assert.isTrue(fixed.indexOf('h.m["a"] = "b";') != -1);
		Assert.equals(-1, fixed.indexOf('.set'));
	}

	public function testPathSetNotFixedInExpressionPosition(): Void {
		final source: String = holderUserField('m:Map<String, String>', 'var r = h.m.set("a", "b")');
		Assert.equals(1, violations(source).length);
		Assert.equals(source, applyFix(source));
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

	public function testStaticTypeRootMapFlaggedAcrossFiles(): Void {
		// The root ident is a TYPE name owning a static Map field, resolved through the
		// SymbolIndex (not a value binding) — the static-type-root arm.
		final registry: String = 'class Registry {\n\tpublic static var m:Map<String, Int>;\n}';
		final user: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = Registry.m.get("a");\n\t}\n}';
		Assert.equals(1, violationsAcross([registry, user]).length);
	}

	public function testStaticTypeRootMapFixed(): Void {
		// Same static-type-root resolution, fixed in place (two classes, one file so applyFix reaches it).
		final source: String = 'class Registry {\n\tpublic static var m:Map<String, Int>;\n}\n\n'
			+ 'class C {\n\tfunction f():Void {\n\t\tvar v = Registry.m.get("a");\n\t}\n}';
		Assert.equals(1, violations(source).length);
		final fixed: String = applyFix(source);
		Assert.isTrue(fixed.indexOf('var v = Registry.m["a"];') != -1);
		Assert.equals(-1, fixed.indexOf('.get'));
	}

	public function testThreeLevelStaticPathFlaggedAcrossFiles(): Void {
		// A.b.c across THREE files: root TYPE Outer (static var mid:Mid), Mid.m:Map.
		final mid: String = 'class Mid {\n\tpublic var m:Map<String, Int>;\n}';
		final outer: String = 'class Outer {\n\tpublic static var mid:Mid;\n}';
		final user: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = Outer.mid.m.get("a");\n\t}\n}';
		Assert.equals(1, violationsAcross([mid, outer, user]).length);
	}

	public function testStaticRootNotDeclaredNotFlagged(): Void {
		// The root ident is not a declared type anywhere in scope — unresolvable, skip.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tvar v = Unknown.m.get("a");\n\t}\n}').length);
	}

	public function testStaticRootNonMapMemberNotFlagged(): Void {
		// A resolved static-type root whose member is a StringMap (no @:arrayAccess) — a safe miss.
		final registry: String = 'class Registry {\n\tpublic static var sm:StringMap<Int>;\n}';
		final user: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = Registry.sm.get("a");\n\t}\n}';
		Assert.equals(0, violationsAcross([registry, user]).length);
	}

	public function testAmbiguousStaticRootNotFlagged(): Void {
		// Two types share the simple name 'Reg' — the root is ambiguous, fails closed (skip),
		// even though both carry an identical Map member.
		final regA: String = 'class Reg {\n\tpublic static var m:Map<String, Int>;\n}';
		final regB: String = 'class Reg {\n\tpublic static var m:Map<String, Int>;\n}';
		final user: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = Reg.m.get("a");\n\t}\n}';
		Assert.equals(0, violationsAcross([regA, regB, user]).length);
	}

	public function testAmbiguousSegmentNominalNotFlagged(): Void {
		// The mid-segment nominal `Mid` is declared twice with DIFFERENT `m` types — the
		// simple-name member walk fails closed (divergent typeSource → null) → skip.
		final midA: String = 'class Mid {\n\tpublic var m:Map<String, Int>;\n}';
		final midB: String = 'class Mid {\n\tpublic var m:StringMap<Int>;\n}';
		final outer: String = 'class Outer {\n\tpublic static var mid:Mid;\n}';
		final user: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = Outer.mid.m.get("a");\n\t}\n}';
		Assert.equals(0, violationsAcross([midA, midB, outer, user]).length);
	}

	public function testValueBindingShadowsTypeNameResolvesAsValue(): Void {
		// A param named like a type (`Registry`) shadows the class. The value binding WINS: the
		// receiver resolves to the param's type Holder (whose `m` is a Map — flag), NOT to class
		// Registry (whose static `m` is a StringMap — would skip). Asserting 1 proves value wins.
		final registry: String = 'class Registry {\n\tpublic static var m:StringMap<Int>;\n}';
		final holder: String = 'class Holder {\n\tpublic var m:Map<String, Int>;\n}';
		final user: String = 'class C {\n\tfunction f(Registry:Holder):Void {\n\t\tvar v = Registry.m.get("a");\n\t}\n}';
		Assert.equals(1, violationsAcross([registry, holder, user]).length);
	}

	public function testStaticRootCrossPackageInheritedNonMapNotFlagged(): Void {
		// Reviewer repro: `Outer.mid.m` where the import-correct a.Mid INHERITS m:StringMap, while
		// an unrelated b.Mid in another package declares m:Map DIRECTLY. The package-blind
		// simple-name walk returned b.Mid's Map (→ a compile-breaking `[]` on a StringMap); the
		// import-aware walk reads m off a.Mid through a.Base → StringMap → skip.
		Assert.equals(0, violationsForFiles([
			{ file: 'a/Base.hx', source: 'package a;\nclass Base {\n\tpublic var m:StringMap<Int>;\n}' },
			{ file: 'a/Mid.hx', source: 'package a;\nclass Mid extends Base {\n}' },
			{ file: 'b/Mid.hx', source: 'package b;\nclass Mid {\n\tpublic var m:Map<String, Int>;\n}' },
			{ file: 'top/Outer.hx', source: 'package top;\nimport a.Mid;\nclass Outer {\n\tpublic static var mid:Mid;\n}' },
			{ file: 'top/User.hx', source: 'package top;\nclass User {\n\tfunction f():Void {\n\t\tvar v = Outer.mid.m.get("a");\n\t}\n}' }
		]).length);
	}

	public function testValueRootCrossPackageInheritedNonMapNotFlagged(): Void {
		// Same cross-package poison via a VALUE root `o.mid.m` (o:Outer) — proves the pre-existing
		// value-root hole is closed too, not only the new static-root surface.
		Assert.equals(0, violationsForFiles([
			{ file: 'a/Base.hx', source: 'package a;\nclass Base {\n\tpublic var m:StringMap<Int>;\n}' },
			{ file: 'a/Mid.hx', source: 'package a;\nclass Mid extends Base {\n}' },
			{ file: 'b/Mid.hx', source: 'package b;\nclass Mid {\n\tpublic var m:Map<String, Int>;\n}' },
			{ file: 'top/Outer.hx', source: 'package top;\nimport a.Mid;\nclass Outer {\n\tpublic var mid:Mid;\n}' },
			{
				file: 'top/User.hx',
				source: 'package top;\nclass User {\n\tfunction f(o:Outer):Void {\n\t\tvar v = o.mid.m.get("a");\n\t}\n}'
			}
		]).length);
	}

	public function testCrossPackageDirectMapStillFlagged(): Void {
		// Positive control: when the import-correct a.Mid ITSELF declares m:Map directly (no
		// inheritance divergence), the same shape flags — the fix does not over-refuse ≥3-segment
		// cross-package paths, only the poisoned ones.
		Assert.equals(1, violationsForFiles([
			{ file: 'a/Mid.hx', source: 'package a;\nclass Mid {\n\tpublic var m:Map<String, Int>;\n}' },
			{ file: 'b/Mid.hx', source: 'package b;\nclass Mid {\n\tpublic var m:StringMap<Int>;\n}' },
			{ file: 'top/Outer.hx', source: 'package top;\nimport a.Mid;\nclass Outer {\n\tpublic static var mid:Mid;\n}' },
			{ file: 'top/User.hx', source: 'package top;\nclass User {\n\tfunction f():Void {\n\t\tvar v = Outer.mid.m.get("a");\n\t}\n}' }
		]).length);
	}

	private function src(decl: String, body: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$decl\n\t\t$body\n\t}\n}';
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

	/** A two-class same-file source: a `Holder` with field `<field>` and a `C.f(h:Holder)` body `<body>;`. */
	private function holderUserField(field: String, body: String): String {
		return 'class Holder {\n\tpublic var $field;\n}\n\nclass C {\n\tfunction f(h:Holder):Void {\n\t\t$body;\n\t}\n}';
	}

	/** `holderUserField` with the default `m:Map<String, Int>` field. */
	private function holderUser(body: String): String {
		return holderUserField('m:Map<String, Int>', body);
	}

	/** Run over several sources at once, so the type gate can resolve a member declared in another file. */
	private function violationsAcross(sources: Array<String>): Array<Violation> {
		return new PreferIndexAccess().run([for (i in 0...sources.length) { file: 'F$i.hx', source: sources[i] }], new HaxeQueryPlugin());
	}

	/** Run over explicit file paths, so package + import scope (isMain module names) resolves. */
	private function violationsForFiles(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new PreferIndexAccess().run(files, new HaxeQueryPlugin());
	}

}
