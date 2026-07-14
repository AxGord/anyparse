package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxMetadataUtil;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice 37 — `static var` / `static final` local-statement declarations
 * (Haxe 4.3 static-locals feature, persists across function calls).
 *
 * Two new ctors on `HxStatement`: `StaticVarStmt` and `StaticFinalStmt`,
 * byte-twin of `VarStmt` / `FinalStmt`. The `static` prefix dispatches via
 * `@:kw('static') @:lead('var')` / `@:lead('final')` — kw+lead single-Ref
 * pattern (precedent: `LocalInlineFnStmt` `@:kw('inline') @:lead('function')`).
 * Reuses `HxVarDecl`, so Slice 2 multi-var (`static var a, b;`) and Slice 20
 * leading-meta (`static final @Test a = 1, b = 2;`) compose for free.
 *
 * Unblocks `whitespace/static_locals.hxtest` (sole-blocker confirmed by
 * `hxq recon --predict-strip` pre-edit).
 */
class HxStaticLocalStmtSliceTest extends HxTestHelpers {

	// -- Static var with init --

	public function testStaticVarStmt(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { static function main() { static var x = 1; } }');
		Assert.equals(1, stmts.length);
		final decl: HxVarDecl = expectStaticVarStmtDecl(stmts[0]);
		Assert.equals('x', (decl.name: String));
		Assert.notNull(decl.init);
	}

	// -- Static final with init --

	public function testStaticFinalStmt(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { static function main() { static final y = 2; } }');
		final decl: HxVarDecl = expectStaticFinalStmtDecl(stmts[0]);
		Assert.equals('y', (decl.name: String));
		Assert.notNull(decl.init);
	}

	// -- Static var multi-var (Slice 2 compose) --

	public function testStaticVarMulti(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { static function main() { static var a, b; } }');
		final decl: HxVarDecl = expectStaticVarStmtDecl(stmts[0]);
		Assert.equals('a', (decl.name: String));
		Assert.equals(1, decl.more.length);
		final tail: HxVarDecl = decl.more[0].decl;
		Assert.equals('b', (tail.name: String));
	}

	// -- Static final with leading meta + multi-var (Slice 20 + Slice 2 compose),
	//    the canonical corpus fixture shape --

	public function testStaticFinalLeadingMetaMulti(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { static function main() { static final @Test a = 1, b = 2; } }');
		final decl: HxVarDecl = expectStaticFinalStmtDecl(stmts[0]);
		Assert.equals(1, decl.meta.length);
		Assert.equals('@Test', metaName(decl.meta[0]));
		Assert.equals('a', (decl.name: String));
		Assert.equals(1, decl.more.length);
		final tail: HxVarDecl = decl.more[0].decl;
		Assert.equals('b', (tail.name: String));
	}

	// -- writerEquals on simple static-local shapes (single binding) --
	// Note: the multi-var/leading-meta corpus shape (`static final @Test
	// a = 1, b = 2;` etc.) round-trips, but the HxVarMore `,` writer is
	// tight (`,b`, not `, b`) so a byte-equal assert against the
	// human-canonical form is out of scope for this slice. The
	// `roundTrip` helper covers the multi-var path via AST-level parity.

	public function testStaticVarWriterEquals(): Void {
		writerEquals(
			'class M {\n\tstatic function m() {\n\t\tstatic var x = 1;\n\t}\n}',
			'class M {\n\tstatic function m() {\n\t\tstatic var x = 1;\n\t}\n}\n'
		);
	}

	public function testStaticFinalWriterEquals(): Void {
		writerEquals(
			'class M {\n\tstatic function m() {\n\t\tstatic final y = 2;\n\t}\n}',
			'class M {\n\tstatic function m() {\n\t\tstatic final y = 2;\n\t}\n}\n'
		);
	}

	public function testStaticLocalsRoundTrip(): Void {
		roundTrip(
			'class Main {\n\tstatic function main() {\n\t\tstatic final @Test a = 1, b = 2;\n\t\tstatic var c, d;\n\t\tfinal e = 2;\n\t\tvar f;\n\t}\n}'
		);
	}

	// -- No-static regression: bare `var`/`final` still route to VarStmt/FinalStmt --

	public function testNoStaticVarStmtRegression(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { function main() { var x = 1; } }');
		switch stmts[0] {
			case VarStmt(_):
				Assert.pass();
			case _:
				Assert.fail('expected VarStmt, got ${stmts[0]}');
		}
	}

	public function testNoStaticFinalStmtRegression(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { function main() { final x = 1; } }');
		switch stmts[0] {
			case FinalStmt(_):
				Assert.pass();
			case _:
				Assert.fail('expected FinalStmt, got ${stmts[0]}');
		}
	}

	private function fnBodyStmtsFromSource(source: String): Array<HxStatement> {
		final fn: HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	private function expectStaticVarStmtDecl(stmt: HxStatement): HxVarDecl {
		return switch stmt {
			case StaticVarStmt(decl): decl;
			case _: throw 'expected StaticVarStmt, got $stmt';
		};
	}

	private function expectStaticFinalStmtDecl(stmt: HxStatement): HxVarDecl {
		return switch stmt {
			case StaticFinalStmt(decl): decl;
			case _: throw 'expected StaticFinalStmt, got $stmt';
		};
	}

	private function metaName(m: HxMetadata): String {
		return switch m {
			case MetaCall(call): (call.name: String);
			case _: HxMetadataUtil.source(m);
		};
	}

}
