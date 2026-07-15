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
 * `Refs.find` walks a parsed QueryNode tree and collects every name-
 * matching hit classified as `decl` / `read` / `write` per the
 * plugin's `RefShape`.
 *
 * Covers across Phase 3.1 → 3.3:
 *  - Bare identifier read collection (3.1).
 *  - VarStmt / FnDecl / ClassDecl decl-host detection (3.1).
 *  - HxParam binding via the `Required` enum-ctor name slot (3.1).
 *  - Field-access exclusion: `obj.foo` is `FieldAccess`, not
 *    `IdentExpr`; only the receiver `obj` qualifies as a read (3.1).
 *  - Lexical scope: inner local shadows outer field; function
 *    bodies do not cross-resolve; read `bindingSpan` points at the
 *    innermost enclosing decl (3.2).
 *  - Write classification: direct `IdentExpr` child of an assign
 *    ctor (bare / compound / null-coalescing) reclassifies to Write;
 *    nested LHS shapes (`FieldAccess`, `IndexAccess`) keep their
 *    inner identifiers as Reads (3.3).
 *  - Self-scoped decls: the `for` / array-comprehension iterator binds
 *    into the loop's own scope (visible inside the body, shadowing an
 *    outer same-named decl; not visible after the loop) (3.2b-α).
 */
class ApqRefsTest extends Test {

