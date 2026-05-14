package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.Span;

using Lambda;

/**
 * Phase 3.1 probe — `Refs.find` walks a parsed QueryNode tree and
 * collects every name-matching hit classified as `decl` / `read` per
 * the plugin's `RefShape`.
 *
 * Covers:
 *  - Bare identifier read collection.
 *  - VarStmt / FnDecl / ClassDecl decl-host detection.
 *  - HxParam binding via the `Required` enum-ctor name slot.
 *  - Field-access exclusion: `obj.foo` is `FieldAccess`, not
 *    `IdentExpr`; only the receiver `obj` qualifies as a read.
 */
class ApqRefsTest extends Test {

	public function testVarReadAndDeclCollected():Void {
		final hits:Array<RefHit> = findIn('class X { static function a() { var n:Int = 0; var m:Int = n; } }', 'n');
		Assert.equals(2, hits.length, 'one decl + one read expected, got ${describe(hits)}');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Decl), 'decl hit expected — got ${describe(hits)}');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Read), 'read hit expected — got ${describe(hits)}');
	}

	public function testParamDeclCollected():Void {
		final hits:Array<RefHit> = findIn('class X { static function f(arg:Int):Int { return arg; } }', 'arg');
		Assert.equals(2, hits.length, 'param decl + return-site read expected, got ${describe(hits)}');
		final decls:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		Assert.equals(1, decls.length, 'exactly one decl from HxParam.Required expected');
		final reads:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, reads.length, 'exactly one read in return position expected');
	}

	public function testTopLevelClassAndFnDeclCollected():Void {
		final classHits:Array<RefHit> = findIn('class Foo { static function bar():Void {} }', 'Foo');
		Assert.equals(1, classHits.length, 'class decl expected');
		Assert.equals(RefKind.Decl, classHits[0].kind);
		final fnHits:Array<RefHit> = findIn('class Foo { static function bar():Void {} }', 'bar');
		Assert.equals(1, fnHits.length, 'fn-member decl expected');
		Assert.equals(RefKind.Decl, fnHits[0].kind);
	}

	public function testFieldAccessReceiverMatchesAsRead():Void {
		// `obj.foo` — receiver `obj` IS an IdentExpr (read).
		// The field-side `foo` is HxIdentLit on FieldAccess; it does not
		// produce an IdentExpr QueryNode, so a search for `foo` here
		// returns zero hits.
		final source:String = 'class X { static function a() { var obj:Int = 0; obj.foo; } }';
		final objHits:Array<RefHit> = findIn(source, 'obj');
		Assert.isTrue(objHits.exists(h -> h.kind == RefKind.Read), 'receiver obj must surface as read');
		final fooHits:Array<RefHit> = findIn(source, 'foo');
		Assert.equals(0, fooHits.length, 'field-side `foo` must not surface — FieldAccess does not emit IdentExpr');
	}

	public function testCallOperandReadCollected():Void {
		final hits:Array<RefHit> = findIn('class X { static function a() { var f:Int->Int = null; f(1); } }', 'f');
		// expect: 1 decl (VarStmt) + 1 read (Call operand) = 2
		Assert.equals(2, hits.length, 'decl + call-operand read expected, got ${describe(hits)}');
	}

	public function testNonMatchingNameReturnsEmpty():Void {
		final hits:Array<RefHit> = findIn('class X { static function a() { var n:Int = 0; } }', 'z');
		Assert.equals(0, hits.length);
	}

	public function testHitsCarryPositiveSpan():Void {
		final hits:Array<RefHit> = findIn('class X { static function a() { var n:Int = 0; n; } }', 'n');
		for (h in hits) {
			Assert.isTrue(h.span.from >= 0, 'span.from must be non-negative');
			Assert.isTrue(h.span.to >= h.span.from, 'span.to must be >= span.from');
		}
	}

	public function testRefKindToStringMatchesSpec():Void {
		Assert.equals('decl', RefKind.Decl.toString());
		Assert.equals('read', RefKind.Read.toString());
		Assert.equals('write', RefKind.Write.toString());
	}

	public function testInnerLocalShadowsClassField():Void {
		final source:String = 'class X { var n:Int = 0; static function f():Int { var n:Int = 1; return n; } }';
		final hits:Array<RefHit> = findIn(source, 'n');
		final decls:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'outer field + inner local decls expected — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read expected — got ${describe(hits)}');
		final outerDecl:RefHit = decls[0];
		final innerDecl:RefHit = decls[1];
		Assert.isTrue(innerDecl.span.from > outerDecl.span.from, 'inner decl must follow outer in source');
		final read:RefHit = reads[0];
		final boundTo:Null<Span> = read.bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(innerDecl.span.from, boundTo.from, 'read must bind to INNER decl, not outer — got ${describe(hits)}');
		final outerBind:Null<Span> = outerDecl.bindingSpan;
		final innerBind:Null<Span> = innerDecl.bindingSpan;
		if (outerBind != null) Assert.equals(outerDecl.span.from, outerBind.from, 'outer decl self-binding');
		if (innerBind != null) Assert.equals(innerDecl.span.from, innerBind.from, 'inner decl self-binding');
	}

	public function testFunctionParamShadowsClassField():Void {
		final source:String = 'class X { var arg:Int = 0; static function f(arg:Int):Int { return arg; } }';
		final hits:Array<RefHit> = findIn(source, 'arg');
		final reads:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		final decls:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		Assert.equals(1, reads.length, 'one read at return position — got ${describe(hits)}');
		Assert.equals(2, decls.length, 'field decl + param decl — got ${describe(hits)}');
		final paramDecl:RefHit = decls[1];
		final read:RefHit = reads[0];
		final boundTo:Null<Span> = read.bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(paramDecl.span.from, boundTo.from, 'read binds to param, not class field');
	}

	public function testSiblingFunctionsDoNotCrossResolve():Void {
		final source:String = 'class X { static function a():Int { var n:Int = 0; return n; } '
			+ 'static function b():Int { return n; } }';
		final hits:Array<RefHit> = findIn(source, 'n');
		final reads:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, reads.length, 'two reads expected — got ${describe(hits)}');
		// First read is inside a(); it binds to a()'s local. Second is in
		// b(); it cannot see a()'s local and is unresolved at file level.
		final innerARead:RefHit = reads[0];
		final innerBRead:RefHit = reads[1];
		Assert.notNull(innerARead.bindingSpan, 'a()-read should bind to its local — got ${describe(hits)}');
		Assert.isNull(innerBRead.bindingSpan, 'b()-read must NOT cross-resolve to a()-local — got ${describe(hits)}');
	}

	public function testForLoopOuterReadBindsToOuterDecl():Void {
		// 3.2b gap acknowledged: HxForStmt.varName is absorbed and does not
		// surface as a separate decl-host. The test asserts what 3.2 CAN
		// verify — that an outer `i` Read at `return i` binds to the outer
		// `var i` decl, regardless of the for-loop iterator's invisibility.
		final source:String = 'class X { static function f():Int { var i:Int = 0; '
			+ 'for (i in 0...10) {} return i; } }';
		final hits:Array<RefHit> = findIn(source, 'i');
		final decls:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, 'only outer var i surfaces in 3.2 — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'only the return-site read surfaces — got ${describe(hits)}');
		final outerDecl:RefHit = decls[0];
		final read:RefHit = reads[0];
		final boundTo:Null<Span> = read.bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(outerDecl.span.from, boundTo.from, 'return-read binds to outer var i');
	}

	public function testClassFieldResolvedFromMethodBody():Void {
		final source:String = 'class X { var n:Int = 0; static function f():Int { return n; } }';
		final hits:Array<RefHit> = findIn(source, 'n');
		final reads:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		final decls:Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		Assert.equals(1, reads.length);
		Assert.equals(1, decls.length);
		final field:RefHit = decls[0];
		final read:RefHit = reads[0];
		final boundTo:Null<Span> = read.bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(field.span.from, boundTo.from, 'method-body read resolves to class field');
	}

	public function testDeclSelfBinding():Void {
		final hits:Array<RefHit> = findIn('class Foo { static function bar():Void { var n:Int = 0; } }', 'n');
		for (h in hits) if (h.kind == RefKind.Decl) {
			final boundTo:Null<Span> = h.bindingSpan;
			Assert.notNull(boundTo);
			if (boundTo != null) {
				Assert.equals(h.span.from, boundTo.from, 'decl bindingSpan == own span');
				Assert.equals(h.span.to, boundTo.to);
			}
		}
	}

	private static function findIn(source:String, name:String):Array<RefHit> {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree:QueryNode = plugin.parseFile(source);
		final shape:RefShape = plugin.refShape();
		return Refs.find(name, tree, shape);
	}

	private static function describe(hits:Array<RefHit>):String {
		return '[' + hits.map(h -> {
			final base:String = '${h.kind.toString()}:${h.name}@${h.span.from}-${h.span.to}';
			final b:Null<Span> = h.bindingSpan;
			return b == null ? base : '$base->bind@${b.from}-${b.to}';
		}).join(', ') + ']';
	}
}
