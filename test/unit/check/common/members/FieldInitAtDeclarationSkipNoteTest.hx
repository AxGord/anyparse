package unit.check.common.members;

import anyparse.check.Check;
import anyparse.check.common.members.FieldInitAtDeclaration;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.Cli.RuleEdits;
import anyparse.query.RunLedger;
import anyparse.query.cli.command.LintFixDriver;

/**
 * The skip notice of `field-init-at-declaration` is a note the fix RETURNS (`NotedFix`), not a line it prints: the fixpoint
 * driver says each note once per run, however many passes and splits re-ask the same finding.
 */
class FieldInitAtDeclarationSkipNoteTest extends Test {

	private static final CHAIN: String = 'class C {\n\tvar _a:Array<Int>;\n\tvar _b:Array<Int>;\n\tvar _c:Array<Int>;\n'
		+ '\tpublic function new() {\n\t\t_a = new Array<Int>();\n\t\t_b = new Array<Int>();\n\t\t_c = new Array<Int>();\n\t}\n'
		+ '\tpublic function dispose():Void {\n\t\t_a = null;\n\t\t_b = null;\n\t\t_c = null;\n\t}\n}';

	/** A list thinned past the first field leaves the later two in the constructor, and the fix says so once per field. */
	@:pin('control')
	@:killer('M-FIELDINIT-SKIP-NOTE')
	public function testSkippedFieldsComeBackAsNotes(): Void {
		final check: FieldInitAtDeclaration = new FieldInitAtDeclaration();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final all: Array<Violation> = CheckFixture.violations(check, CHAIN, plugin);
		Assert.equals(3, all.length);
		final answer: NotedEdits = check.fixNoted(CHAIN, all.slice(1), plugin);
		Assert.equals(0, answer.edits.length);
		Assert.equals(2, answer.notes.length);
		Assert.isTrue(answer.notes[0].key.indexOf('#_b') != -1, answer.notes[0].key);
		Assert.isTrue(answer.notes[1].key.indexOf('#_c') != -1, answer.notes[1].key);
		Assert.isTrue(answer.notes[0].text.indexOf('\'_b\' skipped') != -1, answer.notes[0].text);
	}

	/** `fix` is the projection of `fixNoted`: a full list moves everything and notes nothing. */
	public function testFixIsTheProjectionOfFixNoted(): Void {
		final check: FieldInitAtDeclaration = new FieldInitAtDeclaration();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final all: Array<Violation> = CheckFixture.violations(check, CHAIN, plugin);
		final answer: NotedEdits = check.fixNoted(CHAIN, all, plugin);
		Assert.isTrue(answer.edits.length > 0);
		Assert.equals(0, answer.notes.length);
		Assert.equals(answer.edits.length, check.fix(CHAIN, all, plugin).length);
	}

	/** A note is said once per rule and key in a run, and a new run starts clean. */
	@:pin('control')
	@:killer('M-LINT-FIX-NOTE-ONCE')
	public function testNoteIsSaidOncePerRuleAndKey(): Void {
		final notes: Array<FixNote> = [{ key: 'k1', text: 'one' }, { key: 'k2', text: 'two' }];
		RunLedger.begin();
		Assert.same(['one', 'two'], LintFixDriver.freshNoteLines('r', notes));
		Assert.same([], LintFixDriver.freshNoteLines('r', notes));
		Assert.same(['one', 'two'], LintFixDriver.freshNoteLines('other', notes));
		RunLedger.begin();
		Assert.same(['one', 'two'], LintFixDriver.freshNoteLines('r', notes));
	}

	/** The driver asks a `NotedFix` through `fixNoted` and records its notes, however many times it re-asks. */
	@:pin('control')
	@:killer('M-LINT-FIX-NOTE-ROUTED')
	public function testDriverRecordsTheNotesOfAThinnedList(): Void {
		#if (sys || nodejs)
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final check: Null<Check> = Linter.byId('field-init-at-declaration');
		if (check == null) {
			Assert.fail('field-init-at-declaration is not registered');
			return;
		}
		final files: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: CHAIN }];
		final all: Array<Violation> = CheckFixture.violationsIn(check, files, plugin);
		Assert.equals(3, all.length);
		RunLedger.begin();
		for (_ in 0...2) {
			final groups: Array<RuleEdits> = LintFixDriver.collectFileLintEdits(
				CHAIN, all.slice(1), [check], plugin, CheckFixture.index(files, plugin)
			);
			Assert.equals(0, LintFixDriver.contributedEdits(groups).length);
		}
		Assert.same(['C.hx#_b', 'C.hx#_c'], RunLedger.keysOf('fix-note:field-init-at-declaration'));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The EMBEDDED shape (the write sits inside another expression) is skipped and noted the same way. */
	@:pin('control')
	@:killer('M-FIELDINIT-SKIP-NOTE-EMBEDDED')
	public function testSkippedEmbeddedWriteComesBackAsNote(): Void {
		final src: String = 'class C {\n\tprivate var _a:Foo;\n\tprivate var _b:Foo;\n\tpublic function new() {\n\t\t_a = new Foo();\n'
			+ '\t\tsink([_b = new Foo()]);\n\t}\n}';
		final check: FieldInitAtDeclaration = new FieldInitAtDeclaration();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final all: Array<Violation> = CheckFixture.violations(check, src, plugin);
		Assert.equals(2, all.length);
		final onlyB: Array<Violation> = all.filter(v -> v.span != null && src.substring(v.span.from, v.span.to).indexOf('_b') != -1);
		Assert.equals(1, onlyB.length);
		final answer: NotedEdits = check.fixNoted(src, onlyB, plugin);
		Assert.equals(0, answer.edits.length);
		Assert.equals(1, answer.notes.length);
		Assert.isTrue(answer.notes[0].key.indexOf('#_b') != -1, answer.notes[0].key);
	}

}
