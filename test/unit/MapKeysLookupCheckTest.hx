package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.MapKeysLookup;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

/**
 * The `map-keys-lookup` check: a `for (k in m.keys())` loop whose body re-looks-up the
 * same map by the same key (`m[k]` / `m.get(k)`) is flagged `Info`, with an autofix
 * applying the key-value rewrite. The receiver may be a bare identifier or a PATH — a
 * chain of plain field accesses over an identifier or `this` (`this.files`,
 * `session.files`, `o.a.b`). Soundness misses: a body with no matching lookup, a
 * different key / map / path, any mutation of the map (`m[k] =` / `m.set` / `m.remove` /
 * `m.clear`, through the path too), an assignment re-binding the path or one of its
 * prefixes (`m = other` / `o.files = other` / `o = p`), a re-binding shadowing `k` or the
 * path ROOT, a path containing a call, an index access or a `?.` link, and a receiver
 * whose type resolves to a concrete non-map — the last one now reached THROUGH a path
 * too, so a custom `keys()`-bearing type is skipped whether it is spelled `registry` or
 * `svc.registry`. Write comparisons run on self-normalised paths, so `this.files` and a
 * bare `files` count as one member in both directions. Still flagged: a write DEEPER
 * than the path (`o.files.inner =`) or to a sibling field (`o.other =`), neither of
 * which re-binds the iterable; and a receiver whose type no seam can resolve. The fix
 * reuses the name of a leading immutable single-variable local bound to exactly the
 * lookup (and drops that declaration), unless the local is mutable, not the body's first
 * statement, or annotated with anything outside the builtin whitelist — a `typedef` over
 * `Null<Int>` is indistinguishable from a class by spelling, so only builtins qualify.
 */
class MapKeysLookupCheckTest extends Test {

