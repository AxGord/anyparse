package unit;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxAbstractDecl;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxCondDeclPrefix;
import anyparse.grammar.haxe.HxConditionalMember;
import anyparse.grammar.haxe.HxConditionalMeta;
import anyparse.grammar.haxe.HxInterfaceDecl;
import anyparse.grammar.haxe.HxMemberDecl;
import anyparse.grammar.haxe.HxMetadata;
import anyparse.grammar.haxe.HxModule;
import anyparse.runtime.ParseError;
import utest.Assert;

/**
 * Slice apq-P5-J: member-scope `#if` conditional compilation.
 *
 * `HxClassMember` gained a `Conditional(HxConditionalMember)` ctor —
 * the member-scope completion of the cond-comp arc (decl / stmt /
 * modifier scopes already shipped). `#if <cond> <members> [#elseif …]
 * [#else …] #end` now parses where whole class / interface / abstract
 * member declarations are expected, unblocking apq self-parse of
 * anyparse source that guards members with `#if sys` / `#if macro`.
 *
 * Covers the single-branch / else / elseif / nested / empty-body
 * shapes, the no-conditional regression (the new ctor must not perturb
 * existing member dispatch), the real dogfood shape (`Glob.hx`'s
 * `#if sys` method between two methods), and that the single
 * `HxClassMember` edit reaches class + interface + abstract bodies.
 */
class HxConditionalMemberSliceTest extends HxTestHelpers {

	// -- `#if` wrapping a single member inside a class --

	public function testSingleMemberConditional(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if sys\n\tfunction a():Void {}\n\t#end\n}');
		Assert.equals(1, cls.members.length);
		final cond: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals(1, cond.body.length);
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
		Assert.equals(0, cond.elseifs.length);
		Assert.isNull(cond.elseBody);
	}

	// -- A real member follows the conditional region --

	public function testConditionalThenPlainMember(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if sys\n\tfunction a():Void {}\n\t#end\n\tfunction b():Void {}\n}');
		Assert.equals(2, cls.members.length);
		final cond: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
		Assert.equals('b', (expectFnMember(cls.members[1].member).name: String));
	}

	// -- `#if … #else …` two-branch --

