package unit.cli;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * hxq's edit ops on a `.json` file, end to end through the CLI the way an agent calls them — the
 * `hxq` shim's own `--lang haxe` included, which the file's extension overrides. Each case asserts the
 * whole written file: the edit changes its own lines and nothing else.
 */
class JsonEditCliTest extends Test {

	private static final CONFIG: String = '{\n\t"rules": {\n\t\t"thread-safety": {\n\t\t\t"registers": [\n\t\t\t\t"addEventListener"\n'
		+ '\t\t\t],\n\t\t\t"spawns": [\n\t\t\t\t"Thread.create",\n\t\t\t\t"api.R.success"\n\t\t\t],\n\t\t\t"n": 3\n\t\t}\n\t}\n}\n';

	/** `--append` into a one-per-line array: the new entry takes its own line at its siblings' indentation. */
	@:killer('M-LAYOUT-SPLICE-BYPASSED')
	@:killer('M-PICK-PLUGIN-FOR-IGNORES-PATH')
	@:pin('control')
	public function testAppendIntoAnArray(): Void {
		assertEdit([
			'add-element',
			'--lang',
			'haxe',
			'--append',
			'--select',
			'Member:registers > JArray',
			'"api.R.success"'
		], CONFIG.replace('"addEventListener"\n', '"addEventListener",\n\t\t\t\t"api.R.success"\n'));
	}

	/** `--after` a member adds a member — key and value — formatted like its siblings. */
	public function testAddAMemberAfterAMember(): Void {
		assertEdit(
			['add-element', '--after', '--select', 'Member:n', '"m": {"x": [1]}'],
			CONFIG.replace('"n": 3\n', '"n": 3,\n\t\t\t"m": {\n\t\t\t\t"x": [\n\t\t\t\t\t1\n\t\t\t\t]\n\t\t\t}\n')
		);
	}

	/** `--after` the SOLE entry of an array: the array is a comma container, so the entry is joined with a `,`. */
	@:killer('M-COMMA-CONTAINER-KINDS-UNREAD')
	@:pin('control')
	public function testAfterTheSoleEntryOfAnArray(): Void {
		assertEdit(
			['add-element', '--after', '--select', 'JString:addEventListener', '"x"'],
			CONFIG.replace('"addEventListener"\n', '"addEventListener",\n\t\t\t\t"x"\n')
		);
	}

	/** `--sorted` places each string entry at its sorted position. */
	@:killer('M-JSON-LITERAL-NONE')
	@:pin('control')
	public function testSortedInsert(): Void {
		assertEdit(
			['add-element', '--sorted', '--select', 'Member:spawns > JArray', '"api.A.x"'],
			CONFIG.replace('"Thread.create",\n', '"Thread.create",\n\t\t\t\t"api.A.x",\n')
		);
	}

	/** `remove-element` on the last entry takes its line and the `,` before it. */
	public function testRemoveTheLastEntry(): Void {
		assertEdit(
			['remove-element', '--select', 'Member:spawns > JArray > JString:api.R.success'],
			CONFIG.replace('"Thread.create",\n\t\t\t\t"api.R.success"\n', '"Thread.create"\n')
		);
	}

	/** `remove-element` on a member takes the whole member, key and value. */
	public function testRemoveAMember(): Void {
		assertEdit(
			['remove-element', '--select', 'Member:registers'],
			CONFIG.replace('\t\t\t"registers": [\n\t\t\t\t"addEventListener"\n\t\t\t],\n', '')
		);
	}

	/** `replace-node` on a value replaces the value and lays the new one out like the document. */
	public function testReplaceAValue(): Void {
		assertEdit(
			['replace-node', '--select', 'Member:n > JNumber', '[4, 5]'],
			CONFIG.replace('"n": 3\n', '"n": [\n\t\t\t\t4,\n\t\t\t\t5\n\t\t\t]\n')
		);
	}

	/** `ast --select` reads a JSON file in the JSON vocabulary. */
	public function testAstReadsTheJsonVocabulary(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('jsonedit', [{ name: 'config.json', source: CONFIG }]);
		var rc: Int = -1;
		final printed: String = CliFixture.captureStdout(() -> rc = Cli.run(['ast', '$dir/config.json', '--select', 'Member:n']));
		Assert.equals(0, rc);
		#if nodejs
		Assert.equals('(Member n (JNumber))', printed.trim());
		#end
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Run `args` with `--write` on a fresh copy of `CONFIG` and assert the file it leaves. */
	private function assertEdit(args: Array<String>, expected: String): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('jsonedit', [{ name: 'config.json', source: CONFIG }]);
		final path: String = '$dir/config.json';
		final rc: Int = Cli.run([args[0], path].concat(args.slice(1)).concat(['--write']));
		Assert.equals(0, rc, '${args.join(' ')} succeeds');
		Assert.equals(expected, File.getContent(path));
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

}
