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

}
