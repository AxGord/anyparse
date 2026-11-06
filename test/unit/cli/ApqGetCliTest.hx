package unit.cli;

import anyparse.query.Cli;
import anyparse.query.cli.DataPath;
import anyparse.query.cli.UsageFailure;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * `apq get` end to end through `Cli.run`: what it prints for each kind of value, how a path names a key or an
 * index, and how it refuses — a missing path, a code file.
 */
@:nullSafety(Strict)
class ApqGetCliTest extends Test {

	private static final DOCUMENT: String =
		'{\n\t"rules": {"a.b": 1, "list": [10, "x\\n\\"y", true, null, {"deep": []}]},\n\t"name": "plain"\n}\n';
	private static final WHERE_A: String = '{"title": "plain", "arms": [{"name": "X", "member": "run"}, {"name": "Y", "member": "walk"}]}';
	private static final WHERE_B: String = '{"arms": [{"name": "Z", "member": "run", "nested": {"member": "run"}}]}';

	/** A string prints decoded and unquoted. */
	@:killer('M-GET-STRING-QUOTED')
	@:pin('control')
	public function testAStringPrintsDecodedAndUnquoted(): Void {
		assertGet(['rules.list.1'], 'x\n"y\n');
		assertGet(['name'], 'plain\n');
	}

	/** A number, a boolean and null print as written. */
	public function testScalarsPrintAsWritten(): Void {
		assertGet(['rules.list.0'], '10\n');
		assertGet(['rules.list.2'], 'true\n');
		assertGet(['rules.list.3'], 'null\n');
	}

	/** An object or array prints as compact JSON, its strings re-escaped. */
	public function testAContainerPrintsAsCompactJson(): Void {
		assertGet(['rules.list'], '[10,"x\\n\\"y",true,null,{"deep":[]}]\n');
		assertGet(['.'], '{"rules":{"a.b":1,"list":[10,"x\\n\\"y",true,null,{"deep":[]}]},"name":"plain"}\n');
	}

	/** `\.` is a dot inside a key, not a separator. */
	@:killer('M-DATA-PATH-ESCAPE-IGNORED')
	@:pin('control')
	public function testAnEscapedDotStaysInTheKey(): Void {
		assertGet(['rules.a\\.b'], '1\n');
		Assert.same(['a.b', 'c\\'], DataPath.parse('a\\.b.c\\\\'));
		Assert.raises(DataPath.parse.bind('a\\b'), UsageFailure);
	}

	/** `--select` starts the walk at the node it names; a path continues from there. */
	public function testSelectStartsTheWalk(): Void {
		assertGet(['--select', 'Member:list', '4.deep'], '[]\n');
		assertGet(['--select', 'Member:name'], 'plain\n');
	}

