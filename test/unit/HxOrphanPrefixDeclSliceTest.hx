package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxAnonMember;
import anyparse.grammar.haxe.HxEnumDecl;
import anyparse.grammar.haxe.HxEnumMember;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxTopLevelDecl;
import anyparse.runtime.ParseError;
import anyparse.grammar.haxe.HxConditionalMeta;

/**
 * A declaration that is nothing but its own `#if X #end` prefix, at the three
 * scopes T15's member-position slice left open.
 *
 * T15 made `class C { #if swc #end }` legal by turning `HxMemberDecl.member`
 * into `@:optional @:absentOn('}')`: the region is claimed one level earlier by
 * the metadata Star (`HxMetadata.Conditional` takes an empty body), so what was
 * missing was a member declaration that is only a prefix. The identical shape
 * reaches `HxEnumMember.ctor`, `HxAnonMember.field` and `HxTopLevelDecl.decl`
 * — and only the LAST of those needed anything new. The first two face the
 * body `}`, which `@:absentOn` already spells; module scope faces EOF, which it
 * cannot (an empty literal peeks true everywhere), so `@:absentOnEof` supplies
 * that one disjunct of the same peek chain.
 *
 * The writer half is separate and was pre-existing: a BLANK line between a
 * prefix-only region and what follows was dropped at every scope, including
 * the member one T15 had just opened. It is NOT the same answer as a blank
 * after ordinary metadata — the fork deletes that one
 * (`emptylines/issue_384_macro_classes_with_metadata`) and keeps this one
 * (`emptylines/after_vars_before_conditionals` even MOVES a blank to the far
 * side of `#end`) — so `@:fmt(keepBlankAfterStarCtor('meta', 'Conditional'))`
 * gates the keep on the prefix run ENDING in a region. Both halves are pinned
 * here, because a fix that also kept the metadata blank would look correct on
 * every region fixture and silently regress issue_384.
 */
class HxOrphanPrefixDeclSliceTest extends HxTestHelpers {

	// -- module scope: the EOF terminator --

	public function testModuleTrailingEmptyRegion(): Void {
		final module: HxModule = HaxeModuleParser.parse('class C {}\n\n#if sys\n#end\n');
		Assert.equals(2, module.decls.length);
		Assert.equals('C', (expectClassDecl(module.decls[0]).name: String));
		final orphan: HxTopLevelDecl = module.decls[1];
		Assert.isNull(orphan.decl, 'a trailing prefix-only region carries no declaration');
		Assert.equals(1, orphan.meta.length);
		Assert.equals('sys', (expectConditionalMeta(orphan.meta[0]).cond: String));
	}

	public function testModuleTrailingEmptyRegionWithElse(): Void {
		final source: String = 'class C {}\n\n#if sys\n#else\n#end';
		final module: HxModule = HaxeModuleParser.parse(source);
		Assert.equals(2, module.decls.length);
		Assert.isNull(module.decls[1].decl);
		Assert.equals(source, HxWriteFixture.triviaWrite(source, '{}'));
	}

	/**
	 * The hazard the EOF disjunct could have introduced: a Seq whose every
	 * field can be absent parses having consumed NOTHING, and the module Star
	 * has no try-parse guard to rethrow on a zero-width iteration. It cannot
	 * happen here — `decl` is absent only at EOF, which is the enclosing
	 * loop's own exit test, taken BEFORE the element parse — so an
	 * unterminated `#if` must fail rather than spin.
	 */
	public function testModuleUnterminatedRegionThrows(): Void {
		Assert.raises(HaxeModuleParser.parse.bind('class C {}\n\n#if sys\n'), ParseError);
	}

	// -- enum + anon scope: the `}` terminator the mechanism already spelled --

	public function testEnumBodyEmptyRegion(): Void {
		final module: HxModule = HaxeModuleParser.parse('enum E {\n\t#if sys\n\t#end\n}\n');
		final ed: HxEnumDecl = expectEnumDecl(module.decls[0]);
		Assert.equals(1, ed.ctors.length);
		final orphan: HxEnumMember = ed.ctors[0];
		Assert.isNull(orphan.ctor, 'a prefix-only enum member carries no constructor');
		Assert.equals('sys', (expectConditionalMeta(orphan.meta[0]).cond: String));
		Assert.equals('enum E {\n\t#if sys\n\t#end\n}', HxWriteFixture.triviaWrite('enum E {\n\t#if sys\n\t#end\n}', '{}'));
	}

