package unit.cli;

import anyparse.query.Cli;
import anyparse.query.cli.CliArgs;
import utest.Assert;
import utest.Test;

/**
 * Several queries in ONE walk, and the argument grammar that makes them
 * unambiguous.
 *
 * One name per process is one ROUND per name at the call site, and a round is
 * the whole context re-sent. Measured on this tree 2026-09-07: three
 * `refs <name> src --decls` calls cost 5108 bytes of output over 3 rounds; the
 * same three names batched cost 1191 bytes over 1. What a batch does NOT buy is
 * CPU — the walkers pre-filter by raw substring, so a name costs 0.23 s whether
 * it is alone or not; the saving is rounds and stderr.
 *
 * THE GRAMMAR. The second positional of every one of these commands is a SCOPE
 * spec today, and several of them are legal (`apq refs X src test`), so "the
 * last positional is the scope" would silently reinterpret an existing call. A
 * bare `--` occurs in no working invocation, so it is free: positionals before
 * it are queries, positionals after it are scope. Without it the grammar is
 * untouched, which is what `testTheSingleQueryFormIsUnchanged` pins.
 *
 * The shape the separator replaces was SILENT: `apq refs A B C src` walked `src`
 * alone, dropped `B` and `C` without a word, and exited 0. It now nudges.
 *
 * `testTheSeparatorIsWhatSplitsQueriesFromScope` is the control — every other
 * batch assertion here would also pass if `--` were merely tolerated and
 * ignored, provided the first positional happened to be the one under test.
 */
@:nullSafety(Strict)
class ApqBatchQueryCliTest extends Test {

	/** Two types and two members, so a batch of two queries has two distinct answers. */
	private static final FIXTURE: String = 'class Alpha {\n\tpublic static function alphaOne(): Int {\n\t\treturn 1;\n\t}\n}\n\n'
		+ 'class Beta {\n\tpublic static function betaTwo(): Int {\n\t\treturn 2;\n\t}\n}\n';

	public function testTheSeparatorIndexReadsABareDoubleDashOnly(): Void {
		Assert.equals(1, CliArgs.nameSeparatorIndex(['a', '--', 'src']));
		Assert.equals(-1, CliArgs.nameSeparatorIndex(['a', 'src']));
		Assert.equals(-1, CliArgs.nameSeparatorIndex(['a', '--decls', 'src']), 'a long option is not the separator');
		Assert.equals(-1, CliArgs.nameSeparatorIndex([]));
	}

	/**
	 * The index IS the side test: a positional lands in the scope list only when it
	 * sits past the separator, so the router needs no running flag of its own.
	 */
	public function testThePositionalRouterSplitsOnTheSeparatorIndex(): Void {
		final queries: Array<String> = [];
		final specs: Array<String> = [];
		for (i => arg in ['A', 'B', '--', 'src', 'test']) if (arg != '--') CliArgs.routePositional(arg, i, 2, queries, specs);
		Assert.same(['A', 'B'], queries);
		Assert.same(['src', 'test'], specs);
		final one: Array<String> = [];
		final rest: Array<String> = [];
		for (i => arg in ['A', 'src', 'test']) CliArgs.routePositional(arg, i, -1, one, rest);
		Assert.same(['A'], one, 'no separator: the FIRST positional is the query');
		Assert.same(['src', 'test'], rest, 'no separator: every later positional is a scope spec');
	}

