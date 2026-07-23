package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DocCoverage;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

/**
 * The `doc-coverage` check: a public API type or member without a leading `/**`
 * doc comment is flagged `Info` (report-only). By default only the type-level
 * requirement is on (`requireTypeDoc` true, `requireMemberDoc` false); the member
 * matrix runs with member coverage opted in. Module-private types, private / default
 * members, and the constructor are out of scope; a line comment is not a doc.
 */
class DocCoverageCheckTest extends Test {

	// --- type-level (default config: type-only) ---

	public function testUndocumentedTypeFlagged(): Void {
		final vs: Array<Violation> = typeVs('class C {}');
		Assert.equals(1, vs.length);
		Assert.equals('doc-coverage', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(vs[0].message.contains("public type 'C'"));
	}

	public function testDocumentedTypeQuiet(): Void {
		Assert.equals(0, typeVs('/** A documented class. */\nclass C {}').length);
	}

	public function testLineCommentIsNotTypeDoc(): Void {
		// A `//` line comment is not documentation.
		Assert.equals(1, typeVs('// just a note\nclass C {}').length);
	}

	public function testPlainBlockIsNotTypeDoc(): Void {
		// A plain `/*` block (not `/**`) is not documentation.
		Assert.equals(1, typeVs('/* license banner */\nclass C {}').length);
	}

	public function testModulePrivateTypeQuiet(): Void {
		// `private class` is not part of the module's public surface.
		Assert.equals(0, typeVs('private class C {}').length);
	}

	public function testFinalClassNameResolved(): Void {
		// A `final class` projects as `FinalDecl` (name on the inner `ClassForm`);
		// the message must name it, not `<anonymous>`, and the doc anchor sits
		// before the `@:meta` run.
		final vs: Array<Violation> = typeVs('@:nullSafety(Strict)\nfinal class C {}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("public type 'C'"));
	}

	public function testDocBeforeMetaQuiet(): Void {
		// The doc sits before the modifier / `@:meta` run, not the decl node.
		Assert.equals(0, typeVs('/** Doc. */\n@:nullSafety(Strict)\nfinal class C {}').length);
	}

	public function testInterfaceTypeFlagged(): Void {
		Assert.equals(1, typeVs('interface I { function h():Void; }').length);
	}

	public function testEnumTypeFlaggedNotConstructors(): Void {
		// One finding for the enum type; its constructors are never members.
		final vs: Array<Violation> = typeVs('enum E { A; B; }');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("public type 'E'"));
	}

	public function testMembersOffByDefault(): Void {
		// Default config leaves the member requirement off — only the type flags.
		final vs: Array<Violation> = typeVs('/** Doc. */\nclass C {\n\tpublic function m() {}\n}');
		Assert.equals(0, vs.length);
	}

	// --- member-level (member coverage opted in, type requirement off) ---

	public function testPublicMethodNoDocFlagged(): Void {
		final vs: Array<Violation> = memberVs('class C {\n\tpublic function m() {}\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("public member 'm'"));
	}

	public function testDocumentedMemberQuiet(): Void {
		Assert.equals(0, memberVs('class C {\n\t/** Does m. */\n\tpublic function m() {}\n}').length);
	}

	public function testPrivateMemberQuiet(): Void {
		Assert.equals(0, memberVs('class C {\n\tprivate function m() {}\n}').length);
	}

	public function testDefaultVisibilityMemberQuiet(): Void {
		// An unmodified member is private in Haxe — not public API.
		Assert.equals(0, memberVs('class C {\n\tfunction m() {}\n}').length);
	}

	public function testStaticPrivateMemberQuiet(): Void {
		Assert.equals(0, memberVs('class C {\n\tstatic function h() {}\n}').length);
	}

	public function testPublicFieldNoDocFlagged(): Void {
		final vs: Array<Violation> = memberVs('class C {\n\tpublic var x:Int;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("public member 'x'"));
	}

	public function testLineCommentBeforeMemberFlagged(): Void {
		// A `//` line comment before a public member is not a doc.
		Assert.equals(1, memberVs('class C {\n\t// note\n\tpublic function m() {}\n}').length);
	}

	public function testDocBeforeMemberModifierRunQuiet(): Void {
		// The doc precedes the `@:meta` + `public` run, not the member host span.
		Assert.equals(0, memberVs('class C {\n\t/** Does m. */\n\t@:keep public function m() {}\n}').length);
	}

	public function testInterfaceMemberFlagged(): Void {
		// Interface members are implicitly public.
		final vs: Array<Violation> = memberVs('interface I {\n\tfunction h():Void;\n}');
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("public member 'h'"));
	}

	public function testConstructorExemptByDefault(): Void {
		Assert.equals(0, memberVs('class C {\n\tpublic function new() {}\n}').length);
	}

	public function testIncludeConstructorOptIn(): Void {
		final vs: Array<Violation> = run(
			'{"rules":{"doc-coverage":{"requireMemberDoc":true,"requireTypeDoc":false,"includeConstructor":true}}}',
			'class C {\n\tpublic function new() {}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains("public member 'new'"));
	}

	public function testModulePrivateTypeMembersSkipped(): Void {
		// A public member of a `private class` is not public API.
		Assert.equals(0, memberVs('private class C {\n\tpublic function m() {}\n}').length);
	}

	public function testTypedefFieldsNotMembers(): Void {
		Assert.equals(0, memberVs('typedef T = { a:Int, b:String };').length);
	}

	// --- suppression / config / framework ---

	public function testNoqaSuppresses(): Void {
		Assert.equals(0, suppressed('class C {} // noqa: doc-coverage').length);
	}

	public function testConfigDisableDropsFinding(): Void {
		final check: DocCoverage = new DocCoverage();
		final cfg: LintConfig = LintConfig.parse('{"rules":{"doc-coverage":{"enabled":false}}}');
		final vs: Array<Violation> = Linter.run([{ file: 'C.hx', source: 'class C {}' }], new HaxeQueryPlugin(), [check], (_) -> cfg, true);
		Assert.equals(0, vs.length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C {}';
		final check: DocCoverage = new DocCoverage();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, typeVs('class Bad { var x ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('doc-coverage'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('doc-coverage'));
		Assert.equals(99, Linter.builtins().length);
	}

	/** Run with the default config (type requirement only). */
	private function typeVs(src: String): Array<Violation> {
		return new DocCoverage().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Run with member coverage opted in and the type requirement off (isolates member findings). */
	private function memberVs(src: String): Array<Violation> {
		return run('{"rules":{"doc-coverage":{"requireMemberDoc":true,"requireTypeDoc":false}}}', src);
	}

	/** Run the check with a specific `apqlint.json` config threaded through the resolver. */
	private function run(configJson: String, src: String): Array<Violation> {
		final check: DocCoverage = new DocCoverage();
		final cfg: LintConfig = LintConfig.parse(configJson);
		check.setConfigResolver((_) -> cfg);
		return check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	/** Through `Linter.run` so inline `// noqa` suppression applies (default config). */
	private function suppressed(src: String): Array<Violation> {
		return Linter.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin(), [new DocCoverage()]);
	}

}
