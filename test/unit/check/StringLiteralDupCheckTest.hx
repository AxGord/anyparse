package unit.check;

import anyparse.check.AnonTypeDup;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.StringLiteralDup;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `string-literal-dup` check: a plain string literal repeated
 * `minOccurrences` (default 3) or more times in ONE file, whose raw content is
 * at least `minLength` (default 4) characters, yields ONE `Info` finding at its
 * first occurrence. The occurrence threshold and its boundary, the length boundary,
 * the by-construction empty / single-char exemption, the interpolation
 * exclusion (in both directions), the metadata-argument exclusion, quote-style-
 * agnostic grouping, and the `apqlint.json` overrides are all pinned. So is the
 * DATA-TABLE criterion, in the shape a lowered threshold could not have expressed: a collection
 * literal of only literals is a table at ANY arity and in the map spelling too, while one mixing an
 * identifier with its literals stays logic.
 * Report-only — `fix` yields no edits (the constant's name is intent).
 */
class StringLiteralDupCheckTest extends Test {

	/**
	 * An empty edit set is the SAME answer a check with no autofix and one whose gate declined here
	 * give, and this rule gave it while declaring neither — so `--fix` reported it as a rule that had
	 * nothing to fix, while the work is real and `apq extract-constant` performs it. The pin is the
	 * pair: no edits AND a declared reason that names the op which does the hoist. The twin
	 * `anon-type-dup` is the second instance — same shape, its own sentence, so a reason hard-coded
	 * for one of them fails the other. Killed by arm `M-STRING-LITERAL-DUP-REASON-MUTE`.
	 */
	@:pin('control')
	@:killer('M-STRING-LITERAL-DUP-REASON-MUTE')
	public function testReportOnlyIsDeclaredAndPointsAtExtractConstant(): Void {
		final check: StringLiteralDup = new StringLiteralDup();
		final src: String = body('trace("hello"); trace("hello"); trace("hello");');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
		Assert.isTrue(check is NoAutofix);
		final reason: String = check.noAutofixReason();
		Assert.isTrue(reason.contains('extract-constant'));
		final twin: String = new AnonTypeDup().noAutofixReason();
		Assert.isTrue(twin.length > 0);
		Assert.notEquals(reason, twin);
	}

	public function testThreeOccurrencesFlagged(): Void {
		// Three plain "hello" (5 chars >= minLength) -> ONE finding at the first occurrence.
		final vs: Array<Violation> = violations(body('trace("hello"); trace("hello"); trace("hello");'));
		Assert.equals(1, vs.length);
		Assert.equals('string-literal-dup', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains('hello'));
		Assert.isTrue(vs[0].message.contains('3 times'));
	}

	public function testTwoOccurrencesNotFlagged(): Void {
		// Boundary: two occurrences is below the default minOccurrences (3).
		Assert.equals(0, violations(body('trace("hello"); trace("hello");')).length);
	}

	public function testMinLengthBoundary(): Void {
		// "abc" (3 chars) is below the default minLength (4) -> exempt; "abcd" (4) flags.
		Assert.equals(0, violations(body('trace("abc"); trace("abc"); trace("abc");')).length);
		Assert.equals(1, violations(body('trace("abcd"); trace("abcd"); trace("abcd");')).length);
	}

	public function testEmptyAndSingleCharExempt(): Void {
		// Empty and single-character literals carry no naming value — exempt by construction (minLength).
		Assert.equals(0, violations(body('trace(""); trace(""); trace("");')).length);
		Assert.equals(0, violations(body('trace("x"); trace("x"); trace("x");')).length);
	}

	public function testInterpolationExcluded(): Void {
		// An interpolated literal captures surrounding values — not a constant candidate,
		// so three identical `'v $x'` never group.
		Assert.equals(0, violations(body('trace(\'val $$x\'); trace(\'val $$x\'); trace(\'val $$x\');')).length);
	}

	public function testInterpolationDoesNotInflatePlainGroup(): Void {
		// An interpolated occurrence must not count toward a plain literal's group:
		// two plain "value" + one interpolated stays below the threshold -> 0.
		Assert.equals(0, violations(body('trace("value"); trace("value"); trace(\'value$$x\');')).length);
	}

	public function testMetaArgsExcluded(): Void {
		// A string in `@:meta('…')` is a contract token bound to the annotation, not a
		// duplicated value — excluded, so three `@:native("metatoken")` yield nothing.
		final m: String = '\t@:native("metatoken") var';
		Assert.equals(0, violations('class C {\n$m a:Int;\n$m b:Int;\n$m c:Int;\n}').length);
	}

	public function testMetaArgsDoNotInflateCodeGroup(): Void {
		// A metadata occurrence does not count toward a code group: two plain "shared"
		// plus one `@:native("shared")` stays below the threshold -> 0.
		final src: String = 'class C {\n\t@:native("shared") var a:Int;\n\tfunction f() { trace("shared"); trace("shared"); }\n}';
		Assert.equals(0, violations(src).length);
	}

	public function testDifferentLiteralsNotGrouped(): Void {
		// Three DISTINCT literals, one occurrence each — no group reaches the threshold.
		Assert.equals(0, violations(body('trace("aaaa"); trace("bbbb"); trace("cccc");')).length);
	}

	public function testQuoteStyleAgnosticGrouping(): Void {
		// Same string value, mixed quotes: two "hello" + one plain 'hello' group by content -> ONE finding.
		Assert.equals(1, violations(body('trace("hello"); trace("hello"); trace(\'hello\');')).length);
	}

	public function testConfigOverrideMinOccurrences(): Void {
		// An apqlint.json lowering minOccurrences to 2 flags a two-occurrence group.
		Assert.equals(
			1,
			findingsWithConfig('sld_occ', '{"rules":{"string-literal-dup":{"minOccurrences":2}}}', body('trace("hello"); trace("hello");'))
		);
	}

	public function testConfigOverrideMinLength(): Void {
		// An apqlint.json lowering minLength to 3 flags a three-char literal the default exempts.
		Assert.equals(
			1,
			findingsWithConfig(
				'sld_len', '{"rules":{"string-literal-dup":{"minLength":3}}}', body('trace("abc"); trace("abc"); trace("abc");')
			)
		);
	}

	public function testIntOptionAccessor(): Void {
		final cfg: LintConfig = LintConfig.parse('{"rules":{"string-literal-dup":{"minOccurrences":5,"minLength":8}}}');
		Assert.equals(5, cfg.intOption('string-literal-dup', 'minOccurrences'));
		Assert.equals(8, cfg.intOption('string-literal-dup', 'minLength'));
	}

	public function testFixReturnsEmpty(): Void {
		// Report-only: the constant's name is intent a human supplies, like magic-number.
		final src: String = body('trace("hello"); trace("hello"); trace("hello");');
		final check: StringLiteralDup = new StringLiteralDup();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { trace("hello"); trace("hello"); trace("hello"').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('string-literal-dup'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('string-literal-dup'));
	}

	public function testDataTableEntriesExcluded(): Void {
		// A homogeneous run of three plain string literals is a vocabulary TABLE and its
		// entries are DATA — the array already names the value once, so nothing is reported.
		Assert.equals(0, violations(body('var v = ["aaaa", "aaaa", "aaaa"];')).length);
	}

	public function testTableEntryDoesNotInflateCodeGroup(): Void {
		// THE FALSE-NEGATIVE PRICE, in its exact shape. At base the table entry counted as the
		// third occurrence and the group was flagged; it no longer counts, so the two LOGIC
		// sites stay below `minOccurrences` and nothing is reported. Measured over this
		// project's `src/`: of the 113 groups the carve-out removes, 53 still hold two
		// non-table occurrences like this one, 44 hold one, and 16 were pure vocabulary. A
		// project that wants them back configures `string-literal-dup.minOccurrences: 2`.
		Assert.equals(0, violations(body('var v = ["aaaa", "bbbb", "cccc"]; trace("aaaa"); trace("aaaa");')).length);
	}

	/**
	 * THE difference an arity floor hid. A ONE- or TWO-name array of only literals is a vocabulary
	 * exactly as a thirty-name one is — `arrayTypeNames: ['Array']` and `ownedMeta = [':postfix']`
	 * are the shapes that motivated dropping the floor — so its entries are DATA and stop
	 * counting. The concatenation beside it is excluded by the KIND gate, not by arity: its node
	 * is not the grammar's collection literal, so it still contributes the occurrence that would
	 * flag the group if the array entries counted, which is what makes this an assertion about
	 * arity and nothing else. Killed by arm `M-STRING-LITERAL-DUP-TABLE-ARITY`.
	 */
	@:pin('control')
	@:killer('M-STRING-LITERAL-DUP-TABLE-ARITY')
	public function testSmallCollectionOfOnlyLiteralsIsATable(): Void {
		Assert.equals(0, violations(body('var a = ["aaaa", "bbbb"]; var b = "aaaa" + "zzzz"; trace("aaaa");')).length);
		Assert.equals(0, violations(body('var a = ["aaaa"]; var b = "aaaa" + "zzzz"; trace("aaaa");')).length);
	}

	public function testCallArgumentsAreNotATable(): Void {
		// A call is not the grammar's collection literal, so the KIND gate rejects it before
		// homogeneity is consulted and three literal arguments stay candidates. (It is also
		// non-homogeneous — the callee sits under the same parent — but that is no longer the
		// operative reason, and the sibling `new Foo(…)` case proves why it could not be: a
		// constructor carries its type as the node's NAME, so nothing separates it by shape.)
		Assert.equals(1, violations(body('g("aaaa", "aaaa", "aaaa");')).length);
	}

	/**
	 * The second difference: Haxe spells a map literal with the SAME collection kind, pairing key
	 * and value under the grammar's `mapLiteralEntryKind`, so a table of only literals had no
	 * bare-literal child and every key stayed a candidate — nine `'String'` values of a
	 * `kind => type` map in the grammar plugin were the standing evidence. Three entries, so the
	 * arity floor cannot be what carries this one. Killed by arm
	 * `M-STRING-LITERAL-DUP-MAP-ENTRY-BLIND`.
	 */
	@:pin('control')
	@:killer('M-STRING-LITERAL-DUP-MAP-ENTRY-BLIND')
	public function testMapOfOnlyStringLiteralsIsATable(): Void {
		Assert.equals(0, violations(body('var m = ["aaaa" => "bbbb", "aaaa" => "cccc", "aaaa" => "dddd"];')).length);
	}

	/**
	 * The third arm, and the only one that moved NOTHING when it landed — on this project's
	 * `src` + `test` and on the user's Pony tree alike. A map that stores numbers is a table as
	 * much as one that stores strings (`indexedElementTypeParams: ['Map' => 1, 'Array' => 0]`),
	 * and the entry test says so by asking the GRAMMAR which kinds are literals
	 * (`RefShape.literalTypeNames` keys) rather than admitting strings only. A measured-inert
	 * clause is exactly the one that rots unnoticed, which is why it is pinned. Killed by arm
	 * `M-STRING-LITERAL-DUP-STRING-ONLY-ENTRIES`.
	 */
	@:pin('control')
	@:killer('M-STRING-LITERAL-DUP-STRING-ONLY-ENTRIES')
	public function testMapWithNonStringValuesIsATable(): Void {
		Assert.equals(0, violations(body('var m = ["aaaa" => 1, "aaaa" => 2, "aaaa" => 3];')).length);
	}

	public function testInterpolatedEntryKeepsTheCollectionLogic(): Void {
		// The entry test admits a non-string literal by KIND, so it has to refuse an interpolated
		// string, whose kind IS a literal kind: it carries its captured expressions as children,
		// and the childless half of the test is what keeps it out. The array is therefore not a
		// table and its plain entry still counts, reaching the threshold with the two traces.
		Assert.equals(1, violations(body('var v = [\'aaaa\', \'bb $$x\']; trace("aaaa"); trace("aaaa");')).length);
	}

	public function testObjectLiteralValuesAreNotATable(): Void {
		// An object literal is a different kind from the collection literal, so the KIND gate
		// rejects it — deliberately, and unlike the map literal next door, which SHARES the
		// collection kind and is now read through the grammar's map-entry kind. An object literal
		// is how a Haxe expression builds an anonymous VALUE, not only how a file spells a table,
		// so admitting it would exempt a struct assembled in logic.
		Assert.equals(1, violations(body('var o = { a: "aaaa", b: "aaaa", c: "aaaa" };')).length);
	}

	public function testNestedTableStillExcluded(): Void {
		// The gate reads ONE parent at a time and is not sticky (unlike the metadata one), so a
		// table nested inside a non-table array is still recognised.
		Assert.equals(0, violations(body('var v = [["aaaa", "aaaa", "aaaa"]];')).length);
	}

	public function testMessageIdentityMasksRepetitionCount(): Void {
		// Pinned against messages `run` produced, as `Check.VolatileMessage` requires: a group
		// growing from three occurrences to four is the SAME finding, so the blast-radius gate
		// must not report it as one added plus one removed.
		final check: StringLiteralDup = new StringLiteralDup();
		final three: String = messageOf(check, 'trace("hello"); trace("hello"); trace("hello");');
		final four: String = messageOf(check, 'trace("hello"); trace("hello"); trace("hello"); trace("hello");');
		Assert.notEquals(three, four);
		Assert.equals(check.messageIdentity(three), check.messageIdentity(four));
		Assert.isTrue(check.messageIdentity(three).contains('repeated # times'));
		Assert.equals(check.messageIdentity(three), check.messageIdentity(check.messageIdentity(three)));
	}

	public function testConstructorArgumentsAreNotATable(): Void {
		// The first leak a shape-only gate had, and the reason `isTable` asks the grammar for
		// its `arrayLiteralKind` instead of inferring one: a Haxe `new` carries its TYPE as the
		// node's NAME, not as a child, so every child of `new Foo("a", "b", "c")` is a plain
		// literal and the homogeneity test alone read it as a vocabulary.
		final src: String = 'class C {\n\tfunction f() { var a = new Foo("aaaa", "bbbb", "cccc"); }\n'
			+ '\tfunction g() { var b = new Foo("aaaa", "bbbb", "cccc"); }\n\tfunction h() { var c = new Foo("aaaa", "bbbb", "cccc"); }\n}';
		Assert.equals(3, violations(src).length);
	}

	public function testConditionalCompilationBranchesAreNotATable(): Void {
		// The second leak: a conditional-compilation expression projects its branch values as
		// sibling children, so three per-target literals were all-literal too. A per-target
		// value is logic, not a vocabulary, and the kind gate keeps it a candidate.
		Assert.equals(1, violations(body('var v = #if js "aaaa" #elseif neko "aaaa" #else "aaaa" #end;')).length);
	}

	/**
	 * The homogeneity half, inside the collection kind itself, and the half that had to SURVIVE
	 * the widening: with arity gone it is the only thing left separating a vocabulary from an
	 * expression list, so an array holding one identifier beside its literals is logic and its
	 * literals count. Killed by arm `M-STRING-LITERAL-DUP-TABLE-ANY`.
	 */
	@:pin('control')
	@:killer('M-STRING-LITERAL-DUP-TABLE-ANY')
	public function testMixedArrayIsNotATable(): Void {
		Assert.equals(1, violations(body('var v = ["aaaa", x, "aaaa", "aaaa"];')).length);
	}

	public function testCasePatternArrayIsNotATable(): Void {
		// The third leak, and the one the grammar CANNOT distinguish by kind: Haxe spells an
		// array destructuring PATTERN with the same `arrayLiteralKind` it spells a vocabulary
		// with. A pattern is logic, so `collect` carries a sticky `inPattern` from the grammar's
		// `plainCasePatternKind` and switches the table gate off beneath it — the literals
		// themselves still count, which is why this asserts 3 and not 0.
		final src: String = 'class C {\n\tfunction f() {\n\t\tswitch v {\n\t\t\tcase ["aaaa", "bbbb", "cccc"]: 1;\n'
			+ '\t\t\tcase ["aaaa", "bbbb", "cccc"]: 2;\n\t\t\tcase ["aaaa", "bbbb", "cccc"]: 3;\n\t\t\tcase _: 4;\n\t\t}\n\t}\n}';
		Assert.equals(3, violations(src).length);
	}

	/** Wrap `stmts` in a one-method class so the fixtures stay terse. */
	private function body(stmts: String): String {
		return 'class C {\n\tfunction f(x:Int) { $stmts }\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new StringLiteralDup().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Write `configJson` + `fixture` to a fresh temp dir, run the check with on-disk config discovery, return the finding count. */
	private function findingsWithConfig(tag: String, configJson: String, fixture: String): Int {
		final dir: String = tmpDir(tag);
		File.saveContent('$dir/apqlint.json', configJson);
		final path: String = '$dir/Foo.hx';
		File.saveContent(path, fixture);
		final count: Int = new StringLiteralDup().run([{ file: path, source: fixture }], new HaxeQueryPlugin()).length;
		cleanup(dir, path);
		return count;
	}

	private function tmpDir(tag: String): String {
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = tmp != null && tmp.length > 0 ? tmp : '/tmp';
		final dir: String = '$base/anyparse_${tag}_${Sys.time()}';
		FileSystem.createDirectory(dir);
		return dir;
	}

	private function cleanup(dir: String, path: String): Void {
		FileSystem.deleteFile(path);
		FileSystem.deleteFile('$dir/apqlint.json');
		FileSystem.deleteDirectory(dir);
	}

	/** The one message `check` reports for `stmts` wrapped in the standard one-method class. */
	private function messageOf(check: StringLiteralDup, stmts: String): String {
		final src: String = body(stmts);
		return check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin())[0].message;
	}

}
