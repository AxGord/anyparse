package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxIdentLit;
import anyparse.grammar.haxe.HxType;
import anyparse.grammar.haxe.HxTypeRef;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 skeleton tests for the macro-generated Haxe parser.
 *
 * Validates the smallest useful subset of the Haxe language:
 *  - empty class declarations,
 *  - classes with zero or more `var` members,
 *  - classes with zero or more `function` members (empty signature,
 *    empty body),
 *  - mixed member lists,
 *  - whitespace resilience via `@:ws`,
 *  - the Kw strategy's word-boundary guarantee (`classy` is not a
 *    truncated `class`).
 *
 * These tests are hand-written rather than sourced from the user's
 * haxe-formatter fork test corpus — the formatter corpus covers the
 * full language (ternaries, macros, switch, type parameters, …) and
 * would be ~95% red against the skeleton grammar. Corpus integration
 * is a later Phase 3 milestone, once the grammar covers enough
 * constructs for the signal to dominate the noise.
 */
class HaxeFirstSliceTest extends Test {

	public function new() {
		super();
	}

	public function testEmptyClass():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo {}');
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(0, ast.members.length);
	}

	public function testClassWithOneVar():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var x:Int; }');
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(1, ast.members.length);
		assertVarMember(ast.members[0].member, 'x', 'Int');
	}

	public function testClassWithMultipleVars():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var x:Int; var y:String; var z:Bool; }');
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(3, ast.members.length);
		assertVarMember(ast.members[0].member, 'x', 'Int');
		assertVarMember(ast.members[1].member, 'y', 'String');
		assertVarMember(ast.members[2].member, 'z', 'Bool');
	}

	public function testClassWithOneFunction():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { function bar():Void {} }');
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(1, ast.members.length);
		assertFnMember(ast.members[0].member, 'bar', 'Void');
	}

	public function testClassWithMixedMembers():Void {
		final ast:HxClassDecl = HaxeParser.parse('class Foo { var count:Int; function tick():Void {} var name:String; }');
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(3, ast.members.length);
		assertVarMember(ast.members[0].member, 'count', 'Int');
		assertFnMember(ast.members[1].member, 'tick', 'Void');
		assertVarMember(ast.members[2].member, 'name', 'String');
	}

	public function testIrregularWhitespace():Void {
		final source:String = 'class\n\tFoo\n{\n\tvar\tx\t:\tInt\t;\n\tfunction bar\t():\tVoid\t{}\n}';
		final ast:HxClassDecl = HaxeParser.parse(source);
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(2, ast.members.length);
		assertVarMember(ast.members[0].member, 'x', 'Int');
		assertFnMember(ast.members[1].member, 'bar', 'Void');
	}

	public function testRejectsClassyAsClass():Void {
		// `classy` must not match the `class` keyword — the Kw strategy
		// enforces a word boundary, so the leading `class` rule fails
		// and the overall parse fails because no other rule matches.
		Assert.raises(() -> HaxeParser.parse('classy {}'), ParseError);
	}

	public function testRejectsMissingClassName():Void {
		Assert.raises(() -> HaxeParser.parse('class { var x:Int; }'), ParseError);
	}

	public function testRejectsMissingClassBrace():Void {
		Assert.raises(() -> HaxeParser.parse('class Foo var x:Int;'), ParseError);
	}

	public function testRejectsUnknownMember():Void {
		// `let` is not a valid Haxe class-member introducer — the Alt
		// tries both VarMember and FnMember and both fail their keyword
		// match, so the loop throws on the first member.
		Assert.raises(() -> HaxeParser.parse('class Foo { let x:Int; }'), ParseError);
	}

	public function testSkipsLineComment():Void {
		// Line comments `// ...` consumed by the comment-aware `skipWs`
		// generated from HaxeFormat's `lineComment` field. Plain-mode
		// parsers skip-and-discard — source-fidelity comment capture
		// lives in Trivia-mode variants.
		final ast:HxClassDecl = HaxeParser.parse('class Foo { // trailing note\n\tvar x:Int; }');
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(1, ast.members.length);
		assertVarMember(ast.members[0].member, 'x', 'Int');
	}

	public function testSkipsBlockComment():Void {
		// Block comments `/* ... */` consumed similarly via
		// `blockComment` open/close delimiters on HaxeFormat.
		final ast:HxClassDecl = HaxeParser.parse('class /* name */ Foo { /* empty */ }');
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(0, ast.members.length);
	}

	public function testSkipsMultiLineBlockComment():Void {
		// Block comments may span multiple lines — scanner walks past
		// interior newlines until it finds the close delimiter.
		final ast:HxClassDecl = HaxeParser.parse('class Foo {\n\t/*\n\t * multi\n\t * line\n\t */\n\tvar x:Int;\n}');
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(1, ast.members.length);
		assertVarMember(ast.members[0].member, 'x', 'Int');
	}

	public function testSkipsMixedCommentsAndWhitespace():Void {
		// Interleaved `//`, `/* */`, whitespace — all collapsed in a
		// single `skipWs` call between tokens.
		final source:String = 'class // hdr\n\t/* tag */ Foo /* ok */ {\n\t// field\n\tvar x:Int; // inline\n}';
		final ast:HxClassDecl = HaxeParser.parse(source);
		Assert.equals('Foo', (ast.name : String));
		Assert.equals(1, ast.members.length);
		assertVarMember(ast.members[0].member, 'x', 'Int');
	}

	private function assertVarMember(member:HxClassMember, expectedName:String, expectedType:String):Void {
		switch member {
			case VarMember(decl):
				Assert.equals(expectedName, (decl.name : String));
				Assert.equals(expectedType, (namedRef(decl.type).name : String));
			case _:
				Assert.fail('expected VarMember, got $member');
		}
	}

	private function assertFnMember(member:HxClassMember, expectedName:String, expectedReturnType:String):Void {
		switch member {
			case FnMember(decl):
				Assert.equals(expectedName, (decl.name : String));
				Assert.equals(expectedReturnType, (namedRef(decl.returnType).name : String));
			case _:
				Assert.fail('expected FnMember, got $member');
		}
	}

	private static function namedRef(t:Null<HxType>):HxTypeRef {
		return switch t {
			case null: throw 'expected HxType.Named, got null';
			case Named(ref): ref;
		};
	}
}
