package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;

/**
 * Tests for the dot-path form of a bare (unparenthesised) `#if` / `#elseif`
 * condition atom — `HxPpCondLit`'s identifier alternative extended with a
 * `(?:\.[A-Za-z_][A-Za-z0-9_]*)*` tail, mirroring `HxTypeName`.
 *
 * Real-world motivation (10 files across three trees): haxe std's
 * `#if target.unicode` (`UnicodeString.hx`, `haxe/crypto/Sha1.hx`,
 * `haxe/crypto/Md5.hx`, `haxe/crypto/Sha256.hx`,
 * `haxe/format/JsonParser.hx`) and `#if target.utf16`
 * (`UnicodeString.hx`); lime's `#if target.threaded`
 * (`lime/_internal/backend/native/NativeApplication.hx`, `lime/system/JNI.hx`,
 * `lime/system/ThreadPool.hx`, `lime/system/WorkOutput.hx`); Pony's
 * `#if perf.js` (`pony/js/Perform.hx`). All ten use the BARE form —
 * `#if (target.threaded)` (parenthesised) already parsed before this
 * change; only the unparenthesised identifier alternative needed
 * widening.
 */
class HxPpCondDottedSliceTest extends HxTestHelpers {

	public function testDottedIdentInBareCondition(): Void {
		final ast: HxModule = HaxeModuleParser.parse('#if target.threaded\nclass A {}\n#end');
		switch ast.decls[0].decl {
			case Conditional(inner):
				Assert.equals('target.threaded', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].decl}');
		}
	}

	public function testMultiSegmentDottedIdent(): Void {
		// Three segments — proves the `(?:\.ident)*` tail actually repeats,
		// not just a single hardcoded dot.
		final ast: HxModule = HaxeModuleParser.parse('#if a.b.c\nclass A {}\n#end');
		switch ast.decls[0].decl {
			case Conditional(inner):
				Assert.equals('a.b.c', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].decl}');
		}
	}

	public function testNegatedDottedIdent(): Void {
		final ast: HxModule = HaxeModuleParser.parse('#if !target.threaded\nclass A {}\n#end');
		switch ast.decls[0].decl {
			case Conditional(inner):
				Assert.equals('!target.threaded', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].decl}');
		}
	}

	public function testDottedIdentRoundTrip(): Void {
		roundTrip('#if target.threaded\nclass A {}\n#end', 'target.threaded');
		roundTrip('#if perf.js\nclass A {}\n#end', 'perf.js');
	}

	public function testDottedIdentInMetaPrefix(): Void {
		// The decl-prefix `#if <dotted> @:meta #end` shape (HxConditionalMeta),
		// not just the plain HxDecl.Conditional wrapper.
		final ast: HxModule = HaxeModuleParser.parse('#if target.threaded @:keep #end class A {}');
		switch ast.decls[0].meta[0] {
			case Conditional(inner):
				Assert.equals('target.threaded', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].meta[0]}');
		}
	}

	public function testParenthesizedDottedIdentStillParses(): Void {
		// The parenthesised form already worked before this slice — not
		// touched by the fix (it rides the separate paren alternative).
		final ast: HxModule = HaxeModuleParser.parse('#if (target.threaded)\nclass A {}\n#end');
		switch ast.decls[0].decl {
			case Conditional(inner):
				Assert.equals('(target.threaded)', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].decl}');
		}
	}

	public function testBareIdentifierStillParses(): Void {
		final ast: HxModule = HaxeModuleParser.parse('#if cppia\nclass A {}\n#end');
		switch ast.decls[0].decl {
			case Conditional(inner):
				Assert.equals('cppia', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].decl}');
		}
	}

	public function testIntegerConditionStillParses(): Void {
		// `[0-9]+` alternative — must stay disjoint from the identifier tail
		// (a leading digit can never enter the dotted-identifier branch).
		final ast: HxModule = HaxeModuleParser.parse('#if 0\nclass A {}\n#end');
		switch ast.decls[0].decl {
			case Conditional(inner):
				Assert.equals('0', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].decl}');
		}
	}

	public function testParenCompoundConditionStillParses(): Void {
		final ast: HxModule = HaxeModuleParser.parse('#if (cppia && !flash)\nclass A {}\n#end');
		switch ast.decls[0].decl {
			case Conditional(inner):
				Assert.equals('(cppia && !flash)', (inner.cond: String));
			case _:
				Assert.fail('expected Conditional, got ${ast.decls[0].decl}');
		}
	}

}
