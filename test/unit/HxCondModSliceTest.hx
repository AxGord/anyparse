package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxCondModPrefix;
import anyparse.grammar.haxe.HxConditionalMod;
import anyparse.grammar.haxe.HxMemberModifier;
import anyparse.grammar.haxe.HxModifier;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Tests for `#else` / `#elseif` arms and widened entries in a
 * MODIFIER-prefix `#if` region: `HxConditionalMod` gaining `elseifs` /
 * `elseBody`, and `HxCondModPrefix` replacing `HxModifier` as its body
 * element type.
 *
 * Before the slice the typedef was `{ cond, body: Array<HxModifier> }` -
 * one arm, modifier keywords only. The bisection that pinned the
 * trigger: `#if x extern #end` parsed and `#if x @:a #else @:b #end`
 * parsed (claimed by the metadata Star), but `#if x extern #else static
 * #end`, `#if x extern #else #end` AND `#if x @:a #else extern #end` all
 * failed - so the defect was the missing `#else` arm, not the
 * modifier/metadata straddle it was first blamed on. The straddle is a
 * second, independent gap that the same region shape needs.
 *
 * 107 modules across four dogfood trees carry it:
 *
 *  - Pony, 100 modules - `#if (haxe_ver >= 4.2) extern #else @:extern
 *    #end` in front of an inline abstract method, bare or behind a
 *    metadata tag; the tag is `@:from`, `@:to`, `@:op(...)` (18 distinct
 *    operator spellings) or `@:nullSafety(Off)`, and 82 modules carry
 *    more than one region. The four tag families are covered below; only
 *    the counts are approximate, the file:line references are exact;
 *  - lime, 3 - `ArrayBufferView` repeats the Pony shape, while
 *    `NativeWindow` and `System` carry TWO tokens per branch:
 *    `#if (haxe_ver>=4.0) private enum #else @:enum private #end
 *    abstract Name(Int)`;
 *  - the Haxe standard library, 3 - `js`/`flash` `_std/haxe/Json.hx`
 *    lines 25-28 (`@:native("JSON") extern`, metadata AND a modifier in
 *    ONE branch, at type level, spread over four lines) and
 *    `haxe/macro/Compiler.hx`, whose spliced token is the `macro`
 *    keyword;
 *  - swf, 1 - `AnimateLibraryExporter`, where a PRECEDING `private` is
 *    what forces the region into the modifier Star instead of the
 *    metadata one.
 *
 * The regression half pins the other side of the contract. Which Star
 * claims a prefix region is decided by field order, not lookahead
 * (`meta` before `modifiers` in `HxMemberDecl` / `HxTopLevelDecl`), so
 * every metadata-only region - including openfl's `#if (haxe_ver >= 4.0)
 * enum #else @:enum #end abstract` - must keep its pre-slice metadata
 * AST, a single-branch modifier region must keep its exact pre-slice
 * shape, and the widened element type must stay invisible outside a
 * `#if`.
 *
 * Writer assertions use `writerEquals` / `triviaRoundTrip` (byte-exact)
 * rather than `roundTrip` wherever the shape allows it: `roundTrip` only
 * asserts idempotency, and the writer's known `#else#end` gap re-parses
 * to itself, so an idempotency-only check would pass on it.
 */
class HxCondModSliceTest extends HxTestHelpers {

	public function testBareExternElseAtExtern(): Void {
		// Pony's dominant shape (95 of its 100 modules), e.g. pony/Or.hx:19.
		final mods: Array<HxMemberModifier> =
			memberModifiers('class C { #if (haxe_ver >= 4.2) extern #else @:extern #end public inline function f():Void {} }');
		Assert.equals(3, mods.length);
		final inner: HxConditionalMod = expectMemberCond(mods[0]);
		Assert.equals('(haxe_ver >= 4.2)', (inner.cond: String));
		Assert.equals(1, inner.body.length);
		Assert.equals(HxCondModPrefix.Extern, inner.body[0]);
		Assert.equals(0, inner.elseifs.length);
		Assert.equals('@:extern', elseEntryMetaName(inner, 0));
		Assert.equals(HxMemberModifier.Public, mods[1]);
		Assert.equals(HxMemberModifier.Inline, mods[2]);
	}

