package unit;

import anyparse.check.Check;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import sys.io.File;
#end

/** One edit the table-driven fake produces: the source text it replaces and the replacement. */
private typedef FakeEdit = {
	var find: String;
	var text: String;
}

/**
 * End-to-end coverage of the bisect probe that the WRITER refuses — the one arm of
 * `FixVerifier.verifyEntry` a fake probe cannot reach, because it needs a real
 * `canonicalize` refusal on a subset of a set that canonicalises whole.
 *
 * The fixture manufactures exactly that with `BodySlotGuard`: one edit deletes the BODY
 * of a brace-less `if`, another deletes the `if (flag) ` lead. Together the statement is
 * gone and nothing is left reaching; the body deletion ALONE would leave `if (flag)` to
 * swallow the next statement, which `RefactorSupport.canonicalize` refuses. So a probe
 * over a subset holding the body deletion without its partner produces no candidate at
 * all — asserted directly in `testTheFixtureReallyReachesTheRefusingArm`, so the two
 * behavioural pins below cannot pass vacuously if that guard ever stops firing.
 *
 * Each table also carries at least one POISON (`NoSuchType.…`), which is what makes
 * the full set compiler-rejected and sends `verifyEntry` into the bisect at all. Every scenario drives
 * the real compiler through a tiny on-disk fixture and skips gracefully with no `haxe` on
 * PATH.
 */
@:nullSafety(Strict)
final class FixVerifierProbeRefusalE2ETest extends Test {

	#if (sys || nodejs)
	/**
	 * A brace-less `if` whose body can be deleted independently of its lead, plus two
	 * unrelated literals — one benign edit target, one poison.
	 */
	private static final MAIN: String = 'class Main {\n\n\tstatic function main() {\n\t\tfinal flag:Bool = true;\n'
		+ '\t\tfinal a:String = "aaa";\n\t\tif (flag) trace("in");\n\t\ttrace(a);\n\t\ttrace("ccc");\n\t}\n\n}\n';

	/**
	 * Order is the BISECT's, not the source's. `unitsOf` numbers units in ARRAY order and
	 * the search splits at the midpoint, so [lead, benign | slot, poison] puts the two
	 * halves of the interdependent deletion on opposite sides of the first split: the left
	 * probe holds both halves of nothing and passes, the right probe holds the body
	 * deletion WITHOUT its lead and is refused by the writer.
	 */
	private static final TABLE: Array<FakeEdit> = [
		{ find: 'if (flag) ', text: '' },
		{ find: '"aaa"', text: '"AAA"' },
		{ find: 'trace("in");', text: '' },
		{ find: '"ccc"', text: 'NoSuchType.value' }
	];

