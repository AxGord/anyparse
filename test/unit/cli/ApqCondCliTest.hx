package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * `apq cond <DEFINE> <scope>` — the branch BODIES of every `#if` region that mentions a define.
 *
 * What the command replaces is a two-step route with a GUESS in it: `lit --include-directives`
 * reaches a directive's text — the only thing about a region no node carries — but answers with a
 * `line:col` and nothing more, so the region's extent stays unknown and every site costs one
 * `source --range` over a window whose end is estimated. Measured on this tree for the define
 * `nodejs` over `src/anyparse/query`: 87 regions, 88 commands, 57 497 bytes of stdout, and 25 of
 * the 87 estimated windows never reached their own `#end`. `apq cond nodejs src/anyparse/query`
 * is one command and 40 750 bytes.
 *
 * The expectations below are the RENDERING — indentation, tag list, and the order branches come
 * out in. The mechanism they sit on (a branch is delimited by its directives, not by a node) is
 * pinned at the API in `unit.query.CondQueryTest`, whose tiling invariant is what proves the
 * bodies are exact; these fixtures state what a reader sees.
 */
@:nullSafety(Strict)
class ApqCondCliTest extends Test {

	/** A three-branch region with a second `#if nodejs` nested inside its first branch. */
	private static final SRC_NEST: String = 'class C {\n\tfunction f():Void {\n\t\t#if nodejs\n\t\ta();\n\t\t#if nodejs\n'
		+ '\t\tinner();\n\t\t#end\n\t\t#elseif other\n\t\tc();\n\t\t#else\n\t\td();\n\t\t#end\n\t}\n}';

	/** Exactly what `apq cond nodejs <SRC_NEST>` prints under the file's group header. */
	private static final NEST_REPORT: Array<String> = [
		'  3:3: #if nodejs [live]',
		'      a();',
		'      #if nodejs',
		'      inner();',
		'      #end',
		'  8:3: #elseif other [dead]',
		'      c();',
		'  10:3: #else [dead]',
		'      d();',
		'  5:3: #if nodejs [live, nested]',
		'      inner();'
	];

	/** An expression-position region: the grammar parses it and projects one CHILDLESS node. */
	private static final SRC_RAW: String = 'class C {\n\tfunction f():Int {\n\t\treturn #if nodejs 1; #else 2; #end\n\t}\n}';

	/** A region whose first branch turns on a flag the query says nothing about. */
	private static final SRC_MAYBE: String =
		'class C {\n\tfunction f():Void {\n\t\t#if other\n\t\ta();\n\t\t#elseif nodejs\n\t\tb();\n\t\t#else\n\t\tc();\n\t\t#end\n\t}\n}';

