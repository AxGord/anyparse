package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxForExpr;
import anyparse.grammar.haxe.HxForStmt;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxKeyValueBinder;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * Slice apq-P5-K2: map key-value `for (k => v in m)` iteration.
 *
 * `HxForStmt` and `HxForExpr` gained an optional `valueName` field (`@:optional @:lead('=>') var
 * valueName:Null<HxKeyValueBinder>`) between `varName` and the `in` keyword — the same optional-single-Ref-with-
 * literal-commit pattern as `HxParamBody.defaultValue`
 * (`@:optional @:lead('=')`) and `HxFnDecl.returnType`
 * (`@:optional @:lead(':')`). Additive: zero core/synth/writer change.
 *
 * Contract mirrors the probed single-iter precedent: plain
 * `for (v in m)` keeps `valueName == null` (the `=>` peek fails on
 * `in`), so the existing form is a strict regression guard. Both the
 * statement (`HxForStmt` via `HxStatement.ForStmt`) and the
 * expression-comprehension (`HxForExpr` via `HxExpr.ForExpr`) forms
 * are covered, since the single grammar edit was applied to both.
 */
class HxForKeyValueSliceTest extends HxTestHelpers {

	// --- statement scope ---

	public function testForStmtKeyValue(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f(m:Map<Int,Int>):Void { for (k => v in m) trace(k); } }');
		Assert.equals(1, body.length);
		final fs: HxForStmt = expectForStmt(body[0]);
		Assert.equals('k', (fs.varName: String));
		Assert.notNull(fs.valueName);
		Assert.equals('v', valueBinderName(fs.valueName));
	}

	public function testForStmtSingleIterStillNull(): Void {
		final body: Array<HxStatement> = parseBody('class C { function f(xs:Array<Int>):Void { for (v in xs) trace(v); } }');
		final fs: HxForStmt = expectForStmt(body[0]);
		Assert.equals('v', (fs.varName: String));
		Assert.isNull(fs.valueName);
	}

	public function testForStmtKeyValueBlockBodyUsesBoth(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f(m:Map<String,Int>):Void { for (key => val in m) { trace(key); trace(val); } } }'
		);
		final fs: HxForStmt = expectForStmt(body[0]);
		Assert.equals('key', (fs.varName: String));
		Assert.equals('val', valueBinderName(fs.valueName));
	}

	public function testNestedForStmtKeyValue(): Void {
		final body: Array<HxStatement> = parseBody(
			'class C { function f(m:Map<Int,Int>, n:Map<Int,Int>):Void { for (k => v in m) for (k2 => v2 in n) trace(k); } }'
		);
		final outer: HxForStmt = expectForStmt(body[0]);
		Assert.equals('k', (outer.varName: String));
		Assert.equals('v', valueBinderName(outer.valueName));
		final inner: HxForStmt = expectForStmt(outer.body);
		Assert.equals('k2', (inner.varName: String));
		Assert.equals('v2', valueBinderName(inner.valueName));
	}

	// --- expression-comprehension scope ---

	public function testForExprComprehensionKeyValue(): Void {
		final init: HxExpr = parseVarInit('class C { function f(m:Map<Int,Int>):Void { var a = [for (k => v in m) v]; } }');
		final elems: Array<HxExpr> = expectArrayExpr(init);
		Assert.equals(1, elems.length);
		final fe: HxForExpr = expectForExpr(elems[0]);
		Assert.equals('k', (fe.varName: String));
		Assert.equals('v', valueBinderName(fe.valueName));
	}

	public function testForExprComprehensionSingleIterStillNull(): Void {
		final init: HxExpr = parseVarInit('class C { function f():Void { var a = [for (i in 0...10) i]; } }');
		final fe: HxForExpr = expectForExpr(expectArrayExpr(init)[0]);
		Assert.equals('i', (fe.varName: String));
		Assert.isNull(fe.valueName);
	}

	/**
	 * The QueryNode projection, which is the contract every consumer indexes on: the loop keeps
	 * the KEY as its own `name`, the VALUE arrives as a `KeyValueBinder` child spanning exactly
	 * the identifier, and it sits AHEAD of the iterable — so a consumer reading loop operands
	 * has to skip it (`RefShape.iterationValueBinderKinds`) rather than take `children[0]`.
	 */
	public function testKeyValueProjectsBinderChildBeforeIterable(): Void {
		final source: String = 'class C { function f(m:Map<Int,Int>):Void { for (k => v in m) trace(v); } }';
		final loop: Null<QueryNode> = firstOfKind(new HaxeQueryPlugin().parseFile(source), 'ForStmt');
		Assert.notNull(loop);
		if (loop == null) return;
		Assert.equals('k', loop.name);
		Assert.equals(3, loop.children.length);
		final binder: QueryNode = loop.children[0];
		Assert.equals('KeyValueBinder', binder.kind);
		Assert.equals('v', binder.name);
		final binderSpan: Null<Span> = binder.span;
		Assert.notNull(binderSpan);
		if (binderSpan != null) Assert.equals('v', source.substring(binderSpan.from, binderSpan.to));
		Assert.equals('IdentExpr', loop.children[1].kind);
	}

	/** A single-binder loop projects no binder child at all — the shape every existing consumer was written against. */
	public function testSingleIterProjectsNoBinderChild(): Void {
		final loop: Null<QueryNode> = firstOfKind(
			new HaxeQueryPlugin().parseFile('class C { function f(xs:Array<Int>):Void { for (v in xs) trace(v); } }'), 'ForStmt'
		);
		Assert.notNull(loop);
		if (loop == null) return;
		Assert.equals('v', loop.name);
		Assert.equals(2, loop.children.length);
		Assert.equals('IdentExpr', loop.children[0].kind);
	}

	private function parseBody(source: String): Array<HxStatement> {
		return fnBodyStmts(parseSingleFnDecl(source));
	}

	private function expectForStmt(stmt: HxStatement): HxForStmt {
		return switch stmt {
			case ForStmt(s): s;
			case _: throw 'expected ForStmt, got $stmt';
		};
	}

	private function parseVarInit(source: String): HxExpr {
		final stmt: HxStatement = parseBody(source)[0];
		return switch stmt {
			case VarStmt(decl): decl.init ?? throw 'var has no init';
			case _: throw 'expected VarStmt, got $stmt';
		};
	}

	private function expectForExpr(e: HxExpr): HxForExpr {
		return switch e {
			case ForExpr(s): s;
			case _: throw 'expected ForExpr, got $e';
		};
	}

	private function expectArrayExpr(e: HxExpr): Array<HxExpr> {
		return switch e {
			case ArrayExpr(elems): elems;
			case _: throw 'expected ArrayExpr, got $e';
		};
	}

	/** The bound name of an optional key-value VALUE binder, or null when the loop is single-iter. */
	private static function valueBinderName(binder: Null<HxKeyValueBinder>): Null<String> {
		return binder == null ? null : (binder.name: String);
	}

	/** The first node of `kind` in pre-order, or null when the tree holds none. */
	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

}
