package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxMetadataUtil;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxMemberDecl;

/**
 * Tests for dot-path metadata names — Haxe's metadata tag is a dotted
 * path (`@` `:`? ident (`.` ident)*), not a bare identifier. openfl's
 * `openfl/utils/ByteArray.hx` uses `@:flash.property` on every extern
 * property, and the single-ident regex made the whole 2435-line module
 * unparseable (`error at 1900:9`, the `.` after `@:flash`) — which in
 * turn kept `ByteArray` out of any `SymbolIndex`, so `prefer-final`
 * could never resolve its abstractness.
 *
 * All three meta-name terminals carry the same shape as the existing
 * dotted-path terminals `HxTypeName` / `HxNewTypeName`:
 * `HxMetaName` (paren-less structural `Meta`), `HxMetaNameTight`
 * (structural `MetaCall`, `(?=\()` lookahead), and `HxMetaRaw`
 * (the `PlainMeta` verbatim catch-all).
 *
 * The dot run requires an identifier after each `.`, so a following
 * float literal (`@:privateAccess .5`) or field access on a separate
 * expression can never be swallowed into the tag name.
 */
class HxDottedMetaNameSliceTest extends HxTestHelpers {

	public function testDottedMetaOnVarMember(): Void {
		final src: String = 'class M {\n\t@:flash.property var x:Int;\n}';
		final ast: HxModule = HaxeModuleParser.parse(src);
		final m: HxMetadata = expectClassMembers(ast)[0].meta[0];
		Assert.equals('@:flash.property', HxMetadataUtil.source(m));
	}

	public function testDottedMetaOnPropertyMember(): Void {
		// The exact ByteArray.hx shape that failed at 1900:9.
		final src: String = 'class M {\n\t@:flash.property static var x(get, set):Int;\n}';
		final ast: HxModule = HaxeModuleParser.parse(src);
		final m: HxMetadata = expectClassMembers(ast)[0].meta[0];
		Assert.equals('@:flash.property', HxMetadataUtil.source(m));
	}

	public function testMultiSegmentUserMetaOnClass(): Void {
		final ast: HxModule = HaxeModuleParser.parse('@a.b.c class M {}');
		final m: HxMetadata = ast.decls[0].meta[0];
		switch m {
			case Meta(name):
				Assert.equals('@a.b.c', (name: String));
			case _:
				Assert.fail('expected Meta, got $m');
		}
	}

	public function testDottedMetaCallKeepsArgs(): Void {
		final ast: HxModule = HaxeModuleParser.parse('@:flash.property(1) class M {}');
		final m: HxMetadata = ast.decls[0].meta[0];
		switch m {
			case MetaCall(call):
				Assert.equals('@:flash.property', (call.name: String));
				Assert.equals(1, call.args.length);
			case _:
				Assert.fail('expected MetaCall, got $m');
		}
	}

	public function testDottedMetaWritesVerbatim(): Void {
		final src: String = 'class M {\n\t@:flash.property var x:Int;\n}';
		Assert.isTrue(HxModuleWriter.write(HaxeModuleParser.parse(src)).indexOf('@:flash.property') != -1);
		roundTrip(src, 'dotted meta');
	}

	public function testTagNameStopsBeforeFloatLiteral(): Void {
		// A `.` not followed by an identifier is not part of the tag: the
		// dot run must not swallow `.5` into `@:privateAccess`.
		final ast: HxModule = HaxeModuleParser.parse('class M {\n\tfunction f():Void {\n\t\tvar v = @:privateAccess .5;\n\t}\n}');
		Assert.equals(1, ast.decls.length);
	}


	private function expectClassMembers(ast: HxModule): Array<HxMemberDecl> {
		return switch ast.decls[0].decl {
			case ClassDecl(c): c.members;
			case _: throw 'expected ClassDecl, got ${ast.decls[0].decl}';
		};
	}

}