	public function testVarReadAndDeclCollected(): Void {
		final hits: Array<RefHit> = findIn('class X { static function a() { var n:Int = 0; var m:Int = n; } }', 'n');
		Assert.equals(2, hits.length, 'one decl + one read expected, got ${describe(hits)}');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Decl), 'decl hit expected — got ${describe(hits)}');
		Assert.isTrue(hits.exists(h -> h.kind == RefKind.Read), 'read hit expected — got ${describe(hits)}');
	}

	public function testParamDeclCollected(): Void {
		final hits: Array<RefHit> = findIn('class X { static function f(arg:Int):Int { return arg; } }', 'arg');
		Assert.equals(2, hits.length, 'param decl + return-site read expected, got ${describe(hits)}');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		Assert.equals(1, decls.length, 'exactly one decl from HxParam.Required expected');
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, reads.length, 'exactly one read in return position expected');
	}

	public function testTopLevelClassAndFnDeclCollected(): Void {
		final classHits: Array<RefHit> = findIn('class Foo { static function bar():Void {} }', 'Foo');
		Assert.equals(1, classHits.length, 'class decl expected');
		Assert.equals(RefKind.Decl, classHits[0].kind);
		final fnHits: Array<RefHit> = findIn('class Foo { static function bar():Void {} }', 'bar');
		Assert.equals(1, fnHits.length, 'fn-member decl expected');
		Assert.equals(RefKind.Decl, fnHits[0].kind);
	}

	public function testFieldAccessReceiverMatchesAsRead(): Void {
		// `obj.foo` — receiver `obj` IS an IdentExpr (read).
		// The field-side `foo` is HxIdentLit on FieldAccess; it does not
		// produce an IdentExpr QueryNode, so a search for `foo` here
		// returns zero hits.
		final source: String = 'class X { static function a() { var obj:Int = 0; obj.foo; } }';
		final objHits: Array<RefHit> = findIn(source, 'obj');
		Assert.isTrue(objHits.exists(h -> h.kind == RefKind.Read), 'receiver obj must surface as read');
		final fooHits: Array<RefHit> = findIn(source, 'foo');
		Assert.equals(0, fooHits.length, 'field-side `foo` must not surface — FieldAccess does not emit IdentExpr');
	}

	public function testCallOperandReadCollected(): Void {
		final hits: Array<RefHit> = findIn('class X { static function a() { var f:Int->Int = null; f(1); } }', 'f');
		// expect: 1 decl (VarStmt) + 1 read (Call operand) = 2
		Assert.equals(2, hits.length, 'decl + call-operand read expected, got ${describe(hits)}');
	}

	public function testNonMatchingNameReturnsEmpty(): Void {
		final hits: Array<RefHit> = findIn('class X { static function a() { var n:Int = 0; } }', 'z');
		Assert.equals(0, hits.length);
	}

	public function testHitsCarryPositiveSpan(): Void {
		final hits: Array<RefHit> = findIn('class X { static function a() { var n:Int = 0; n; } }', 'n');
		for (h in hits) {
			Assert.isTrue(h.span.from >= 0, 'span.from must be non-negative');
			Assert.isTrue(h.span.to >= h.span.from, 'span.to must be >= span.from');
		}
	}

	public function testRefKindToStringMatchesSpec(): Void {
		Assert.equals('decl', RefKind.Decl.toString());
		Assert.equals('read', RefKind.Read.toString());
		Assert.equals('write', RefKind.Write.toString());
	}

	public function testInnerLocalShadowsClassField(): Void {
		final source: String = 'class X { var n:Int = 0; static function f():Int { var n:Int = 1; return n; } }';
		final hits: Array<RefHit> = findIn(source, 'n');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'outer field + inner local decls expected — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read expected — got ${describe(hits)}');
		final outerDecl: RefHit = decls[0];
		final innerDecl: RefHit = decls[1];
		Assert.isTrue(innerDecl.span.from > outerDecl.span.from, 'inner decl must follow outer in source');
		final read: RefHit = reads[0];
		final boundTo: Null<Span> = read.bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null)
			Assert.equals(innerDecl.span.from, boundTo.from, 'read must bind to INNER decl, not outer — got ${describe(hits)}');
		final outerBind: Null<Span> = outerDecl.bindingSpan;
		final innerBind: Null<Span> = innerDecl.bindingSpan;
		if (outerBind != null) Assert.equals(outerDecl.span.from, outerBind.from, 'outer decl self-binding');
		if (innerBind != null) Assert.equals(innerDecl.span.from, innerBind.from, 'inner decl self-binding');
	}

	public function testFunctionParamShadowsClassField(): Void {
		final source: String = 'class X { var arg:Int = 0; static function f(arg:Int):Int { return arg; } }';
		final hits: Array<RefHit> = findIn(source, 'arg');
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		Assert.equals(1, reads.length, 'one read at return position — got ${describe(hits)}');
		Assert.equals(2, decls.length, 'field decl + param decl — got ${describe(hits)}');
		final paramDecl: RefHit = decls[1];
		final read: RefHit = reads[0];
		final boundTo: Null<Span> = read.bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(paramDecl.span.from, boundTo.from, 'read binds to param, not class field');
	}

	public function testSiblingFunctionsDoNotCrossResolve(): Void {
		final source: String = 'class X { static function a():Int { var n:Int = 0; return n; } static function b():Int { return n; } }';
		final hits: Array<RefHit> = findIn(source, 'n');
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, reads.length, 'two reads expected — got ${describe(hits)}');
		// First read is inside a(); it binds to a()'s local. Second is in
		// b(); it cannot see a()'s local and is unresolved at file level.
		final innerARead: RefHit = reads[0];
		final innerBRead: RefHit = reads[1];
		Assert.notNull(innerARead.bindingSpan, 'a()-read should bind to its local — got ${describe(hits)}');
		Assert.isNull(innerBRead.bindingSpan, 'b()-read must NOT cross-resolve to a()-local — got ${describe(hits)}');
	}

	public function testForLoopOuterReadBindsToOuterDecl(): Void {
		// 3.2b-α: the for-loop iterator now surfaces as its own `ForStmt`
		// decl (self-scoped). The iterator binds INSIDE the loop only, so a
		// `return i` AFTER the loop still resolves to the outer `var i` —
		// two decls total (outer var + ForStmt), one read at the return.
		final source: String = 'class X { static function f():Int { var i:Int = 0; for (i in 0...10) {} return i; } }';
		final hits: Array<RefHit> = findIn(source, 'i');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'outer var i + ForStmt iterator — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'only the return-site read surfaces — got ${describe(hits)}');
		final outerDecl: RefHit = decls[0];
		final read: RefHit = reads[0];
		final boundTo: Null<Span> = read.bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(outerDecl.span.from, boundTo.from, 'return-read binds to outer var i, not the loop iterator');
	}

	public function testForIterVisibleInsideBody(): Void {
		// Read of `i` inside the loop body resolves to the ForStmt
		// iterator (self-scoped decl), not to any enclosing binding.
		final source: String = 'class X { static function f():Void { for (i in 0...10) { var x:Int = i; } } }';
		final hits: Array<RefHit> = findIn(source, 'i');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, 'one ForStmt iterator decl — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read at `var x = i` — got ${describe(hits)}');
		final iterDecl: RefHit = decls[0];
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(iterDecl.span.from, boundTo.from, 'body read binds to the for-loop iterator');
	}

	public function testForIterShadowsOuter(): Void {
		// An outer `var i` plus a same-named loop iterator: a read inside
		// the loop body binds to the iterator (innermost frame wins),
		// shadowing the outer decl.
		final source: String = 'class X { static function f():Void { var i:Int = 0; for (i in 0...10) { g(i); } } }';
		final hits: Array<RefHit> = findIn(source, 'i');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'outer var i + ForStmt iterator — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read at `g(i)` — got ${describe(hits)}');
		final outerDecl: RefHit = decls[0];
		final iterDecl: RefHit = decls[1];
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) {
			Assert.equals(iterDecl.span.from, boundTo.from, 'inner read binds to the iterator, not the outer var');
			Assert.notEquals(outerDecl.span.from, boundTo.from, 'inner read must NOT bind to the shadowed outer var');
		}
	}

	public function testForComprehensionIterBinds(): Void {
		// Expression-position `for` (array comprehension): the `ForExpr`
		// iterator self-binds and the comprehension-body read resolves to
		// it, same as the statement form.
		final source: String = 'class X { static function f():Void { var ys = [for (i in 0...10) i * 2]; } }';
		final hits: Array<RefHit> = findIn(source, 'i');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, 'one ForExpr iterator decl — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read at `i * 2` — got ${describe(hits)}');
		final iterDecl: RefHit = decls[0];
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(iterDecl.span.from, boundTo.from, 'comprehension read binds to the ForExpr iterator');
	}

	public function testCatchExceptionVisibleInClauseBody(): Void {
		// 3.2b-β: the catch-clause exception name surfaces as its own
		// `CatchClause` decl (self-scoped, like a for-loop iterator). A
		// read inside the clause body resolves to it.
		final source: String = 'class X { static function f():Void { try {} catch (e:String) { g(e); } } }';
		final hits: Array<RefHit> = findIn(source, 'e');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, 'one CatchClause exception decl — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read at `g(e)` — got ${describe(hits)}');
		final clauseDecl: RefHit = decls[0];
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(clauseDecl.span.from, boundTo.from, 'body read binds to the catch-clause exception');
	}

	public function testCatchExceptionShadowsOuter(): Void {
		// An outer `var e` plus a same-named catch exception: a read inside
		// the clause body binds to the exception (innermost frame wins),
		// shadowing the outer decl.
		final source: String = 'class X { static function f():Void { var e:Int = 0; try {} catch (e:String) { g(e); } } }';
		final hits: Array<RefHit> = findIn(source, 'e');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'outer var e + CatchClause exception — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read at `g(e)` — got ${describe(hits)}');
		final outerDecl: RefHit = decls[0];
		final clauseDecl: RefHit = decls[1];
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) {
			Assert.equals(clauseDecl.span.from, boundTo.from, 'inner read binds to the exception, not the outer var');
			Assert.notEquals(outerDecl.span.from, boundTo.from, 'inner read must NOT bind to the shadowed outer var');
		}
	}

	public function testCatchExceptionFallsThroughAfter(): Void {
		// The exception binds INSIDE the clause only. A `return e` AFTER
		// the try/catch resolves to the outer `var e`, not the exception.
		final source: String = 'class X { static function f():Int { var e:Int = 0; try {} catch (e:String) {} return e; } }';
		final hits: Array<RefHit> = findIn(source, 'e');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'outer var e + CatchClause exception — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'only the return-site read surfaces — got ${describe(hits)}');
		final outerDecl: RefHit = decls[0];
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(outerDecl.span.from, boundTo.from, 'return-read binds to outer var e, not the exception');
	}

	public function testTwoCatchClausesDistinctBindings(): Void {
		// Two catch clauses with the same exception name: each read binds
		// to its OWN clause (separate scope frames, distinct spans).
		final source: String = 'class X { static function f():Void { try {} catch (e:A) { g(e); } catch (e:B) { h(e); } } }';
		final hits: Array<RefHit> = findIn(source, 'e');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'two CatchClause exception decls — got ${describe(hits)}');
		Assert.equals(2, reads.length, 'one read per clause body — got ${describe(hits)}');
		final firstClause: RefHit = decls[0];
		final secondClause: RefHit = decls[1];
		Assert.isTrue(secondClause.span.from > firstClause.span.from, 'second clause follows first in source');
		final firstBind: Null<Span> = reads[0].bindingSpan;
		final secondBind: Null<Span> = reads[1].bindingSpan;
		Assert.notNull(firstBind);
		Assert.notNull(secondBind);
		if (firstBind != null) Assert.equals(firstClause.span.from, firstBind.from, 'first read binds to first clause');
		if (secondBind != null) Assert.equals(secondClause.span.from, secondBind.from, 'second read binds to second clause');
	}

	public function testLambdaParamVisibleInBody(): Void {
		// 3.2b-β: a lambda parameter surfaces as a `LambdaParam` decl-host
		// bound into the enclosing lambda scope frame; a body read of the
		// parameter resolves to it.
		final source: String = 'class X { static function f():Void { var fn = (x) -> x + 1; } }';
		final hits: Array<RefHit> = findIn(source, 'x');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, 'one LambdaParam decl — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read at `x + 1` — got ${describe(hits)}');
		final paramDecl: RefHit = decls[0];
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(paramDecl.span.from, boundTo.from, 'body read binds to the lambda parameter');
	}

	public function testLambdaParamShadowsOuter(): Void {
		// An outer `var x` plus a same-named lambda parameter: a read in
		// the lambda body binds to the parameter (innermost frame wins).
		final source: String = 'class X { static function f():Void { var x:Int = 0; var fn = (x) -> g(x); } }';
		final hits: Array<RefHit> = findIn(source, 'x');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'outer var x + LambdaParam — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read at `g(x)` — got ${describe(hits)}');
		final outerDecl: RefHit = decls[0];
		final paramDecl: RefHit = decls[1];
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) {
			Assert.equals(paramDecl.span.from, boundTo.from, 'inner read binds to the lambda parameter, not the outer var');
			Assert.notEquals(outerDecl.span.from, boundTo.from, 'inner read must NOT bind to the shadowed outer var');
		}
	}

	public function testClassFieldResolvedFromMethodBody(): Void {
		final source: String = 'class X { var n:Int = 0; static function f():Int { return n; } }';
		final hits: Array<RefHit> = findIn(source, 'n');
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		Assert.equals(1, reads.length);
		Assert.equals(1, decls.length);
		final field: RefHit = decls[0];
		final read: RefHit = reads[0];
		final boundTo: Null<Span> = read.bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(field.span.from, boundTo.from, 'method-body read resolves to class field');
	}

	public function testBareAssignClassifiedAsWrite(): Void {
		// `x = 1` — LHS is a direct IdentExpr child of Assign → Write.
		final source: String = 'class X { static function f():Void { var x:Int = 0; x = 1; } }';
		final hits: Array<RefHit> = findIn(source, 'x');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final writes: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Write);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, 'one VarStmt decl — got ${describe(hits)}');
		Assert.equals(1, writes.length, 'one Assign LHS write — got ${describe(hits)}');
		Assert.equals(0, reads.length, 'Assign LHS must not double as a Read — got ${describe(hits)}');
		final boundTo: Null<Span> = writes[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(decls[0].span.from, boundTo.from, 'write binds to var decl');
	}

	public function testCompoundAssignClassifiedAsWrite(): Void {
		// `x += 1` — LHS is a direct IdentExpr child of AddAssign → Write.
		final source: String = 'class X { static function f():Void { var x:Int = 0; x += 1; } }';
		final hits: Array<RefHit> = findIn(source, 'x');
		final writes: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Write);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, writes.length, 'compound assign LHS classified as Write — got ${describe(hits)}');
		Assert.equals(0, reads.length, 'compound assign LHS not classified as Read — got ${describe(hits)}');
	}

	public function testNullCoalAssignClassifiedAsWrite(): Void {
		// `x ??= 1` — last entry in writeParentKinds; confirms the full list
		// participates, not just the leading `Assign` entry.
		final source: String = 'class X { static function f():Void { var x:Null<Int> = null; x ??= 1; } }';
		final hits: Array<RefHit> = findIn(source, 'x');
		final writes: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Write);
		Assert.equals(1, writes.length, 'NullCoalAssign LHS classified as Write — got ${describe(hits)}');
	}

	public function testFieldAccessLhsKeepsTargetUnaffected(): Void {
		// `obj.x = 1` — LHS is FieldAccess, not IdentExpr. There is no
		// IdentExpr named `x` on the LHS (field name lives on FieldAccess's
		// HxIdentLit slot, not a child node), so a search for `x` after the
		// inner-scope `var x` decl returns the decl and zero Writes.
		final source: String = 'class X { static function f():Void { var obj:Dynamic = null; var x:Int = 0; obj.x = 1; } }';
		final hits: Array<RefHit> = findIn(source, 'x');
		final writes: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Write);
		Assert.equals(0, writes.length, '`obj.x = …` must not surface a Write on `x` — got ${describe(hits)}');
	}

	public function testIndexAccessLhsKeepsInnerIdentsAsReads(): Void {
		// `arr[i] = v` — LHS is IndexAccess wrapping two IdentExprs.
		// Write reclassification fires only for the direct child of the
		// Assign ctor; IdentExprs nested inside IndexAccess stay as Reads.
		final source: String = 'class X { static function f():Void { var arr:Array<Int> = []; var i:Int = 0; var v:Int = 0; arr[i] = v; } }';
		final arrHits: Array<RefHit> = findIn(source, 'arr');
		final iHits: Array<RefHit> = findIn(source, 'i');
		final vHits: Array<RefHit> = findIn(source, 'v');
		Assert.equals(0, arrHits.filter(h -> h.kind == RefKind.Write).length, '`arr` must remain Read — got ${describe(arrHits)}');
		Assert.isTrue(arrHits.exists(h -> h.kind == RefKind.Read), '`arr` Read inside IndexAccess expected — got ${describe(arrHits)}');
		Assert.equals(0, iHits.filter(h -> h.kind == RefKind.Write).length, '`i` must remain Read — got ${describe(iHits)}');
		Assert.isTrue(iHits.exists(h -> h.kind == RefKind.Read), '`i` Read inside IndexAccess expected — got ${describe(iHits)}');
		Assert.equals(0, vHits.filter(h -> h.kind == RefKind.Write).length, '`v` on the RHS must remain Read — got ${describe(vHits)}');
		Assert.isTrue(vHits.exists(h -> h.kind == RefKind.Read), '`v` Read on RHS expected — got ${describe(vHits)}');
	}

	public function testWriteBindingSpanResolvesInnermost(): Void {
		// Outer field + inner local with same name; inner `x = 1` binds to
		// the inner local, not the outer field. Same shadowing rule as
		// Reads — Slice 3.3 reuses Read's resolveInnermost path.
		final source: String = 'class X { var x:Int = 0; static function f():Void { var x:Int = 0; x = 1; } }';
		final hits: Array<RefHit> = findIn(source, 'x');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final writes: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Write);
		Assert.equals(2, decls.length, 'field + local decls — got ${describe(hits)}');
		Assert.equals(1, writes.length, 'one inner write — got ${describe(hits)}');
		final innerDecl: RefHit = decls[1];
		final boundTo: Null<Span> = writes[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(innerDecl.span.from, boundTo.from, 'write binds to INNER local, not outer field');
	}

	public function testDeclSelfBinding(): Void {
		final hits: Array<RefHit> = findIn('class Foo { static function bar():Void { var n:Int = 0; } }', 'n');
		for (h in hits) if (h.kind == RefKind.Decl) {
			final boundTo: Null<Span> = h.bindingSpan;
			Assert.notNull(boundTo);
			if (boundTo != null) {
				Assert.equals(h.span.from, boundTo.from, 'decl bindingSpan == own span');
				Assert.equals(h.span.to, boundTo.to);
			}
		}
	}

	public function testMacroEmittedIdentNotCountedAsRef(): Void {
		// A bare identifier inside `macro {…}` is a runtime emit spliced into
		// generated code, not a reference to the enclosing local — only the decl
		// is collected.
		final hits: Array<RefHit> = findIn('class X { function f() { var ctx = 0; var e = macro ctx.pos; } }', 'ctx');
		Assert.equals(1, hits.length, 'decl only, no macro-emit read — got ${describe(hits)}');
		Assert.equals(RefKind.Decl, hits[0].kind);
	}

	public function testInterpolatedIdentInMacroCountedAsRef(): Void {
		// Interpolations re-open normal resolution: the interpolated identifier IS
		// a genuine compile-time reference, so decl + read are both collected.
		final blockInterp: Array<RefHit> = findIn("class X { function f() { var ctx = 0; var e = macro foo(${ctx}); } }", 'ctx');
		Assert.equals(2, blockInterp.length, 'decl + dollar-block interpolation read — got ${describe(blockInterp)}');
		final reifInterp: Array<RefHit> = findIn("class X { function f() { var ctx = 0; var e = macro foo($v{ctx}); } }", 'ctx');
		Assert.equals(2, reifInterp.length, 'decl + reification interpolation read — got ${describe(reifInterp)}');
	}

	public function testMacroMixedEmitAndInterp(): Void {
		// Within one macro block: the bare emit is skipped, the interpolation is
		// counted — exactly one read survives.
		final hits: Array<RefHit> = findIn("class X { function f() { var ctx = 0; var e = macro { bar(ctx); baz(${ctx}); }; } }", 'ctx');
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, reads.length, 'only the interpolated read, emit skipped — got ${describe(hits)}');
	}

	private static function findIn(source: String, name: String): Array<RefHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: RefShape = plugin.refShape();
		return Refs.find(name, tree, shape);
	}

	private static function describe(hits: Array<RefHit>): String {
		return '[' + hits.map(h -> {
			final base: String = '${h.kind.toString()}:${h.name}@${h.span.from}-${h.span.to}';
			final b: Null<Span> = h.bindingSpan;
			return b == null ? base : '$base->bind@${b.from}-${b.to}';
		}).join(', ') + ']';
	}


	/**
	 * A local `function f(...) {...}` statement opens its OWN scope frame:
	 * sibling local fns' same-named params must not cross-bind. Regression
	 * for the CallGraph `span` collision — reads inside the second local fn
	 * bound to the FIRST one's param before `LocalFnStmt` joined
	 * `scopeKinds` / `declHostKinds`.
	 */
	public function testSiblingLocalFnParamsDoNotCrossBind(): Void {
		final source: String = 'class X { static function outer() {\n\tfunction a(p:Int):Int { return p; }\n'
			+ '\tfunction b(p:String):String { return p; }\n' + '} }';
		final hits: Array<RefHit> = findIn(source, 'p');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'two param decls expected, got ${describe(hits)}');
		Assert.equals(2, reads.length, 'two reads expected, got ${describe(hits)}');
		for (r in reads) {
			final binding: Null<Span> = r.bindingSpan;
			Assert.notNull(binding, 'read must resolve to a binding');
			// Each read binds to the decl of ITS OWN function: the read's span
			// sits on the same fixture line as its binding (fixture is one
			// local fn per line).
			if (binding != null) {
				final sameLine: Bool = lineOf(source, r.span.from) == lineOf(source, binding.from);
				Assert.isTrue(sameLine, 'read at ${r.span.from} bound across sibling local fns (binding ${binding.from})');
			}
		}
	}

	/** A local fn's name is a Decl visible from the enclosing body (calls bind to it). */
	public function testLocalFnNameIsDecl(): Void {
		final source: String = 'class X { static function outer() {\n\tfunction helper():Void {}\n\thelper();\n} }';
		final hits: Array<RefHit> = findIn(source, 'helper');
		Assert.equals(1, hits.filter(h -> h.kind == RefKind.Decl).length, 'local fn decl expected, got ${describe(hits)}');
		Assert.equals(1, hits.filter(h -> h.kind == RefKind.Read).length, 'call-site read expected, got ${describe(hits)}');
	}

	/** 0-based-agnostic line index of a byte offset in `s` — fixture-local helper. */
	private static function lineOf(s: String, from: Int): Int {
		var line: Int = 0;
		for (i in 0...from) if (StringTools.fastCodeAt(s, i) == '\n'.code) line++;
		return line;
	}

}
