package unit.check;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.CheckScan;
import anyparse.check.RunScan;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/** One report entry, as `Check.run` receives it. */
private typedef Entry = { file: String, source: String };

/**
 * `RunScan`, the entry loops a check's `run` and `fix` share: every parseable file is visited
 * in the caller's order and an unparseable one is skipped, a null seam gate answers nothing
 * without parsing, the gate reaches the body non-null, the parse projection is overridable,
 * and the span-key readers skip a spanless finding. Green at base by construction: the helpers
 * restate loops the checks already ran.
 */
class RunScanTest extends Test {

	private static final GOOD_A: Entry = { file: 'A.hx', source: 'class A {}' };
	private static final BAD: Entry = { file: 'B.hx', source: 'class {' };
	private static final GOOD_C: Entry = { file: 'C.hx', source: 'class C {}' };

	private final _plugin: GrammarPlugin = new HaxeQueryPlugin();

	public function testCollectVisitsParseableFilesInOrder(): Void {
		final seen: Array<String> = [];
		final out: Array<Violation> = RunScan.collect([GOOD_A, BAD, GOOD_C], _plugin, (entry, tree, out) -> {
			seen.push(entry.file);
			Assert.equals('module', tree.kind);
			out.push(violation(entry.file));
		});
		Assert.same(['A.hx', 'C.hx'], seen);
		Assert.same(['A.hx', 'C.hx'], out.map(v -> v.file));
	}

	public function testCollectWithNullGateParsesNothing(): Void {
		var parses: Int = 0;
		var bodies: Int = 0;
		final out: Array<Violation> =
			RunScan.collectWith([GOOD_A], _plugin, (null: Null<{ k: String }>), (entry, tree, s, out) -> bodies++, (p, s) -> {
				parses++;
				return null;
			});
		Assert.equals(0, out.length);
		Assert.equals(0, parses);
		Assert.equals(0, bodies);
	}

	public function testCollectWithHandsTheGateToEveryBody(): Void {
		final gate: Null<{ k: String }> = { k: 'seam' };
		final out: Array<Violation> = RunScan.collectWith(
			[GOOD_A, GOOD_C], _plugin, gate, (entry, tree, s, out) -> out.push(violation('${entry.file}:${s.k}'))
		);
		Assert.same(['A.hx:seam', 'C.hx:seam'], out.map(v -> v.file));
	}

	public function testCollectTypedHandsTheProviderAndTheIndexToEveryBody(): Void {
		final seen: Array<String> = [];
		final out: Array<Violation> = RunScan.collectTyped([GOOD_A, BAD, GOOD_C], _plugin, (entry, tree, typed, index, out) -> {
			seen.push(entry.file);
			Assert.isTrue(index.declaresTypeInScope('A', entry.file));
			Assert.isTrue([for (k in typed.declaredTypes(entry.source).keys()) k].length == 0);
			out.push(violation(entry.file));
		});
		Assert.same(['A.hx', 'C.hx'], seen);
		Assert.same(['A.hx', 'C.hx'], out.map(v -> v.file));
	}

	public function testCollectTypedAnswersNothingWithoutTypeInformation(): Void {
		var bodies: Int = 0;
		final out: Array<Violation> = RunScan.collectTyped([GOOD_A], new UntypedPlugin(), (entry, tree, typed, index, out) -> bodies++);
		Assert.equals(0, out.length);
		Assert.equals(0, bodies);
	}

	public function testCollectHonoursTheParseOverride(): Void {
		var parses: Int = 0;
		final out: Array<Violation> =
			RunScan.collect([GOOD_A, BAD], _plugin, (entry, tree, out) -> out.push(violation(entry.file)), (p, s) -> {
				parses++;
				return CheckScan.parseBranchAwareOrNull(p, s);
			});
		Assert.equals(2, parses);
		Assert.same(['A.hx'], out.map(v -> v.file));
	}

	public function testGatherVisitsEveryFileWithoutParsing(): Void {
		final out: Array<Violation> = RunScan.gather([GOOD_A, BAD, GOOD_C], (entry, out) -> out.push(violation(entry.file)));
		Assert.same(['A.hx', 'B.hx', 'C.hx'], out.map(v -> v.file));
	}

	public function testEditsAnswerTheBodyOrNothing(): Void {
		var bodies: Int = 0;
		final edits: Array<FixEdit> = RunScan.edits(_plugin, GOOD_A.source, tree -> {
			bodies++;
			return [{ span: new Span(0, 1), text: 'x' }];
		});
		Assert.equals(1, edits.length);
		Assert.equals('x', edits[0].text);
		Assert.equals(
			0, RunScan.edits(_plugin, BAD.source, tree -> {
				bodies++;
				return [{ span: new Span(0, 1), text: 'x' }];
			}).length
		);
		Assert.equals(1, bodies);
	}

	public function testEditsWithGate(): Void {
		var parses: Int = 0;
		Assert.equals(
			0,
			RunScan.editsWith(
				_plugin, GOOD_A.source, (null: Null<{ k: String }>), (tree, s) -> [{ span: new Span(0, 1), text: s.k }], (p, s) -> {
					parses++;
					return null;
				}
			)
				.length
		);
		Assert.equals(0, parses);
		final edits: Array<FixEdit> = RunScan.editsWith(
			_plugin, GOOD_A.source, ({ k: 'seam' }: Null<{ k: String }>), (tree, s) -> [{ span: new Span(0, 1), text: s.k }]
		);
		Assert.same(['seam'], edits.map(e -> e.text));
	}

	public function testSpanKeysAndStartsSkipASpanlessFinding(): Void {
		final vs: Array<Violation> = [spanned(3, 7), violation('x'), spanned(10, 12)];
		Assert.same(['3:7', '10:12'], RunScan.spanKeys(vs));
		Assert.same([3, 10], RunScan.spanStarts(vs));
	}

	public function testEachMatchedVisitsResolvedKeysInReportOrder(): Void {
		final byKey: Map<String, String> = ['3:7' => 'a', '10:12' => 'c'];
		final seen: Array<String> = [];
		RunScan.eachMatched(
			[spanned(10, 12), violation('x'), spanned(3, 7), spanned(1, 2)], byKey, (m, span) -> seen.push('$m@${span.from}')
		);
		Assert.same(['c@10', 'a@3'], seen);
	}

	public function testSpanEditsSkipSpanlessAndDeclined(): Void {
		final edits: Array<FixEdit> = RunScan.spanEdits(
			[spanned(3, 7), violation('x'), spanned(10, 12)], (v, span) -> span.from > 5 ? null : {span: span, text: '' }
		);
		Assert.equals(1, edits.length);
		Assert.equals(3, edits[0].span.from);
	}

	public function testOneFileNamesTheFileAndRefusesAMix(): Void {
		Assert.raises(() -> RunScan.oneFile([], 'probe'), Exception);
		Assert.equals('x', RunScan.oneFile([spanned(1, 2), spanned(3, 4)], 'probe'));
		Assert.raises(() -> RunScan.oneFile([spanned(1, 2), violation('y')], 'probe'), Exception);
	}

	public function testTypeInfoOfATypedPlugin(): Void {
		Assert.notNull(RunScan.typeInfoOf(_plugin));
	}

	private static function violation(file: String): Violation {
		return {
			file: file,
			span: null,
			rule: 'probe',
			severity: Severity.Info,
			message: 'probe'
		};
	}

	private static function spanned(from: Int, to: Int): Violation {
		return {
			file: 'x',
			span: new Span(from, to),
			rule: 'probe',
			severity: Severity.Info,
			message: 'probe'
		};
	}

}