	public function testFromPrefixedRegion(): Void {
		// pony/events/Listener0.hx:24 - a real meta tag precedes the region,
		// so the metadata Star consumes `@:from` and then yields at `#if`.
		assertMetaPrefixedExternGuard(
			'class C { @:from #if (haxe_ver >= 4.2) extern #else @:extern #end private static inline function f():Void {} }', '@:from'
		);
	}

	public function testOpMetaPrefixedRegion(): Void {
		// pony/events/Signal0.hx:56 - `@:op(A >> B)` is a paren-bearing tag,
		// so the preceding entry goes through HxMetadata.MetaCall.
		assertMetaPrefixedExternGuard(
			'class C { @:op(A >> B) #if (haxe_ver >= 4.2) extern #else @:extern #end private inline function f():Void {} }', '@:op'
		);
	}

	public function testNullSafetyMetaPrefixedRegion(): Void {
		// The fourth Pony column signature - an argument-bearing tag whose
		// name is not an operator alias.
		assertMetaPrefixedExternGuard(
			'class C { @:nullSafety(Off) #if (haxe_ver >= 4.2) extern #else @:extern #end public inline function f():Void {} }',
			'@:nullSafety'
		);
	}

	public function testTwoTokenBranches(): Void {
		// lime NativeWindow.hx:731 / System.hx:927 - each branch carries a
		// modifier AND the declaration keyword, in opposite orders.
		final ast: HxModule = HaxeModuleParser.parse(
			'#if (haxe_ver>=4.0) private enum #else @:enum private #end abstract N(Int) from Int to Int {}'
		);
		Assert.equals(0, ast.decls[0].meta.length);
		Assert.equals(1, ast.decls[0].modifiers.length);
		final inner: HxConditionalMod = expectDeclCond(ast.decls[0].modifiers[0]);
		Assert.equals(2, inner.body.length);
		Assert.equals(HxCondModPrefix.Private, inner.body[0]);
		Assert.equals(HxCondModPrefix.EnumKw, inner.body[1]);
		final elseBody: Null<Array<HxCondModPrefix>> = inner.elseBody;
		if (elseBody == null) {
			Assert.fail('expected an #else body');
			return;
		}
		Assert.equals(2, elseBody.length);
		Assert.equals('@:enum', elseEntryMetaName(inner, 0));
		Assert.equals(HxCondModPrefix.Private, elseBody[1]);
		Assert.equals('N', (expectAbstractDecl(ast.decls[0]).name: String));
	}

	public function testMetadataAndModifierInSameBranch(): Void {
		// js/_std/haxe/Json.hx:29 and flash/_std/haxe/Json.hx:29 - one branch,
		// a tag and a modifier side by side, at type level.
		final ast: HxModule = HaxeModuleParser.parse('#if !haxeJSON @:native("JSON") extern #end class Json {}');
		Assert.equals(0, ast.decls[0].meta.length);
		final inner: HxConditionalMod = expectDeclCond(ast.decls[0].modifiers[0]);
		Assert.equals(2, inner.body.length);
		Assert.equals('@:native', entryMetaName(inner.body[0]));
		Assert.equals(HxCondModPrefix.Extern, inner.body[1]);
		Assert.isNull(inner.elseBody);
		Assert.equals('Json', (expectClassDecl(ast.decls[0]).name: String));
	}

	public function testMacroKeywordSpliced(): Void {
		// haxe/macro/Compiler.hx:563 - `macro` is absent from HxModifier
		// (`macro class` is not Haxe) but must be spliceable inside a guard.
		final mods: Array<HxMemberModifier> = memberModifiers('class C { public static #if !macro macro #end function f():Void {} }');
		Assert.equals(3, mods.length);
		Assert.equals(HxMemberModifier.Public, mods[0]);
		Assert.equals(HxMemberModifier.Static, mods[1]);
		final inner: HxConditionalMod = expectMemberCond(mods[2]);
		Assert.equals(1, inner.body.length);
		Assert.equals(HxCondModPrefix.Macro, inner.body[0]);
	}

