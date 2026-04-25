package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxFnBody;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.runtime.ParseError;

/**
 * Tests for `function name():T;` (no-body abstract method form) on
 * `HxFnDecl.body`. Adds the `NoBody` branch to `HxFnBody` while keeping
 * `BlockBody({ stmts })` working byte-identically.
 *
 * Coverage:
 *  - parse: NoBody dispatched by `;` — interface, class, abstract, with
 *    and without return type, with type params, with parameters.
 *  - parse: BlockBody dispatched by `{` — preserves existing semantics
 *    (regression check from this slice's neighbour tests).
 *  - parse: rejects `function f():Int` (neither `;` nor `{`).
 *  - writer: NoBody round-trips as `function name();` (no space before
 *    `;`, no inserted braces).
 *  - writer: BlockBody still respects `@:fmt(leftCurly)` brace policy.
 *  - module-root smoke through `HaxeModuleParser`.
 */
class HxNoBodyAbstractTest extends HxTestHelpers {

	private function parseInterfaceMembers(source:String):Array<HxFnDecl> {
		final m:HxModule = HaxeModuleParser.parse(source);
		Assert.equals(1, m.decls.length);
		final iface:HxInterfaceDecl = expectInterfaceDecl(m.decls[0]);
		final out:Array<HxFnDecl> = [];
		for (mb in iface.members) {
			final member:HxClassMember = mb.member;
			out.push(switch member {
				case FnMember(d): d;
				case _: throw 'expected FnMember';
			});
		}
		return out;
	}

	// ---- parse: NoBody ----

	public function testInterfaceMethodNoBody():Void {
		final fns:Array<HxFnDecl> = parseInterfaceMembers('interface IFoo { function bar():Void; }');
		Assert.equals(1, fns.length);
		Assert.equals('bar', (fns[0].name : String));
		Assert.equals('Void', (expectNamedType(fns[0].returnType).name : String));
		Assert.isTrue(fns[0].body.match(NoBody));
	}

	public function testInterfaceMultipleMethodsNoBody():Void {
		final fns:Array<HxFnDecl> = parseInterfaceMembers(
			'interface IFoo { function a():Int; function b(x:String):Void; }'
		);
		Assert.equals(2, fns.length);
		Assert.equals('a', (fns[0].name : String));
		Assert.equals(0, fns[0].params.length);
		Assert.isTrue(fns[0].body.match(NoBody));
		Assert.equals('b', (fns[1].name : String));
		Assert.equals(1, fns[1].params.length);
		Assert.isTrue(fns[1].body.match(NoBody));
	}

	public function testNoBodyWithoutReturnType():Void {
		final fns:Array<HxFnDecl> = parseInterfaceMembers('interface IFoo { function bar(); }');
		Assert.equals(1, fns.length);
		Assert.isNull(fns[0].returnType);
		Assert.isTrue(fns[0].body.match(NoBody));
	}

	public function testNoBodyWithTypeParams():Void {
		final fns:Array<HxFnDecl> = parseInterfaceMembers('interface IFoo { function bar<T>(x:T):T; }');
		Assert.equals(1, fns.length);
		Assert.notNull(fns[0].typeParams);
		Assert.equals(1, fns[0].typeParams.length);
		Assert.equals('T', (fns[0].typeParams[0] : String));
		Assert.isTrue(fns[0].body.match(NoBody));
	}

	public function testNoBodyOnClassMember():Void {
		final m:HxModule = HaxeModuleParser.parse('class C { function abstractish():Void; }');
		Assert.equals(1, m.decls.length);
		final cls:HxClassDecl = expectClassDecl(m.decls[0]);
		Assert.equals(1, cls.members.length);
		final fn:HxFnDecl = expectFnMember(cls.members[0].member);
		Assert.isTrue(fn.body.match(NoBody));
	}

	public function testNoBodyOnAbstractMember():Void {
		final m:HxModule = HaxeModuleParser.parse('abstract A(Int) { function decl():Void; }');
		Assert.equals(1, m.decls.length);
		final ad:HxAbstractDecl = expectAbstractDecl(m.decls[0]);
		Assert.equals(1, ad.members.length);
		final fn:HxFnDecl = expectFnMember(ad.members[0].member);
		Assert.isTrue(fn.body.match(NoBody));
	}

	public function testNoBodyWhitespace():Void {
		final fns:Array<HxFnDecl> = parseInterfaceMembers('interface IFoo {  function  bar (  ) : Void  ;  }');
		Assert.isTrue(fns[0].body.match(NoBody));
	}

	// ---- parse: BlockBody regression ----

	public function testBlockBodyStillWorksAlongsideNoBody():Void {
		final fns:Array<HxFnDecl> = parseInterfaceMembers(
			'interface IFoo { function a():Void; function b():Int { return 1; } function c():Bool; }'
		);
		Assert.equals(3, fns.length);
		Assert.isTrue(fns[0].body.match(NoBody));
		switch fns[1].body {
			case BlockBody(block): Assert.equals(1, block.stmts.length);
			case _: Assert.fail('expected BlockBody for fns[1]');
		}
		Assert.isTrue(fns[2].body.match(NoBody));
	}

	// ---- parse: rejects malformed ----

	public function testRejectsFunctionWithoutBodyOrSemi():Void {
		Assert.raises(() -> HaxeModuleParser.parse('interface IFoo { function bar():Void }'), ParseError);
	}

	// ---- writer: NoBody round-trip ----

	public function testNoBodyRoundTrip():Void {
		final source:String = 'interface IFoo {\n\tfunction bar():Void;\n}\n';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		Assert.equals(source, out);
	}

	public function testNoBodyMultipleMembersRoundTrip():Void {
		final source:String = 'interface IFoo {\n\tfunction a():Int;\n\tfunction b(x:String):Void;\n}\n';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		Assert.equals(source, out);
	}

	public function testMixedBodiesRoundTrip():Void {
		final source:String = 'interface IFoo {\n\tfunction a():Void;\n\tfunction b():Int {\n\t\treturn 1;\n\t}\n}\n';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		Assert.equals(source, out);
	}

	public function testEmptyBlockBodyStillRoundTrips():Void {
		final source:String = 'class C {\n\tfunction f():Void {}\n}\n';
		final out:String = HxModuleWriter.write(HaxeModuleParser.parse(source));
		Assert.equals(source, out);
	}
}
