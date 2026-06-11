package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.runtime.ParseError;

/**
 * Slice ω-enum-abstract: the modern `enum abstract Name(T) { ... }`
 * form, recognised at the `HxDecl` level via the `EnumAbstractDecl`
 * ctor (consumes the leading `enum`, reuses `HxAbstractDecl` verbatim).
 *
 * Covers parse of the enum-value body (`final A = 0;`, `var B;`),
 * modifier-prefixed (`private enum abstract`), the shared-keyword
 * rollback that keeps plain `enum Name { ... }` routing to `EnumDecl`,
 * and writer round-trip preserving the `enum` keyword.
 */
class HxEnumAbstractSliceTest extends HxTestHelpers {

	public function testEnumAbstractFinalMembers(): Void {
		final module: HxModule = HaxeModuleParser.parse('enum abstract Mode(Int) { final Fast = 0; final Tolerant = 1; }');
		Assert.equals(1, module.decls.length);
		final ad: HxAbstractDecl = expectEnumAbstractDecl(module.decls[0]);
		Assert.equals('Mode', (ad.name: String));
		Assert.equals('Int', (expectNamedType(ad.underlyingType).name: String));
		Assert.equals(0, ad.clauses.length);
		Assert.equals(2, ad.members.length);
	}

	public function testEnumAbstractVarMember(): Void {
		final module: HxModule = HaxeModuleParser.parse('enum abstract E(String) { var A; }');
		Assert.equals(1, module.decls.length);
		final ad: HxAbstractDecl = expectEnumAbstractDecl(module.decls[0]);
		Assert.equals('E', (ad.name: String));
		Assert.equals(1, ad.members.length);
	}

	public function testPrivateEnumAbstract(): Void {
		final module: HxModule = HaxeModuleParser.parse('private enum abstract LeafDirection(Int) { final Head = 0; final Tail = 1; }');
		Assert.equals(1, module.decls.length);
		final ad: HxAbstractDecl = expectEnumAbstractDecl(module.decls[0]);
		Assert.equals('LeafDirection', (ad.name: String));
		Assert.equals(2, ad.members.length);
	}

	public function testEnumAbstractWhitespace(): Void {
		final module: HxModule = HaxeModuleParser.parse('  enum  abstract  Mode (  Int  ) {  final  Fast = 0 ;  }  ');
		Assert.equals(1, module.decls.length);
		final ad: HxAbstractDecl = expectEnumAbstractDecl(module.decls[0]);
		Assert.equals('Mode', (ad.name: String));
		Assert.equals(1, ad.members.length);
	}

	// -- Rollback: plain enum must still route to EnumDecl --

	public function testPlainEnumStillRoutesToEnumDecl(): Void {
		final module: HxModule = HaxeModuleParser.parse('enum Color { Red; Green; }');
		Assert.equals(1, module.decls.length);
		final ed: HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name: String));
	}

	public function testMixedModuleEnumAndEnumAbstract(): Void {
		final module: HxModule = HaxeModuleParser.parse('enum Color { Red; } enum abstract Mode(Int) { final Fast = 0; }');
		Assert.equals(2, module.decls.length);
		final ed: HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals('Color', (ed.name: String));
		final ad: HxAbstractDecl = expectEnumAbstractDecl(module.decls[1]);
		Assert.equals('Mode', (ad.name: String));
	}

	// -- Writer: `enum` keyword must round-trip, not be dropped --

	public function testWriterPreservesEnumKeyword(): Void {
		final src: String = 'enum abstract Mode(Int) { final Fast = 0; final Tolerant = 1; }';
		final written: String = HxModuleWriter.write(HaxeModuleParser.parse(src));
		Assert.isTrue(
			StringTools.startsWith(StringTools.ltrim(written), 'enum abstract '),
			'expected output to start with "enum abstract ", got <$written>'
		);
		// Reparse must still classify as EnumAbstractDecl (keyword not lost).
		final reparsed: HxModule = HaxeModuleParser.parse(written);
		expectEnumAbstractDecl(reparsed.decls[0]);
		roundTrip(src, 'enum abstract idempotency');
	}

	// -- Word boundary --

	public function testWordBoundaryEnumlike(): Void {
		// `enumish` is not the `enum` keyword; with no matching decl this must fail.
		Assert.raises(() -> HaxeModuleParser.parse('enumish abstract Foo(Int) {}'), ParseError);
	}

}