	/**
	 * No unit survivable, and the WHOLE set still canonicalises — the lead deletion is in
	 * it, so the `if` is removed rather than left reaching. Order puts the body deletion in
	 * the FIRST half without its lead, so the opening probe is refused; both halves then
	 * fail, the search fans out and exhausts the budget, and nothing lands.
	 *
	 * The lead deletion must NOT be droppable on its own or the bisect would salvage it,
	 * which is why it sits in the second half beside a poison the compiler rejects.
	 */
	private static final ALL_DOOMED: Array<FakeEdit> = [
		{ find: '"aaa"', text: 'NoSuchType.one' },
		{ find: 'trace("in");', text: '' },
		{ find: 'if (flag) ', text: '' },
		{ find: '"ccc"', text: 'NoSuchType.two' }
	];

	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	/**
	 * The fixture's discriminator, asserted on its own so neither pin below can go
	 * vacuous: the body deletion alone must be REFUSED by `canonicalize`, and the pair
	 * must be accepted. Without the refusal the bisect would simply confirm that subset
	 * and this file would test nothing the group E2E does not already cover.
	 */
	public function testTheFixtureReallyReachesTheRefusingArm(): Void {
		#if (sys || nodejs)
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final slot: Int = MAIN.indexOf('trace("in");');
		final lead: Int = MAIN.indexOf('if (flag) ');
		final slotOnly: Array<{ span: Span, text: String }> = [{ span: new Span(slot, slot + 'trace("in");'.length), text: '' }];
		final both: Array<{ span: Span, text: String }> = slotOnly.concat([{ span: new Span(lead, lead + 'if (flag) '.length), text: '' }]);
		Assert.isTrue(
			RefactorSupport.canonicalize(MAIN, slotOnly, false, plugin, null).match(Err(_)),
			'deleting the body of a brace-less `if` alone must be refused — that refusal IS the arm under test'
		);
		Assert.isTrue(
			RefactorSupport.canonicalize(MAIN, both, false, plugin, null).match(Ok(_, _)),
			'deleting the lead WITH the body is accepted, so the full set reaches the compiler'
		);
		Assert.isTrue(
			RefactorSupport.isWriterCanonical(MAIN, plugin, null), 'the fixture must be the writer fixed point, else nothing is spliced'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A refusing probe must not throw away the salvageable complement.
	 *
	 * RED at the base commit, which abandoned the whole bisect on the first refusal and
	 * reverted the file: 0 of 4 edits applied, one `reverted` row, disk byte-identical to
	 * the input. The complement the search does reach is confirm-typechecked before it is
	 * written — that gate is what makes continuing safe, and it is why a mis-attributed
	 * unit can only ever cost that unit.
	 *
	 * The asserted signature is discriminating, not merely "a bisect happened": the two
	 * SURVIVING edits are the lead deletion and the benign rewrite, and the two REVERTED
	 * ones are the body deletion and the poison. A run in which the writer had NOT refused
	 * the body deletion would confirm that subset instead and apply three edits, deleting
	 * `trace("in")` — so `trace("in")` surviving while `if (flag)` is gone is reachable
	 * only through the refusal.
	 */
	public function testARefusingProbeKeepsTheConfirmedComplement(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixverifrefusal', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'check.hxml', source: HXML }
		]);
		final files: Array<{ file: String, source: String }> = [{ file: '$dir/Main.hx', source: MAIN }];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new TableFake(TABLE)],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		final after: String = File.getContent('$dir/Main.hx');
		Assert.equals(2, result.appliedEdits, 'the complement the search reached is applied, not discarded');
		Assert.equals(0, result.reverted.length, 'the file is not fully reverted');
		Assert.equals(1, result.partials.length);
		Assert.equals(2, result.partials[0].appliedEdits);
		Assert.equals(2, result.partials[0].revertedEdits, 'the body deletion goes back WITH the poison');
		Assert.equals(-1, after.indexOf('NoSuchType'), 'the poison reverts');
		Assert.notEquals(-1, after.indexOf('"AAA"'), 'the benign rewrite lands');
		Assert.equals(-1, after.indexOf('if (flag)'), 'the lead deletion lands');
		Assert.notEquals(-1, after.indexOf('trace("in")'), 'its refused partner does NOT — the signature only the refusal produces');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `oracleInvocations` is a count of compiler SPAWNS, so a probe the writer refused —
	 * which never reached a compiler — must not appear in it.
	 *
	 * RED at the base commit, where the field carried the BUDGET counter instead: every
	 * probe attempt cost one, refused or not, and `Cli.bisectTail` prints the total as
	 * "$n oracle run(s)".
	 *
	 * Measured against `CompilerOracle.invocations` rather than against a hand-derived
	 * number, so the assertion cannot drift with the fixture: `verify` spawns exactly one
	 * typecheck of its own (the baseline) on top of whatever the single bisected file
	 * costs, and there is one file and one rule here.
	 */
	public function testOracleInvocationsCountsSpawnsNotProbeAttempts(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixverifrefusal', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'check.hxml', source: HXML }
		]);
		final files: Array<{ file: String, source: String }> = [{ file: '$dir/Main.hx', source: MAIN }];
		final before: Int = CompilerOracle.invocations;
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new TableFake(TABLE)],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		final spawns: Int = CompilerOracle.invocations - before;
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		Assert.equals(1, result.partials.length);
		Assert.equals(
			spawns - 1, result.partials[0].oracleInvocations,
			'every spawn but the baseline belongs to the one bisected file (spawned $spawns, reported ${result.partials[0].oracleInvocations})'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * CONTROL — green at the base commit BY CONSTRUCTION, and it must stay green.
	 *
	 * The base commit's whole point was that a refusal is not a compiler rejection, and it
	 * bought that by abandoning the search. Continuing the search must not take the
	 * diagnostic back: when NOTHING lands and a probe was refused along the way, the
	 * reverted row still names the WRITER (`NotCanonical`), never `OracleRejected` — a
	 * reader chasing that cause would otherwise go looking in the check's edit for a type
	 * error that is not there.
	 *
	 * Every unit is doomed here (the refused body deletion plus two independent poisons),
	 * so the search blames them all and the file reverts whole — the shape where the cause
	 * is the only thing the reader gets.
	 */
	public function testARefusalStillNamesTheWriterWhenNothingLands(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixverifrefusal', [
			{ name: 'Main.hx', source: MAIN },
			{ name: 'check.hxml', source: HXML }
		]);
		final files: Array<{ file: String, source: String }> = [{ file: '$dir/Main.hx', source: MAIN }];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new TableFake(ALL_DOOMED)],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		Assert.equals(0, result.appliedEdits, 'nothing survives when every unit is doomed');
		// The BISECT was entered and produced this verdict. Without this the fixture could
		// pass through the full-set canonical gate instead — which also answers
		// `NotCanonical`, from a site the search never reaches — and the cause assertion
		// below would prove nothing about the search. Measured: the first version of this
		// fixture did exactly that, and a mutation that flattened the cause flipped nothing.
		Assert.equals(1, result.partials.length, 'the full set reached the compiler and was bisected');
		Assert.equals(1, result.reverted.length);
		Assert.equals(
			'NotCanonical', result.reverted[0].cause.getName(),
			'a refused probe is the writer declining a candidate, not the compiler rejecting one'
		);
		Assert.equals(MAIN, File.getContent('$dir/Main.hx'), 'disk is byte-identical to the input');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('fixverifrefusal', [
			{ name: 'Main.hx', source: 'class Main {\n\n\tstatic function main() {}\n\n}\n' },
			{ name: 'check.hxml', source: HXML }
		]);
		final ok: Bool = switch CompilerOracle.typecheck('check.hxml', dir) {
			case Confirmed: true;
			case _: false;
		};
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

}

/**
 * A `Check` + `RiskyFix` stand-in that turns a fixed find/replace TABLE into UNGROUPED
 * edits, so a scenario can hand `FixVerifier` any dependency shape without inventing a
 * real rule. Each `find` is unique in the fixture and located from the start, so the
 * table's order is free — which is what lets a scenario choose where the bisect's
 * midpoint falls. A `find` the fixture no longer contains is a broken fixture, not a
 * finding: it throws rather than silently producing fewer edits.
 */
@:nullSafety(Strict)
private class TableFake implements Check implements RiskyFix {

	private static inline final RULE_ID: String = 'table-fake';

	private final _table: Array<FakeEdit>;

	public function new(table: Array<FakeEdit>) {
		_table = table;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'test double: rewrites a fixed literal table';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files)
				{
					file: entry.file,
					span: null,
					rule: RULE_ID,
					severity: Severity.Warning,
					message: 'test double finding'
				}
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [
			for (entry in _table) {
				final at: Int = source.indexOf(entry.find);
				if (at < 0) throw new Exception('the fixture no longer contains ${entry.find}');
				{ span: new Span(at, at + entry.find.length), text: entry.text };
			}
		];
	}

}
