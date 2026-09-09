package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Severity;
import anyparse.check.UnusedPrivate;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * T865: every gate `unused-private`s autofix declines a member at SAYS which gate it was.
 *
 * `apq lint --fix` reports a per-rule unfixed ledger, and its only input for the sentence is
 * `Violation.declineReason` — the field the check writes at the refusal site. `unused-private`
 * wrote it nowhere: eleven gates returned a bare `false` (seven of them from one predicate
 * pair), so a user who ran `--fix` over a file with a declined finding read `declined` and no
 * cause, for the rule whose whole design is a broad report with a conservative deletion.
 *
 * The cells below drive ONE gate each, through the same seam the pipeline uses (`run` then
 * `fix`, the report-scoped index handed in). What they assert is the LEDGER channel and nothing
 * else: no reported byte moves when a check adopts the field, so a report-text assertion would
 * be green either way.
 *
 * Eleven sites, TEN sentences: a member of a macro-built type and a private empty constructor
 * of one decline for the same cause and share one named sentence, which is what keeps the
 * ledger from splitting one cause into two rows. The two remaining `continue`s in `fix` get no
 * sentence by intent — see `testAFindingThisCallCannotPlaceGetsNoSentence`.
 */
class UnusedPrivateDeclineReasonTest extends Test {

	/** A gate is driven by the file it needs, and answers with a sentence naming ITSELF. */
	private static final GATES: Array<Gate> = [
		{
			name: 'no-body',
			fragment: 'has no body',
			files: [{ file: 'C.hx', source: 'class C {\n\tprivate function dead(): Int;\n}\n' }]
		},
		{
			name: 'side-effecting-initializer',
			fragment: 'not provably side-effect-free',
			files: [
				{ file: 'C.hx', source: 'class C {\n\tprivate var _x: Int = Std.random(3);\n}\n' }
			]
		},
		{
			name: 'abstract-method-impl',
			fragment: 'ABSTRACT method',
			files: [
				{ file: 'C.hx', source: 'class C extends Base {\n\tprivate function impl(): Int {\n\t\treturn 1;\n\t}\n}\n' }
			]
		},
		{
			name: 'rtti',
			fragment: '`@:rtti`',
			files: [{ file: 'C.hx', source: '@:rtti\nclass C {\n\tprivate var _x: Int = 0;\n}\n' }]
		},
		{
			name: 'build-macro',
			fragment: '`@:build` macro',
			files: [
				{ file: 'C.hx', source: '@:build(M.build())\nclass C {\n\tprivate var _x: Int = 0;\n}\n' }
			]
		},
		{
			name: 'keep',
			fragment: '`@:keep`',
			files: [{ file: 'C.hx', source: '@:keep\nclass C {\n\tprivate var _x: Int = 0;\n}\n' }]
		},
		{
			name: 'reflected-name',
			fragment: 'occurs in a STRING',
			files: [
				{ file: 'C.hx', source: 'class C {\n\tprivate var _x: Int = 0;\n}\n' },
				{
					file: 'D.hx',
					source: 'class D {\n\tpublic function read(o: Dynamic): Dynamic {\n\t\treturn Reflect.field(o, \'_x\');\n\t}\n}\n'
				}
			]
		},
		{
			name: 'private-empty-ctor-under-conditional',
			fragment: 'private empty constructor',
			files: [
				{
					file: 'C.hx',
					source: 'class C {\n\t#if js\n\tpublic static function jsOnly(): Int {\n\t\treturn 1;\n\t}\n\t#end\n'
						+ '\tpublic static function helper(): Int {\n\t\treturn 2;\n\t}\n\n\tprivate function new() {}\n}\n'
				},
				{ file: 'D.hx', source: 'class D {\n\tpublic function f(): Int {\n\t\treturn C.helper();\n\t}\n}\n' }
			]
		},
		{
			name: 'conditional-file-with-an-occurrence-elsewhere',
			fragment: 'which branch reads it',
			files: [
				{
					file: 'C.hx',
					source: 'class C {\n\t#if js\n\tpublic static function jsOnly(): Int {\n\t\treturn 1;\n\t}\n\t#end\n'
						+ '\tprivate var _x: Int = 0;\n}\n'
				},
				{ file: 'D.hx', source: 'class D {\n\t// C._x is written by the loader.\n}\n' }
			]
		},
		{
			name: 'emptying-a-conditional-region',
			fragment: 'emptying a conditional region',
			files: [
				{
					file: 'C.hx',
					source: 'class C {\n\t#if js\n\tprivate var _onlyMember: Int = 0;\n\t#end\n\n\tpublic function new() {}\n}\n'
				}
			]
		}
	];

