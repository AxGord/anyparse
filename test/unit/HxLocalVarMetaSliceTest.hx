package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxMetadataUtil;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice 20 — metadata between `var`/`final` and the binding name on
 * a local statement: `var @:name name = 'Foo';` (fork fixture
 * `whitespace/var_meta_data`).
 *
 * The `meta` Star sits as the first field of `HxVarDecl`, BEFORE the
 * existing `name`/`access`/`type`/`init`/`more` chain. The Star is
 * `@:trivia @:tryparse` with no `@:lead`/`@:trail`/`@:sep` — the
 * try-parse loop attempts an `HxMetadata` parse each iteration and
 * breaks when the next token isn't `@`. Empty meta on the dominant
 * "no-metadata" case keeps every existing class-member, anon-struct,
 * top-level decl, expression-position `VarExpr`/`FinalExpr`, and
 * `HxVarMore` site byte-identical.
 *
 * Class-member and anon-struct positions stay permissive: the macro
 * pipeline accepts `class C { var @:foo x:Int; }` because the same
 * `HxVarDecl` field is reached, even though that placement is
 * non-canonical in Haxe (class-member metadata is normally
 * captured by `HxMemberDecl.meta`, BEFORE the `var` keyword).
 */
class HxLocalVarMetaSliceTest extends HxTestHelpers {

	private function fnBodyStmtsFromSource(source: String): Array<HxStatement> {
		final fn: HxFnDecl = parseSingleFnDecl(source);
		return fnBodyStmts(fn);
	}

	private function expectVarStmtDecl(stmt: HxStatement): HxVarDecl {
		return switch stmt {
			case VarStmt(decl): decl;
			case _: throw 'expected VarStmt, got $stmt';
		};
	}

	private function expectFinalStmtDecl(stmt: HxStatement): HxVarDecl {
		return switch stmt {
			case FinalStmt(decl): decl;
			case _: throw 'expected FinalStmt, got $stmt';
		};
	}

	private function metaName(m: HxMetadata): String {
		return switch m {
			case MetaCall(call): (call.name: String);
			case _: HxMetadataUtil.source(m);
		};
	}

	// -- Single meta before a local var name (the fork fixture) --

	public function testSingleMetaBeforeLocalVarName(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource("class M { function main() { var @:name name = 'Foo'; } }");
		Assert.equals(1, stmts.length);
		final decl: HxVarDecl = expectVarStmtDecl(stmts[0]);
		Assert.equals(1, decl.meta.length);
		Assert.equals('@:name', metaName(decl.meta[0]));
		Assert.equals('name', (decl.name: String));
		Assert.notNull(decl.init);
	}

	// -- Multiple meta before a local var name --

	public function testMultipleMetaBeforeLocalVarName(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { function main() { var @:foo @:bar(1) x = 1; } }');
		final decl: HxVarDecl = expectVarStmtDecl(stmts[0]);
		Assert.equals(2, decl.meta.length);
		Assert.equals('@:foo', metaName(decl.meta[0]));
		Assert.equals('@:bar', metaName(decl.meta[1]));
		Assert.equals('x', (decl.name: String));
	}

	// -- Meta before `final` local --

	public function testMetaBeforeFinalLocal(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { function main() { final @:keep y = 1; } }');
		final decl: HxVarDecl = expectFinalStmtDecl(stmts[0]);
		Assert.equals(1, decl.meta.length);
		Assert.equals('@:keep', metaName(decl.meta[0]));
		Assert.equals('y', (decl.name: String));
	}

	// -- No-meta regression: meta Star stays empty for the common case --

	public function testNoMetaStaysEmpty(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { function main() { var x = 1; } }');
		final decl: HxVarDecl = expectVarStmtDecl(stmts[0]);
		Assert.equals(0, decl.meta.length);
		Assert.equals('x', (decl.name: String));
	}

	public function testNoMetaRoundTripUnchanged(): Void {
		roundTrip('class M { function main() { var x = 1; } }', 'no-meta local var');
		roundTrip('class M { function main() { final y:Int = 2; } }', 'no-meta local final');
	}

	// -- Round-trip the fork fixture body --

	public function testForkFixtureRoundTrip(): Void {
		roundTrip("class Main {\n\tfunction main() {\n\t\tvar @:name name = 'Foo';\n\t}\n}", 'fork var_meta_data fixture');
	}

	// -- Meta inside an HxVarMore continuation (`var a, @:foo b`) --

	public function testMetaOnVarMoreContinuation(): Void {
		final stmts: Array<HxStatement> = fnBodyStmtsFromSource('class M { function main() { var a = 1, @:foo b = 2; } }');
		final decl: HxVarDecl = expectVarStmtDecl(stmts[0]);
		Assert.equals(0, decl.meta.length);
		Assert.equals('a', (decl.name: String));
		Assert.equals(1, decl.more.length);
		final tail: HxVarDecl = decl.more[0].decl;
		Assert.equals(1, tail.meta.length);
		Assert.equals('@:foo', metaName(tail.meta[0]));
		Assert.equals('b', (tail.name: String));
	}

}
