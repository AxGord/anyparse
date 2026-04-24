package unit;

import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxMemberDecl;
import anyparse.grammar.haxe.HxVarDecl;
import utest.Assert;

/**
 * Tests for the var-no-type slice (slice ω-var-notype): `HxVarDecl.type`
 * is `@:optional`, so any of `var x;`, `var x:Int;`, `var x = 1;`, and
 * `var x:Int = 1;` parse. The `@:lead(':')` on the optional acts as the
 * commit point — matchLit peeks the colon and the sub-rule only fires
 * when the peek hits.
 *
 * Primary corpus target: the `@in var someVar = 123;` /
 * `@in(true) var someVar` fixture (issue_594_metatdata_in) left as
 * skip-parse by ω-member-meta because the member body still choked on
 * the missing `:Type`.
 */
class HxVarNoTypeSliceTest extends HxTestHelpers {

	public function new() {
		super();
	}

	public function testInitOnlyNoType():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x = 1; }');
		Assert.equals('x', (decl.name : String));
		Assert.isNull(decl.type);
		Assert.notNull(decl.init);
	}

	public function testBareNameNoTypeNoInit():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x; }');
		Assert.equals('x', (decl.name : String));
		Assert.isNull(decl.type);
		Assert.isNull(decl.init);
	}

	public function testTypeAndInitStillWorks():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = 42; }');
		Assert.equals('x', (decl.name : String));
		Assert.notNull(decl.type);
		Assert.notNull(decl.init);
	}

	public function testTypeOnlyStillWorks():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int; }');
		Assert.equals('x', (decl.name : String));
		Assert.notNull(decl.type);
		Assert.isNull(decl.init);
	}

	public function testMetadataThenNoTypeInit():Void {
		// Primary corpus target: issue_594_metatdata_in fixture shape.
		final ast:HxClassDecl = HaxeParser.parse('class Foo { @in var someVar = 123; }');
		Assert.equals(1, ast.members.length);
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.meta.length);
		final decl:HxVarDecl = expectVarMember(m.member);
		Assert.equals('someVar', (decl.name : String));
		Assert.isNull(decl.type);
		Assert.notNull(decl.init);
	}

	public function testMetadataWithArgsThenNoType():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { @in(true) var someVar; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(1, m.meta.length);
		final decl:HxVarDecl = expectVarMember(m.member);
		Assert.equals('someVar', (decl.name : String));
		Assert.isNull(decl.type);
		Assert.isNull(decl.init);
	}

	public function testModifiersWithNoType():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { public static var x = 0; }');
		final m:HxMemberDecl = ast.members[0];
		Assert.equals(2, m.modifiers.length);
		final decl:HxVarDecl = expectVarMember(m.member);
		Assert.isNull(decl.type);
		Assert.notNull(decl.init);
	}

	public function testWriterRoundTripInitOnly():Void {
		roundTrip('class Foo { var x = 1; }');
	}

	public function testWriterRoundTripBareName():Void {
		roundTrip('class Foo { var x; }');
	}

	public function testWriterRoundTripMetadataNoType():Void {
		roundTrip('class Foo { @in var someVar = 123; }');
	}

	public function testWriterRoundTripMixedShapes():Void {
		roundTrip('class F { var a; var b:Int; var c = 1; var d:Int = 2; }');
	}

}
