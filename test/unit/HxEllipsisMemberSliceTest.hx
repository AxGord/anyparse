package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxModule;

/**
 * Slice 33: `...` placeholder as a class-body member.
 *
 * `HxClassMember` gained a SimpleCtor `@:lit('...') EllipsisMember;` —
 * a literal-only ctor (no payload) twin of `HxStatement.EmptyStmt(';')`.
 * Targets the haxe-formatter test corpus convention for elided code
 * (`class A { ... }` in `emptylines/issue_255_*` fixtures). Not standard
 * Haxe syntax, but the formatter round-trips these files verbatim.
 *
 * Covers: the isolated ctor in single- and two-class module forms,
 * writer-equals on the canonical corpus shape (tabs + blank line
 * between classes), idempotency, and the no-`...` regression
 * (existing var/fn dispatch unaffected).
 */
class HxEllipsisMemberSliceTest extends HxTestHelpers {

	public function testEllipsisMemberSingleClass():Void {
		final cls:HxClassDecl = HaxeParser.parse('class A { ... }');
		Assert.equals(1, cls.members.length);
		switch cls.members[0].member {
			case EllipsisMember: Assert.pass();
			case _: Assert.fail('expected EllipsisMember, got ${cls.members[0].member}');
		}
	}

	public function testEllipsisMemberTwoClasses():Void {
		final module:HxModule = HaxeModuleParser.parse(
			'class A {\n\t...\n}\n\nclass B {\n\t...\n}'
		);
		Assert.equals(2, module.decls.length);
	}

	public function testEllipsisMemberWriterEquals():Void {
		writerEquals(
			'class A {\n\t...\n}\n\nclass B {\n\t...\n}',
			'class A {\n\t...\n}\n\nclass B {\n\t...\n}\n'
		);
	}

	public function testEllipsisMemberRoundTrip():Void {
		roundTrip('class A {\n\t...\n}\n\nclass B {\n\t...\n}');
	}

	public function testNoEllipsisRegression():Void {
		final cls:HxClassDecl = HaxeParser.parse('class C {\n\tvar x:Int;\n}');
		Assert.equals(1, cls.members.length);
		Assert.equals('x', (expectVarMember(cls.members[0].member).name : String));
	}
}
