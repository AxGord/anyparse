package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifier;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;
#if (sys || nodejs)
import sys.io.File;
#end

/** One edit the table-driven fake produces: the source text it targets, its replacement, and its group. */
private typedef FakeEdit = {
	var find: String;
	var text: String;
	var group: Null<Int>;
}

/**
 * End-to-end coverage of `FixVerifier.verify`'s ATOMIC GROUPS: an edit a check declared
 * inseparable from another must never survive a bisect that dropped its partner. The
 * motivating shape is `shorten-type-ref`'s orphan import — the `import` line COMPILES on
 * its own, so a probe that keeps it and drops every use-site rewrite typechecks, the
 * complement confirm accepts it, and a file is written with an import nothing uses. Only
 * the grouping can refuse that subset; no oracle ever will.
 *
 * Both scenarios drive the real compiler through a tiny on-disk fixture, so each probes
 * availability first and skips gracefully when the host has no `haxe` on PATH.
 */
@:nullSafety(Strict)
final class FixVerifierGroupE2ETest extends Test {

	#if (sys || nodejs)
	/** Three independent literal initializers — the fixture creates no dependency of its own. */
	private static final POISON_MAIN: String = 'class Main {\n\n\tstatic function main() {\n'
		+ '\t\tfinal a:String = "aaa";\n\t\tfinal b:String = "bbb";\n\t\tfinal c:String = "ccc";\n'
		+ '\t\ttrace(a);\n\t\ttrace(b);\n\t\ttrace(c);\n\t}\n\n}\n';

	/**
	 * A benign GROUP (rewrite `"aaa"`, poison `"bbb"`) plus an independent `"ccc"`. Edit A is
	 * the orphan-import analogue: on its own it compiles, which is exactly why nothing
	 * downstream of the bisect could ever catch a probe that kept it.
	 */
	private static final POISON_TABLE: Array<FakeEdit> = [
		{ find: '"aaa"', text: '"AAA"', group: 0 },
		{ find: '"bbb"', text: 'NoSuchType.value', group: 0 },
		{ find: '"ccc"', text: '"CCC"', group: null }
	];

	/** A declaration and its one use — renaming HALF of this breaks the build, so the pair is a real group. */
	private static final DEPENDENT_MAIN: String =
		'class Main {\n\n\tstatic function main() {\n\t\tfinal alpha:String = "aaa";\n\t\ttrace(alpha);\n\t\ttrace("ccc");\n\t}\n\n}\n';

	/** The mirror shape: the GROUP is sound and must land whole, the UNGROUPED edit is the poison. */
	private static final DEPENDENT_TABLE: Array<FakeEdit> = [
		{ find: 'alpha', text: 'beta', group: 0 },
		{ find: 'alpha', text: 'beta', group: 0 },
		{ find: '"ccc"', text: 'NoSuchType.value', group: null }
	];

	/** Every edit in ONE group: the whole set is a single indivisible unit, so there is no subset to salvage. */
	private static final SINGLE_GROUP_TABLE: Array<FakeEdit> = [
		{ find: 'alpha', text: 'beta', group: 0 },
		{ find: 'alpha', text: 'NoSuchType.value', group: 0 }
	];

	private static final HXML: String = '-cp .\n-main Main\n';
	#end

