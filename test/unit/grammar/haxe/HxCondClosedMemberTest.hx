package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxModuleWriter;
import utest.Assert;

/**
 * A member-scope `#if` region closed by `;` or `}` before its `#end` is complete at its own
 * `#end`: the member after it is a sibling, never the "shared body" of the region.
 */
final class HxCondClosedMemberTest extends HxTestHelpers {

	@:pin('control')
	@:killer('M-COND-CLOSED-MEMBER-OFF')
	public function testFunctionAfterDeadBraceRegionIsASibling(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class A {\n\t#if false {} #end function b() {}\n}');
		Assert.equals(2, ast.members.length);
		expectFnNamed(ast.members[1].member, 'b');
	}

	@:pin('control')
	@:killer('M-COND-CLOSED-MEMBER-OFF')
	public function testFunctionOnNextLineAfterDeadBraceRegionIsASibling(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class A {\n\t#if false {} #end\n\tfunction b() {}\n}');
		Assert.equals(2, ast.members.length);
		expectFnNamed(ast.members[1].member, 'b');
	}

	@:pin('control')
	@:killer('M-COND-CLOSED-MEMBER-OFF')
	public function testVarAfterDeadBraceRegionIsASibling(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class A {\n\t#if false {} #end var x:Int;\n}');
		Assert.equals(2, ast.members.length);
		switch ast.members[1].member {
			case VarMember(_):
			case other:
				Assert.fail('expected VarMember, got $other');
		}
	}

	@:pin('control')
	@:killer('M-COND-CLOSED-MEMBER-OFF')
	public function testModifiedFunctionAfterDeadBraceRegionParses(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class A {\n\t#if false {} #end public function b() {}\n}');
		Assert.equals(2, ast.members.length);
		expectFnNamed(ast.members[1].member, 'b');
	}

	@:pin('control')
	@:killer('M-COND-CLOSED-MEMBER-OFF')
	public function testRegionAndFollowingMemberRoundTrip(): Void {
		final src: String = 'class A {\n\t#if false {} #end\n\tfunction b() {}\n}';
		final out: String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(out.indexOf('function b()') != -1, 'the following member survives the write');
		Assert.equals(2, HaxeParser.parse(out).members.length);
	}

	@:pin('guard')
	public function testDanglingSignatureRegionKeepsItsSharedBody(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class A {\n\t#if a function f():Int #else function f():String #end\n\treturn 1;\n}');
		Assert.equals(1, ast.members.length);
		switch ast.members[0].member {
			case CondSpliceMember(_):
			case other:
				Assert.fail('expected CondSpliceMember, got $other');
		}
	}

	@:pin('guard')
	public function testDanglingSignatureHoldingAClosedNestedRegionStaysOneSplice(): Void {
		final ast: HxClassDecl = HaxeParser.parse(
			'class A {\n\t#if X\n\t@:keep #if Y static var b:Int; #end\n\tfunction c()\n\t#end\n\t{}\n\tvar d:Int;\n}'
		);
		Assert.equals(2, ast.members.length);
		switch ast.members[0].member {
			case CondSpliceMember(_):
			case other:
				Assert.fail('expected CondSpliceMember, got $other');
		}
		switch ast.members[1].member {
			case VarMember(_):
			case other:
				Assert.fail('expected VarMember, got $other');
		}
	}

	@:pin('guard')
	public function testAnonStructReturnSignatureKeepsItsBlockBody(): Void {
		final ast: HxClassDecl = HaxeParser.parse(
			'class A {\n\t#if js\n\tfunction f():{a:Int}\n\t#else\n\tfunction f():{a:Int}\n\t#end\n\t{ return null; }\n}'
		);
		Assert.equals(1, ast.members.length);
		switch ast.members[0].member {
			case CondSpliceMember(_):
			case other:
				Assert.fail('expected CondSpliceMember, got $other');
		}
	}

	private function expectFnNamed(member: HxClassMember, name: String): Void {
		switch member {
			case FnMember(decl):
				Assert.equals(name, (decl.name: String));
			case other:
				Assert.fail('expected FnMember $name, got $other');
		}
	}

}