	public function testAnonBodyEmptyRegion(): Void {
		final module: HxModule = HaxeModuleParser.parse('typedef T = {\n\t#if sys\n\t#end\n}\n');
		final members: Array<HxAnonMember> = expectAnonMembers(expectTypedefDecl(module.decls[0]).type);
		Assert.equals(1, members.length);
		Assert.isNull(members[0].field, 'a prefix-only anon member carries no field');
		Assert.equals('typedef T = {\n\t#if sys\n\t#end\n}', HxWriteFixture.triviaWrite('typedef T = {\n\t#if sys\n\t#end\n}', '{}'));
	}

	// -- the writer half: a blank after a region prefix survives --

	public function testBlankAfterRegionPrefixKeptAtEveryScope(): Void {
		for (src in [
			'class C {\n\t#if sys\n\t#end\n\n\tvar x:Int;\n}',
			'class C {\n\t#if sys\n\t#end\n\n\tpublic var x:Int;\n}',
			'enum E {\n\t#if sys\n\t#end\n\n\tA;\n}',
			'typedef T = {\n\t#if sys\n\t#end\n\n\tvar a:Int;\n}',
			'#if sys\n#end\n\nclass C {}'
		]) Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'), 'blank after region prefix kept for <$src>');
	}

	/**
	 * The other half of the same gate, and the reason it is a gate at all:
	 * `emptylines/issue_384_macro_classes_with_metadata` requires the blank
	 * after an ORDINARY metadata prefix to be deleted. Same source shape, same
	 * `meta` Star, opposite answer — decided by the run's last ctor.
	 */
	public function testBlankAfterMetadataPrefixStillCollapses(): Void {
		Assert.equals(
			'class C {\n\t@:keep\n\tvar x:Int;\n}', HxWriteFixture.triviaWrite('class C {\n\t@:keep\n\n\tvar x:Int;\n}', '{}'),
			'member, no modifiers'
		);
		Assert.equals(
			'class C {\n\t@:keep\n\tpublic var x:Int;\n}',
			HxWriteFixture.triviaWrite('class C {\n\t@:keep\n\n\tpublic var x:Int;\n}', '{}'), 'modifier run follows the metadata'
		);
	}

	/**
	 * A prefix-only region followed by a member that already has one carries
	 * a trailing comment through the absent branch's rewind. T15's slice paid
	 * for this once — the branch stashed AND rewound the same trivia and the
	 * comment doubled on every pass — and no gate reports it, so the check is
	 * a second write over the first write's output.
	 */
	public function testEmptyRegionTrailingCommentDoesNotDouble(): Void {
		for (src in [
			'class C {\n\t#if sys\n\t#end\n\t// c\n}',
			'enum E {\n\tA;\n\t#if sys\n\t#end\n\t// c\n}',
			'typedef T = {\n\tvar a:Int;\n\t#if sys\n\t#end\n\t// c\n}',
			'class C {}\n#if sys\n#end\n// c'
		]) {
			final once: String = HxWriteFixture.triviaWrite(src, '{}');
			Assert.equals(1, count(once, '// c'), 'the trailing comment comes out once for <$src>');
			Assert.equals(once, HxWriteFixture.triviaWrite(once, '{}'), 'second pass must not grow <$src>');
		}
	}

	/** Occurrences of `needle` in `s` — the doubling check counts, it does not compare. */
	private function count(s: String, needle: String): Int {
		var n: Int = 0;
		var at: Int = s.indexOf(needle);
		while (at >= 0) {
			n++;
			at = s.indexOf(needle, at + needle.length);
		}
		return n;
	}

	/** Unwrap the `#if` region the metadata Star claimed. */
	private function expectConditionalMeta(meta: HxMetadata): HxConditionalMeta {
		return switch meta {
			case Conditional(inner): inner;
			case _: throw 'expected HxMetadata.Conditional, got $meta';
		};
	}

}