	/**
	 * KILLED by arm `M-BATCH-SEPARATOR-BLIND`, which makes the separator
	 * predicate answer `false` — the batched form then reads `Alpha` as the one
	 * query and `Beta` as a scope spec, so the second section never prints.
	 */
	@:pin('control')
	@:killer('M-BATCH-SEPARATOR-BLIND')
	public function testTheSeparatorIsWhatSplitsQueriesFromScope(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchsep', [{ name: 'A.hx', source: FIXTURE }]);
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['declares', 'Alpha', 'Beta', '--', dir]));
		CliFixture.removeDir(dir);
		Assert.equals(0, code);
		#if nodejs
		// Both sections, in the order given, each naming its own query.
		Assert.stringContains('=== Alpha ===', out);
		Assert.stringContains('=== Beta ===', out);
		Assert.isTrue(out.indexOf('=== Alpha ===') < out.indexOf('=== Beta ==='), 'sections keep the argument order: $out');
		Assert.stringContains('Alpha\tClassDecl', out);
		Assert.stringContains('Beta\tClassDecl', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/**
	 * ONE query prints exactly what it printed before the separator existed — no
	 * banner, no reordering. The skill, the hooks and every existing fixture call
	 * that spelling, so it is the compatibility the batch is not allowed to cost.
	 */
	public function testTheSingleQueryFormIsUnchanged(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchone', [{ name: 'A.hx', source: FIXTURE }]);
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['declares', 'Alpha', dir]));
		CliFixture.removeDir(dir);
		Assert.equals(0, code);
		#if nodejs
		Assert.isFalse(out.indexOf('===') >= 0, 'one query gets no banner: $out');
		Assert.stringContains('Alpha\tClassDecl', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testRefsBatchesNamesIntoPerNameSections(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchrefs', [{ name: 'A.hx', source: FIXTURE }]);
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['refs', 'alphaOne', 'betaTwo', '--', dir, '--decls']));
		CliFixture.removeDir(dir);
		Assert.equals(0, code);
		#if nodejs
		Assert.stringContains('=== alphaOne ===', out);
		Assert.stringContains('=== betaTwo ===', out);
		Assert.stringContains('[decl] alphaOne', out);
		Assert.stringContains('[decl] betaTwo', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testLitBatchesTextsIntoPerTextSections(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchlit', [{ name: 'A.hx', source: FIXTURE }]);
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run(['lit', 'alphaOne', 'betaTwo', '--', dir]));
		CliFixture.removeDir(dir);
		Assert.equals(0, code);
		#if nodejs
		// Each section must carry ITS OWN hits, not just its banner: a batch that
		// printed two banners over one query's answer would pass on banners alone.
		final alphaSection: String = out.substring(out.indexOf('=== alphaOne ==='), out.indexOf('=== betaTwo ==='));
		final betaSection: String = out.substring(out.indexOf('=== betaTwo ==='));
		Assert.stringContains('=== alphaOne ===', out);
		Assert.stringContains('=== betaTwo ===', out);
		Assert.stringContains('alphaOne', alphaSection);
		Assert.isFalse(alphaSection.indexOf('betaTwo') >= 0, 'the first section holds only its own hits: $alphaSection');
		Assert.stringContains('betaTwo', betaSection);
		Assert.isFalse(betaSection.indexOf('alphaOne') >= 0, 'and the second only its own: $betaSection');
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/**
	 * `--json` renders ONE document and two concatenated documents are not JSON,
	 * so a batch with it is refused rather than given a second schema.
	 */
	public function testJsonRefusesMoreThanOneName(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchjson', [{ name: 'A.hx', source: FIXTURE }]);
		final refused: Int = Cli.run(['refs', 'alphaOne', 'betaTwo', '--', dir, '--json']);
		final accepted: Int = Cli.run(['refs', 'alphaOne', '--', dir, '--json']);
		CliFixture.removeDir(dir);
		Assert.equals(2, refused, '--json with two names is a usage error');
		Assert.equals(0, accepted, '--json with one name still works');
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/**
	 * The shape the separator exists to disambiguate, without the separator: a
	 * second positional that matched no file used to vanish silently.
	 */
	public function testAPositionalThatMatchedNoFileIsNamedOnStderr(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchnudge', [{ name: 'A.hx', source: FIXTURE }]);
		var code: Int = -1;
		final err: String = CliFixture.captureStderr(() -> code = Cli.run(['refs', 'alphaOne', 'betaTwo', dir, '--decls']));
		CliFixture.removeDir(dir);
		Assert.equals(0, code, 'still a successful run — the nudge is advice, not a failure');
		#if nodejs
		Assert.stringContains('"betaTwo" matched no files', err);
		Assert.stringContains('bare `--`', err);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** A batch whose every query finds nothing is still one empty walk for `--exit-on-empty`. */
	public function testAnAllEmptyBatchIsEmptyForExitOnEmpty(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchempty', [{ name: 'A.hx', source: FIXTURE }]);
		final allEmpty: Int = Cli.run(['refs', 'noSuchOne', 'noSuchTwo', '--', dir, '--exit-on-empty']);
		final oneHit: Int = Cli.run(['refs', 'noSuchOne', 'alphaOne', '--', dir, '--exit-on-empty']);
		CliFixture.removeDir(dir);
		Assert.equals(1, allEmpty, 'nothing found by any name is an empty walk');
		Assert.equals(0, oneHit, 'one name finding something is not an empty walk');
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** `source --select` is repeatable, and the nodes print in DOCUMENT order whatever order the flags came in. */
	public function testSourceSelectRepeatsInDocumentOrder(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchsource', [{ name: 'A.hx', source: FIXTURE }]);
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run([
			'source',
			'$dir/A.hx',
			'--select',
			'FnMember:betaTwo',
			'--select',
			'FnMember:alphaOne'
		]));
		var oneCode: Int = -1;
		final one: String = CliFixture.captureStdout(() -> oneCode = Cli.run(['source', '$dir/A.hx', '--select', 'FnMember:alphaOne']));
		CliFixture.removeDir(dir);
		Assert.equals(0, code);
		Assert.equals(0, oneCode);
		#if nodejs
		Assert.stringContains('=== FnMember:alphaOne ===', out);
		Assert.stringContains('=== FnMember:betaTwo ===', out);
		Assert.isTrue(
			out.indexOf('=== FnMember:alphaOne ===') < out.indexOf('=== FnMember:betaTwo ==='), 'document order, not flag order: $out'
		);
		Assert.isFalse(one.indexOf('===') >= 0, 'one selector gets no banner: $one');
		Assert.stringContains('function alphaOne', one);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/** One bad selector in a batch does not lose the good ones — they print, and the run exits non-zero. */
	public function testABadSelectorInABatchStillPrintsTheRest(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('batchbadsel', [{ name: 'A.hx', source: FIXTURE }]);
		var code: Int = -1;
		final out: String = CliFixture.captureStdout(() -> code = Cli.run([
			'source',
			'$dir/A.hx',
			'--select',
			'FnMember:alphaOne',
			'--select',
			'FnMember:nothingHere'
		]));
		CliFixture.removeDir(dir);
		Assert.equals(1, code, 'a selector that matched nothing is a runtime error');
		#if nodejs
		Assert.stringContains('function alphaOne', out);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

}
