package unit.cli;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Cli;
#if nodejs
import sys.io.File;
#end

/**
 * `apq merge-file`, the git merge driver, over scratch files: a merge written over ours with exit 0, a place both sides
 * changed left between markers with exit 1 and settled by a `--choices` line, and a file no grammar reads given git's
 * own line merge.
 */
@:nullSafety(Strict)
class MergeFileCommandCliTest extends Test {

	public function testMembersBothSidesAddedAreWrittenOverOurs(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_merge_file', [
			{ name: 'base', source: module(['f' => '1']) },
			{ name: 'ours', source: module(['f' => '1', 'h' => '2']) },
			{ name: 'theirs', source: module(['f' => '1', 'k' => '3']) }
		]);
		final status: Int = run(root);
		final merged: String = File.getContent('$root/ours');
		CliFixture.removeDir(root);
		Assert.equals(0, status);
		Assert.equals(module(['f' => '1', 'h' => '2', 'k' => '3']), merged);
		#else
		Assert.pass('file IO needs the nodejs target');
		#end
	}

	public function testAConflictExitsOneAndAChoiceSettlesIt(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_merge_file', [
			{ name: 'base', source: module(['f' => '1']) },
			{ name: 'ours', source: module(['f' => '2']) },
			{ name: 'theirs', source: module(['f' => '3']) }
		]);
		final conflicted: Int = run(root);
		final marked: String = File.getContent('$root/ours');
		File.saveContent('$root/ours', module(['f' => '2']));
		File.saveContent('$root/choices.tsv', '$root/C.hx\tC.f\ttheirs\n');
		final chosen: Int = run(root, ['--choices', '$root/choices.tsv']);
		final settled: String = File.getContent('$root/ours');
		CliFixture.removeDir(root);
		Assert.equals(1, conflicted);
		Assert.isTrue(marked.indexOf('<<<<<<< ours C.f') >= 0, marked);
		Assert.equals(0, chosen);
		Assert.equals(module(['f' => '3']), settled);
		#else
		Assert.pass('file IO needs the nodejs target');
		#end
	}

	public function testAFileNoGrammarReadsGetsGitsLineMerge(): Void {
		#if nodejs
		final root: String = CliFixture.writeTree('apq_merge_file', [
			{ name: 'base', source: 'a\nb\nc\n' },
			{ name: 'ours', source: 'A\nb\nc\n' },
			{ name: 'theirs', source: 'a\nb\nC\n' }
		]);
		final status: Int = Cli.run([
			'merge-file',
			'$root/base',
			'$root/ours',
			'$root/theirs',
			'--path',
			'$root/notes.txt'
		]);
		final merged: String = File.getContent('$root/ours');
		CliFixture.removeDir(root);
		Assert.equals(0, status);
		Assert.equals('A\nb\nC\n', merged);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** `merge-file` over the three versions under `root`, as the module `C.hx` there. */
	private static function run(root: String, ?extra: Array<String>): Int {
		return Cli.run(['merge-file', '$root/base', '$root/ours', '$root/theirs', '--path', '$root/C.hx'].concat(extra ?? []));
	}

	/** Class `C` holding a function per name returning its value, as the writer emits it under its defaults. */
	private static function module(members: Map<String, String>): String {
		final names: Array<String> = [for (name in members.keys()) name];
		names.sort(Reflect.compare);
		final body: String = [
			for (name in names) '\tpublic function $name():Int {\n\t\treturn ${members[name]};\n\t}\n'
		].join('\n');
		final source: String = 'class C {\n$body}\n';
		return new HaxeQueryPlugin().writeRoundTrip(source, null) ?? source;
	}

}
