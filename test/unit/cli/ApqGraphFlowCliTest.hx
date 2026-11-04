package unit.cli;

import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * `apq graph --flow` end to end through `Cli.run`: the chart of the function named, in each output, and how it
 * refuses — a name no function bears, an option that draws a whole scope.
 */
@:nullSafety(Strict)
class ApqGraphFlowCliTest extends Test {

	private static final SOURCE: String = "class C { static function f(a: Int): Int { if (a > 0) throw 'x'; return a; } }\n";

	/** The text report names the function and draws the branches of its `if`. */
	@:killer('M-FLOW-CLI-NOT-WIRED')
	@:pin('control')
	public function testFlowPrintsTheChartOfTheNamedFunction(): Void {
		final out: String = run(['--flow', 'C.f'], 0);
		Assert.isTrue(out.indexOf('C.f: 5 node(s), 5 edge(s)') >= 0, out);
		Assert.isTrue(out.indexOf('n1 -> n2  yes') >= 0, out);
	}

	/** `--format mermaid` prints the flowchart. */
	public function testFlowFormatMermaid(): Void {
		final out: String = run(['--flow', 'C.f', '--format', 'mermaid'], 0);
		Assert.isTrue(out.indexOf('flowchart TB') >= 0, out);
		Assert.isTrue(out.indexOf('n1 -->|yes| n2') >= 0, out);
	}

	/** A name no function bears says so and is the empty answer. */
	public function testAnUnknownFunctionIsTheEmptyAnswer(): Void {
		Assert.isTrue(runErr(['--flow', 'C.nope'], 0).indexOf('no function in scope matches "C.nope"') >= 0);
	}

	/** A member declared once per conditional-compilation branch is refused, naming each declaration, not drawn from the first alone. */
	@:killer('M-FLOW-CLI-BRANCHES-IGNORED')
	@:pin('control')
	public function testAMemberDeclaredPerBranchIsRefused(): Void {
		final err: String = runErr(
			['--flow', 'C.g'], 2, 'class C {\n#if js\nfunction g() { return 1; }\n#else\nfunction g() { return 2; }\n#end\n}\n'
		);
		Assert.isTrue(err.indexOf('"C.g" is declared 2 times') >= 0, err);
		Assert.isTrue(err.indexOf(':3\n') >= 0 && err.indexOf(':5\n') >= 0, err);
		final overloaded: String = runErr(
			['--flow', 'C.h'],
			2,
			'class C {\nextern overload inline function h(a: Int): Int return 1;\n'
			+ 'extern overload inline function h(a: String): Int return 2;\n}\n'
		);
		Assert.isTrue(overloaded.indexOf('"C.h" is declared 2 times; a chart is of one declaration') >= 0, overloaded);
		Assert.isTrue(overloaded.indexOf('conditional') < 0, overloaded);
	}

	/** An option that draws a whole scope is refused beside `--flow`. */
	public function testAWholeScopeOptionIsRefused(): Void {
		final err: String = runErr(['--flow', 'C.f', '--level', 'type'], 2);
		Assert.isTrue(err.indexOf('--level draws a whole scope') >= 0, err);
	}

	/** Run `apq graph <fixture> <args>` and assert the exit code; the stdout. */
	private function run(args: Array<String>, expected: Int): String {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('apq_graph_flow', 'hx', SOURCE);
		var exit: Int = -1;
		final out: String = CliFixture.captureStdout(() -> exit = Cli.run(['graph', f].concat(args)));
		Assert.equals(expected, exit, 'graph ${args.join(' ')}');
		FileSystem.deleteFile(f);
		return out;
		#else
		Assert.pass('non-sys target');
		return '';
		#end
	}

	/** Run `apq graph <fixture> <args>` and assert the exit code; the stderr. */
	private function runErr(args: Array<String>, expected: Int, ?source: String): String {
		#if (sys || nodejs)
		final f: String = CliFixture.writeAs('apq_graph_flow', 'hx', source ?? SOURCE);
		var exit: Int = -1;
		final err: String = CliFixture.captureStderr(() -> exit = Cli.run(['graph', f].concat(args)));
		Assert.equals(expected, exit, 'graph ${args.join(' ')}');
		FileSystem.deleteFile(f);
		return err;
		#else
		Assert.pass('non-sys target');
		return '';
		#end
	}

}
