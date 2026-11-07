package unit.cli;

import anyparse.query.cli.BatchAnswer;
import anyparse.query.cli.BatchRun;

/**
 * `apq --batch`: each call answers with its own status, streams and stdin, the process streams are its own again after the
 * call, and a call over a tree an earlier call already read answers as a fresh process would.
 */
@:nullSafety(Strict)
final class BatchRunTest extends Test {

	public function testACallAnswersWithItsOwnStatusStreamsAndStdin(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('batch_streams', []);
		final stdout: haxe.Constraints.Function = Reflect.field(js.Node.process.stdout, 'write');
		final probed: BatchAnswer = BatchRun.answer({ argv: ['probe', '--lang-default', 'haxe', '-'], cwd: dir, stdin: 'var x = 1;' });
		final unknown: BatchAnswer = BatchRun.answer({ argv: ['no-such-command'], cwd: dir, stdin: null });
		Assert.isTrue(Reflect.field(js.Node.process.stdout, 'write') == stdout, 'the process writes to its own stdout again');
		Assert.equals(0, probed.status);
		Assert.stringContains('(VarDecl x (IntLit 1))', probed.out, 'the call read the stdin it was given');
		Assert.equals(2, unknown.status);
		Assert.equals('', unknown.out);
		Assert.stringContains('unknown subcommand "no-such-command"', unknown.err);
		final entry: BatchAnswer = BatchRun.answer({ argv: [BatchRun.FLAG], cwd: dir, stdin: null });
		Assert.equals(2, entry.status);
		Assert.equals('usage: apq --batch <calls.json> <answers.json>\n', entry.err, 'a call reaches the entry the process does');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('nodejs only');
		#end
	}

	@:pin('control')
	@:killer('M-BATCH-RUN-REMEMBERS')
	public function testACallOverATreeAnEarlierCallReadAnswersAsAFreshProcess(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('batch_forget', [
			{ name: 'hxformat.json', source: '{"noSuchKnobAtAll": 1}' },
			{ name: 'A.hx', source: 'class A {\n\tvar x:Int;\n}\n' }
		]);
		final fmt: Array<String> = ['fmt', '--lang-default', 'haxe', 'A.hx'];
		final first: BatchAnswer = BatchRun.answer({ argv: fmt, cwd: dir, stdin: null });
		final second: BatchAnswer = BatchRun.answer({ argv: fmt, cwd: dir, stdin: null });
		Assert.stringContains('noSuchKnobAtAll', first.err);
		Assert.equals(first.err, second.err, 'the second call warns about the config again');
		sys.io.File.saveContent('$dir/hxformat.json', '{"indentation": {"character": "  "}}');
		final changed: BatchAnswer = BatchRun.answer({ argv: fmt, cwd: dir, stdin: null });
		Assert.equals('class A {\n  var x:Int;\n}\n', changed.out, 'the call reads the config as it is now');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('nodejs only');
		#end
	}

	@:pin('control')
	@:killer('M-RUN-KEEPS-LEDGER')
	public function testASecondLintCallOverABrokenConfigWarnsAgain(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('batch_lint_warn', [
			{ name: 'apqlint.json', source: '{' },
			{ name: 'A.hx', source: 'class A {}\n' }
		]);
		final lint: Array<String> = ['lint', '--lang-default', 'haxe', 'A.hx', '--no-oracle'];
		for (call in 0...2)
			Assert.stringContains(
				'apqlint.json failed to parse', BatchRun.answer({ argv: lint, cwd: dir, stdin: null }).err, 'call #$call'
			);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('nodejs only');
		#end
	}

	@:pin('control')
	@:killer('M-RUN-KEEPS-LEDGER')
	public function testASecondFixCallReportsItsSkipAgain(): Void {
		#if nodejs
		// `b` moves only with the first write of `a`, which is no candidate: `a` is written twice
		final dir: String = CliFixture.writeDir('batch_fix_skip', [
			{
				name: 'A.hx',
				source: 'class A {\n\tvar a:Int;\n\tvar b:Int;\n\n\tpublic function new() {\n\t\ta = 1;\n\t\tb = 2;\n\t\ta = 3;\n\t}\n}\n'
			}
		]);
		final fix: Array<String> = [
			'lint',
			'--lang-default',
			'haxe',
			'A.hx',
			'--rule',
			'field-init-at-declaration',
			'--no-oracle',
			'--fix'
		];
		for (call in 0...2)
			Assert.stringContains('\'b\' skipped', BatchRun.answer({ argv: fix, cwd: dir, stdin: null }).err, 'call #$call');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('nodejs only');
		#end
	}

	@:pin('control')
	@:killer('M-RUN-KEEPS-LEDGER')
	public function testASecondFormatCallOverAnUnreadConfigKeyWarnsAgain(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('batch_format_warn', [
			{ name: 'hxformat.json', source: '{"noSuchSection":{}}' },
			{ name: 'A.hx', source: 'class A {}\n' }
		]);
		final format: Array<String> = ['fmt', '--list', 'A.hx'];
		for (call in 0...2)
			Assert.stringContains('hxq does not implement', BatchRun.answer({ argv: format, cwd: dir, stdin: null }).err, 'call #$call');
		CliFixture.removeDir(dir);
		#else
		Assert.pass('nodejs only');
		#end
	}

}
