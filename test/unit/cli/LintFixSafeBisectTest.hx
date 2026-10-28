package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.check.oracle.CompilerOracle;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExitCode;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.cli.command.LintFixDriver;
import anyparse.runtime.Span;

using Lambda;

/** What one `lint --fix` run answered: its exit code and everything it wrote to stderr. */
typedef FixRun = {
	final code: Int;
	final err: String;
};

/**
 * A safe fix that breaks a module the run never wrote costs that fix, not the run's other safe fixes.
 *
 * The net attributes a failure by the files the compiler blames; when the blamed file is the CALLER of an edited
 * declaration there is nothing to attribute to, and the whole safe pass used to go back — every import fix of an
 * unrelated file with it, on every run, since the next run re-applied the same edit. Here a test-only rule drops a
 * field another module reads, beside three import rules fixing three other files and the culprit file itself.
 */
@:nullSafety(Strict)
class LintFixSafeBisectTest extends Test {

	#if (sys || nodejs)
	private static final HOLDER: String = 'package p;\n\nimport r.Spare;\n\nclass Holder {\n\n'
		+ '\tpublic static var drop:Int = 1;\n\n\tpublic static function value():Int {\n\t\treturn 2;\n\t}\n\n}\n';
	private static final READER: String =
		'package p;\n\nclass Reader {\n\n\tpublic static function read():Int {\n\t\treturn Holder.drop + Holder.value();\n\t}\n\n}\n';
	private static final TWICE: String = 'package q;\n\nimport p.Reader;\nimport p.Reader;\n\nclass Twice {\n\n'
		+ '\tpublic static function run():Int {\n\t\treturn Reader.read();\n\t}\n\n}\n';
	private static final UNUSED: String = 'package q;\n\nimport r.Spare;\nimport p.Reader;\n\nclass Unused {\n\n'
		+ '\tpublic static function run():Int {\n\t\treturn Reader.read();\n\t}\n\n}\n';
	private static final MAIN: String = 'import q.Twice;\nimport q.Unused;\n\nclass Main {\n\n\tprivate static function main():Void {\n'
		+ '\t\ttrace(Twice.run() + Unused.run());\n\t}\n\n}\n';
	private static final SPARE: String = 'package r;\n\nclass Spare {}\n';
	private static final HXML: String = '-cp .\n-main Main\n';

	/** The poison of the first fixture: the field `Reader` reads. */
	private static final DROP: String = '\tpublic static var drop:Int = 1;\n\n';
	private static final HOLDER_AB: String = 'package p;\n\nclass Holder {\n\n\tpublic static var a:Int = 1;\n\n'
		+ '\tpublic static var b:Int = 2;\n\n\tpublic static function value():Int {\n\t\treturn a + b;\n\t}\n\n}\n';
	private static final READER_VALUE: String =
		'package p;\n\nclass Reader {\n\n\tpublic static function read():Int {\n\t\treturn Holder.value();\n\t}\n\n}\n';
	private static final A1: String = '\tpublic static var a1:Int = 1;\n\n';
	private static final A2: String = '\tpublic static var a2:Int = 2;\n\n';
	private static final LATE: String = '\tpublic static var late:Int = 3;\n\n';
	private static final HOLDER_CHAIN: String =
		'package p;\n\nclass Holder {\n\n$A1$A2$LATE\tpublic static function value():Int {\n\t\treturn 2;\n\t}\n\n}\n';
	private static final READER_A2: String =
		'package p;\n\nclass Reader {\n\n\tpublic static function read():Int {\n\t\treturn Holder.a2 + Holder.value();\n\t}\n\n}\n';
	#end