	public function testPrecedingModifierForcesModifierStar(): Void {
		// swf AnimateLibraryExporter.hx:1502 - without the leading `private`
		// the metadata Star claims the region (openfl's enum-abstract shape);
		// with it, the meta Star is already empty and the region must be
		// reachable from the modifier Star instead.
		final ast: HxModule = HaxeModuleParser.parse('private #if (haxe_ver >= 4.0) enum #end abstract T(Int) from Int to Int {}');
		Assert.equals(0, ast.decls[0].meta.length);
		Assert.equals(2, ast.decls[0].modifiers.length);
		Assert.equals(HxModifier.Private, ast.decls[0].modifiers[0]);
		final inner: HxConditionalMod = expectDeclCond(ast.decls[0].modifiers[1]);
		Assert.equals(HxCondModPrefix.EnumKw, inner.body[0]);
		Assert.equals('T', (expectAbstractDecl(ast.decls[0]).name: String));
	}

	public function testElseifArmInModifierRegion(): Void {
		// No dogfood tree chains a modifier region through `#elseif`; the arm
		// exists for symmetry with HxConditionalMeta / HxConditionalHeritage.
		final mods: Array<HxMemberModifier> =
			memberModifiers('class C { #if a inline #elseif b extern #else @:extern #end public function f():Void {} }');
		final inner: HxConditionalMod = expectMemberCond(mods[0]);
		Assert.equals(HxCondModPrefix.Inline, inner.body[0]);
		Assert.equals(1, inner.elseifs.length);
		Assert.equals('b', (inner.elseifs[0].cond: String));
		Assert.equals(HxCondModPrefix.Extern, inner.elseifs[0].body[0]);
		Assert.equals('@:extern', elseEntryMetaName(inner, 0));
		// Idempotency only: an `#elseif` body is followed by a double space
		// in the writer today. That gap is PRE-EXISTING and identical in
		// HxConditionalMeta / HxConditionalHeritage, so it is not pinned
		// byte-exactly here - a shared-mechanism fix should flip this to
		// triviaRoundTrip.
		roundTrip('class C { #if a inline #elseif b extern #else @:extern #end public function f():Void {} }', 'elseif arm');
	}

	public function testEmptyElseArm(): Void {
		final mods: Array<HxMemberModifier> = memberModifiers('class C { #if x extern #else #end public function f():Void {} }');
		final inner: HxConditionalMod = expectMemberCond(mods[0]);
		Assert.equals(HxCondModPrefix.Extern, inner.body[0]);
		final elseBody: Null<Array<HxCondModPrefix>> = inner.elseBody;
		if (elseBody == null) {
			Assert.fail('expected a present but empty #else body');
			return;
		}
		Assert.equals(0, elseBody.length);
	}

	public function testTopLevelGuardWritesVerbatim(): Void {
		// BYTE-exact, not merely idempotent: `roundTrip` alone would pass on
		// a writer that glued `#else` to `#end`, because that output
		// re-parses to itself. A top-level guard needs no reflow, so the
		// plain writer's output is comparable to the input as typed.
		for (src in [
			'#if (haxe_ver>=4.0) private enum #else @:enum private #end abstract N(Int) from Int to Int {}',
			'#if !haxeJSON @:native("JSON") extern #end class Json {}',
			'private #if (haxe_ver >= 4.0) enum #end abstract T(Int) from Int to Int {}'
		]) writerEquals(src, '$src\n', src);
	}

	public function testMemberGuardWritesVerbatim(): Void {
		// Member-level guards go through the TRIVIA pipeline (the one
		// `hxq fmt` ships) because the plain writer always breaks a class
		// body onto its own lines regardless of the guard.
		for (src in [
			'class C {\n\t#if (haxe_ver >= 4.2) extern #else @:extern #end\n\tpublic inline function f():Void {}\n}',
			'class C {\n\t@:from #if (haxe_ver >= 4.2) extern #else @:extern #end\n\tpublic static inline function f():Void {}\n}',
			'class C {\n\t@:op(A >> B) #if (haxe_ver >= 4.2) extern #else @:extern #end\n\tprivate inline function f():Void {}\n}',
			'class C {\n\tpublic static #if !macro macro #end function f():Void {}\n}'
		]) triviaRoundTrip(src);
	}

	public function testStdJsonMultiLineGuardWritesVerbatim(): Void {
		// js/_std/haxe/Json.hx lines 25-28 as it actually reads - the guard
		// spans four lines, which is the trivia-sensitive form; the
		// single-line variant asserted above is the reduced shape.
		triviaRoundTrip('@:coreApi\n#if !haxeJSON\n@:native("JSON")\nextern\n#end\nclass Json {}');
	}

