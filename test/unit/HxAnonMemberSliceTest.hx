package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxAnonMember;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxMetadataUtil;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxTypedefDecl;

/**
 * Slice apq-P5-C: anon-structure-type field-level metadata.
 *
 * `HxType.Anon` now iterates `HxAnonMember` (a leading
 * `@:trivia @:tryparse var meta:Array<HxMetadata>` Star + the
 * `HxAnonField` kind), the `HxMemberDecl` to `HxClassMember` split
 * applied at the anon-struct level. This unblocks `@:peg typedef`
 * grammar DSL files (`typedef T = { @:lead('(') var x:Y; }`) — the
 * dominant apq self-parse blocker.
 *
 * Covers metadata before each field kind (var / final / function /
 * short / optional-short), multi-field with mixed metadata, the
 * no-metadata case staying empty (byte-identical regression), and
 * the dogfood shape (metadata-bearing typedef inside `#if`).
 */
class HxAnonMemberSliceTest extends HxTestHelpers {

	// -- Metadata before a class-notation `var` field --

	public function testMetaCallBeforeVarField(): Void {
		final members: Array<HxAnonMember> = membersOf("typedef T = { @:lead('(') var x:Int; }");
		Assert.equals(1, members.length);
		Assert.equals(1, members[0].meta.length);
		Assert.equals('@:lead', metaName(members[0].meta[0]));
		Assert.equals('x', (expectVarField(members[0].field).name: String));
	}

	// -- Multiple metadata, one bare + one paren, before a field --

	public function testMultipleMetaBeforeField(): Void {
		final members: Array<HxAnonMember> = membersOf('typedef T = { @:foo @:bar(1) var y:String; }');
		Assert.equals(1, members.length);
		Assert.equals(2, members[0].meta.length);
		Assert.equals('@:foo', metaName(members[0].meta[0]));
		Assert.equals('@:bar', metaName(members[0].meta[1]));
		Assert.equals('y', (expectVarField(members[0].field).name: String));
	}

	// -- Metadata before `final` / `function` / short / optional kinds --

	public function testMetaBeforeFinalField(): Void {
		final members: Array<HxAnonMember> = membersOf('typedef T = { @:keep final c:Int; }');
		Assert.equals(1, members[0].meta.length);
		Assert.equals('@:keep', metaName(members[0].meta[0]));
		Assert.equals('c', (expectFinalField(members[0].field).name: String));
	}

	public function testMetaBeforeFnField(): Void {
		final members: Array<HxAnonMember> = membersOf('typedef T = { @:meta function f():Void; }');
		Assert.equals(1, members[0].meta.length);
		Assert.equals('@:meta', metaName(members[0].meta[0]));
		Assert.equals('f', (expectFnField(members[0].field).name: String));
	}

	public function testMetaBeforeShortField(): Void {
		final members: Array<HxAnonMember> = membersOf('typedef T = { @:foo name:String }');
		Assert.equals(1, members[0].meta.length);
		Assert.equals('@:foo', metaName(members[0].meta[0]));
		Assert.equals('name', (expectShortFieldBody(members[0].field).name: String));
	}

	public function testMetaBeforeOptionalShortField(): Void {
		final members: Array<HxAnonMember> = membersOf('typedef T = { @:optional ?z:Int }');
		Assert.equals(1, members[0].meta.length);
		Assert.equals('@:optional', metaName(members[0].meta[0]));
		Assert.equals('z', (expectShortFieldBody(members[0].field).name: String));
	}

	// -- Multi-field, mixed metadata, `;`-separated (Slice 0 loop) --

	public function testMultiFieldMixedMeta(): Void {
		final members: Array<HxAnonMember> = membersOf('typedef T = { @:a var p:Int; @:b(2) var q:String; }');
		Assert.equals(2, members.length);
		Assert.equals('@:a', metaName(members[0].meta[0]));
		Assert.equals('p', (expectVarField(members[0].field).name: String));
		Assert.equals('@:b', metaName(members[1].meta[0]));
		Assert.equals('q', (expectVarField(members[1].field).name: String));
	}

	// -- No-metadata regression: meta Star stays empty, kinds preserved --

	public function testNoMetadataStaysEmpty(): Void {
		final members: Array<HxAnonMember> = membersOf('typedef T = { var a:Int; b:Float }');
		Assert.equals(2, members.length);
		Assert.equals(0, members[0].meta.length);
		Assert.equals(0, members[1].meta.length);
		Assert.equals('a', (expectVarField(members[0].field).name: String));
		Assert.equals('b', (expectShortFieldBody(members[1].field).name: String));
	}

	public function testNoMetadataRoundTripUnchanged(): Void {
		roundTrip('typedef T = {x:Int, y:String}', 'no-meta anon byte-identical');
		roundTrip('typedef T = { var a:Int; var b:String; }', 'no-meta class-notation anon');
	}

	// -- Dogfood shape: metadata-bearing typedef inside #if (apq self-parse) --

	public function testMetaTypedefInsideConditional(): Void {
		final src: String = "#if macro\ntypedef T = { @:lead('(') var x:Int; }\n#end";
		final module: HxModule = HaxeModuleParser.parse(src);
		Assert.equals(1, module.decls.length);
	}

	private function membersOf(source: String): Array<HxAnonMember> {
		final module: HxModule = HaxeModuleParser.parse(source);
		final td: HxTypedefDecl = expectTypedefDecl(module.decls[0]);
		return expectAnonMembers(td.type);
	}

	private function metaName(m: HxMetadata): String {
		return switch m {
			case MetaCall(call): (call.name: String);
			case _: HxMetadataUtil.source(m);
		};
	}

}