	/** Each gate names itself, and drives its own cell to exactly one declined finding. */
	@:pin('control')
	@:killer('M-UNUSED-PRIVATE-DECLINE-SILENT')
	@:killer('M-UNUSED-PRIVATE-REGION-DECLINE-SILENT')
	public function testEachGateNamesItself(): Void {
		for (gate in GATES) {
			final answer: Declines = declineReasons(gate.files);
			final spoke: Int = answer.reasons.length;
			Assert.equals(1, spoke, '${gate.name}: $spoke declined finding(s), expected exactly one');
			// A sentence on a finding the same call went on to FIX would be a lie about the run: the
			// gate has to have closed for the label to mean anything.
			Assert.equals(0, answer.edits, '${gate.name}: the call wrote ${answer.edits} edit(s), so nothing was declined');
			final said: String = spoke == 1 ? answer.reasons[0] : '';
			Assert.isTrue(said.indexOf(gate.fragment) != -1, '${gate.name}: the sentence does not name the gate — $said');
		}
	}

	/**
	 * The sentences are pairwise DISTINCT, which is what makes the ledger readable: a shared
	 * sentence would merge two causes into one row and a reader could not tell which gate closed.
	 */
	public function testTheGatesSpeakDistinctSentences(): Void {
		final said: Array<String> = [];
		for (gate in GATES) for (reason in declineReasons(gate.files).reasons) if (!said.contains(reason)) said.push(reason);
		Assert.equals(GATES.length, said.length, 'two gates share a sentence: ${said.join(' | ')}');
	}

	/**
	 * The eleventh site is DEFENSIVE, and this is the measurement that says so: `run`s
	 * never-instantiated constructor arm already excludes a class carrying `@:build`
	 * (`collectClassMeta` / the ctor collector), so no finding ever reaches the same re-check in
	 * `fix` and no fixture can drive its sentence through the public seam.
	 *
	 * That is why the sentence is a named constant rather than a second literal: its one LIVE writer
	 * is the member gate, and the defensive one has to keep saying the same thing if it ever starts
	 * firing. Ten sentences, eleven sites, one of them a guard.
	 */
	public function testTheMacroBuiltCtorIsNeverReportedSoItsGateIsDefensive(): Void {
		final files: Array<SourceFile> = [
			{
				file: 'C.hx',
				source: '@:build(M.build())\nclass C {\n\tpublic static function helper(): Int {\n\t\treturn 2;\n\t}\n\n'
					+ '\tprivate function new() {}\n}\n'
			},
			{ file: 'D.hx', source: 'class D {\n\tpublic function f(): Int {\n\t\treturn C.helper();\n\t}\n}\n' }
		];
		final reported: Array<Violation> = new UnusedPrivate().run(files, new HaxeQueryPlugin()).filter(v -> v.file == 'C.hx');
		Assert.equals(0, reported.length, 'run reported ${reported.length} finding(s) — the gate below it is reachable after all');
		// Non-vacuity: drop the `@:build` and the very same class DOES report its constructor, so the
		// zero above is that meta and not a fixture that reports nothing.
		final withoutMeta: Array<SourceFile> = [
			{ file: 'C.hx', source: files[0].source.substr('@:build(M.build())\n'.length) },
			files[1]
		];
		Assert.equals(1, new UnusedPrivate().run(withoutMeta, new HaxeQueryPlugin()).filter(v -> v.file == 'C.hx').length);
	}

