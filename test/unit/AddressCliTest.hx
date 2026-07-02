package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * End-to-end tests for the shared addressing flags on the mutation ops:
 * `--select` / `--match` / `--nth`, the `--kind` lift, valueless
 * `--after` / `--before` / `--append` mode flags, and line-only positions.
 * Each drives `Cli.run` against a temp fixture with `--write` and asserts
 * the resulting file content.
 */
class AddressCliTest extends Test {

	#if (sys || nodejs)
	private static final FIXTURE: String = 'class C {\n\tfunction f():Int {\n\t\tvar x:Int = 1;\n\t\ttrace(x);\n\t\treturn x;\n\t}\n}\n';
	#end

	public function testAddElementAfterSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_ae', FIXTURE);
		final rc: Int = Cli.run([
			'add-element',
			path,
			'--after',
			'--select',
			'FnMember:f >> VarStmt:x',
			'trace(2);',
			'--write'
		]);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('var x:Int = 1;\n\t\ttrace(2);') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRemoveElementSelectDescendant(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_re', 'class C {\n\tfunction f():Int {\n\t\tvar dead:Int = 1;\n\t\treturn 2;\n\t}\n}\n');
		final rc: Int = Cli.run(['remove-element', path, '--select', 'FnMember:f >> VarStmt:dead', '--write']);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('dead') < 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRemoveElementLineOnly(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_lo', 'class C {\n\tfunction f():Int {\n\t\tvar dead:Int = 1;\n\t\treturn 2;\n\t}\n}\n');
		// Line 3 with no column — snaps past the leading tabs to `var`.
		final rc: Int = Cli.run(['remove-element', path, '3', '--write']);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('dead') < 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testReplaceNodeMatchKindLift(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rn', FIXTURE);
		final rc: Int = Cli.run([
			'replace-node',
			path,
			'--match',
			'trace(x)',
			'--kind',
			'ExprStmt',
			'trace(x);\ntrace(x + 1);',
			'--write'
		]);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('trace(x + 1);') >= 0);
		// The lift replaced the whole statement — no stray `;;` artifact.
		Assert.isTrue(out.indexOf(';;') < 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSetModifierSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_sm', FIXTURE);
		final rc: Int = Cli.run(['set-modifier', path, '--select', 'FnMember:f', 'public', '--write']);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('public function f') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testSetDocSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_sd', FIXTURE);
		final rc: Int = Cli.run(['set-doc', path, '--select', 'FnMember:f', 'Returns one.', '--write']);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('Returns one.') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAmbiguousSelectFailsWithCandidates(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_amb', 'class C {\n\tfunction f():Void {\n\t\ttrace(1);\n\t\ttrace(2);\n\t}\n}\n');
		final before: String = File.getContent(path);
		final rc: Int = Cli.run(['remove-element', path, '--select', 'ExprStmt', '--write']);
		Assert.isTrue(rc != 0);
		Assert.equals(before, File.getContent(path));
		// --nth resolves the ambiguity.
		final rc2: Int = Cli.run(['remove-element', path, '--select', 'ExprStmt', '--nth', '2', '--write']);
		Assert.equals(0, rc2);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('trace(1);') >= 0);
		Assert.isTrue(out.indexOf('trace(2);') < 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testAddElementAppendSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_ap', 'class C {\n\tfunction f():Void {}\n}\n');
		// Valueless --append + --select of the empty body container.
		final rc: Int = Cli.run([
			'add-element',
			path,
			'--append',
			'--select',
			'FnMember:f > BlockBody',
			'trace(1);',
			'--write'
		]);
		Assert.equals(0, rc);
		Assert.isTrue(File.getContent(path).indexOf('trace(1);') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRenameSelectLocal(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_rn2', FIXTURE);
		final rc: Int = Cli.run(['rename', path, '--select', 'FnMember:f >> VarStmt:x', 'renamed', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('var renamed:Int = 1;') >= 0);
		Assert.isTrue(out.indexOf('return renamed;') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testChangeSigSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'addr_cs', 'class C {\n\tfunction g(a:Int, b:String):Void {}\n\tfunction f():Void {\n\t\tg(1, "s");\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['change-sig', path, '--select', 'FnMember:g', '1,0', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('function g(b:String, a:Int)') >= 0);
		Assert.isTrue(out.indexOf('g("s", 1)') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testRemoveParamSelect(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write(
			'addr_rp',
			'class C {\n\tfunction g(a:Int, unused:String):Void {\n\t\ttrace(a);\n\t}\n\tfunction f():Void {\n\t\tg(1, "s");\n\t}\n}\n'
		);
		final rc: Int = Cli.run(['remove-param', path, '--select', 'FnMember:g', '1', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('function g(a:Int)') >= 0);
		Assert.isTrue(out.indexOf('g(1)') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testExtractVarMatch(): Void {
		#if (sys || nodejs)
		final path: String = CliFixture.write('addr_ev', 'class C {\n\tfunction f(a:Int):Int {\n\t\treturn a * 2 + 1;\n\t}\n}\n');
		final rc: Int = Cli.run(['extract-var', path, '--match', 'a * 2', 'doubled', '--write']);
		Assert.equals(0, rc);
		final out: String = File.getContent(path);
		Assert.isTrue(out.indexOf('final doubled = a * 2;') >= 0);
		Assert.isTrue(out.indexOf('return doubled + 1;') >= 0);
		FileSystem.deleteFile(path);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