	public function testSwfMetaRegionThenModifierRegionWritesVerbatim(): Void {
		// swf AnimateLibraryExporter.hx:1501-1502 in full: a metadata-only
		// region on its own line, then `private` + a keyword region. The
		// first is meta-Star-claimed, the second modifier-Star-claimed, on
		// adjacent lines of one declaration.
		triviaRoundTrip('#if (haxe_ver < 4.0) @:enum #end\nprivate #if (haxe_ver >= 4.0) enum #end abstract T(Int) from Int to Int {}');
	}

	public function testPonyPrefixKeepsItsOwnLine(): Void {
		// The `#end` -> next-modifier newline rides the per-element trivia
		// channel; pony/Or.hx:19 puts the whole guard on its own line. Byte
		// fidelity of that newline is a TRIVIA-pipeline property, so this
		// goes through HaxeModuleTriviaParser/Writer - the plain
		// `HxModuleWriter` used by `roundTrip` collapses the modifier list
		// onto one line for the pre-slice single-branch shape too.
		triviaRoundTrip(
			'abstract Or<A, B>(S) from S to S {\n\t#if (haxe_ver >= 4.2) extern #else @:extern #end\n\tpublic inline function f():Void {}\n}'
		);
	}

	public function testV4MultiLineShapeUnchanged(): Void {
		// issue_332_conditional_modifiers V4 - cond / modifier / `#end` on
		// three separate source lines. Adding two fields after `body` must
		// not disturb the trivia slots the writer reads for this.
		triviaRoundTrip(
			'class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash)\n\tinline\n\t#end\n\tpublic static function main() {}\n}'
		);
	}

	public function testV1SingleBranchOwnLineUnchanged(): Void {
		// issue_332 V1 - the pre-slice single-branch shape, byte-pinned on
		// the same pipeline so a regression here is attributable.
		triviaRoundTrip('class Main {\n\t#if (neko_v21 || (cpp && !cppia) || flash) inline #end\n\tpublic static function main() {}\n}');
	}

	public function testSingleBranchModifierRegionUnchanged(): Void {
		// issue_291 / issue_107 shape - must keep its exact pre-slice AST:
		// one entry, no elseifs, absent elseBody.
		final mods: Array<HxMemberModifier> = memberModifiers('class C { #if !cppia inline #end function f():Void {} }');
		Assert.equals(1, mods.length);
		final inner: HxConditionalMod = expectMemberCond(mods[0]);
		Assert.equals('!cppia', (inner.cond: String));
		Assert.equals(1, inner.body.length);
		Assert.equals(HxCondModPrefix.Inline, inner.body[0]);
		Assert.equals(0, inner.elseifs.length);
		Assert.isNull(inner.elseBody);
	}

	public function testMetadataOnlyRegionStaysMetaClaimed(): Void {
		// Both arms metadata -> HxConditionalMeta wins on field order, and
		// the modifier Star never sees the region.
		final ast: HxModule = HaxeModuleParser.parse('#if x @:a #else @:b #end class C {}');
		Assert.equals(1, ast.decls[0].meta.length);
		Assert.equals(0, ast.decls[0].modifiers.length);
		roundTrip('#if x @:a #else @:b #end class C {}', 'metadata-only prefix region');
	}

	public function testEnumAbstractDeclPrefixStaysMetaClaimed(): Void {
		// openfl's 92-module shape - HxCondDeclPrefix territory, untouched.
		final ast: HxModule = HaxeModuleParser.parse('#if (haxe_ver >= 4.0) enum #else @:enum #end abstract E(Int) {}');
		Assert.equals(1, ast.decls[0].meta.length);
		Assert.equals(0, ast.decls[0].modifiers.length);
		Assert.equals('E', (expectAbstractDecl(ast.decls[0]).name: String));
	}