	/**
	 * The two guards that get NO sentence, and why that is the correct answer rather than a
	 * missing one: a finding with no span, and one whose span matches no member of THIS source,
	 * are not gates that closed — they are a violation this call cannot place. A sentence there
	 * would be invented, which is the defect `declineReason` exists to end.
	 *
	 * Non-vacuous on purpose: the same call DOES delete a real dead member, so "no reason" is a
	 * statement about these two findings and not about a `fix` that answered nothing.
	 */
	public function testAFindingThisCallCannotPlaceGetsNoSentence(): Void {
		final source: String = 'class C {\n\tprivate function dead(): Int {\n\t\treturn 1;\n\t}\n}\n';
		final files: Array<SourceFile> = [{ file: 'C.hx', source: source }];
		final check: UnusedPrivate = new UnusedPrivate();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final own: Array<Violation> = check.run(files, plugin);
		Assert.equals(1, own.length);
		final unspanned: Violation = probe(null);
		final unplaced: Violation = probe(new Span(0, 1));
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, own.concat([unspanned, unplaced]), plugin, SymbolIndex.build(files, plugin)
		);
		Assert.equals(1, edits.length, 'the deletion this call CAN make is what keeps the two null assertions non-vacuous');
		Assert.isNull(unspanned.declineReason);
		Assert.isNull(unplaced.declineReason);
		Assert.isNull(own[0].declineReason);
	}

	/**
	 * The region gate speaks for EVERY finding it takes down, not just the first.
	 *
	 * `GATES`'s region cell holds ONE member in its `#if` branch, so a mutation that labels only the
	 * first refused member — a `break` in `noteRegionDeclines` — passes every assertion above: with
	 * N == 1 the first is all of them. Two dead members in one branch make the count observable, and
	 * the ledger then prints one row of two rather than a labelled finding beside a silent one.
	 */
	public function testTheRegionGateSpeaksForEveryMemberItTakesDown(): Void {
		final files: Array<SourceFile> = [
			{
				file: 'C.hx',
				source: 'class C {\n\t#if js\n\tprivate var _a: Int = 0;\n\tprivate var _b: Int = 0;\n\t#end\n\n'
					+ '\tpublic function new() {}\n}\n'
			}
		];
		final answer: Declines = declineReasons(files);
		final spoke: Int = answer.reasons.length;
		Assert.equals(2, spoke, '$spoke of the two members in the emptied branch got a sentence');
		Assert.equals(0, answer.edits, 'the call wrote ${answer.edits} edit(s), so the region gate did not close');
		for (said in answer.reasons)
			Assert.isTrue(said.indexOf('emptying a conditional region') != -1, 'not the region gate speaking — $said');
	}

	/** A finding of this rule at `span` that no gate decides — the shape both `fix` guards drop. */
	private function probe(span: Null<Span>): Violation {
		return {
			file: 'C.hx',
			span: span,
			rule: 'unused-private',
			severity: Severity.Warning,
			message: 'probe'
		};
	}

	/**
	 * The decline sentences `fix` wrote on the findings for `files[0]`, in report order — the
	 * ledger channel, asked exactly the way `apq lint --fix` asks it: `run` first (which fills the
	 * reflection surface), then `fix` over that file with the report-scoped index.
	 */
	private function declineReasons(files: Array<SourceFile>): Declines {
		final check: UnusedPrivate = new UnusedPrivate();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final target: String = files[0].file;
		final own: Array<Violation> = check.run(files, plugin).filter(v -> v.file == target);
		final edits: Array<{ span: Span, text: String }> = check.fix(files[0].source, own, plugin, SymbolIndex.build(files, plugin));
		final out: Array<String> = [];
		for (v in own) {
			final reason: Null<String> = v.declineReason;
			if (reason != null) out.push(reason);
		}
		return { reasons: out, edits: edits.length };
	}

}

/** One gate: the cell that drives it, and the fragment of its sentence that names it. */
private typedef Gate = {
	final name: String;
	final fragment: String;
	final files: Array<SourceFile>;
};

/** One source of a cell's scope. */
private typedef SourceFile = {
	var file: String;
	var source: String;
};

/** What a cell's `fix` call said: one sentence per declined finding, and how many edits it wrote. */
private typedef Declines = {
	final reasons: Array<String>;
	final edits: Int;
};
