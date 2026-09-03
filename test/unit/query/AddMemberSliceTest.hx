package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddMember;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

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

	/**
	 * The `emptyLines` keys this project sets that decide the shape: a blank RUN may be two lines
	 * long, and a blank before a closing brace is KEPT. Under the compiled defaults the run
	 * collapses to one and the brace blank is removed, which is why nothing in this suite saw the
	 * doubling.
	 */
	private static inline final TWO_BLANK_LINES: String = '{"emptyLines": {"maxAnywhereInFile": 2, "beforeRightCurly": "keep"}}';

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

	/**
	 * Refuse a type carrying a `#if` region spliced at MEMBER scope — `CondSpliceMember`, the
	 * `#if <signature> #else <signature> #end <shared-body>` shape. The whole region projects as
	 * ONE unnamed node, so the duplicate-name scan reads the type as declaring nothing there and
	 * the op fail-opens. `pony/Tools.hx:490` is the live case: adding `sget` reported success and
	 * produced a THIRD `sget`, which the compiler rejects with `Duplicate class field declaration`
	 * under both define branches.
	 */
	public function testRefuseTypeWithCondSpliceRegion(): Void {
		assertRefusedForOpaqueRegion(condSpliceSource(), 'T', 'public function g():Void {}');
	}

	/**
	 * The refusal is TYPE-scoped, not file-scoped: a sibling declaration in the SAME file that
	 * carries no opaque region is still served. A file-wide refusal would strand every type
	 * declared next to one guarded member.
	 */
	public function testAddsToSiblingTypeBesideCondSpliceRegion(): Void {
		final expected: String = condSpliceSource().replace('\tvar x:Int;\n}\n', '\tvar x:Int;\n\n\tvar y:Int;\n}\n');
		assertAdd(condSpliceSource(), 'U', 'var y:Int;', expected);
	}

	/**
	 * Refuse a type carrying a `function` whose NAME is a `#if` region — `CondNameFnMember`. Same
	 * blindness in a different spelling: the member declares one name per branch and the node
	 * exposes neither.
	 */
	public function testRefuseTypeWithCondNameFnRegion(): Void {
		final source: String = 'class T {\n\tpublic function #if js alpha #else beta #end(b:Int):Int {\n\t\treturn b;\n\t}\n}\n';
		assertRefusedForOpaqueRegion(source, 'T', 'public function g():Void {}');
	}

	/**
	 * A PLAIN `#if` member region — complete declarations in both branches — is still served: its
	 * members hang off the `Conditional` as ordinary named nodes, so the duplicate-name scan sees
	 * them. Guards the gate against over-refusing every conditional-compilation region.
	 */
	public function testAddsBesidePlainConditionalMember(): Void {
		final source: String = 'class T {\n\t#if js\n\tpublic function alpha():Int\n\t\treturn 1;\n\t#else\n\tpublic function beta():Int\n'
			+ '\t\treturn 2;\n\t#end\n}\n';
		final expected: String = source.replace('\t#end\n}\n', '\t#end\n\n\tpublic function g():Void {}\n}\n');
		assertAdd(source, 'T', 'public function g():Void {}', expected);
	}

	/**
	 * Refuse a member TEXT that is itself an opaque region — the mirror of the host gate. The
	 * spliced node carries no name either, so the duplicate scan reads the ADDITION as declaring
	 * nothing: the op appended a second `alpha` beside an existing one and reported success, which
	 * `-D js` rejects as a duplicate.
	 */
	public function testRefuseOpaqueMemberText(): Void {
		final source: String = 'class C {\n\tpublic function alpha():Int\n\t\treturn 1;\n}\n';
		final text: String = '#if js\npublic function alpha(): Int\n#else\npublic function beta(): Int\n#end\n{\n\treturn 2;\n}';
		assertRefusedMatching(source, 'C', text, 'the member text is a conditional member region', 'the opaque member text');
	}

	/**
	 * A `var` whose INITIALIZER alone is guarded (`VarSemiCondInitMember`) is still served: its name
	 * sits outside the region and IS exposed, which is exactly why `RefactorSupport.isOpaqueMemberKind`
	 * excludes the kind. Pins that exclusion — adding the kind to the set would otherwise start
	 * refusing these hosts with no test flipping.
	 */
	public function testAddsBesideGuardedVarInitializer(): Void {
		final source: String = 'class C {\n\tpublic static var get:Int = #if nodejs\n\t1; #else 2; #end\n}\n';
		final expected: String = source.replace('#end\n}\n', '#end\n\n\tvar y:Int;\n}\n');
		assertAdd(source, 'C', 'var y:Int;', expected);
	}

	/**
	 * The separator is emitted only when one is MISSING. A body already carrying a blank line
	 * before its closing brace — what this project's own config makes canonical — got a second
	 * one, and nothing reported it: the writer re-emits a blank run verbatim, so `fmt --list`
	 * called the result canonical and every lint rule stayed silent. The other direction — a body
	 * with no blank before its brace, which still owes one — is guarded by `testAppendToEnum`,
	 * `testAppendToTypedefAnon`, `testReformatProceedsOnNonCanonical` and the three guarded-region
	 * cases: suppressing the separator unconditionally flips exactly those six.
	 */
	public function testAppendAfterABlankLineDoesNotDoubleIt(): Void {
		final source: String = 'class C {\n\tvar x:Int;\n\n}\n';
		final expected: String = 'class C {\n\tvar x:Int;\n\n\tvar y:Int;\n\n}\n';
		// Under the compiled DEFAULTS a blank RUN collapses to one line on the way out, which hid
		// the doubling; this project's own config allows two, and that is where it survived.
		final res: EditResult = AddMember.addMember(source, 'C', 'var y:Int;', false, new HaxeQueryPlugin(), TWO_BLANK_LINES);
		switch res {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	/**
	 * Refusal naming the HOST type as carrying an opaque region.
	 */
	private inline function assertRefusedForOpaqueRegion(source: String, typeName: String, memberText: String): Void {
		assertRefusedMatching(source, typeName, memberText, 'carries a conditional member region', 'the opaque member region');
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
	 * Refusal naming the colliding member.
	 */
	private function assertRefusedNaming(source: String, typeName: String, memberText: String, name: String): Void {
		assertRefusedMatching(source, typeName, memberText, 'already declares a member named "$name"', 'the colliding member "$name"');
	}

	/**
	 * The refusal must name ITS OWN gate, not merely fail: every gate on this path — unknown type,
	 * non-canonical source, unparseable member, duplicate name, opaque region — answers `Err`, so an
	 * assertion that only checks for `Err` would pass with the gate under test removed. `fragment` is
	 * the text only that gate emits; `describe` names it in the failure message.
	 */
	private function assertRefusedMatching(source: String, typeName: String, memberText: String, fragment: String, describe: String): Void {
		switch addOf(source, typeName, memberText, false) {
			case Ok(text):
				Assert.fail('expected $describe refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf(fragment) >= 0, 'refusal must name $describe: $message');
		}
	}

	/**
	 * A class carrying a member-scope `#if` splice region beside a sibling class that carries none —
	 * the two-type shape of `pony/Tools.hx`, writer-canonical so the canonical gate stays out of the
	 * way.
	 */
	private static inline function condSpliceSource(): String {
		return 'class T {\n\t#if js\n\tpublic function alpha(): Int\n\t#else\n\tpublic function beta(): Int\n\t#end\n\t{\n\t\treturn 1;\n'
			+ '\t}\n}\n\nclass U {\n\tvar x:Int;\n}\n';
	}

	private static function addOf(source: String, typeName: String, memberText: String, reformat: Bool): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddMember.addMember(source, typeName, memberText, reformat, plugin);
	}

}
