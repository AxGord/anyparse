package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxStatement;

/**
 * Slice 35: `....` placeholder as a function-body statement.
 *
 * `HxStatement` gained a SimpleCtor `@:lit('....') EllipsisStmt;` — the
 * statement-level twin of Slice 33's `HxClassMember.EllipsisMember`
 * (`@:lit('...')`). Targets the haxe-formatter test corpus convention for
 * elided function bodies (`function f() { .... }` in
 * `lineends/issue_369_anon_type_hint_return_value*.hxtest`). Not standard
 * Haxe syntax, but the formatter round-trips these fixtures verbatim.
 *
 * Covers: the isolated ctor inside a function body, writer-equals on the
 * canonical corpus shape, idempotency, and the no-`....` regression
 * (existing ExprStmt / EmptyStmt dispatch unaffected).
 */
class HxEllipsisStmtSliceTest extends HxTestHelpers {

	public function testEllipsisStmtSingleBody():Void {
		final module:HxModule = HaxeModuleParser.parse('class A {\n\tfunction f():Void {\n\t\t....\n\t}\n}');
		Assert.equals(1, module.decls.length);
		final fn:HxFnDecl = expectFnMemberFromTopLevelClass(module, 0);
		final body:Array<HxStatement> = expectFnBodyBlock(fn.body);
		Assert.equals(1, body.length);
		switch body[0] {
			case EllipsisStmt: Assert.pass();
			case _: Assert.fail('expected EllipsisStmt, got ${body[0]}');
		}
	}

	public function testEllipsisStmtWriterEquals():Void {
		writerEquals(
			'class A {\n\tfunction f():Void {\n\t\t....\n\t}\n}',
			'class A {\n\tfunction f():Void {\n\t\t....\n\t}\n}\n'
		);
	}

	public function testEllipsisStmtRoundTrip():Void {
		roundTrip('class A {\n\tfunction f():Void {\n\t\t....\n\t}\n}');
	}

	public function testNoEllipsisStmtRegression():Void {
		final module:HxModule = HaxeModuleParser.parse('class A {\n\tfunction f():Void {\n\t\tx;\n\t}\n}');
		final fn:HxFnDecl = expectFnMemberFromTopLevelClass(module, 0);
		final body:Array<HxStatement> = expectFnBodyBlock(fn.body);
		Assert.equals(1, body.length);
		switch body[0] {
			case ExprStmt(_): Assert.pass();
			case _: Assert.fail('expected ExprStmt, got ${body[0]}');
		}
	}

	private function expectFnMemberFromTopLevelClass(module:HxModule, idx:Int):HxFnDecl {
		final cls = expectClassDecl(module.decls[idx]);
		return expectFnMember(cls.members[0].member);
	}

	private function expectFnBodyBlock(body:HxFnBody):Array<HxStatement> {
		return switch body {
			case BlockBody(stmts): stmts;
			case _: throw 'expected BlockBody, got $body';
		};
	}
}
