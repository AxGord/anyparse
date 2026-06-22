package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end probe for the `--from-file` code-input mode shared by the
 * writer-emit mutation ops (`add-member` / `add-element` / `replace-node`).
 *
 * `--from-file <path>` reads the new code from a file instead of the
 * positional argument — the quote-safe path for code containing `$` or
 * quotes that a shell would mangle as an argument. These tests drive
 * `Cli.run([...])` with a member / element file, apply `--write`, and read
 * the rewritten fixture back to confirm the file content reached the
 * writer verbatim. The conflict and missing-file cases cover the resolver's
 * error exits. (Stdin `-` shares the same resolver but is not in-process
 * mockable, so it is smoke-tested at the CLI, not here.)
 */
class ApqFromFileCliTest extends Test {

	public function testAddMemberFromFile(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_fromfile', 'class C {\n\tvar x:Int;\n}\n');
		// Member text carries both `$` (interpolation) and single quotes —
		// the exact shape the shell would mangle as a positional argument.
		final member: String = CliFixture.write(
			'apq_member', "public function greet():String {\n\tfinal w:String = 'hi';\n\treturn 'a $w';\n}"
		);
		Assert.equals(0, Cli.run(['add-member', fixture, '--type', 'C', '--from-file', member, '--write']));
		final result: String = File.getContent(fixture);
		Assert.isTrue(result.indexOf('function greet') >= 0, 'member from file must be inserted');
		Assert.isTrue(result.indexOf("'a $w'") >= 0, 'the $-and-quote content must survive verbatim');
		FileSystem.deleteFile(fixture);
		FileSystem.deleteFile(member);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAddElementFromFile(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_fromfile', 'class C {\n\tvar x:Int;\n}\n');
		final element: String = CliFixture.write('apq_element', "function f():Void { trace('$x'); }");
		// Append into the class body (point at the `class` keyword).
		Assert.equals(0, Cli.run(['add-element', fixture, '--append', '1:0', '--from-file', element, '--write']));
		final result: String = File.getContent(fixture);
		Assert.isTrue(result.indexOf('function f') >= 0, 'element from file must be appended');
		FileSystem.deleteFile(fixture);
		FileSystem.deleteFile(element);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReplaceNodeFromFile(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_fromfile', 'class C {\n\tfunction f():Void {\n\t\tvar y = 0;\n\t}\n}\n');
		final repl: String = CliFixture.write('apq_repl', 'var y = 42');
		Assert.equals(0, Cli.run(['replace-node', fixture, '--at', '3:2', '--from-file', repl, '--write']));
		final result: String = File.getContent(fixture);
		Assert.isTrue(result.indexOf('var y = 42') >= 0, 'node source must come from the file');
		FileSystem.deleteFile(fixture);
		FileSystem.deleteFile(repl);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReplaceNodeFromFileStripsTrailingNewline(): Void {
		#if (sys || nodejs)
		final fixture: String = CliFixture.write('apq_trail', 'class C {\n\tfunction f():Int {\n\t\treturn 1;\n\t}\n}\n');
		// A --from-file / stdin source carries a trailing newline (a heredoc always appends one);
		// the splice op must strip it so it does not surface as a stray blank line before `}`.
		final repl: String = CliFixture.write('apq_trailrepl', 'function f():Int {\n\t\treturn 99;\n\t}\n');
		Assert.equals(
			0, Cli.run([
				'replace-node',
				fixture,
				'--select',
				'FnMember:f',
				'--from-file',
				repl,
				'--write'
			])
		);
		final result: String = File.getContent(fixture);
		Assert.isTrue(result.indexOf('return 99') >= 0, 'replacement applied');
		Assert.isTrue(result.indexOf('}\n\n}') < 0, 'no stray blank line before the closing brace');
		FileSystem.deleteFile(fixture);
		FileSystem.deleteFile(repl);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testInlineAndFromFileConflict(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_fromfile', 'class C {\n\tvar x:Int;\n}\n');
		final member: String = CliFixture.write('apq_member', 'var z:Int;');
		// Both an inline member and --from-file → runtime error, file untouched.
		Assert.equals(1, Cli.run(['add-member', fixture, '--type', 'C', 'var q:Int;', '--from-file', member]));
		FileSystem.deleteFile(fixture);
		FileSystem.deleteFile(member);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFromFileMissingPath(): Void {
		#if sys
		final fixture: String = CliFixture.write('apq_fromfile', 'class C {\n\tvar x:Int;\n}\n');
		Assert.equals(1, Cli.run(['add-member', fixture, '--type', 'C', '--from-file', '/no/such/file.hx']));
		FileSystem.deleteFile(fixture);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
