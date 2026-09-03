package unit.check;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedPublicMember;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `unused-public-member` check: a PUBLIC METHOD of a class whose name occurs nowhere in scope
 * outside its own declaration is dead weight nothing can reach. The reference test is two raw-text
 * mechanisms (a global identifier-token count map, then `nameOccursOutside` on the report index),
 * so any occurrence at all — a call, a bare identifier, a comment, a string literal — keeps the
 * member. The autofix deletes the method with its modifier run and doc comment, unless an
 * interpolation fragment could name it at runtime. `DefaultOff`.
 */
@:nullSafety(Strict) class UnusedPublicMemberCheckTest extends Test {

	/** The check's id, asserted on every finding. */
	private static inline final RULE: String = 'unused-public-member';

	// --- the finding ---

	public function testPlainUnreferencedPublicMethodFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tpublic function orphaned():Void {}\n}');
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(RULE, vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('unused public orphaned: no reference to it anywhere in scope', vs[0].message);
	}

	public function testCanarySystemDataReplaceWordShapeFlagged(): Void {
		// The shape of TM's crashdumper/SystemData.hx `replaceWord`: a `public static function` in
		// a plain, meta-free, supertype-free class, referenced nowhere.
		final src: String = 'class SystemData {\n\tpublic static function replaceWord(line:String, word:String, replace:String):String {\n'
			+ '\t\tif (word == replace) return line;\n\t\twhile (line.indexOf(word) != -1) line = line.replace(word, replace);\n'
			+ '\t\treturn line;\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals(RULE, vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('unused public replaceWord: no reference to it anywhere in scope', vs[0].message);
	}

	public function testStaticAndFinalMethodsAreBothCandidates(): Void {
		Assert.equals(1, violations('class C {\n\tpublic static function orphaned():Void {}\n}').length);
		Assert.equals(1, violations('class C {\n\tpublic final function orphaned():Void {}\n}').length);
	}

	public function testAbstractClassBodyIsInScope(): Void {
		Assert.equals(1, violations('abstract class C {\n\tpublic function orphaned():Void {}\n}').length);
	}

	// --- any occurrence keeps the member ---

	public function testCrossFileCallNotFlagged(): Void {
		Assert.equals(0, withUser('c.orphaned();').length);
	}

	public function testBareIdentifierReferenceNotFlagged(): Void {
		// A value reference (`f.bind(orphaned)`) never reaches a call, but the name IS written.
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic function orphaned():Void {}\n\tpublic static function main():Void {\n'
				+ '\t\tfinal f:Void -> Void = orphaned;\n\t}\n}'
			).length
		);
	}

	public function testCommentMentionNotFlagged(): Void {
		// The raw-text scan sees comments, and the exclusion region covers only the member's OWN
		// doc comment — a mention anywhere else keeps it.
		Assert.equals(0, withUser('// calls orphaned one day').length);
	}

	public function testStringLiteralMentionNotFlagged(): Void {
		// A whole reflection literal needs no separate gate: its content is raw source text, so the
		// reference test refuses to report the member at all.
		Assert.equals(0, withUser('Reflect.field(c, \'orphaned\');').length);
	}

	public function testInterpolationEscapeKeepsTheMember(): Void {
		// `'\x24zqxwvEscaped'` DECODES to `'$zqxwvEscaped'`, a real read. The token map cannot see
		// it — a word-boundary scan reads `x24zqxwvEscaped` as ONE token — so this is the whole of
		// what the `nameOccursOutside` confirm adds over the map (`RefactorSupport.DOLLAR_ESCAPES`).
		// The sibling method pins that the file is not silencing the class wholesale.
		final owner: String = 'class C {\n\tpublic function zqxwvEscaped():Void {}\n\tpublic function zqxwvPlain():Void {}\n}';
		final user: String = 'class U {\n\tpublic static function main(e:C):Dynamic return Reflect.field(e, \'\\x24zqxwvEscaped\');\n}';
		final vs: Array<Violation> = violationsOf([{ file: 'C.hx', source: owner }, { file: 'U.hx', source: user }]);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('unused public zqxwvPlain: no reference to it anywhere in scope', vs[0].message);
	}

	public function testOwnDocCommentDoesNotCountAsAReference(): Void {
		// `docExtendedSpan` folds the doc into the exclusion region — otherwise every documented
		// member would read as referenced by its own documentation.
		Assert.equals(1, violations('class C {\n\n\t/** Calls orphaned. */\n\tpublic function orphaned():Void {}\n}').length);
	}

	// --- member-level gates ---

	public function testPrivateMethodNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tprivate function orphaned():Void {}\n}').length);
	}

	public function testNoVisibilityKeywordNotFlagged(): Void {
		// A Haxe member with no visibility keyword is PRIVATE — `unused-private` owns it.
		Assert.equals(0, violations('class C {\n\tfunction orphaned():Void {}\n}').length);
	}

	public function testOverrideNotFlagged(): Void {
		// The base deliberately declares NO `orphaned`, so nothing else in scope writes the name
		// and the `override` modifier is the only thing that can reject it. The pair shows it does.
		final base: String = 'class Base {}';
		final plain: String = 'class Sub extends Base {\n\tpublic function orphaned():Void {}\n}';
		final overridden: String = 'class Sub extends Base {\n\toverride public function orphaned():Void {}\n}';
		Assert.equals(1, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: plain }]).length);
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: overridden }]).length);
	}

	public function testMemberMetadataNotFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tpublic function orphaned():Void {}\n}').length);
		Assert.equals(0, violations('class C {\n\t@:keep public function orphaned():Void {}\n}').length);
	}

	public function testConditionalMetadataInTheRunNotFlagged(): Void {
		// `#if js @:keep #end` projects as `(Conditional (Meta (Meta @:keep)))`, which is neither a
		// META_KINDS sibling nor a member decl — read as a plain modifier it would leave the
		// annotation count at zero and make a `@:keep`ed method reportable AND deletable.
		Assert.equals(1, violations('class C {\n\tpublic function orphaned():Void {}\n}').length);
		Assert.equals(0, violations('class C {\n\t#if js @:keep #end public function orphaned():Void {}\n}').length);
	}

	public function testPrecedingFieldModifiersDoNotLeakOntoTheMethod(): Void {
		// The `@:keep` and the `public` here belong to `other`; a run that reset only at methods
		// would read the next method as kept (and as public when it is not).
		final src: String = 'class C {\n\t@:keep public var other:Int = 0;\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testPrecedingFieldModifiersDoNotInventVisibility(): Void {
		// The mirror direction: the `public` belongs to `other`, so the keyword-less — therefore
		// PRIVATE — method must not read as public and become this rule's finding.
		Assert.equals(0, violations('class C {\n\tpublic var other:Int = 0;\n\tfunction orphaned():Void {}\n}').length);
	}

	public function testUtestMethodOfATestClassNotFlagged(): Void {
		// Routed through the same `NamingSupport.frameworkReachable` predicate `unused-private`
		// uses: utest calls a `test*` method of a class transitively extending `Test` by
		// reflection, so no source token ever names it.
		final base: String = 'class Test {}';
		final suite: String = 'class MySuite extends Test {\n\tpublic function testZqxwvAlpha():Void {}\n}';
		final plain: String = 'class MySuite extends Test {\n\tpublic function zqxwvAlpha():Void {}\n}';
		Assert.equals(0, violationsOf([{ file: 'Test.hx', source: base }, { file: 'MySuite.hx', source: suite }]).length);
		Assert.equals(1, violationsOf([{ file: 'Test.hx', source: base }, { file: 'MySuite.hx', source: plain }]).length);
	}

	public function testImplicitlyReachableNamesNotFlagged(): Void {
		for (name in ['new', 'main', 'toString', '__init__'])
			Assert.equals(0, violations('class C {\n\tpublic function $name():Void {}\n}').length, 'flagged $name');
	}

	public function testImplicitlyCalledIterationAndSerializationNamesNotFlagged(): Void {
		// Nothing in source spells `iterator` / `hasNext` / `next` (the `for` desugaring calls them)
		// or `hxSerialize` / `hxUnserialize` (`haxe.Serializer` calls them) — without the gate these
		// survive only when the resolution scope happens to carry a std that mentions them.
		for (name in [
			'iterator',
			'keyValueIterator',
			'hasNext',
			'next',
			'hxSerialize',
			'hxUnserialize'
		]) Assert.equals(0, violations('class C {\n\tpublic function $name():Void {}\n}').length, 'flagged $name');
	}

	public function testAccessorNamesLeftToOrphanAccessor(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function get_x():Int return 1;\n}').length);
		Assert.equals(0, violations('class C {\n\tpublic function set_x(v:Int):Int return v;\n}').length);
	}

	// --- class-level gates ---

	public function testKeepClassNotFlagged(): Void {
		Assert.equals(0, violations('@:keep class C {\n\tpublic function orphaned():Void {}\n}').length);
	}

	public function testBuildMacroClassNotFlagged(): Void {
		Assert.equals(0, violations('@:build(M.gen()) class C {\n\tpublic function orphaned():Void {}\n}').length);
	}

	public function testRttiClassNotFlagged(): Void {
		Assert.equals(0, violations('@:rtti class C {\n\tpublic function orphaned():Void {}\n}').length);
	}

	public function testExternClassNotFlagged(): Void {
		Assert.equals(0, violations('extern class C {\n\tpublic function orphaned():Void;\n}').length);
	}

	public function testAutoBuildAncestorNotFlagged(): Void {
		// `@:autoBuild` generates into DESCENDANTS, so it is read while walking the chain UPWARD —
		// the subclass's member set is not knowable. The pair isolates the metadata.
		final plain: String = 'class Base {\n\tpublic function main():Void {}\n}';
		final generated: String = '@:autoBuild(M.gen()) class Base {\n\tpublic function main():Void {}\n}';
		final sub: String = 'class Sub extends Base {\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(1, violationsOf([{ file: 'Base.hx', source: plain }, { file: 'Sub.hx', source: sub }]).length);
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: generated }, { file: 'Sub.hx', source: sub }]).length);
	}

	public function testUnresolvableSupertypeNotFlagged(): Void {
		// Unresolvable anything -> skip: this rule has no report-only third arm.
		Assert.equals(1, violations('class C {\n\tpublic function orphaned():Void {}\n}').length);
		Assert.equals(0, violations('class C extends Unknown {\n\tpublic function orphaned():Void {}\n}').length);
	}

	public function testSameNamedDeclarationInASupertypeIsItselfAnOccurrence(): Void {
		// The text scan SUBSUMES an index-resolved supertype query: the base's own declaration
		// writes the name, so the whole-scope token count exceeds the subclass's own region and
		// the candidate never survives. No separate `supertypeDeclaresMember` gate is reachable.
		final base: String = 'class Base {\n\tpublic function orphaned():Void {}\n}';
		final sub: String = 'class Sub extends Base {\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: sub }]).length);
	}

	public function testSameNamedDeclarationInAnInterfaceIsItselfAnOccurrence(): Void {
		// As above: the interface's declaration of the name is an occurrence in scope, so the text
		// scan refuses before any `implementsInterfaceDeclaringMember` question could be asked.
		final iface: String = 'interface I {\n\tpublic function orphaned():Void;\n}';
		final impl: String = 'class C implements I {\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(0, violationsOf([{ file: 'I.hx', source: iface }, { file: 'C.hx', source: impl }]).length);
	}

	public function testSameNamedDeclarationInASubtypeIsItselfAnOccurrence(): Void {
		// And downward: the subtype's `override` declaration writes the name too, so deleting the
		// base is refused by the same count comparison — the direction a `subtypeDeclaresMember`
		// query would have covered.
		final base: String = 'class Base {\n\tpublic function orphaned():Void {}\n}';
		final sub: String = 'class Sub extends Base {\n\toverride public function orphaned():Void {}\n}';
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: sub }]).length);
	}

	// --- robustness ---

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { public function orphaned():Void {').length);
	}

	// --- autofix ---

	public function testFixDeletesMethodWithDocComment(): Void {
		final src: String = 'class C {\n\n\t/** The orphan. */\n\tpublic inline function orphaned():Void {}\n}';
		Assert.equals('class C {\n\n}', applyFix(src));
	}

	public function testInterpolationFragmentBlocksFix(): Void {
		// `'orphan$suffix'` may name this very method at runtime, and `literalOf` answers null for
		// an interpolated string — so its static FRAGMENTS carry the intent.
		final owner: String = 'class C {\n\tpublic function orphaned():Void {}\n}';
		final user: String =
			'class U {\n\tpublic static function main(c:C, suffix:String):Dynamic return Reflect.field(c, \'orphan$$suffix\');\n}';
		Assert.equals(1, fixEditCount(owner, [{ file: 'C.hx', source: owner }]));
		Assert.equals(0, fixEditCount(owner, [{ file: 'C.hx', source: owner }, { file: 'U.hx', source: user }]));
	}

	public function testFixWithoutRunEditsNothing(): Void {
		// The deletability memo is populated by `run`; a bare `fix` is fail-closed.
		final src: String = 'class C {\n\tpublic function orphaned():Void {}\n}';
		final probe: Null<Check> = Linter.byId(RULE);
		final check: Null<Check> = Linter.byId(RULE);
		Assert.notNull(check);
		if (probe == null || check == null) return;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final vs: Array<Violation> = probe.run([{ file: 'C.hx', source: src }], plugin);
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, plugin).length);
	}

	// --- registry / enablement ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId(RULE));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains(RULE));
	}

	public function testDefaultOffSuppressed(): Void {
		Assert.equals(0, runGated('class C {\n\tpublic function orphaned():Void {}\n}', '{}', true).length);
	}

	public function testOptInEnabled(): Void {
		final json: String = '{"rules":{"unused-public-member":{"enabled":true}}}';
		Assert.equals(1, runGated('class C {\n\tpublic function orphaned():Void {}\n}', json, true).length);
	}

	public function testExplicitSelectionBypassesGate(): Void {
		// applyEnablement=false is the --rule path: a DefaultOff rule runs regardless.
		Assert.equals(1, runGated('class C {\n\tpublic function orphaned():Void {}\n}', '{}', false).length);
	}

	/**
	 * A public method written inside a member-position `#if` is a method of the class like any other,
	 * and just as unreachable when nothing names it. The region is ONE child of the container holding
	 * every branch's members flattened, so scanning the container's direct children alone silently
	 * exempted it.
	 */
	public function testConditionalMemberFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\t#if cpp\n\tpublic function gone():Void {}\n\tpublic var keeper:Int = 0;\n\t#end\n}').length
		);
	}

	/**
	 * A call written in ANY branch is a reference: the token scan reads the whole file, so a method
	 * declared under `#if cpp` and called under the same guard is reachable and stays unreported.
	 */
	public function testConditionalCallInAnotherBranchCounts(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\t#if cpp\n\tpublic function used():Void {}\n\t#end\n\t#if cpp\n\tpublic function go():Void {\n\t\tused();\n'
				+ '\t}\n\t#end\n}'
			).filter(v -> v.message.indexOf('public used') >= 0).length
		);
	}

	/**
	 * The deletion carries the method's doc comment and modifier run, both of which live INSIDE the
	 * region — a group span computed against the container would leave them behind as debris that
	 * does not parse. The region's other member is untouched and the directives stay.
	 */
	public function testConditionalMemberDeletedInsideItsBranch(): Void {
		final src: String =
			'class C {\n\t#if cpp\n\t/** Doc. */\n\tpublic function gone():Void {}\n\tpublic var keeper:Int = 0;\n\t#end\n}';
		Assert.equals('class C {\n\t#if cpp\n\tpublic var keeper:Int = 0;\n\t#end\n}', applyFix(src));
	}

	/**
	 * Deleting the SOLE member of a region would leave a bare `#if … #end`, a shape the grammar does
	 * not model (an empty BRANCH parses, an empty REGION does not) — the finding stays, its deletion
	 * does not.
	 */
	public function testConditionalSoleMemberReportedButNotDeleted(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tpublic function gone():Void {}\n\t#end\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	/**
	 * A `public` carried out of a `#if` region makes the method public in one build only, and this
	 * rule reads `public` as the gate that admits a candidate at all. A run the branches disagree on
	 * refuses the member — the conservatism the old wrapper-counts-as-annotation reading provided.
	 */
	public function testConditionalCarriedVisibilityRefusesTheMethod(): Void {
		Assert.equals(
			0, violations('class C {\n\t#if js\n\tpublic\n\t#end\n\tfunction zqxwvOnly():Void {}\n\tpublic var keeper:Int = 0;\n}').length
		);
	}

	/**
	 * Emptying a region is a property of the whole edit SET: two unused methods that are together all
	 * of a region's members each look non-sole on their own, and deleting both leaves a bare
	 * `#if … #end` whose rejected splice would drop every other edit the pass had for the file.
	 */
	public function testConditionalAllRegionMembersReportedButNotDeleted(): Void {
		final src: String = 'class C {\n\t#if cpp\n\tpublic function zqxwvA():Void {}\n\tpublic function zqxwvB():Void {}\n\t#end\n}';
		Assert.equals(2, violations(src).length);
		Assert.equals(src, applyFix(src));
	}

	// --- an unreadable file in scope ---

	/**
	 * A file the grammar cannot read no longer silences the RULE. `run` used to open with
	 * `if (index.skippedFiles().length != 0) return [];`, so one unparseable file anywhere in scope
	 * returned zero findings for every other file — indistinguishable from a clean tree, and with
	 * no `declineReason` anywhere to say otherwise.
	 *
	 * The caution it was standing in for is in the reference proof itself: both mechanisms are raw
	 * text over the RETAINED sources, which include the skipped file. This test and its twin below
	 * differ ONLY in what that unreadable file contains.
	 */
	public function testUnreadableFileNotSpellingTheMemberLeavesTheRuleReporting(): Void {
		final vs: Array<Violation> = violationsOf([
			{ file: 'C.hx', source: 'class C {\n\tpublic function orphaned():Void {}\n}' },
			{ file: 'B.hx', source: 'class B {\n\tfunction q(: {{{\n}\n' }
		]);
		Assert.equals(1, vs.length);
		if (vs.length != 1) return;
		Assert.equals('unused public orphaned: no reference to it anywhere in scope', vs[0].message);
	}

	/** The twin: the same unreadable file, now spelling the member — the textual proof reads it and refuses. */
	public function testUnreadableFileSpellingTheMemberStillSuppresses(): Void {
		Assert.equals(
			0, violationsOf([
				{ file: 'C.hx', source: 'class C {\n\tpublic function orphaned():Void {}\n}' },
				{ file: 'B.hx', source: 'class B {\n\tfunction q(: {{{\n\tc.orphaned();\n}\n' }
			]).length
		);
	}

	/** And the DELETION follows the report: an unreadable file naming nothing does not withhold the edit either. */
	public function testUnreadableFileNotSpellingTheMemberLeavesTheDeletionAvailable(): Void {
		final owner: String = 'class C {\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(1, fixEditCount(owner, [
			{ file: 'C.hx', source: owner },
			{ file: 'B.hx', source: 'class B {\n\tfunction q(: {{{\n}\n' }
		]));
	}

	/**
	 * The narrowing this rule KNOWINGLY takes, pinned so it stays the only one. An INTERPOLATED
	 * reflection name contributes a static fragment that `runtimeNameFragment` matches against the
	 * method name — from a PARSED file. A skipped file contributes no fragment, so the deletion
	 * proceeds. The two arms differ ONLY in whether the reflecting file parses.
	 */
	public function testInterpolatedReflectionNameBlocksTheDeletionOnlyWhenItsFileParses(): Void {
		// The fragment must be a PROPER substring of the method name: were it the whole name, the
		// skipped file would spell it and the textual proof would suppress the finding outright,
		// leaving nothing for the fragment gate to be the difference on.
		final owner: String = 'class C {\n\tpublic function orphanedThing():Void {}\n}';
		final parsed: String = 'class B {\n\tfunction q(o:Dynamic, n:String):Dynamic return Reflect.field(o, \'orphaned$${n}\');\n}';
		final skipped: String = 'class B {\n\tfunction q(: {{{ Reflect.field(o, \'orphaned$${n}\');\n}\n';
		Assert.equals(0, fixEditCount(owner, [{ file: 'C.hx', source: owner }, { file: 'B.hx', source: parsed }]));
		Assert.equals(1, fixEditCount(owner, [{ file: 'C.hx', source: owner }, { file: 'B.hx', source: skipped }]));
	}

	/**
	 * The STATIC twin of the test above, and the pin that holds the modifier NAME to one spelling across
	 * two modules: `CheckScan.frameworkReachableMethod` writes the literal `'static'` into the
	 * `NamedDecl` it builds and `HaxeNamingSupport.nominated` reads it, with no shared constant possible
	 * - this module may not import the grammar that owns the vocabulary. This stops flagging the moment
	 * either side drifts.
	 *
	 * utest discovers with `!isStatic && isTestName(...)`, so a `public static function testX()` in a
	 * `Test` subclass is reached by nobody and is exactly the dead public member this rule reports. The
	 * adapter used to pass an EMPTY modifier list, so the carve-out applied to it too.
	 */
	public function testStaticUtestMethodStillFlagged(): Void {
		final base: String = 'class Test {}';
		final statics: String = 'class MySuite extends Test {\n\tpublic static function testZqxwvAlpha():Void {}\n}';
		final instance: String = 'class MySuite extends Test {\n\tpublic function testZqxwvAlpha():Void {}\n}';
		Assert.equals(
			1, violationsOf([{ file: 'Test.hx', source: base }, { file: 'MySuite.hx', source: statics }]).length,
			'a static test method is discovered by nothing'
		);
		Assert.equals(
			0, violationsOf([{ file: 'Test.hx', source: base }, { file: 'MySuite.hx', source: instance }]).length,
			'the instance twin is still the framework\'s'
		);
	}

	/** Findings over `C.hx` plus a second file whose `main` (implicitly reachable, never flagged) carries `body`. */
	private function withUser(body: String): Array<Violation> {
		final owner: String = 'class C {\n\tpublic function orphaned():Void {}\n}';
		final user: String = 'class U {\n\tpublic static function main(c:C):Void {\n\t\t$body\n\t}\n}';
		return violationsOf([{ file: 'C.hx', source: owner }, { file: 'U.hx', source: user }]);
	}

	private function violations(src: String): Array<Violation> {
		return violationsOf([{ file: 'C.hx', source: src }]);
	}

	private function violationsOf(files: Array<{ file: String, source: String }>): Array<Violation> {
		final check: Null<Check> = Linter.byId(RULE);
		return check == null ? [] : check.run(files, new HaxeQueryPlugin());
	}

	/** The number of edits `fix` yields for `owner` after `run` over `files` — the deletion gate's verdict. */
	private function fixEditCount(owner: String, files: Array<{ file: String, source: String }>): Int {
		final check: Null<Check> = Linter.byId(RULE);
		Assert.notNull(check);
		if (check == null) return -1;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return check.fix(owner, check.run(files, plugin), plugin).length;
	}

	private function applyFix(src: String): String {
		final check: Null<Check> = Linter.byId(RULE);
		return check == null ? src : CheckFixture.fixedSource(check, src);
	}

	private function runGated(source: String, json: String, applyEnablement: Bool): Array<Violation> {
		function resolver(file: String): LintConfig return LintConfig.parse(json);
		return Linter.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin(), [new UnusedPublicMember()], resolver, applyEnablement);
	}

}
