package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxAccessClause;
import anyparse.grammar.haxe.HxAnonField;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxTypedefDecl;
import anyparse.grammar.haxe.HxVarDecl;

/**
 * Slice ω-accessor: property accessor clause `(read, write)` on a
 * `var`/`final` member, modelled as the optional `HxVarDecl.access`
 * sub-field (`HxAccessClause` inner shape) between `name` and the
 * optional `:Type`.
 *
 * Covers the accessor keyword forms (`get`/`set`/`never`/`default`/
 * `null`), method-name accessors, the `final` member position, the
 * anon-struct field position, the no-accessor case staying null
 * (regression for plain `var x:Int;`), and writer round-trip.
 */
class HxAccessorSliceTest extends HxTestHelpers {

	private function memberVarDecl(source:String):HxVarDecl {
		final module:HxModule = HaxeModuleParser.parse('class C { $source }');
		final c:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, c.members.length);
		return expectVarMember(c.members[0].member);
	}

	private function accessorIds(decl:HxVarDecl):Array<String> {
		final clause:Null<HxAccessClause> = decl.access;
		if (clause == null) throw 'expected accessor clause, got null';
		return [for (id in clause.ids) (id : String)];
	}

	private function expectFinalMember(member:HxClassMember):HxVarDecl {
		return switch member {
			case FinalMember(decl): decl;
			case _: throw 'expected FinalMember, got $member';
		};
	}

	public function testGetSet():Void {
		final decl:HxVarDecl = memberVarDecl('var x(get, set):Int;');
		Assert.equals('x', (decl.name : String));
		Assert.same(['get', 'set'], accessorIds(decl));
		Assert.equals('Int', (expectNamedType(decl.type).name : String));
	}

	public function testDefaultNull():Void {
		final decl:HxVarDecl = memberVarDecl('var x(default, null):String;');
		Assert.same(['default', 'null'], accessorIds(decl));
		Assert.equals('String', (expectNamedType(decl.type).name : String));
	}

	public function testGetNever():Void {
		final decl:HxVarDecl = memberVarDecl('var x(get, never):Int;');
		Assert.same(['get', 'never'], accessorIds(decl));
	}

	public function testMethodNameAccessors():Void {
		final decl:HxVarDecl = memberVarDecl('var x(getX, setX):Int;');
		Assert.same(['getX', 'setX'], accessorIds(decl));
	}

	public function testAccessorWithInit():Void {
		final decl:HxVarDecl = memberVarDecl('var x(default, null):Int = 1;');
		Assert.same(['default', 'null'], accessorIds(decl));
		Assert.notNull(decl.init);
	}

	public function testFinalMemberAccessor():Void {
		final module:HxModule = HaxeModuleParser.parse('class C { final x(get, never):Int; }');
		final c:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, c.members.length);
		final decl:HxVarDecl = expectFinalMember(c.members[0].member);
		Assert.same(['get', 'never'], accessorIds(decl));
	}

	public function testAnonStructFieldAccessor():Void {
		final module:HxModule = HaxeModuleParser.parse('typedef T = { var x(get, set):Int; }');
		final td:HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		final fields:Array<HxAnonField> = expectAnon(td.type);
		Assert.equals(1, fields.length);
		final decl:HxVarDecl = expectVarField(fields[0]);
		Assert.same(['get', 'set'], accessorIds(decl));
	}

	public function testWhitespaceTolerant():Void {
		final decl:HxVarDecl = memberVarDecl('var  x  (  get , set )  :  Int ;');
		Assert.same(['get', 'set'], accessorIds(decl));
	}

	// -- Regression: no accessor stays null, plain forms unchanged --

	public function testNoAccessorStaysNull():Void {
		Assert.isNull(memberVarDecl('var x:Int;').access);
		Assert.isNull(memberVarDecl('var x = 1;').access);
		Assert.isNull(memberVarDecl('var x;').access);
		Assert.isNull(memberVarDecl('var x:Int = 1;').access);
	}

	// -- Writer: accessor clause must round-trip --

	public function testWriterPreservesAccessor():Void {
		roundTrip('class C { var x(get, set):Int; }', 'get/set idempotency');
		roundTrip('class C { var x(default, null):String; }', 'default/null idempotency');
		roundTrip('class C { final x(get, never):Int; }', 'final accessor idempotency');
		roundTrip('typedef T = { var x(get, set):Int; }', 'anon accessor idempotency');
	}

	// -- Slice 26: writer must emit `(...)` tight, no space before `(` or
	// -- after it. `@:fmt(tightLead)` on `HxVarDecl.access` collapses both
	// -- the inter-field separator and the post-lead `_dop(' ')` for this
	// -- single grammar site. Pre-slice bytes: `name ( default, null)`.

	public function testWriterTightOpenParenClassMember():Void {
		writerEquals(
			'class C {\n\tpublic var x(default, null):Int;\n}',
			'class C {\n\tpublic var x(default, null):Int;\n}\n',
			'tight `(` on class member accessor'
		);
	}

	public function testWriterTightOpenParenAnonStruct():Void {
		// Plain `HxModuleWriter` flattens the anon struct (no trivia
		// preservation) and re-emits a trailing `;`. The slice 26
		// invariant under check is just the tight `(default, null)` —
		// surrounding shape stays whatever the plain writer prints.
		writerEquals(
			'typedef T = {\n\tvar x(default, null):Int;\n}',
			'typedef T = {var x(default, null):Int;};\n',
			'tight `(` on anon-struct accessor'
		);
	}

	public function testWriterTightOpenParenGetSet():Void {
		writerEquals(
			'class C {\n\tvar x(get, set):Int;\n}',
			'class C {\n\tvar x(get, set):Int;\n}\n',
			'tight `(` on `(get, set)`'
		);
	}
}