	public function testConditionalElse(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if js\n\tfunction a():Void {}\n\t#else\n\tfunction b():Void {}\n\t#end\n}');
		Assert.equals(1, cls.members.length);
		final cond: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('js', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
		final elseBody: Null<Array<HxMemberDecl>> = cond.elseBody;
		Assert.notNull(elseBody);
		if (elseBody == null) return;
		Assert.equals(1, elseBody.length);
		Assert.equals('b', (expectFnMember(elseBody[0].member).name: String));
	}

	// -- `#elseif` chained clause --

	public function testConditionalElseif(): Void {
		final cls: HxClassDecl = classMembersOf(
			'class C {\n\t#if js\n\tfunction a():Void {}\n\t#elseif sys\n\tfunction b():Void {}\n\t#else\n\tfunction c():Void {}\n\t#end\n}'
		);
		Assert.equals(1, cls.members.length);
		final cond: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('js', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
		Assert.equals(1, cond.elseifs.length);
		Assert.equals('sys', (cond.elseifs[0].cond: String));
		Assert.equals('b', (expectFnMember(cond.elseifs[0].body[0].member).name: String));
		final elseBody: Null<Array<HxMemberDecl>> = cond.elseBody;
		Assert.notNull(elseBody);
		if (elseBody != null) Assert.equals('c', (expectFnMember(elseBody[0].member).name: String));
	}

	// -- Nested `#if` inside the body --

	public function testNestedConditional(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if sys\n\t#if js\n\tfunction a():Void {}\n\t#end\n\t#end\n}');
		Assert.equals(1, cls.members.length);
		final outer: HxConditionalMember = expectConditionalMember(cls.members[0].member);
		Assert.equals('sys', (outer.cond: String));
		Assert.equals(1, outer.body.length);
		final inner: HxConditionalMember = expectConditionalMember(outer.body[0].member);
		Assert.equals('js', (inner.cond: String));
		Assert.equals('a', (expectFnMember(inner.body[0].member).name: String));
	}

	// -- Empty body `#if X #end` at member position --
	//
	// A member-position region holding no member declaration at all is
	// valid Haxe (`haxe --interp` accepts it with the condition true, with
	// it false, and with an `#else`), and it now parses.
	//
	// The pre-fix reject was NOT the `@:tryparse` member Star failing to
	// roll back to zero elements — it does roll back, which is why
	// `#if a #else var x; #end` has always parsed with an empty then-body.
	// The region is claimed one level EARLIER, by `HxMemberDecl`'s `meta`
	// Star: `HxMetadata.Conditional` accepts an empty body, so the region
	// becomes a member PREFIX (exactly as in `#if a #end var b:Int;`, which
	// has always parsed) and the mandatory `member` field was then left
	// facing the class-body `}`. `member` is now
	// `@:optional @:absentOn('}')`, so a member declaration consisting of
	// nothing but its prefix is a legal member declaration.
	//
	// The shape therefore lands in `meta`, not in `member` — the same slot
	// it lands in when a member DOES follow. Both project as a bare
	// `(Conditional)` child of the class, so nothing downstream of the
	// projection sees a new shape.

	public function testEmptyConditionalBodyParsesAsPrefixOnlyMember(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if sys\n\t#end\n}');
		Assert.equals(1, cls.members.length);
		final decl: HxMemberDecl = cls.members[0];
		Assert.isNull(decl.member, 'the region is the whole member declaration');
		Assert.equals(1, decl.meta.length);
		final region: HxConditionalMeta = expectConditionalMeta(decl.meta[0]);
		Assert.equals('sys', (region.cond: String));
		Assert.equals(0, region.body.length, 'the region carries nothing');
		Assert.isNull(region.elseBody);
	}

	/**
	 * The `#else` spelling of the same shape, and the writer round-trip for
	 * both: an emptied region must come back byte-for-byte, or `hxq fmt`
	 * would silently rewrite a file it cannot represent.
	 */
	public function testEmptyConditionalBodyElseBranchAndRoundTrip(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\t#if sys\n\t#else\n\t#end\n}');
		Assert.equals(1, cls.members.length);
		Assert.isNull(cls.members[0].member);
		final region: HxConditionalMeta = expectConditionalMeta(cls.members[0].meta[0]);
		Assert.equals(0, region.body.length);
		final elseBody: Null<Array<HxCondDeclPrefix>> = region.elseBody;
		if (elseBody == null)
			Assert.fail('expected an #else clause');
		else
			Assert.equals(0, elseBody.length, 'the #else branch carries nothing either');
		for (src in [
			'class C {\n\t#if sys\n\t#end\n}',
			'class C {\n\t#if sys\n\t#else\n\t#end\n}',
			'class C {\n\t#if sys\n\t#end\n\tvar x:Int;\n}',
			'class C {\n\tpublic static inline final X:Int = 1;\n\n\t#if sys\n\t#end\n}',
			'interface I {\n\t#if sys\n\t#end\n}'
		]) Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'), 'writer round-trip for <$src>');
	}

	/**
	 * A comment between a prefix-only member and the class `}` must be emitted ONCE.
	 *
	 * The absent branch of `@:absentOn` rewinds the cursor past the trivia it just
	 * scanned, so the enclosing member Star re-scans those bytes — handing them to
	 * the Star a SECOND time through `ctx.pendingTrivia` duplicated the comment, and
	 * the duplicate doubled again on every further writer pass (1 -> 2 -> 4). The
	 * absent branch therefore restores the INCOMING stash, not the freshly-scanned
	 * one. Asserting idempotence as well as equality is what catches the compounding
	 * half: a single-pass equality check alone passes on output that still grows.
	 */
	public function testTrailingCommentAfterPrefixOnlyMemberIsNotDuplicated(): Void {
		// Counted, not compared: the exact blank-line layout is the writer config's
		// business and differs between the compiled defaults used here and the
		// project's own `hxformat.json`. How MANY times the comment comes out is
		// config-independent, and it is the whole bug.
		for (spec in [
			{ src: 'class C {\n\t#if swc\n\t#end\n\t// zz\n}', needle: '// zz' },
			{ src: 'class C {\n\t#if swc\n\t#end\n\t// zz\n\t// yy\n}', needle: '// yy' },
			{ src: 'class C {\n\t#if swc\n\t#end\n\t/* block */\n}', needle: '/* block */' },
			{ src: 'class C {\n\t@:keep\n\t// zz\n}', needle: '// zz' },
			{ src: 'class C {\n\tstatic\n\t// zz\n}', needle: '// zz' }
		]) {
			final once: String = HxWriteFixture.triviaWrite(spec.src, '{}');
			Assert.equals(1, count(once, spec.needle), 'comment emitted once for <${spec.src}>');
			final twice: String = HxWriteFixture.triviaWrite(once, '{}');
			Assert.equals(once, twice, 'second pass must not grow <${spec.src}>');
		}
	}


	/**
	 * The zero-width guard that makes the optional `member` field safe: an
	 * UNTERMINATED member-position `#if` leaves the region body Star facing
	 * the class-body `}`, where every field of `HxMemberDecl` is absent. A
	 * try-parse Star whose only exit is a parse failure would spin forever
	 * on that zero-width success, so the loop rethrows the backtrack
	 * sentinel instead. The assertion is that this returns at all.
	 */
	public function testUnterminatedMemberRegionFailsInsteadOfSpinning(): Void {
		Assert.raises(classMembersOf.bind('class C {\n\t#if sys\n\tfunction f():Void {}\n}'), ParseError);
		Assert.raises(classMembersOf.bind('class C {\n\t#if sys\n}'), ParseError);
	}

	// -- Regression: a class with NO member-`#if` is unaffected --

	public function testNoConditionalRegression(): Void {
		final cls: HxClassDecl = classMembersOf('class C {\n\tvar x:Int;\n\tfunction f():Void {}\n}');
		Assert.equals(2, cls.members.length);
		Assert.equals('x', (expectVarMember(cls.members[0].member).name: String));
		Assert.equals('f', (expectFnMember(cls.members[1].member).name: String));
	}

	// -- Dogfood shape: the `Glob.hx` pattern --

	public function testDogfoodGlobShape(): Void {
		final cls: HxClassDecl = classMembersOf(
			'class Glob {\n\tpublic static function expand():Void {}\n\t#if sys\n\tprivate static function collect():Void {}\n\t#end\n}'
		);
		Assert.equals(2, cls.members.length);
		Assert.equals('expand', (expectFnMember(cls.members[0].member).name: String));
		final cond: HxConditionalMember = expectConditionalMember(cls.members[1].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals('collect', (expectFnMember(cond.body[0].member).name: String));
	}

	// -- The single ctor reaches interface bodies --

	public function testInterfaceMemberConditional(): Void {
		final module: HxModule = HaxeModuleParser.parse('interface I {\n\t#if sys\n\tfunction a():Void;\n\t#end\n}');
		final iface: HxInterfaceDecl = expectInterfaceDecl(module.decls[0]);
		Assert.equals(1, iface.members.length);
		final cond: HxConditionalMember = expectConditionalMember(iface.members[0].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
	}

	// -- The single ctor reaches abstract bodies --

	public function testAbstractMemberConditional(): Void {
		final module: HxModule = HaxeModuleParser.parse('abstract A(Int) {\n\t#if sys\n\tpublic function a():Void {}\n\t#end\n}');
		final abs: HxAbstractDecl = expectAbstractDecl(module.decls[0]);
		Assert.equals(1, abs.members.length);
		final cond: HxConditionalMember = expectConditionalMember(abs.members[0].member);
		Assert.equals('sys', (cond.cond: String));
		Assert.equals('a', (expectFnMember(cond.body[0].member).name: String));
	}

	private function classMembersOf(source: String): HxClassDecl {
		return HaxeParser.parse(source);
	}

	/** The `#if` region a member's `meta` Star claimed, or a failure naming what it got. */
	private function expectConditionalMeta(meta: HxMetadata): HxConditionalMeta {
		return switch meta {
			case Conditional(inner): inner;
			case _: throw 'expected a Conditional meta region, got $meta';
		};
	}


	/** Occurrences of `needle` in `haystack` — the bug was a count, so the test counts. */
	private function count(haystack: String, needle: String): Int {
		var n: Int = 0;
		var at: Int = haystack.indexOf(needle);
		while (at >= 0) {
			n++;
			at = haystack.indexOf(needle, at + needle.length);
		}
		return n;
	}

}