	public function testAPoisonedGroupDragsItsCompilingSiblingBack(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixverifgroup', [
			{ name: 'Main.hx', source: POISON_MAIN },
			{ name: 'check.hxml', source: HXML }
		]);
		final files: Array<{ file: String, source: String }> = [{ file: '$dir/Main.hx', source: POISON_MAIN }];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new TableFake(POISON_TABLE)],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		final after: String = File.getContent('$dir/Main.hx');
		Assert.equals(-1, after.indexOf('NoSuchType'), 'the poison reverts');
		Assert.equals(-1, after.indexOf('"AAA"'), 'its compiling group-mate reverts WITH it — the acceptance criterion');
		Assert.notEquals(-1, after.indexOf('"CCC"'), 'the independent ungrouped edit survives');
		Assert.equals(1, result.partials.length);
		Assert.equals(1, result.partials[0].appliedEdits);
		Assert.equals(2, result.partials[0].revertedEdits, 'kept / reverted stay EDIT counts — one reverted UNIT held two edits');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testASoundGroupSurvivesAnUngroupedPoison(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixverifgroup', [
			{ name: 'Main.hx', source: DEPENDENT_MAIN },
			{ name: 'check.hxml', source: HXML }
		]);
		final files: Array<{ file: String, source: String }> = [{ file: '$dir/Main.hx', source: DEPENDENT_MAIN }];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new TableFake(DEPENDENT_TABLE)],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		final after: String = File.getContent('$dir/Main.hx');
		Assert.equals(-1, after.indexOf('NoSuchType'), 'the ungrouped poison reverts');
		Assert.equals(-1, after.indexOf('alpha'), 'the group landed WHOLE — a half-applied rename would not compile');
		Assert.notEquals(-1, after.indexOf('final beta'), 'the declaration half landed');
		Assert.notEquals(-1, after.indexOf('trace(beta)'), 'the use half landed');
		Assert.equals(1, result.partials.length);
		Assert.equals(2, result.partials[0].appliedEdits, 'a group is probed and kept as ONE unit');
		Assert.equals(1, result.partials[0].revertedEdits);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * One group holding EVERY edit is a single unit, and a single unit has no salvageable subset:
	 * `verifyEntry` takes the `n < 2` arm, reverts the whole file and emits NO `FixVerifyPartial`,
	 * where the per-edit bisect would have probed both halves, failed both, and still reported a
	 * `Partial(0, 2)`. That empty `partials` is the discriminator — the disk state alone is not.
	 */
	public function testAGroupSpanningEveryEditRevertsWholeWithoutABisectReport(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = CliFixture.writeDir('fixverifgroup', [
			{ name: 'Main.hx', source: DEPENDENT_MAIN },
			{ name: 'check.hxml', source: HXML }
		]);
		final files: Array<{ file: String, source: String }> = [{ file: '$dir/Main.hx', source: DEPENDENT_MAIN }];
		final result: FixVerifyResult = FixVerifier.verify(
			files,
			[new TableFake(SINGLE_GROUP_TABLE)],
			new HaxeQueryPlugin(), 'check.hxml', dir, File.saveContent
		);
		Assert.isTrue(result.baseline.match(Confirmed), 'the oracle baseline must confirm — else these negatives are vacuous');
		Assert.equals(0, result.partials.length, 'a single unit is not bisected, so no partial is reported');
		Assert.equals(1, result.reverted.length, 'the file reverts whole');
		Assert.equals(DEPENDENT_MAIN, File.getContent('$dir/Main.hx'), 'disk is byte-identical to the input');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if (sys || nodejs)
	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('fixverifgroup', [
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
 * A `Check` + `RiskyFix` + `GroupedFix` stand-in that turns a fixed find/replace TABLE into
 * grouped edits, so a scenario can hand `FixVerifier` any dependency shape without inventing a
 * real rule. Each `find` is located from where the previous one ended, so a table may target two
 * occurrences of the same text (the rename pair). A `find` the fixture no longer contains is a
 * broken fixture, not a finding — it throws rather than silently producing fewer edits.
 */
@:nullSafety(Strict)
private class TableFake implements Check implements RiskyFix implements GroupedFix {

	/** The rule id the verifier filters this fake's own findings by. */
	private static inline final RULE_ID: String = 'table-fake';

	private final _table: Array<FakeEdit>;

	public function new(table: Array<FakeEdit>) {
		_table = table;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'test double: rewrites a fixed literal table in declared groups';
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
			for (edit in fixGrouped(source, violations, plugin, index)) { span: edit.span, text: edit.text }
		];
	}

	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit> {
		final edits: Array<GroupedEdit> = [];
		var from: Int = 0;
		for (entry in _table) {
			final at: Int = source.indexOf(entry.find, from);
			if (at < 0) throw new Exception('the fixture no longer contains ${entry.find}');
			edits.push({ span: new Span(at, at + entry.find.length), text: entry.text, group: entry.group });
			from = at + entry.find.length;
		}
		return edits;
	}

}
