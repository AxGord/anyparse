package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.runtime.Span;

using StringTools;
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

	/**
	 * A local `function f(...) {...}` statement opens its OWN scope frame:
	 * sibling local fns' same-named params must not cross-bind. Regression
	 * for the CallGraph `span` collision — reads inside the second local fn
	 * bound to the FIRST one's param before `LocalFnStmt` joined
	 * `scopeKinds` / `declHostKinds`.
	 */
	public inline function testSiblingLocalFnParamsDoNotCrossBind(): Void {
		assertSiblingParamsDoNotCrossBind('function');
	}

	/**
	 * The same for a local `inline function` - the form the project's Haxe style prescribes for a
	 * local helper. It projects as its own ctor (`LocalInlineFnStmt`, the `inline` keyword folded
	 * into the kind), which was in neither `scopeKinds` nor `declHostKinds`: the parameters of two
	 * sibling inline helpers collected into the ENCLOSING function's single frame, so the second
	 * one's read of `p` bound to the FIRST one's declaration.
	 */
	public inline function testSiblingLocalInlineFnParamsDoNotCrossBind(): Void {
		assertSiblingParamsDoNotCrossBind('inline function');
	}

	/** A local fn's name is a Decl visible from the enclosing body (calls bind to it). */
	public inline function testLocalFnNameIsDecl(): Void {
		assertLocalFnNameIsDecl('function');
	}

	/** A local `inline function`'s name is a Decl visible from the enclosing body, exactly as the plain form's is. */
	public inline function testLocalInlineFnNameIsDecl(): Void {
		assertLocalFnNameIsDecl('inline function');
	}

	/**
	 * Each `switch` arm frames its own body: two arms declaring the SAME name are two distinct
	 * bindings, and each arm's read binds to its own. Before arms framed, the first arm's local
	 * swallowed the second arm's reads as well.
	 */
	public function testCaseArmLocalsAreDistinctBindings(): Void {
		final src: String =
			'class X { static function f(v:Int) { switch v { case 0: var n:Int = 1; trace(n); case _: var n:Int = 2; trace(n); } } }';
		final hits: Array<RefHit> = findIn(src, 'n');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		Assert.equals(2, decls.length);
		for (h in hits) if (h.kind == RefKind.Read) {
			final binding: Null<Span> = h.bindingSpan;
			Assert.notNull(binding);
			// Each read binds to the decl in its OWN arm — the nearer one, textually before it.
			if (binding != null) Assert.isTrue(decls.exists(d -> d.span.from == binding.from && d.span.from < h.span.from));
		}
		final boundTo: Array<Int> = [for (h in hits) if (h.kind == RefKind.Read && h.bindingSpan != null) h.bindingSpan.from];
		Assert.equals(2, boundTo.length);
		Assert.notEquals(boundTo[0], boundTo[1]);
	}

	/** A member read OUTSIDE the switch is not captured by an arm's same-named local. */
	public function testCaseArmLocalDoesNotCaptureFieldReadAfterSwitch(): Void {
		final src: String =
			'class X { var n:Int = 0; function f(v:Int) { switch v { case 0: var n:Int = 1; trace(n); case _: } trace(n); } }';
		final hits: Array<RefHit> = findIn(src, 'n');
		final armDecl: Null<RefHit> = hits.find(h -> h.kind == RefKind.Decl && h.span.from > src.indexOf('switch'));
		Assert.notNull(armDecl);
		final trailing: Null<RefHit> = hits.find(h -> h.kind == RefKind.Read && h.span.from > src.lastIndexOf('} trace'));
		Assert.notNull(trailing);
		if (armDecl != null && trailing != null && trailing.bindingSpan != null)
			Assert.notEquals(armDecl.span.from, trailing.bindingSpan.from);
	}

	/**
	 * An enum-pattern binding is NOT a declaration to this resolver: `case Some(x)` projects `x` as a
	 * plain `IdentExpr` inside the pattern, so it is collected as a READ like the body's own `x` and
	 * binds to nothing. Arm framing therefore does not touch these — worth pinning, because the shape
	 * LOOKS like a per-arm declaration and assuming so costs a wrong blast-radius estimate.
	 */
	public function testEnumPatternBindingIsNotADeclaration(): Void {
		final src: String = 'class X { static function f(v:Opt) { switch v { case Some(x): trace(x); case Other(x): trace(x); } } }';
		final hits: Array<RefHit> = findIn(src, 'x');
		Assert.equals(4, hits.length);
		Assert.equals(0, hits.filter(h -> h.kind == RefKind.Decl).length);
		Assert.equals(0, hits.filter(h -> h.bindingSpan != null).length);
	}

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
		if (boundTo == null) return;
		Assert.equals(iterDecl.span.from, boundTo.from, 'inner read binds to the iterator, not the outer var');
		Assert.notEquals(outerDecl.span.from, boundTo.from, 'inner read must NOT bind to the shadowed outer var');
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
		if (boundTo == null) return;
		Assert.equals(clauseDecl.span.from, boundTo.from, 'inner read binds to the exception, not the outer var');
		Assert.notEquals(outerDecl.span.from, boundTo.from, 'inner read must NOT bind to the shadowed outer var');
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
		if (boundTo == null) return;
		Assert.equals(paramDecl.span.from, boundTo.from, 'inner read binds to the lambda parameter, not the outer var');
		Assert.notEquals(outerDecl.span.from, boundTo.from, 'inner read must NOT bind to the shadowed outer var');
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
		final source: String =
			'class X { static function f():Void { var arr:Array<Int> = []; var i:Int = 0; var v:Int = 0; arr[i] = v; } }';
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

	/**
	 * A binding of the enclosing body stays visible INSIDE a local `inline function` - the new frame
	 * nests rather than isolating it.
	 *
	 * A FORWARD GUARD, not a discriminator: it passes on the base branch too, where the helper's
	 * `BlockBody` frame already nested the capture into the enclosing declaration. What it pins is the
	 * one direction no other test covers - making the frame isolating.
	 */
	public function testLocalInlineFnCapturesEnclosingLocal(): Void {
		final source: String = 'class X { static function outer() {\n\tvar total:Int = 0;\n'
			+ '\tinline function add(n:Int):Int { return total + n; }\n\treturn add(1);\n} }';
		final hits: Array<RefHit> = findIn(source, 'total');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, 'one local decl expected, got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one captured read expected, got ${describe(hits)}');
		if (decls.length != 1 || reads.length != 1) return;
		Assert.equals(decls[0].span.from, reads[0].bindingSpan?.from, 'capture must bind to the enclosing local');
	}

	/**
	 * A qualified static call is a member access, so `find` — a value-binding walker —
	 * classifies nothing for it. That is by design (`rename` rewrites every hit, and a
	 * local `f` must not drag `obj.f` with it); the skip COUNT is what makes the omission
	 * reportable instead of silent.
	 */
	public function testQualifiedStaticCallIsNotAReadButIsCounted(): Void {
		final source: String = 'class B {\n\tfunction g():Int return A.f() + A.f();\n}\n';
		Assert.equals(0, findIn(source, 'f').length, 'a member access is not a value binding');
		Assert.equals(2, skippedIn(source, 'f'));
	}

	/**
	 * Null-safe and force accesses are member accesses too. Counting at the point emission
	 * is declined — rather than matching one access kind by name — is what covers them:
	 * `?.` is the form strict null-safety pushes callers toward, so missing it would leave
	 * the original defect in place for most of a null-safe codebase.
	 */
	public function testNullSafeAndForceAccessAreCounted(): Void {
		final source: String = 'class B {\n\tfunction g(a:Null<A>):Int return a?.only() + a!.only() + A.only();\n}\n';
		Assert.equals(0, findIn(source, 'only').length);
		Assert.equals(3, skippedIn(source, 'only'));
	}

	/** An unqualified same-class static call DOES resolve — a hit is never also a skip. */
	public function testUnqualifiedStaticCallResolvesAndIsNotCounted(): Void {
		final source: String = 'class A {\n\tstatic function f():Int return 1;\n\tstatic function g():Int return f();\n}\n';
		final found: { hits: Array<RefHit>, skipped: Int } = findWithSkippedIn(source, 'f');

		Assert.equals(1, found.hits.filter(h -> h.kind == RefKind.Read).length, 'got ${describe(found.hits)}');
		Assert.equals(0, found.skipped);
	}

	/** Hits and skips are collected in ONE walk, so a file holding both reports both. */
	public function testHitsAndSkipsCoexistInOneWalk(): Void {
		final source: String =
			'class A {\n\tstatic function f():Int return 1;\n}\nclass B {\n\tfunction g():Int return A.f() + A.f();\n}\n';
		final found: { hits: Array<RefHit>, skipped: Int } = findWithSkippedIn(source, 'f');

		Assert.equals(1, found.hits.filter(h -> h.kind == RefKind.Decl).length, 'got ${describe(found.hits)}');
		Assert.equals(2, found.skipped);
	}

	/**
	 * A macro-reification subtree is excluded from the count exactly as it is from the
	 * hits — the counter sits under the same `macroEmit` guard, so the two cannot diverge.
	 */
	public function testMacroReifiedAccessIsNotCounted(): Void {
		Assert.equals(0, skippedIn('class M {\n\tfunction b():Void {\n\t\tvar e = macro { Foo.emitted(); };\n\t}\n}\n', 'emitted'));
	}

	/** A name that appears only as a plain identifier contributes nothing to the count. */
	public function testPlainIdentifierIsNotCounted(): Void {
		Assert.equals(0, skippedIn('class B {\n\tfunction g():Void {\n\t\tfinal v:Int = 1;\n\t\ttrace(v);\n\t}\n}\n', 'v'));
	}

	/**
	 * The VALUE binder of a key-value `for (k => v in m)` is its own decl. The loop node
	 * names only the KEY, so `v` used to have no declaration node at all: the body read
	 * resolved outward to whatever `v` meant in the enclosing scope, which is how a rename
	 * of that outer binding silently rewrote a reference the loop owns.
	 */
	public function testKeyValueValueBinderShadowsOuter(): Void {
		final source: String = 'class X { static function f(m:Map<String, Int>):Void { var v:Int = 0; g(v); for (k => v in m) g(v); } }';
		final hits: Array<RefHit> = findIn(source, 'v');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(2, decls.length, 'outer var v + KeyValueBinder — got ${describe(hits)}');
		Assert.equals(2, reads.length, 'one read outside the loop, one in its body — got ${describe(hits)}');
		final outerDecl: RefHit = decls[0];
		final binderDecl: RefHit = decls[1];
		final outerRead: Null<Span> = reads[0].bindingSpan;
		final bodyRead: Null<Span> = reads[1].bindingSpan;
		Assert.notNull(outerRead);
		Assert.notNull(bodyRead);
		if (outerRead != null) Assert.equals(outerDecl.span.from, outerRead.from, 'the pre-loop read keeps the outer binding');
		if (bodyRead == null) return;
		Assert.equals(binderDecl.span.from, bodyRead.from, 'the body read binds to the value binder');
		Assert.notEquals(outerDecl.span.from, bodyRead.from, 'the body read must NOT bind to the shadowed outer var');
	}

	/**
	 * The key-value binder of a COMPREHENSION (`ForExpr`) binds the same way — the two loop
	 * forms carry the slot independently, so a fixture on the statement form alone would pass
	 * over a grammar that surfaced only one of them.
	 */
	public function testKeyValueValueBinderBindsInComprehension(): Void {
		final source: String = 'class X { static function f(m:Map<String, Int>):Void { var ys = [for (k => v in m) v * 2]; } }';
		final hits: Array<RefHit> = findIn(source, 'v');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, 'one KeyValueBinder decl — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'one read at `v * 2` — got ${describe(hits)}');
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(decls[0].span.from, boundTo.from, 'comprehension read binds to the value binder');
	}

	/**
	 * A braceless `$name` inside a single-quoted string is a READ bound to the enclosing
	 * scope's declaration — the resolution fact every consumer of `Refs` reads.
	 */
	public function testSimpleInterpolationIsRead(): Void {
		final source: String = "class X { static function f():Void { var n:Int = 0; trace('n is $n'); } }";
		final hits: Array<RefHit> = findIn(source, 'n');
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, hits.filter(h -> h.kind == RefKind.Decl).length, 'one VarStmt decl — got ${describe(hits)}');
		Assert.equals(1, reads.length, 'the braceless interpolation is one read — got ${describe(hits)}');
		Assert.isTrue(reads[0].interpolated, 'the interpolation read must be marked — got ${describe(hits)}');
		final boundTo: Null<Span> = reads[0].bindingSpan;
		Assert.notNull(boundTo);
		if (boundTo != null) Assert.equals(hits[0].span.from, boundTo.from, 'interpolation read binds to the local');
	}

	/**
	 * The interpolation hit's span covers the bytes that SPELL the read, `$` included — the
	 * wide-span convention a splicing consumer must locate the identifier token inside.
	 */
	public function testSimpleInterpolationSpanCoversDollar(): Void {
		final source: String = "class X { static function f():Void { var n:Int = 0; trace('$n'); } }";
		final reads: Array<RefHit> = findIn(source, 'n').filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, reads.length, 'one interpolation read expected — got ${describe(reads)}');
		final read: RefHit = reads[0];
		Assert.equals('$$n', source.substring(read.span.from, read.span.to), 'span spells the dollar too — got ${describe([read])}');
	}

	/** An ordinary identifier read carries `interpolated == false`. */
	public function testPlainReadIsNotMarkedInterpolated(): Void {
		final hits: Array<RefHit> = findIn('class X { static function f():Void { var n:Int = 0; trace(n); } }', 'n');
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, reads.length);
		Assert.isFalse(reads[0].interpolated, 'a plain IdentExpr read is not an interpolation');
	}

	/** `$$` is an escaped dollar, so `$$n` is literal text — no read of `n`. */
	public function testEscapedDollarIsNotRead(): Void {
		final source: String = "class X { static function f():Void { var n:Int = 0; trace('$$n'); } }";
		final hits: Array<RefHit> = findIn(source, 'n');
		Assert.equals(0, hits.filter(h -> h.kind == RefKind.Read).length, '`$$n` is literal text — got ${describe(hits)}');
	}

	/** A double-quoted literal never interpolates, so `"$n"` reads nothing. */
	public function testDoubleQuotedStringIsNotRead(): Void {
		final source: String = 'class X { static function f():Void { var n:Int = 0; trace("$$n"); } }';
		final hits: Array<RefHit> = findIn(source, 'n');
		Assert.equals(0, hits.filter(h -> h.kind == RefKind.Read).length, 'no interpolation in "..." — got ${describe(hits)}');
	}

	/**
	 * A `${ … }` hole keeps its parsed expression subtree, whose identifiers are ordinary
	 * `identKind` reads — unmarked, and unchanged by the braceless arm.
	 */
	public function testBracedInterpolationStaysPlainRead(): Void {
		final source: String = "class X { static function f():Void { var n:Int = 0; trace('${n + 1}'); } }";
		final reads: Array<RefHit> = findIn(source, 'n').filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, reads.length, 'one read inside the brace hole');
		Assert.isFalse(reads[0].interpolated, 'a braced-hole interior read is an ordinary IdentExpr');
	}

	/**
	 * Inside a macro-reification subtree the interpolation belongs to the GENERATED code, so
	 * it is a runtime emit — not a reference to the enclosing scope. Same rule the plain
	 * identifier already follows there.
	 */
	public function testInterpolationInsideReificationIsOpaque(): Void {
		final source: String = "class X { static function f():Void { var n:Int = 0; var e = macro 'v $n'; } }";
		final hits: Array<RefHit> = findIn(source, 'n');
		Assert.equals(0, hits.filter(h -> h.kind == RefKind.Read).length, 'reified emit is not a read — got ${describe(hits)}');
	}

	/**
	 * A metadata string argument is an ordinary expression position, so its interpolation is
	 * indexed like any other — the seam that makes `@:meta('$x')` visible to a rename.
	 */
	public function testInterpolationInMetadataArgumentIsRead(): Void {
		final source: String = "class X { static var n:Int = 0; @:tag('$n') static function f():Void {} }";
		final reads: Array<RefHit> = findIn(source, 'n').filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, reads.length, 'the metadata-argument interpolation is a read');
		Assert.isTrue(reads[0].interpolated);
	}

	/**
	 * An escape-SPELLED `$` (`\x24name`) is interpolation to the compiler, and the query tree
	 * re-projects it as the same `Ident` node — so it indexes as a read too.
	 */
	public function testEscapeSpelledInterpolationIsRead(): Void {
		final source: String = "class X { static function f():Void { var n:Int = 0; trace('\\x24n'); } }";
		final reads: Array<RefHit> = findIn(source, 'n').filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, reads.length, 'the rescanned `\\x24n` is a read');
		Assert.isTrue(reads[0].interpolated);
	}

	/**
	 * Two sibling local functions declared with `keyword` bind their same-named parameters
	 * separately. Shared by the plain and the `inline` form: the grammar gives them different
	 * ctors (`LocalFnStmt` / `LocalInlineFnStmt`) but identical binding semantics, and every
	 * `RefShape` seam that lists one must list the other.
	 */
	private function assertSiblingParamsDoNotCrossBind(keyword: String): Void {
		final source: String =
			'class X { static function outer() {\n\t$keyword a(p:Int):Int { return p; }\n\t$keyword b(p:String):String { return p; }\n} }';
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
			if (binding == null) continue;
			final sameLine: Bool = lineOf(source, r.span.from) == lineOf(source, binding.from);
			Assert.isTrue(sameLine, 'read at ${r.span.from} bound across sibling $keyword decls (binding ${binding.from})');
		}
	}

	/** A local function declared with `keyword` binds its own name into the ENCLOSING body, so the call site resolves to it. */
	private function assertLocalFnNameIsDecl(keyword: String): Void {
		final source: String = 'class X { static function outer() {\n\t$keyword helper():Void {}\n\thelper();\n} }';
		final hits: Array<RefHit> = findIn(source, 'helper');
		final decls: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Decl);
		final reads: Array<RefHit> = hits.filter(h -> h.kind == RefKind.Read);
		Assert.equals(1, decls.length, '$keyword decl expected, got ${describe(hits)}');
		Assert.equals(1, reads.length, 'call-site read expected, got ${describe(hits)}');
		if (decls.length != 1 || reads.length != 1) return;
		// The call sits OUTSIDE the declaration's span, so it resolves only if the name binds into the
		// ENCLOSING frame. Counting the two hits is not enough: moving the kind from `declHostKinds` to
		// `selfScopeDeclKinds` - the swap `RefShape`'s contract forbids - still emits a Decl and a Read,
		// and only this assertion fails (measured: it is the sole failing mark of this test under that
		// mutation). Adding the kind to `selfScopeDeclKinds` while it STAYS a decl host is a no-op, since
		// the parent frame's decl-host collection binds the name there either way.
		Assert.equals(decls[0].span.from, reads[0].bindingSpan?.from, 'the call must bind to the $keyword declaration');
	}

	private static function findIn(source: String, name: String): Array<RefHit> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: RefShape = plugin.refShape();
		return Refs.find(name, tree, shape);
	}

	private static function findWithSkippedIn(source: String, name: String): { hits: Array<RefHit>, skipped: Int } {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return Refs.findWithSkipped(name, plugin.parseFile(source), plugin.refShape());
	}

	private static function skippedIn(source: String, name: String): Int {
		return findWithSkippedIn(source, name).skipped;
	}

	private static function describe(hits: Array<RefHit>): String {
		return '[' + hits.map(h -> {
			final base: String = '${h.kind.toString()}${h.interpolated ? '(interp)' : ''}:${h.name}@${h.span.from}-${h.span.to}';
			final b: Null<Span> = h.bindingSpan;
			return b == null ? base : '$base->bind@${b.from}-${b.to}';
		}).join(', ') + ']';
	}

	/** 0-based-agnostic line index of a byte offset in `s` — fixture-local helper. */
	private static function lineOf(s: String, from: Int): Int {
		var line: Int = 0;
		for (i in 0...from) if (s.fastCodeAt(i) == '\n'.code) line++;
		return line;
	}

}