	public function testConditionalPublicOnVarMember(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class C { #if x public #end var y:Int; }');
		final inner: HxConditionalMod = expectMemberCond(ast.members[0].modifiers[0]);
		Assert.equals(HxCondModPrefix.Public, inner.body[0]);
		Assert.isNull(inner.elseBody);
		switch ast.members[0].member {
			case VarMember(decl):
				Assert.equals('y', (decl.name: String));
			case _:
				Assert.fail('expected VarMember, got ${ast.members[0].member}');
		}
	}

	public function testPlainModifiersUnaffected(): Void {
		final mods: Array<HxMemberModifier> = memberModifiers('class C { public static inline function f():Void {} }');
		Assert.equals(3, mods.length);
		Assert.equals(HxMemberModifier.Public, mods[0]);
		Assert.equals(HxMemberModifier.Static, mods[1]);
		Assert.equals(HxMemberModifier.Inline, mods[2]);
		final decl: HxModule = HaxeModuleParser.parse('private class C {}');
		Assert.equals(1, decl.decls[0].modifiers.length);
		Assert.equals(HxModifier.Private, decl.decls[0].modifiers[0]);
	}

	public function testWidenedEntriesDoNotLeakOutsideGuard(): Void {
		// `enum` / `macro` / `@`-led entries are reachable ONLY from the two
		// conditional-body Stars; ordinary dispatch must be untouched.
		final enumAbstract: HxModule = HaxeModuleParser.parse('enum abstract E(Int) {}');
		Assert.equals(0, enumAbstract.decls[0].modifiers.length);
		Assert.equals('E', (expectEnumAbstractDecl(enumAbstract.decls[0]).name: String));
		final plainEnum: HxModule = HaxeModuleParser.parse('enum E { A; }');
		Assert.equals(0, plainEnum.decls[0].modifiers.length);
		Assert.equals('E', (expectEnumDecl(plainEnum.decls[0]).name: String));
		final macroFn: Array<HxMemberModifier> = memberModifiers('class C { macro function f():Void {} }');
		Assert.equals(1, macroFn.length);
		Assert.equals(HxMemberModifier.Macro, macroFn[0]);
	}

	/**
	 * Byte-exact `parse -> write` check on the TRIVIA pipeline, the one
	 * `hxq fmt` uses and the only one that carries inter-modifier
	 * newlines. Mirror of `CondModProbe.roundTrip`; the fork fixtures'
	 * output sections are trailing-newline-terminated, so the expected
	 * output is the input plus `'\n'`.
	 */
	private function triviaRoundTrip(source: String): Void {
		Assert.equals('$source\n', HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source)));
	}

	/**
	 * Asserts that `source`'s single member carries `expectedTag` as its
	 * one leading metadata tag, followed by the Pony `extern` / `@:extern`
	 * guard - the shared body of the three meta-prefixed sub-shape tests,
	 * which differ only in which tag precedes the region.
	 */
	private function assertMetaPrefixedExternGuard(source: String, expectedTag: String): Void {
		final ast: HxClassDecl = HaxeParser.parse(source);
		Assert.equals(1, ast.members[0].meta.length);
		Assert.equals(expectedTag, entryMetaName(Meta(ast.members[0].meta[0])));
		final inner: HxConditionalMod = expectMemberCond(ast.members[0].modifiers[0]);
		Assert.equals(HxCondModPrefix.Extern, inner.body[0]);
		Assert.equals('@:extern', elseEntryMetaName(inner, 0));
	}

	private function memberModifiers(source: String): Array<HxMemberModifier> {
		final ast: HxClassDecl = HaxeParser.parse(source);
		Assert.equals(1, ast.members.length);
		return ast.members[0].modifiers;
	}

	private function expectMemberCond(modifier: HxMemberModifier): HxConditionalMod {
		return switch modifier {
			case Conditional(inner): inner;
			case _: throw 'expected HxMemberModifier.Conditional, got $modifier';
		};
	}

	private function expectDeclCond(modifier: HxModifier): HxConditionalMod {
		return switch modifier {
			case Conditional(inner): inner;
			case _: throw 'expected HxModifier.Conditional, got $modifier';
		};
	}

	/**
	 * Tag name of a metadata entry inside a conditional modifier body,
	 * covering both the bare (`@:extern`) and paren-bearing
	 * (`@:native("JSON")`) metadata branches.
	 */
	private function entryMetaName(entry: HxCondModPrefix): String {
		return switch entry {
			case Meta(Meta(name)): (name: String);
			case Meta(MetaCall(call)): (call.name: String);
			case _: throw 'expected a metadata entry, got $entry';
		};
	}

	/** `entryMetaName` of the n-th entry of the `#else` arm. */
	private function elseEntryMetaName(inner: HxConditionalMod, index: Int): String {
		final elseBody: Null<Array<HxCondModPrefix>> = inner.elseBody;
		if (elseBody == null) throw 'expected an #else body';
		return entryMetaName(elseBody[index]);
	}

}
