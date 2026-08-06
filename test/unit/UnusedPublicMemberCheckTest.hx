package unit;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnusedPublicMember;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
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
		// The base deliberately declares NO `orphaned`, so the supertype-member gate cannot reject
		// this and the `override` modifier is the only thing that can. The pair shows it does.
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

	public function testPrecedingFieldModifiersDoNotLeakOntoTheMethod(): Void {
		// The `@:keep` and the `public` here belong to `other`; a run that reset only at methods
		// would read the next method as kept (and as public when it is not).
		final src: String = 'class C {\n\t@:keep public var other:Int = 0;\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(1, violations(src).length);
	}

	public function testImplicitlyReachableNamesNotFlagged(): Void {
		for (name in ['new', 'main', 'toString', '__init__'])
			Assert.equals(0, violations('class C {\n\tpublic function $name():Void {}\n}').length, 'flagged $name');
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

	public function testSupertypeDeclaringTheMemberNotFlagged(): Void {
		// Two independent reasons agree here, and the cheaper one answers first: the base's own
		// declaration is an occurrence of the name, so the whole-scope token scan already refuses.
		// `supertypeDeclaresMember` is the index-resolved second opinion behind it.
		final base: String = 'class Base {\n\tpublic function orphaned():Void {}\n}';
		final sub: String = 'class Sub extends Base {\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: sub }]).length);
	}

	public function testInterfaceDeclaringTheMemberNotFlagged(): Void {
		// As above: the interface declaration is itself an occurrence, so the token scan refuses
		// first and `implementsInterfaceDeclaringMember` backs it up.
		final iface: String = 'interface I {\n\tpublic function orphaned():Void;\n}';
		final impl: String = 'class C implements I {\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(0, violationsOf([{ file: 'I.hx', source: iface }, { file: 'C.hx', source: impl }]).length);
	}

	public function testSubtypeDeclaringTheMemberNotFlagged(): Void {
		// Deleting the base method would break the subtype's declaration; the subtype's own
		// occurrence of the name is what the token scan sees, `subtypeDeclaresMember` the model.
		final base: String = 'class Base {\n\tpublic function orphaned():Void {}\n}';
		final sub: String = 'class Sub extends Base {\n\toverride public function orphaned():Void {}\n}';
		Assert.equals(0, violationsOf([{ file: 'Base.hx', source: base }, { file: 'Sub.hx', source: sub }]).length);
	}

	// --- robustness ---

	public function testSkipParseInScopeYieldsNothing(): Void {
		// A file the parser could not read may hold the only call — the whole run reports nothing.
		final owner: String = 'class C {\n\tpublic function orphaned():Void {}\n}';
		Assert.equals(1, violations(owner).length);
		Assert.equals(
			0, violationsOf([
				{ file: 'C.hx', source: owner },
				{ file: 'Bad.hx', source: 'class Bad { public function f() {' }
			]).length
		);
	}

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
		if (check == null) return src;
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final edits: Array<{ span: Span, text: String }> = check.fix(src, check.run([{ file: 'C.hx', source: src }], plugin), plugin);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function runGated(source: String, json: String, applyEnablement: Bool): Array<Violation> {
		final resolver: (String) -> LintConfig = function(file: String): LintConfig return LintConfig.parse(json);
		return Linter.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin(), [new UnusedPublicMember()], resolver, applyEnablement);
	}

}
