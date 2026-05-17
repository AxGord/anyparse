package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.grammar.haxe.HxVarMore;

/**
 * Tests for slice 2 (Phase 3 skip-parse drill) — multi-variable
 * declarations. `HxVarDecl` gains a `@:trivia @:tryparse var
 * more:Array<HxVarMore>` field; each `HxVarMore` is `,` + a full
 * `HxVarDecl`, so `var a, b = 1, c = 2;` and typed
 * `var x:T = e1, y:T = e2;` parse as a single `VarStmt`/`FinalStmt`.
 *
 * The list is right-recursive (each `decl` is a full `HxVarDecl` that
 * itself carries `more`): `var a, b, c;` →
 * `a{more:[{decl: b{more:[{decl: c}]}}]}`, so `more.length` is always
 * exactly 1 until the final binding (`more` empty). `bindingNames`
 * walks that chain — see `HxVarMore`'s doc for the rationale (a flat
 * list would need a ctor-wraps-typedef reshape, out of scope here).
 *
 * Recon-confirmed sole blocker for the `wrapping/issue_355_var_wrapping`
 * cluster (4 clean variants); `whitespace/issue_583_*` has a separate
 * compounding blocker (bodyless `catch (e:Any)`). Pure parse-additive:
 * the `var`/`final` keyword and trailing `;` stay on the enclosing
 * ctor, and `more` is empty for every single-binding declaration, so
 * existing single-var sites are transparent. Mirrors the
 * `HxTypedefDecl.intersections` / `HxIntersectionClause` element-Star
 * precedent.
 *
 * Twin of `HxVarStmtTrailOptSliceTest` — same `parseFunctionBody`
 * helper and `roundTrip` host.
 */
class HxMultiVarDeclSliceTest extends HxTestHelpers {

	// ======== Multi-binding parses into the right-recursive chain ====

	public function testTwoBindingsWithInit():Void {
		Assert.same(['a', 'b'], parseBindingNames('var a = 1, b = 2;'));
	}

	public function testThreeBindingsBareThenInit():Void {
		Assert.same(['v', 'a', 'b'], parseBindingNames('var v, a = 1, b = 2;'));
	}

	public function testTypedMultiBinding():Void {
		// The wrapping/issue_355 motivator shape.
		Assert.same(['rawRead', 'rawWrite'],
			parseBindingNames('var rawRead:Int = getRaw(read), rawWrite:Int = getRaw(write);'));
	}

	public function testFinalMultiBinding():Void {
		final stmts:Array<HxStatement> = parseFunctionBody('final a = 1, b = 2;');
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case FinalStmt(decl): Assert.same(['a', 'b'], bindingNames(decl));
			case _: Assert.fail('expected FinalStmt, got ${stmts[0]}');
		}
	}

	// ======== Single binding still parses, more is empty ========

	public function testSingleBindingMoreIsEmpty():Void {
		final stmts:Array<HxStatement> = parseFunctionBody('var foo = 5;');
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case VarStmt(decl):
				Assert.equals('foo', (decl.name : String));
				Assert.equals(0, decl.more.length);
			case _: Assert.fail('expected VarStmt');
		}
	}

	// ======== Round-trip — writer re-emits the comma list ========

	public function testRoundTripMultiBinding():Void {
		roundTrip('class C { static function m() { var a = 1, b = 2; } }');
		roundTrip('class C { static function m() { var v, a = 1, b = 2; } }');
		roundTrip('class C { static function m() { final a = 1, b = 2; } }');
	}

	// ======== Helpers ========

	private function parseBindingNames(src:String):Array<String> {
		final stmts:Array<HxStatement> = parseFunctionBody(src);
		Assert.equals(1, stmts.length);
		return switch stmts[0] {
			case VarStmt(decl): bindingNames(decl);
			case _:
				Assert.fail('expected VarStmt, got ${stmts[0]}');
				[];
		}
	}

	/** Walk the right-recursive `more` chain, collecting every binding name. */
	private function bindingNames(decl:HxVarDecl):Array<String> {
		final names:Array<String> = [(decl.name : String)];
		var rest:Array<HxVarMore> = decl.more;
		while (rest.length > 0) {
			final next:HxVarDecl = rest[0].decl;
			names.push((next.name : String));
			rest = next.more;
		}
		return names;
	}

	private function parseFunctionBody(src:String):Array<HxStatement> {
		final wrapped:String = 'class C { static function m() { ${src} } }';
		return fnBodyStmts(parseSingleFnDecl(wrapped));
	}

}