	/**
	 * The report is the file's group header followed by one head line per branch — position,
	 * verbatim directive, tags — with the branch's own source indented under it.
	 *
	 * Region by region, and regions in order of their `#if`: the nested region's entry therefore
	 * follows its parent's later branches, because a region is the unit a reader has to see whole.
	 */
	public function testTheReportIsTheBranchBodiesUnderTheirDirectives(): Void {
		#if nodejs
		final f: String = CliFixture.write('cond_nest', SRC_NEST);
		var exit: Int = -1;
		final printed: Array<String> = lines(CliFixture.captureStdout(() -> exit = Cli.run(['cond', 'nodejs', f])));
		Assert.equals(0, exit);
		Assert.equals('$f:', printed[0]);
		Assert.same(NEST_REPORT, printed.slice(1));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--flat` prefixes each head line with the file instead of printing a group header. Bodies are
	 * unchanged: they are the payload, not a hit line.
	 */
	public function testFlatPrefixesEachHeadLineWithTheFile(): Void {
		#if nodejs
		final f: String = CliFixture.write('cond_flat', SRC_NEST);
		final printed: Array<String> = lines(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f, '--flat'])));
		Assert.same([
			for (line in NEST_REPORT) line.charAt(0) == ' ' && line.charAt(2) != ' ' ? '$f:${line.substr(2)}' : line
		], printed);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * An expression-position `#if` is printed VERBATIM and marked `raw span`, under `--names` as
	 * much as by default — the user-reported requirement this command must not miss: 2 of the 10
	 * sites in the session that asked for it were this shape, and going silent on them is the one
	 * failure mode worse than not having the command.
	 */
	public function testARawSpliceIsPrintedVerbatimAndMarkedUnderNamesToo(): Void {
		#if nodejs
		final f: String = CliFixture.write('cond_raw', SRC_RAW);
		final plain: Array<String> = lines(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f])));
		Assert.same([
			'$f:',
			'  3:10: #if nodejs [live, raw span]',
			'      1;',
			'  3:24: #else [dead, raw span]',
			'      2;'
		], plain);
		final named: Array<String> = lines(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f, '--names'])));
		Assert.same(plain, named, '--names must keep the bytes of a branch it has no names for');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--names` replaces a modelled branch's source with the distinct `<Kind> <name>` rows inside it. */
	public function testNamesReplaceAModelledBranchWithItsNameRows(): Void {
		#if nodejs
		final f: String = CliFixture.write(
			'cond_names', 'class C {\n\tfunction f():Void {\n\t\t#if nodejs\n\t\tendpoint();\n\t\t#else\n\t\tother();\n\t\t#end\n\t}\n}'
		);
		Assert.same([
			'$f:',
			'  3:3: #if nodejs [live]',
			'      IdentExpr endpoint',
			'  5:3: #else [dead]',
			'      IdentExpr other'
		], lines(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f, '--names']))));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--active` keeps every branch that can run with the define set, `--inactive` exactly the ones
	 * that cannot, and together they partition the region — an `#elseif` on the define is `maybe`
	 * here rather than live, because the branch before it turns on a flag nothing proved false.
	 */
	public function testActiveAndInactivePartitionTheBranches(): Void {
		#if nodejs
		final f: String = CliFixture.write('cond_partition', SRC_MAYBE);
		final all: Array<String> = heads(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f, '--flat'])), f);
		final active: Array<String> = heads(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f, '--flat', '--active'])), f);
		final inactive: Array<String> = heads(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f, '--flat', '--inactive'])), f);
		Assert.same(['#if other [maybe]', '#elseif nodejs [maybe]', '#else [dead]'], all);
		Assert.same(['#if other [maybe]', '#elseif nodejs [maybe]'], active);
		Assert.same(['#else [dead]'], inactive);
		Assert.equals(all.length, active.length + inactive.length, 'the two filters must partition the branches');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--max-body` bounds a branch and NAMES what it dropped. `--limit` cannot do this job: it
	 * counts branches, and the define this command is most often asked about is the one a file uses
	 * as its top-level guard, where one branch is the whole file.
	 */
	public function testMaxBodyFoldsTheTailAndNamesWhatItDropped(): Void {
		#if nodejs
		final f: String = CliFixture.write(
			'cond_maxbody', 'class C {\n\tfunction f():Void {\n\t\t#if nodejs\n\t\ta();\n\t\tb();\n\t\tc();\n\t\td();\n\t\t#end\n\t}\n}'
		);
		Assert.same([
			'$f:',
			'  3:3: #if nodejs [live]',
			'      a();',
			'      b();',
			'      … +2 more line(s) — raise with --max-body N, 0 for no cap'
		], lines(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f, '--max-body', '2']))));
		Assert.equals(
			6, lines(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f, '--max-body', '0']))).length,
			'--max-body 0 prints every line'
		);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A region matches on the define its condition MENTIONS, which is the difference from the route
	 * this replaces: `#if (sys || nodejs)` is a site of both flags and matches neither `#if sys`
	 * nor `#if nodejs` as text. The `lit` arm is the comparison, not decoration — it is how the
	 * reported session missed 75 of the 87 sites in one scope.
	 */
	public function testACompoundConditionIsFoundWhereATextSearchMissesIt(): Void {
		#if nodejs
		final f: String = CliFixture.write(
			'cond_compound', 'class C {\n\tfunction f():Void {\n\t\t#if (sys || nodejs)\n\t\ta();\n\t\t#end\n\t}\n}'
		);
		Assert.same([
			'$f:',
			'  3:3: #if (sys || nodejs) [live]',
			'      a();'
		], lines(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f]))));
		var text: Int = -1;
		CliFixture.captureStderr(() -> text = Cli.run(['lit', '#if nodejs', f, '--include-directives', '--exact', '--exit-on-empty']));
		Assert.equals(1, text, 'the text route does not see this site at all');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The scan is lexical, so a file the grammar cannot parse is WALKED rather than skipped: the
	 * bodies are still exact and come back tagged `no parse`, since there is no tree to model their
	 * interior. Skipping it would throw away the answer the command can still give.
	 *
	 * `no parse` and not `raw span`: the two say different things about WHY a body is unmodelled,
	 * and in a MULTI-file walk nothing else distinguishes them — `CliWalk.parseWalked` reports a
	 * parse failure only for a single file, so a whole unparseable file would otherwise read as a
	 * pile of expression splices.
	 */
	public function testAnUnparseableFileStillReportsItsBranches(): Void {
		#if nodejs
		final f: String = CliFixture.write('cond_broken', 'class C {\n\t#if nodejs\n\tvar x:Int = 0\n\t#end\n');
		var printed: Array<String> = [];
		Assert.notEquals(
			'', CliFixture.captureStderr(() -> printed = lines(CliFixture.captureStdout(() -> Cli.run(['cond', 'nodejs', f])))),
			'the parse failure is still reported'
		);
		Assert.same([
			'$f:',
			'  2:2: #if nodejs [live, no parse]',
			'      var x:Int = 0'
		], printed);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A 0-hit walk exits 0 by default and non-zero under `--exit-on-empty`, like every other find-walker. */
	public function testAnEmptyWalkAnswersTheRunsExitContract(): Void {
		#if nodejs
		final f: String = CliFixture.write('cond_empty', SRC_NEST);
		final nudge: String = CliFixture.captureStderr(() -> {
			Assert.equals(0, Cli.run(['cond', 'no_such_define', f]));
			Assert.equals(1, Cli.run(['cond', 'no_such_define', f, '--exit-on-empty']));
		});
		Assert.isTrue(nudge.indexOf('0 hits') >= 0, 'a 0-hit walk says so on stderr: $nudge');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A missing argument is a usage error, and `--max-body` refuses anything that is not a line budget. */
	public function testUsageErrorsAreReported(): Void {
		#if nodejs
		final f: String = CliFixture.write('cond_usage', SRC_NEST);
		CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> {
			Assert.equals(2, Cli.run(['cond']));
			Assert.equals(2, Cli.run(['cond', 'nodejs']));
			Assert.equals(2, Cli.run(['cond', 'nodejs', f, '--max-body', 'lots']));
			Assert.equals(2, Cli.run(['cond', 'nodejs', f, '--nope']));
		}));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if nodejs
	/** The captured report as lines, with the trailing empty one dropped. */
	private static function lines(printed: String): Array<String> {
		final out: Array<String> = printed.split('\n');
		if (out.length > 0 && out[out.length - 1] == '') out.pop();
		return out;
	}

	/** Just the directive-and-tags part of each `--flat` head line, so a fixture path never enters the expectation. */
	private static function heads(printed: String, file: String): Array<String> {
		final out: Array<String> = [];
		for (line in lines(printed)) if (line.indexOf('$file:') == 0) {
			final colon: Int = line.indexOf(': ', file.length + 1);
			out.push(line.substr(colon + 2));
		}
		return out;
	}
	#end

}
