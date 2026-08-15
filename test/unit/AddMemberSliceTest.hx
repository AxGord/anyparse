package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddMember;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;

/**
 * `AddMember.addMember` — append a member to a type body, WRITER-FORMATTED.
 *
 * The member is laid out by the grammar's writer (not inserted as-is): the
 * whole file is re-emitted through `writeRoundTrip`, so the result is
 * canonical and the raw `memberText` spacing is normalised. Each test
 * asserts the EXACT canonical output. The source must already be writer-
 * canonical (its own writer output) — a non-canonical file is refused
 * unless `reformat` is passed. Refusal cases assert `Err`; every `Ok` is
 * additionally re-parsed.
 */
class AddMemberSliceTest extends Test {

	/** Append a method to a class that already has a member. */
	public function testAppendToClassWithMembers(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\n\tpublic function g():Void {}\n}\n';
		assertAdd(source, 'C', 'public function g():Void {}', expected);
	}

	/**
	 * The core win: a member with ugly hand-spacing comes out CANONICALLY
	 * formatted (the writer normalises it), not spliced verbatim.
	 */
	public function testUglyMemberIsCanonicalised(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\n\tpublic function g(a:Int, b:Int):Int {\n\t\treturn a + b;\n\t}\n}\n';
		assertAdd(source, 'C', 'public    function  g(a:Int,b:Int):Int{return a+b;}', expected);
	}

	/** Append to an empty class. */
	public function testAppendToEmptyClass(): Void {
		final source: String = 'class C {}\n';
		final expected: String = 'class C {\n\tvar y:Int;\n}\n';
		assertAdd(source, 'C', 'var y:Int;', expected);
	}

	/**
	 * Append to a `final class` — the closing `}` is located via the inner
	 * `ClassForm` name node (the outer `FinalDecl` span swallows the
	 * trailing newline), so the member lands inside the body.
	 */
	public function testAppendToFinalClass(): Void {
		final source: String = 'final class C {\n\tvar x:Int;\n}\n';
		final expected: String = 'final class C {\n\tvar x:Int;\n\n\tpublic function g():Void {}\n}\n';
		assertAdd(source, 'C', 'public function g():Void {}', expected);
	}

	/** Append a constructor to an `enum`. */
	public function testAppendToEnum(): Void {
		final source: String = 'enum E {\n\tA;\n}\n';
		final expected: String = 'enum E {\n\tA;\n\n\tB(x:Int);\n}\n';
		assertAdd(source, 'E', 'B(x:Int);', expected);
	}

	/**
	 * Append to a `typedef` anon body — the closing `}` is found by
	 * scanning back over the trailing newline that the `TypedefDecl` span
	 * swallows (same trivia-swallow as `final class`).
	 */
	public function testAppendToTypedefAnon(): Void {
		final source: String = 'typedef T = {\n\tvar x:Int;\n}\n';
		final expected: String = 'typedef T = {\n\tvar x:Int;\n\n\tvar y:Int;\n}\n';
		assertAdd(source, 'T', 'var y:Int;', expected);
	}

	/** Refuse an unknown type name. */
	public function testRefuseUnknownType(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		assertRefused(source, 'Nope', 'var z:Int;');
	}

	/** Refuse an ambiguous type name (two decls share it). */
	public function testRefuseAmbiguousType(): Void {
		final source: String = 'class C {}\n\nclass C {}\n';
		assertRefused(source, 'C', 'var z:Int;');
	}

	/** Refuse a malformed member — the whole-file re-emit fails to parse. */
	public function testRefuseMalformedMember(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		assertRefused(source, 'C', '@@@ not haxe');
	}

	/**
	 * Refuse a NON-canonical file (4-space indent) without `--reformat` —
	 * the whole-file rewrite would otherwise reflow unrelated formatting.
	 */
	public function testRefuseNonCanonicalWithoutReformat(): Void {
		final source: String = 'class C {\n    var x:Int;\n}\n';
		assertRefused(source, 'C', 'var y:Int;');
	}

	/**
	 * The canonical-gate refusal must not INSTRUCT the user to re-run with `--reformat`.
	 * The gate is shared with `lint --fix`, which has no such flag, and the message it
	 * used to carry sent that user after an argument their command rejects. It now names
	 * `apq fmt --write` — the remedy every caller's user can reach — and mentions
	 * `--reformat` only as something a command may accept. The negative half is the
	 * regression guard; the positive one only requires the remedy to be PRESENT, since
	 * pinning its position would break on any rewording.
	 */
	public function testNonCanonicalRefusalLeadsWithFmtNotReformat(): Void {
		final source: String = 'class C {\n    var x:Int;\n}\n';
		switch addOf(source, 'C', 'var y:Int;', false) {
			case Ok(text):
				Assert.fail('expected the canonical-gate refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('apq fmt --write') >= 0, 'refusal must name the always-available remedy: $message');
				Assert.isTrue(
					message.indexOf('re-run with --reformat') < 0, 'refusal must not order a flag the command may lack: $message'
				);
		}
	}

	/** `reformat` proceeds on a non-canonical file, canonicalising it. */
	public function testReformatProceedsOnNonCanonical(): Void {
		final source: String = 'class C {\n    var x:Int;\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\n\tvar y:Int;\n}\n';
		assertAdd(source, 'C', 'var y:Int;', expected, true);
	}

	/**
	 * Append to a `final class` that is NOT the last decl: a following
	 * doc-commented `typedef` is swallowed into the outer `FinalDecl` span,
	 * so the closing brace comes from the inner `ClassForm` (`nameNode`),
	 * not `fullSpan` — `testAppendToFinalClass` passes only because its
	 * final class is the last decl.
	 */
	public function testAppendToNonLastFinalClass(): Void {
		final source: String = 'final class C {\n\tvar x:Int;\n}\n\n/**\n * Doc.\n */\ntypedef T = {\n\tvar y:Int;\n}\n';
		final expected: String =
			'final class C {\n\tvar x:Int;\n\n\tpublic function g():Void {}\n}\n\n/**\n * Doc.\n */\ntypedef T = {\n\tvar y:Int;\n}\n';
		assertAdd(source, 'C', 'public function g():Void {}', expected);
	}

	/** Refuse a member whose name the type already declares — the result would not compile. */
	public function testRefuseDuplicateMemberName(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		assertRefusedNaming(source, 'C', 'var x:Int;', 'x');
	}

	/**
	 * Refuse a name declared only inside a `#if` region. The default build compiles the result
	 * clean and only the define that reveals the guarded twin rejects it, so a single-arch
	 * oracle calls this case healthy — the scan has to be branch-aware to see it at all.
	 */
	public function testRefuseDuplicateGuardedMemberName(): Void {
		final source: String = 'class C {\n\t#if X\n\tvar h:Int;\n\t#end\n}\n';
		assertRefusedNaming(source, 'C', 'var h:Int;', 'h');
	}

	/** A DISTINCT name next to a guarded member is still added — the gate refuses collisions, not regions. */
	public function testAddsDistinctNameBesideGuardedMember(): Void {
		final source: String = 'class C {\n\t#if X\n\tvar h:Int;\n\t#end\n}\n';
		final expected: String = 'class C {\n\t#if X\n\tvar h:Int;\n\t#end\n\n\tvar k:Int;\n}\n';
		assertAdd(source, 'C', 'var k:Int;', expected);
	}

	/** Refuse a duplicate enum constructor — `Duplicate constructor`, a member kind field-only scans miss. */
	public function testRefuseDuplicateEnumConstructor(): Void {
		final source: String = 'enum E {\n\tA;\n}\n';
		assertRefusedNaming(source, 'E', 'A;', 'A');
	}

	/**
	 * Refuse a duplicate `typedef` field. Its members hang off the anon body rather than off the
	 * declaration, so a scan of the declaration's direct children reports the type as empty.
	 */
	public function testRefuseDuplicateTypedefField(): Void {
		final source: String = 'typedef T = {\n\tvar x:Int;\n}\n';
		assertRefusedNaming(source, 'T', 'var x:Int;', 'x');
	}

	/** Refuse member text that declares one name twice by itself, even though the type declares neither. */
	public function testRefuseMemberTextRepeatingItsOwnName(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n}\n';
		assertRefusedNaming(source, 'C', 'var z:Int;\nvar z:Int;', 'z');
	}

	private function assertAdd(source: String, typeName: String, memberText: String, expected: String, reformat: Bool = false): Void {
		final result: EditResult = addOf(source, typeName, memberText, reformat);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, typeName: String, memberText: String, reformat: Bool = false): Void {
		final result: EditResult = addOf(source, typeName, memberText, reformat);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	private function assertReparses(text: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception: Exception) {
			Assert.fail('add-member output failed to re-parse: ${exception.message}\n$text');
		}
	}

	/**
	 * The refusal must name the colliding member, not merely fail: every other gate on this path
	 * (unknown type, non-canonical source, unparseable member) also answers `Err`, so an assertion
	 * that only checks for `Err` would pass with this gate removed.
	 */
	private function assertRefusedNaming(source: String, typeName: String, memberText: String, name: String): Void {
		switch addOf(source, typeName, memberText, false) {
			case Ok(text):
				Assert.fail('expected the duplicate-name refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(
					message.indexOf('already declares a member named "$name"') >= 0,
					'refusal must name the colliding member "$name": $message'
				);
		}
	}

	private static function addOf(source: String, typeName: String, memberText: String, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddMember.addMember(source, typeName, memberText, reformat, plugin);
	}

}
