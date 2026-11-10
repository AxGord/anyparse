package unit.cli;

import anyparse.query.Cli;
import sys.io.File;

using StringTools;

/**
 * `move-member --scope` is repeatable and every scope counts: a caller in the second scope is
 * rewritten as one in the first, and a scope matching no file refuses instead of narrowing the move.
 */
@:nullSafety(Strict)
class MoveMemberScopeCliTest extends Test {

	@:pin('control')
	@:killer('M-MOVE-MEMBER-LAST-SCOPE-WINS')
	public function testEveryScopeIsRewritten(): Void {
		#if nodejs
		final first: String = CliFixture.writeTree('mmscope1', [
			{ name: 'A.hx', source: 'package p;\n\nclass A {\n\tpublic static function foo():Int return 1;\n}\n' },
			{ name: 'B.hx', source: 'package p;\n\nclass B {}\n' }
		]);
		final second: String = CliFixture.writeTree('mmscope2', [
			{ name: 'C.hx', source: 'package p;\n\nclass C {\n\tpublic static function go():Int return A.foo();\n}\n' }
		]);
		CliFixture.always(() -> {
			CliFixture.removeDir(first);
			CliFixture.removeDir(second);
		}, () -> {
			var code: Int = -1;
			CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> code = Cli.run([
				'move-member',
				'$first/A.hx',
				'foo',
				'--to',
				'B',
				'--scope',
				first,
				'--scope',
				second,
				'--write'
			])));
			Assert.equals(0, code);
			final caller: String = File.getContent('$second/C.hx');
			Assert.isTrue(caller.contains('return B.foo();'), 'the second scope\'s caller should be repointed:\n$caller');
		});
		#else
		Assert.pass('non-nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-MOVE-MEMBER-UNMATCHED-SCOPE-NARROWS')
	public function testAScopeMatchingNothingRefuses(): Void {
		#if nodejs
		final first: String = CliFixture.writeTree('mmscope3', [
			{ name: 'A.hx', source: 'package p;\n\nclass A {\n\tpublic static function foo():Int return 1;\n}\n' },
			{ name: 'B.hx', source: 'package p;\n\nclass B {}\n' }
		]);
		CliFixture.always(CliFixture.removeDir.bind(first), () -> {
			var code: Int = -1;
			final err: String = CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> code = Cli.run([
				'move-member',
				'$first/A.hx',
				'foo',
				'--to',
				'B',
				'--scope',
				first,
				'--scope',
				'$first/nowhere/*.hx'
			])));
			Assert.equals(1, code);
			Assert.isTrue(err.contains('matched no'), err);
		});
		#else
		Assert.pass('non-nodejs target');
		#end
	}

}