	/**
	 * The three innocent files take their import fixes, the culprit file keeps its own import fix and loses only the
	 * dropped field, the tree typechecks — and the notice says, unasked, whom the compiler blamed and what it said.
	 */
	@:pin('control')
	@:killer('M-SAFE-BISECT-OFF', 'M-SAFE-SPLIT-OFF', 'M-SAFE-BLAME-UNSAID')
	public function testTheImportFixesLandAndOnlyThePoisoningEditGoesBack(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_safe_bisect', tree(HOLDER, READER));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			if (!CompilerOracle.typecheck('check.hxml', root).match(Confirmed)) {
				out = 'skipped';
				return;
			}
			final run: FixRun = fix(root, [], [new DropText('drop-shared', [DROP])]);
			final holder: String = File.getContent('$root/p/Holder.hx');
			Assert.isTrue(holder.indexOf('drop') >= 0, 'the poisoning edit is reverted: ${run.err}');
			Assert.equals(-1, holder.indexOf('Spare'), 'the culprit file keeps its own import fix: ${run.err}');
			Assert.equals(-1, File.getContent('$root/q/Twice.hx').indexOf('import p.Reader;\nimport p.Reader;'), run.err);
			Assert.equals(-1, File.getContent('$root/q/Unused.hx').indexOf('Spare'), run.err);
			Assert.isTrue(CompilerOracle.typecheck('check.hxml', root).match(Confirmed), 'the tree the run leaves typechecks: ${run.err}');
			Assert.stringContains(
				'safe-fix REVERTED the edits drop-shared made in $root/p/Holder.hx, KEPT the first-pass edits of unused-import', run.err
			);
			Assert.stringContains('the compiler blames: ', run.err);
			Assert.stringContains('Reader.hx', run.err);
			Assert.stringContains('has no field drop', run.err);
			Assert.equals(ExitCode.EXIT_RUNTIME, run.code, 'a revert is still a fixer defect: ${run.err}');
			out = 'ran';
		});
		if (out == 'skipped') Assert.pass('haxe unavailable — skipped');
		#else
		Assert.pass();
		#end
	}

	/**
	 * The edit the net took back is not applied again later in the same run. A risky rule rewrites the culprit file, so
	 * the follow-up round re-converges it; without the ban the dropped field is dropped again and the follow-up's own net
	 * has to revert it a second time.
	 */
	@:pin('control')
	@:killer('M-SAFE-BAN-OFF')
	public function testARevertedEditIsNotReappliedByTheFollowUpRound(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_safe_bisect_ban', tree(HOLDER, READER));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			if (!CompilerOracle.typecheck('check.hxml', root).match(Confirmed)) {
				out = 'skipped';
				return;
			}
			final run: FixRun = fix(root, ['prefer-inline'], [new DropText('drop-shared', [DROP])]);
			final holder: String = File.getContent('$root/p/Holder.hx');
			Assert.stringContains('inline function value', holder, 'the risky rule rewrote the culprit file: ${run.err}');
			Assert.isTrue(holder.indexOf('drop') >= 0, run.err);
			Assert.equals(1, run.err.split('the safe fixes broke a build that was green').length - 1, 'one revert, not two: ${run.err}');
			out = 'ran';
		});
		if (out == 'skipped') Assert.pass('haxe unavailable — skipped');
		#else
		Assert.pass();
		#end
	}

	/**
	 * A culprit file no subset of whose rules typechecks goes back whole — on disk as well as in the run. Its two rules each
	 * delete one field `value` reads, so every split probe is rejected; the file must end at its pre-fix bytes and the tree
	 * must typecheck, not hold the last rejected probe while the run reports it reverted.
	 */
	@:pin('control')
	@:killer('M-SAFE-PLACE-SKIPPED')
	public function testARejectedSplitLeavesTheTreeTheOracleConfirmedOnDisk(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_safe_bisect_place', tree(HOLDER_AB, READER_VALUE, true));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			if (!CompilerOracle.typecheck('check.hxml', root).match(Confirmed)) {
				out = 'skipped';
				return;
			}
			final run: FixRun = fix(root, [], [
				new DropText('drop-a', ['\tpublic static var a:Int = 1;\n\n']),
				new DropText('drop-b', ['\tpublic static var b:Int = 2;\n\n'])
			], true);
			Assert.equals(
				HOLDER_AB, File.getContent('$root/src/p/Holder.hx'), 'the culprit is back at its pre-fix bytes ON DISK: ${run.err}'
			);
			Assert.isTrue(CompilerOracle.typecheck('check.hxml', root).match(Confirmed), 'the tree the run leaves typechecks: ${run.err}');
			Assert.equals(-1, File.getContent('$root/src/q/Twice.hx').indexOf('import p.Reader;\nimport p.Reader;'), run.err);
			out = 'ran';
		});
		if (out == 'skipped') Assert.pass('haxe unavailable — skipped');
		#else
		Assert.pass();
		#end
	}

	/**
	 * Keeping a culprit's first pass discards every LATER pass, so every rule of those passes is reverted, named and banned —
	 * one that also landed in the first pass included. `drop-chain` deletes a harmless field in pass 1 and the field `Reader`
	 * reads in pass 2; naming only `drop-late` left `drop-chain` free, and the follow-up round (a risky rule rewrites the
	 * file) deleted the field again for a second revert.
	 */
	@:pin('control')
	@:killer('M-SAFE-LATER-UNBANNED')
	public function testEveryRuleOfADiscardedLaterPassIsNamedAndBanned(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_safe_bisect_later', tree(HOLDER_CHAIN, READER_A2));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			if (!CompilerOracle.typecheck('check.hxml', root).match(Confirmed)) {
				out = 'skipped';
				return;
			}
			final run: FixRun = fix(root, ['prefer-inline'], [new DropText('drop-chain', [A1, A2]), new DropText('drop-late', [LATE], A1)]);
			final holder: String = File.getContent('$root/p/Holder.hx');
			Assert.stringContains('a2', holder, 'the field another module reads stays: ${run.err}');
			Assert.stringContains(
				'drop-chain', run.err.split('\n').filter(line -> line.indexOf('safe-fix REVERTED') >= 0).join('\n'), run.err
			);
			Assert.equals(1, run.err.split('the safe fixes broke a build that was green').length - 1, 'one revert, not two: ${run.err}');
			Assert.isTrue(CompilerOracle.typecheck('check.hxml', root).match(Confirmed), 'the tree the run leaves typechecks: ${run.err}');
			out = 'ran';
		});
		if (out == 'skipped') Assert.pass('haxe unavailable — skipped');
		#else
		Assert.pass();
		#end
	}

	#if (sys || nodejs)
	/**
	 * The fixture tree, with `holder` and `reader` as the two modules of package `p` — under `src/`, compiled by `-cp src`,
	 * when `src` is set, so the compiler spells its positions `src/p/Holder.hx` rather than `./p/Holder.hx`.
	 */
	private static function tree(holder: String, reader: String, src: Bool = false): Array<{ name: String, source: String }> {
		final at: String = src ? 'src/' : '';
		return [
			{ name: '${at}p/Holder.hx', source: holder },
			{ name: '${at}p/Reader.hx', source: reader },
			{ name: '${at}q/Twice.hx', source: TWICE },
			{ name: '${at}q/Unused.hx', source: UNUSED },
			{ name: '${at}Main.hx', source: MAIN },
			{ name: '${at}r/Spare.hx', source: SPARE },
			{ name: 'check.hxml', source: src ? '-cp src\n-main Main\n' : HXML }
		];
	}

	/** One `lint --fix` over every module of the fixture, with the oracle, the import rules, the `drops` and `extra`. */
	private static function fix(root: String, extra: Array<String>, drops: Array<Check>, src: Bool = false): FixRun {
		final ids: Array<String> = ['duplicate-import', 'unused-import', 'import-order'].concat(extra);
		final checks: Array<Check> = [for (check in Linter.builtins()) if (ids.contains(check.id())) check].concat(drops);
		final files: Array<{ file: String, source: String }> = [
			for (name in [
				'p/Holder.hx',
				'p/Reader.hx',
				'q/Twice.hx',
				'q/Unused.hx',
				'Main.hx',
				'r/Spare.hx'
			])
				{ file: '$root/${src ? 'src/' : ''}$name', source: File.getContent('$root/${src ? 'src/' : ''}$name') }
		];
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() ->
			code = LintFixDriver.runLintFix(
				files, checks, new HaxeQueryPlugin(), _ -> LintConfig.parse('{}'), false, null,
				[{ hxml: 'check.hxml', dir: root, defines: [] }], false, null, false
			)
		);
		return { code: code, err: err };
	}
	#end

}

/**
 * Deletes the first of `texts` a module still holds, one per pass — so a rule given two texts edits a file in two passes —
 * and, given `unless`, only once that text is gone: a safe fix that breaks every module reading what it deletes.
 */
private class DropText implements Check {

	private final _id: String;
	private final _texts: Array<String>;
	private final _unless: Null<String>;

	public function new(id: String, texts: Array<String>, ?unless: String) {
		_id = id;
		_texts = texts;
		_unless = unless;
	}

	public function id(): String {
		return _id;
	}

	public function description(): String {
		return 'deletes a declaration other code reads';
	}

	public function category(): RuleCategory {
		return RuleCategory.Design;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final found: Array<Violation> = [];
		for (entry in files) {
			final unless: Null<String> = _unless;
			if (unless != null && entry.source.indexOf(unless) >= 0) continue;
			final text: Null<String> = _texts.find(t -> entry.source.indexOf(t) >= 0);
			if (text == null) continue;
			final at: Int = entry.source.indexOf(text);
			found.push({
				file: entry.file,
				span: new Span(at, at + text.length),
				rule: id(),
				severity: Severity.Warning,
				message: 'a declaration'
			});
		}
		return found;
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [for (v in violations) { span: v.span, text: '' }];
	}

}