	public function testIndexLookupFlagged(): Void {
		final vs: Array<Violation> = violations(wrapMap('for (k in m.keys()) trace(m[k]);'));
		Assert.equals(1, vs.length);
		Assert.equals('map-keys-lookup', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('iterate key-value instead of keys()-then-lookup — for (k => value in m)', vs[0].message);
	}

	public function testGetLookupFlagged(): Void {
		Assert.equals(1, violations(wrapMap('for (k in m.keys()) trace(m.get(k));')).length);
	}

	public function testBracedBodyFlagged(): Void {
		Assert.equals(1, violations(wrapMap('for (k in m.keys()) {\n\t\t\tfinal v = m[k];\n\t\t\ttrace(v);\n\t\t}')).length);
	}

	public function testNoLookupNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) trace(k);')).length);
	}

	public function testDifferentKeyNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(m:Map<String,Int>, j:String):Void {\n\t\tfor (k in m.keys()) trace(m[j]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDifferentMapNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(m:Map<String,Int>, n:Map<String,Int>):Void {\n\t\tfor (k in m.keys()) trace(n[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testIndexWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm[k] = 1;\n\t\t}')).length);
	}

	public function testSetWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm.set(k, 1);\n\t\t}')).length);
	}

	public function testRemoveWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm.remove(k);\n\t\t}')).length);
	}

	public function testShadowedKeyNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\tfinal k = 5;\n\t\t\ttrace(m[k]);\n\t\t}')).length);
	}

	public function testShadowedMapByNestedLoopNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) for (m in rows) trace(m[k]);')).length);
	}

	public function testCompoundAssignWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm[k] += 1;\n\t\t}')).length);
	}

	public function testIncrementWriteNotFlagged(): Void {
		Assert.equals(0, violations(wrapMap('for (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm[k]++;\n\t\t}')).length);
	}

	public function testShadowedKeyByLambdaParamNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapMap('for (k in m.keys()) {\n\t\t\tfinal f = (k:String) -> m[k];\n\t\t\ttrace(f("x"));\n\t\t}')).length
		);
	}

	public function testObjectFieldPathReceiverFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:{ m:Map<String,Int> }):Void {\n\t\tfor (k in o.m.keys()) trace(o.m[k]);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testThisPathReceiverFlagged(): Void {
		final src: String = 'class C {\n\tvar files:Map<String,Int>;\n\tfunction f():Void {\n\t\tfor (k in this.files.keys()) trace(this.files[k]);\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('iterate key-value instead of keys()-then-lookup — for (k => value in this.files)', vs[0].message);
	}

	public function testParamPathGetReceiverFlagged(): Void {
		Assert.equals(1, violations(wrapPath('for (k in o.files.keys()) trace(o.files.get(k));')).length);
	}

	public function testTwoLevelPathFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {\n\t\tfor (k in o.a.b.keys()) trace(o.a.b.get(k));\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('iterate key-value instead of keys()-then-lookup — for (k => value in o.a.b)', vs[0].message);
	}

	public function testDifferentPathNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {\n\t\tfor (k in o.a.keys()) trace(o.b[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testPathPrefixLookupNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {\n\t\tfor (k in o.a.b.keys()) trace(o.a[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testPathRootRebindNotFlagged(): Void {
		Assert.equals(0, violations(wrapPath('for (k in o.files.keys()) {\n\t\t\tfinal o = 1;\n\t\t\ttrace(o.files[k]);\n\t\t}')).length);
	}

	public function testPathSegmentRebindStillFlagged(): Void {
		Assert.equals(
			1, violations(wrapPath('for (k in o.files.keys()) {\n\t\t\tfinal files = 1;\n\t\t\ttrace(o.files[k]);\n\t\t}')).length
		);
	}

	public function testPathIndexWriteNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapPath('for (k in o.files.keys()) {\n\t\t\ttrace(o.files[k]);\n\t\t\to.files[k] = 1;\n\t\t}')).length
		);
	}

	public function testPathSetWriteNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapPath('for (k in o.files.keys()) {\n\t\t\ttrace(o.files[k]);\n\t\t\to.files.set(k, 1);\n\t\t}')).length
		);
	}

	public function testBareReceiverReassignNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(m:Map<String,Int>, other:Map<String,Int>):Void {'
			+ '\n\t\tfor (k in m.keys()) {\n\t\t\ttrace(m[k]);\n\t\t\tm = other;\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testWholePathReassignNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapPath('for (k in o.files.keys()) {\n\t\t\ttrace(o.files[k]);\n\t\t\to.files = null;\n\t\t}')).length
		);
	}

	public function testPathRootReassignNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic, p:Dynamic):Void {'
			+ '\n\t\tfor (k in o.files.keys()) {\n\t\t\ttrace(o.files[k]);\n\t\t\to = p;\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDeeperThanPathWriteStillFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {'
			+ '\n\t\tfor (k in o.files.keys()) {\n\t\t\ttrace(o.files[k]);\n\t\t\to.files.inner = 1;\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testSiblingFieldWriteStillFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {'
			+ '\n\t\tfor (k in o.files.keys()) {\n\t\t\ttrace(o.files[k]);\n\t\t\to.other = 1;\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testPathRemoveWriteNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapPath('for (k in o.files.keys()) {\n\t\t\ttrace(o.files[k]);\n\t\t\to.files.remove(k);\n\t\t}')).length
		);
	}

	public function testPathClearWriteNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapPath('for (k in o.files.keys()) {\n\t\t\ttrace(o.files[k]);\n\t\t\to.files.clear();\n\t\t}')).length
		);
	}

	public function testThisIterableWithBareMemberReassignNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapMember('for (k in this.files.keys()) {\n\t\t\ttrace(this.files[k]);\n\t\t\tfiles = other;\n\t\t}')).length
		);
	}

	public function testBareIterableWithThisMemberReassignNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapMember('for (k in files.keys()) {\n\t\t\ttrace(files[k]);\n\t\t\tthis.files = other;\n\t\t}')).length
		);
	}

	public function testThisIterableWithBareMemberSetNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapMember('for (k in this.files.keys()) {\n\t\t\ttrace(this.files[k]);\n\t\t\tfiles.set(k, 1);\n\t\t}')).length
		);
	}

	public function testBareIterableWithThisMemberIndexWriteNotFlagged(): Void {
		Assert.equals(
			0, violations(wrapMember('for (k in files.keys()) {\n\t\t\ttrace(files[k]);\n\t\t\tthis.files[k] = 1;\n\t\t}')).length
		);
	}

	public function testCallInPathNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {\n\t\tfor (k in o.f().keys()) trace(o.f()[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testIndexAccessInPathNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {\n\t\tfor (k in o.a[0].b.keys()) trace(o.a[0].b[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNullSafeRootInPathNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {\n\t\tfor (k in o?.files.keys()) trace(o?.files[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNullSafeMidPathNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(o:Dynamic):Void {\n\t\tfor (k in o.a?.b.keys()) trace(o.a?.b[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testNonMapTypeNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(arr:Array<Int>):Void {\n\t\tfor (k in arr.keys()) trace(arr[k]);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testCustomKeysTypeNotFlaggedThroughPathOrBareName(): Void {
		final registry: String = 'class Registry {\n\tpublic function keys():Iterator<String> {\n\t\treturn null;\n\t}\n'
			+ '\tpublic function get(k:String):Int {\n\t\treturn 0;\n\t}\n}';
		final svc: String = 'class Svc {\n\tpublic var registry:Registry;\n}';
		final bare: String = 'class C {\n\tfunction f(registry:Registry):Void {\n\t\tfor (k in registry.keys()) trace(registry.get(k));\n\t}\n}';
		final path: String = 'class D {\n\tfunction f(svc:Svc):Void {\n\t\tfor (k in svc.registry.keys()) trace(svc.registry.get(k));\n\t}\n}';
		Assert.equals(0, violationsAcross([registry, svc, bare]).length);
		Assert.equals(0, violationsAcross([registry, svc, path]).length);
	}

	public function testMapMemberThroughPathStillFlaggedAcrossFiles(): Void {
		final data: String = 'class SessionData {\n\tpublic var files(default, null):Map<String, String>;\n}';
		final user: String = 'class C {\n\tfunction f(session:SessionData):Void {'
			+ '\n\t\tfor (n in session.files.keys()) trace(session.files.get(n));\n\t}\n}';
		Assert.equals(1, violationsAcross([data, user]).length);
	}

	public function testThisPathResolvesEnclosingTypeMember(): Void {
		final src: String = 'class Holder {\n\tvar reg:Registry;\n\tfunction f():Void {\n\t\tfor (k in this.reg.keys()) trace(this.reg.get(k));\n\t}\n}';
		final registry: String = 'class Registry {\n\tpublic function keys():Iterator<String> {\n\t\treturn null;\n\t}\n'
			+ '\tpublic function get(k:String):Int {\n\t\treturn 0;\n\t}\n}';
		Assert.equals(0, violationsAcross([registry, src]).length);
	}

	public function testUnresolvableTypeStillFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(m):Void {\n\t\tfor (k in m.keys()) trace(m[k]);\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testFixIndexLookup(): Void {
		assertFixCanonical(wrapMap('for (k in m.keys()) trace(m[k]);'), 'for (k => value in m) trace(value);', '.keys()');
	}

	public function testFixGetLookup(): Void {
		assertFixCanonical(wrapMap('for (k in m.keys()) trace(m.get(k));'), 'for (k => value in m) trace(value);', 'm.get(k)');
	}

	public function testFixFreshValueNameOnCollision(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal value = 7;\n\t\t\ttrace(m[k] + value);\n\t\t}'), 'for (k => value1 in m)', 'm[k]'
		);
	}

	public function testFixPathReceiver(): Void {
		assertFixCanonical(
			wrapPath('for (k in o.files.keys()) trace(o.files[k]);'), 'for (k => value in o.files) trace(value);', '.keys()'
		);
	}

	public function testFixReusesLeadingValueLocalName(): Void {
		final src: String = 'class C {\n\tfunction f(session:Dynamic):Void {\n\t\tfor (filename in session.files.keys()) {'
			+ '\n\t\t\tfinal filecontent:String = session.files.get(filename);\n\t\t\ttrace(filecontent);\n\t\t}\n\t}\n}';
		assertFixCanonical(src, 'for (filename => filecontent in session.files) {', 'final filecontent');
	}

	public function testFixReusesLeadingValueLocalNameForBareIdent(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal v = m[k];\n\t\t\ttrace(v);\n\t\t}'), 'for (k => v in m) {', 'final v'
		);
	}

	public function testFixKeepsWideningAnnotatedLocal(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal v:Null<Int> = m[k];\n\t\t\ttrace(v);\n\t\t}'), 'final v:Null<Int> = value;', 'm[k]'
		);
	}

	public function testFixKeepsDynamicAnnotatedLocal(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal v:Dynamic = m[k];\n\t\t\ttrace(v);\n\t\t}'), 'final v:Dynamic = value;', 'm[k]'
		);
	}

	public function testFixKeepsAnyAnnotatedLocal(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal v:Any = m[k];\n\t\t\ttrace(v);\n\t\t}'), 'final v:Any = value;', 'm[k]'
		);
	}

	public function testFixKeepsAliasAnnotatedLocal(): Void {
		final src: String = 'typedef MaybeInt = Null<Int>;\n\nclass C {\n\tfunction f(m:Map<String,Int>):Void {'
			+ '\n\t\tfor (k in m.keys()) {\n\t\t\tfinal v:MaybeInt = m[k];\n\t\t\ttrace(v);\n\t\t}\n\t}\n}';
		assertFixCanonical(src, 'final v:MaybeInt = value;', 'm[k]');
	}

	public function testFixKeepsUnknownNominalAnnotatedLocal(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal v:Widget = m[k];\n\t\t\ttrace(v);\n\t\t}'), 'final v:Widget = value;', 'm[k]'
		);
	}

	public function testFixKeepsMultiVariableLeadingDecl(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal a = m[k], b = 2;\n\t\t\ttrace(a + b);\n\t\t}'), 'final a = value, b = 2;', 'm[k]'
		);
	}

	public function testFixKeepsCastWrappedLeadingDecl(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal c:Int = cast m[k];\n\t\t\ttrace(c);\n\t\t}'), 'final c:Int = cast value;', 'm[k]'
		);
	}

	public function testFixKeepsLeadingDeclWithDifferentKey(): Void {
		final src: String = 'class C {\n\tfunction f(m:Map<String,Int>, j:String):Void {'
			+ '\n\t\tfor (k in m.keys()) {\n\t\t\tfinal v = m[j];\n\t\t\ttrace(v + m[k]);\n\t\t}\n\t}\n}';
		assertFixCanonical(src, 'final v = m[j];', 'm[k]');
	}

	public function testFixReusedNameCoversLaterLookups(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tfinal v = m[k];\n\t\t\ttrace(v + m.get(k));\n\t\t}'), 'trace(v + v);', 'm.get(k)'
		);
	}

	public function testFixKeepsMutableLocal(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\tvar w = m[k];\n\t\t\tw = 1;\n\t\t\ttrace(m[k] + w);\n\t\t}'), 'var w = value;', 'm[k]'
		);
	}

	public function testFixKeepsNonLeadingLocal(): Void {
		assertFixCanonical(
			wrapMap('for (k in m.keys()) {\n\t\t\ttrace(k);\n\t\t\tfinal v = m[k];\n\t\t\ttrace(v);\n\t\t}'), 'final v = value;', 'm[k]'
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('map-keys-lookup'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('map-keys-lookup'));
		Assert.equals(103, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(m:Map<String,Int>) { for (k in m.keys()) trace(m[k]);').length);
	}

	public function testStaticTypeRootMapFlaggedAcrossFiles(): Void {
		// keys()-then-lookup on a static Map field reached through a TYPE-name root, resolved
		// cross-file via the SymbolIndex (not a value binding).
		final registry: String = 'class Registry {\n\tpublic static var m:Map<String, Int>;\n}';
		final user: String = 'class C {\n\tfunction f():Void {\n\t\tfor (k in Registry.m.keys()) trace(Registry.m.get(k));\n\t}\n}';
		Assert.equals(1, violationsAcross([registry, user]).length);
	}

	public function testStaticTypeRootNonMapNotFlagged(): Void {
		// A custom keys()-bearing type reached through a static-type root resolves to a concrete
		// non-map — skip, exactly as through a value root.
		final registry: String = 'class Registry {\n\tpublic static var box:Box;\n}';
		final box: String = 'class Box {\n\tpublic function keys():Iterator<String> {\n\t\treturn null;\n\t}\n'
			+ '\tpublic function get(k:String):Int {\n\t\treturn 0;\n\t}\n}';
		final user: String = 'class C {\n\tfunction f():Void {\n\t\tfor (k in Registry.box.keys()) trace(Registry.box.get(k));\n\t}\n}';
		Assert.equals(0, violationsAcross([registry, box, user]).length);
	}

	public function testAmbiguousStaticRootStillFlagged(): Void {
		// Two 'Reg' types → root ambiguous → receiver type unresolvable → the permissive
		// polarity FLAGS (the polarity difference from prefer-index-access, which skips here).
		final regA: String = 'class Reg {\n\tpublic static var m:Map<String, Int>;\n}';
		final regB: String = 'class Reg {\n\tpublic static var m:Map<String, Int>;\n}';
		final user: String = 'class C {\n\tfunction f():Void {\n\t\tfor (k in Reg.m.keys()) trace(Reg.m.get(k));\n\t}\n}';
		Assert.equals(1, violationsAcross([regA, regB, user]).length);
	}

	public function testValueBindingShadowsTypeNameResolvesAsValue(): Void {
		// A param `Registry:Holder` shadows class Registry. Value wins → the receiver resolves to
		// Holder.m : Box (a custom keys() type — skip), NOT class Registry.m : Map (would flag).
		// A 0 can only arise from resolving the concrete non-map Box, so it proves value wins.
		final registry: String = 'class Registry {\n\tpublic static var m:Map<String, Int>;\n}';
		final box: String = 'class Box {\n\tpublic function keys():Iterator<String> {\n\t\treturn null;\n\t}\n'
			+ '\tpublic function get(k:String):Int {\n\t\treturn 0;\n\t}\n}';
		final holder: String = 'class Holder {\n\tpublic var m:Box;\n}';
		final user: String = 'class D {\n\tfunction f(Registry:Holder):Void {\n\t\tfor (k in Registry.m.keys()) trace(Registry.m.get(k));\n\t}\n}';
		Assert.equals(0, violationsAcross([registry, box, holder, user]).length);
	}

	public function testFixStaticTypeRoot(): Void {
		final src: String = 'class Registry {\n\tpublic static var m:Map<String, Int>;\n}\n\n'
			+ 'class C {\n\tfunction f():Void {\n\t\tfor (k in Registry.m.keys()) trace(Registry.m.get(k));\n\t}\n}';
		assertFixCanonical(src, 'for (k => value in Registry.m) trace(value);', '.keys()');
	}

	public function testStaticRootCrossPackageInheritedNonMapNotFlagged(): Void {
		// Cross-package poison: the import-correct a.Mid INHERITS m:CustomKeys (a keys()/get()
		// type that is NOT a Map — no key-value iteration), while an unrelated b.Mid declares
		// m:Map directly. The package-blind walk resolved b.Mid's Map → flagged → a broken
		// `for (k => v in ...)` rewrite; the import-aware walk resolves CustomKeys → skip.
		Assert.equals(0, violationsForFiles([
			{
				file: 'keys/CustomKeys.hx',
				source: 'package keys;\nclass CustomKeys {\n\tpublic function keys():Iterator<String> {\n'
				+ '\t\treturn null;\n\t}\n\tpublic function get(k:String):Int {\n\t\treturn 0;\n\t}\n}'
			},
			{ file: 'a/Base.hx', source: 'package a;\nimport keys.CustomKeys;\nclass Base {\n\tpublic var m:CustomKeys;\n}' },
			{ file: 'a/Mid.hx', source: 'package a;\nclass Mid extends Base {\n}' },
			{ file: 'b/Mid.hx', source: 'package b;\nclass Mid {\n\tpublic var m:Map<String, Int>;\n}' },
			{ file: 'top/Outer.hx', source: 'package top;\nimport a.Mid;\nclass Outer {\n\tpublic static var mid:Mid;\n}' },
			{
				file: 'top/User.hx',
				source: 'package top;\nclass User {\n\tfunction f():Void {'
				+ '\n\t\tfor (k in Outer.mid.m.keys()) trace(Outer.mid.m.get(k));\n\t}\n}'
			}
		]).length);
	}

	public function testValueRootCrossPackageInheritedNonMapNotFlagged(): Void {
		// Same cross-package poison via a VALUE root `o.mid.m` (o:Outer) — closes the pre-existing
		// value-root hole too.
		Assert.equals(0, violationsForFiles([
			{
				file: 'keys/CustomKeys.hx',
				source: 'package keys;\nclass CustomKeys {\n\tpublic function keys():Iterator<String> {\n'
				+ '\t\treturn null;\n\t}\n\tpublic function get(k:String):Int {\n\t\treturn 0;\n\t}\n}'
			},
			{ file: 'a/Base.hx', source: 'package a;\nimport keys.CustomKeys;\nclass Base {\n\tpublic var m:CustomKeys;\n}' },
			{ file: 'a/Mid.hx', source: 'package a;\nclass Mid extends Base {\n}' },
			{ file: 'b/Mid.hx', source: 'package b;\nclass Mid {\n\tpublic var m:Map<String, Int>;\n}' },
			{ file: 'top/Outer.hx', source: 'package top;\nimport a.Mid;\nclass Outer {\n\tpublic var mid:Mid;\n}' },
			{
				file: 'top/User.hx',
				source: 'package top;\nclass User {\n\tfunction f(o:Outer):Void {'
				+ '\n\t\tfor (k in o.mid.m.keys()) trace(o.mid.m.get(k));\n\t}\n}'
			}
		]).length);
	}

	private function wrapMap(loopCode: String): String {
		return 'class C {\n\tfunction f(m:Map<String,Int>):Void {\n\t\t$loopCode\n\t}\n}';
	}

	private function wrapPath(loopCode: String): String {
		return 'class C {\n\tfunction f(o:{ files:Map<String,Int> }):Void {\n\t\t$loopCode\n\t}\n}';
	}

	/** A class whose `files` member the loop can reach as both `this.files` and a bare `files`. */
	private function wrapMember(loopCode: String): String {
		return 'class C {\n\tvar files:Map<String,Int>;\n\tfunction f(other:Map<String,Int>):Void {\n\t\t$loopCode\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new MapKeysLookup().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	/** Run over several sources at once, so the type gate can resolve a member declared in another file. */
	private function violationsAcross(sources: Array<String>): Array<Violation> {
		return new MapKeysLookup().run([for (i in 0...sources.length) { file: 'F$i.hx', source: sources[i] }], new HaxeQueryPlugin());
	}

	/** Run over explicit file paths, so package + import scope (isMain module names) resolves. */
	private function violationsForFiles(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new MapKeysLookup().run(files, new HaxeQueryPlugin());
	}


	private function assertFixCanonical(src: String, present: String, absent: String): Void {
		final check: MapKeysLookup = new MapKeysLookup();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

}