	/** A path that names nothing exits 1 and says where the walk stopped. */
	public function testAMissingPathExitsOneAndSaysWhere(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('apq_get_missing', 'json', DOCUMENT);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', f, 'rules.nope']));
		Assert.equals(1, exit, 'a missing path is a runtime answer, not a usage error');
		Assert.isTrue(
			err.indexOf('"rules" is an object with keys "a.b", "list" — no key "nope"') >= 0, 'the reason names the keys there: $err'
		);
		final past: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', f, 'rules.list.9']));
		Assert.equals(1, exit, 'an index past the end is missing too');
		Assert.isTrue(past.indexOf('is an array of 5 — no index "9"') >= 0, past);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** A code file walks like any other, and its root is no object: one stderr line, exit 1. */
	public function testACodeFileNamesNoKey(): Void {
		assertRefused('apq_get_code', 'hx', 'class C {}', 'the document is a ClassDecl, not an object or an array — no key "a"');
	}

	/** A grammar whose shape declares no object or array kind is refused with one line, not a stack. */
	@:killer('M-GET-WALKABLE-ALWAYS')
	@:pin('control')
	public function testAGrammarWithNoContainerIsRefused(): Void {
		assertRefused('apq_get_mermaid', 'mmd', 'flowchart TD\n  A --> B\n', 'the mermaid grammar declares no object or array');
	}

	/** The process entry names the grammar from the extension, with no `--lang` given. */
	public function testTheProcessEntryNeedsNoLang(): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('apq_get_entry', 'json', DOCUMENT);
		var exit: Int = -1;
		final out: String = CliFixture.captureStdout(() -> exit = Cli.run(['get', f, 'name'], true));
		Assert.equals(0, exit);
		Assert.equals('plain\n', out);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--where` names the record holding the value, in every document of a directory, with the path to it. */
	public function testWhereNamesTheRecordInEachDocument(): Void {
		assertWhere(['member=run'], ['a.json arms.0', 'b.json arms.0', 'b.json arms.0.nested'], 0);
	}

	/** A key path with a dot reads a nested key; a match at the root is the path `.`. */
	public function testWhereReadsANestedKeyAndNamesTheRoot(): Void {
		assertWhere(['nested.member=run'], ['b.json arms.0'], 0);
		assertWhere(['title=plain'], ['a.json .'], 0);
	}

	/** No record matching exits 1 and prints nothing. */
	public function testWhereWithNoMatchExitsOne(): Void {
		assertWhere(['member=absent'], [], 1);
		assertWhere(['nested.member=walk'], [], 1);
	}

	/** A code file named beside the documents is refused on one stderr line; the documents still answer, and the exit is 1. */
	public function testWhereRefusesACodeFile(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('apq_get_where_code', [
			{ name: 'a.json', source: WHERE_A },
			{ name: 'c.hx', source: 'class C {}' }
		]);
		var exit: Int = -1;
		var out: String = '';
		final err: String = CliFixture.captureStderr(
			() -> out = CliFixture.captureStdout(() -> exit = Cli.run(['get', '--where', 'member=run', '$dir/a.json', '$dir/c.hx']))
		);
		Assert.equals(1, exit, 'a refused document fails the run: $err');
		Assert.isTrue(err.indexOf('c.hx: the document is a ') >= 0 && err.indexOf('holds no record') >= 0, err);
		Assert.equals(1, err.split('\n').filter(line -> line != '').length, 'one line: $err');
		Assert.equals('$dir/a.json arms.0\n', out);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--where` takes `<path>=<value>` and does not combine with `--select`. */
	public function testWhereRefusesAMalformedClause(): Void {
		#if (sys || nodejs)
		var exit: Int = -1;
		final noEquals: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', '--where', 'member', 'x.json']));
		Assert.equals(2, exit, 'a clause with no "=" is a usage error: $noEquals');
		Assert.isTrue(noEquals.indexOf('--where expects <path>=<value>') >= 0, noEquals);
		final withSelect: String = CliFixture.captureStderr(() ->
			exit = Cli.run(['get', '--where', 'a=b', '--select', 'Member:a', 'x.json'])
		);
		Assert.equals(2, exit, 'a --select beside --where is a usage error: $withSelect');
		Assert.isTrue(withSelect.indexOf('does not combine with --select') >= 0, withSelect);
		final withNth: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', '--where', 'a=b', '--nth', '2', 'x.json']));
		Assert.equals(2, exit, 'a --nth beside --where is a usage error: $withNth');
		final twice: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', '--where', 'a=b', '--where', 'c=d', 'x.json']));
		Assert.equals(2, exit, 'a repeated --where is a usage error: $twice');
		Assert.isTrue(twice.indexOf('--where is given once') >= 0, twice);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * The process entry names no language for `--where`: a directory and a
	 * quoted glob reach the search, each document routed by its extension.
	 */
	public function testWhereNeedsNoLangAtTheProcessEntry(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir(
			'apq_get_where_entry', [{ name: 'a.json', source: WHERE_A }, { name: 'b.json', source: WHERE_B }]
		);
		for (spec in [dir, '$dir/*.json']) {
			var exit: Int = -1;
			final out: String = CliFixture.captureStdout(() -> exit = Cli.run(['get', '--where', 'member=run', spec], true));
			Assert.equals(0, exit, 'process entry, spec $spec');
			Assert.same(
				['a.json arms.0', 'b.json arms.0', 'b.json arms.0.nested'],
				[for (line in out.split('\n')) if (line != '') line.split('$dir/').join('')]
			);
		}
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Run `apq get <fixture> a` on a `.extension` file holding `source`, and assert exit 1 with `reason` on stderr. */
	private function assertRefused(prefix: String, extension: String, source: String, reason: String): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs(prefix, extension, source);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['get', f, 'a']));
		Assert.equals(1, exit, 'refused: $err');
		Assert.isTrue(err.indexOf(reason) >= 0, err);
		Assert.equals(1, err.split('\n').filter(line -> line != '').length, 'one line: $err');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Run `apq get <fixture> <args>` and assert its stdout and a 0 exit. */
	private function assertGet(args: Array<String>, expected: String): Void {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('apq_get', 'json', DOCUMENT);
		var exit: Int = -1;
		final out: String = CliFixture.captureStdout(() -> exit = Cli.run(['get', f].concat(args)));
		Assert.equals(0, exit, 'get ${args.join(' ')} exits 0');
		Assert.equals(expected, out, 'get ${args.join(' ')}');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * Write `WHERE_A` and `WHERE_B` to a directory, run `apq get --where <clause> <dir>`,
	 * and assert its lines (relative to the directory) and exit.
	 */
	private function assertWhere(clause: Array<String>, expected: Array<String>, expectedExit: Int): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir(
			'apq_get_where', [{ name: 'a.json', source: WHERE_A }, { name: 'b.json', source: WHERE_B }]
		);
		var exit: Int = -1;
		final out: String = CliFixture.captureStdout(() -> exit = Cli.run(['get', '--where'].concat(clause).concat([dir])));
		Assert.equals(expectedExit, exit, 'get --where ${clause.join(' ')} exits $expectedExit');
		Assert.same(
			expected,
			[for (line in out.split('\n')) if (line != '') line.split('$dir/').join('')],
			'get --where ${clause.join(' ')}'
		);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
