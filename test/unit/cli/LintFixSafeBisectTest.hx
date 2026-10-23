package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check;
import anyparse.check.CompilerOracle;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.check.RuleCategory;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExitCode;
import anyparse.query.GrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.query.cli.command.LintFixDriver;
import anyparse.runtime.Span;

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
	#end

	/**
	 * The three innocent files take their import fixes, the culprit file keeps its own import fix and loses only the
	 * dropped field, the tree typechecks — and the notice says, unasked, whom the compiler blamed and what it said.
	 */
	@:pin('control')
	@:killer('M-SAFE-BISECT-OFF', 'M-SAFE-SPLIT-OFF', 'M-SAFE-BLAME-UNSAID')
	public function testTheImportFixesLandAndOnlyThePoisoningEditGoesBack(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_safe_bisect', tree());
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			if (!CompilerOracle.typecheck('check.hxml', root).match(Confirmed)) {
				out = 'skipped';
				return;
			}
			final run: FixRun = fix(root, []);
			final holder: String = File.getContent('$root/p/Holder.hx');
			Assert.isTrue(holder.indexOf('drop') >= 0, 'the poisoning edit is reverted: ${run.err}');
			Assert.equals(-1, holder.indexOf('Spare'), 'the culprit file keeps its own import fix: ${run.err}');
			Assert.equals(-1, File.getContent('$root/q/Twice.hx').indexOf('import p.Reader;\nimport p.Reader;'), run.err);
			Assert.equals(-1, File.getContent('$root/q/Unused.hx').indexOf('Spare'), run.err);
			Assert.isTrue(CompilerOracle.typecheck('check.hxml', root).match(Confirmed), 'the tree the run leaves typechecks: ${run.err}');
			Assert.stringContains('safe-fix REVERTED the drop-shared edit(s) of $root/p/Holder.hx, KEPT its other edits', run.err);
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
		final root: String = CliFixture.writeTree('apq_safe_bisect_ban', tree());
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			if (!CompilerOracle.typecheck('check.hxml', root).match(Confirmed)) {
				out = 'skipped';
				return;
			}
			final run: FixRun = fix(root, ['prefer-inline']);
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

	#if (sys || nodejs)
	/** The fixture tree. */
	private static function tree(): Array<{ name: String, source: String }> {
		return [
			{ name: 'p/Holder.hx', source: HOLDER },
			{ name: 'p/Reader.hx', source: READER },
			{ name: 'q/Twice.hx', source: TWICE },
			{ name: 'q/Unused.hx', source: UNUSED },
			{ name: 'Main.hx', source: MAIN },
			{ name: 'r/Spare.hx', source: SPARE },
			{ name: 'check.hxml', source: HXML }
		];
	}

	/** One `lint --fix` over every module of the fixture, with the oracle, the import rules, the poison and `extra`. */
	private static function fix(root: String, extra: Array<String>): FixRun {
		final ids: Array<String> = ['duplicate-import', 'unused-import', 'import-order'].concat(extra);
		final checks: Array<Check> = [for (check in Linter.builtins()) if (ids.contains(check.id())) check];
		checks.push(new DropShared());
		final files: Array<{ file: String, source: String }> = [
			for (name in [
				'p/Holder.hx',
				'p/Reader.hx',
				'q/Twice.hx',
				'q/Unused.hx',
				'Main.hx',
				'r/Spare.hx'
			])
				{ file: '$root/$name', source: File.getContent('$root/$name') }
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

/** Deletes every `public static var drop` declaration — a safe fix that breaks every module reading the field. */
private class DropShared implements Check {

	private static inline final DECLARATION: String = '\tpublic static var drop:Int = 1;\n\n';

	public function new() {}

	public function id(): String {
		return 'drop-shared';
	}

	public function description(): String {
		return 'drops a shared field other modules read';
	}

	public function category(): RuleCategory {
		return RuleCategory.Design;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return [
			for (entry in files) if (entry.source.indexOf(DECLARATION) >= 0) {
				file: entry.file,
				span: new Span(entry.source.indexOf(DECLARATION), entry.source.indexOf(DECLARATION) + DECLARATION.length),
				rule: id(),
				severity: Severity.Warning,
				message: 'a shared field'
			}
		];
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [for (v in violations) { span: v.span, text: '' }];
	}

}
