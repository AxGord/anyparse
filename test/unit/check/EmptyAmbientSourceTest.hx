package unit.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.EmptyAmbientSource;
import unit.cli.CliFixture;

/**
 * `empty-ambient-source` — an ambient import source binding nothing is reported, and deleted when nothing
 * but whitespace is in it. Every fixture is a tree on disk: whether a file IS an ambient source is the
 * grammar's governance seam, which reads the directory.
 */
@:nullSafety(Strict)
class EmptyAmbientSourceTest extends Test {

	/** A blank ambient source is reported. */
	@:pin('control')
	@:killer('M-EMPTY-AMBIENT-NEVER')
	public function testFlagsABlankAmbientSource(): Void {
		Assert.equals('src/aqq/import.hx:delete it', verdicts('\n'));
	}

	/** One carrying comments only is reported too, as a deletion left to a human. */
	@:pin('control')
	@:killer('M-EMPTY-AMBIENT-NEVER')
	public function testFlagsACommentOnlySourceForAHuman(): Void {
		Assert.equals('src/aqq/import.hx:delete it by hand', verdicts('// shared imports\n/* none yet */\n'));
	}

	/** A source with a conditional block in it is not empty, whatever the block holds. */
	@:pin('guard')
	public function testAConditionalBlockIsNotEmpty(): Void {
		Assert.equals('', verdicts('#if js\n#end\n'));
	}

	/** A source with a statement in it binds something. */
	@:pin('guard')
	public function testASourceWithAStatementIsNotEmpty(): Void {
		Assert.equals('', verdicts('import aqq.Oneqq;\n'));
	}

	/** A blank MODULE is no ambient source and is somebody else's finding. */
	@:pin('guard')
	public function testABlankModuleIsNotAnAmbientSource(): Void {
		Assert.equals('', verdicts('import aqq.Oneqq;\n', '\n'));
	}

	/** The fix deletes the blank source, and only that one. */
	@:pin('control')
	@:killer('M-EMPTY-AMBIENT-KEEPS')
	public function testTheFixDeletesABlankSource(): Void {
		Assert.equals('src/aqq/import.hx:remove', fixed('\n'));
	}

	/** A comment-only source is never deleted: its comments would go with it. */
	@:pin('guard')
	public function testTheFixKeepsACommentOnlySource(): Void {
		Assert.equals('', fixed('// shared imports\n'));
	}

	/** Every finding over a tree whose ambient source is `ambient`, as `<file>:<the message's last clause>`. */
	private static function verdicts(ambient: String, ?module: String): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_empty_ambient', treeOf(ambient, module));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			out = [
				for (v in CheckFixture.violationsIn(new EmptyAmbientSource(), filesOf(root, ambient, module), new HaxeQueryPlugin()))
					'${v.file.substr(root.length + 1)}:${v.message.substr(v.message.lastIndexOf('— ') + 2)}'
			].join(',');
		});
		return out;
		#else
		return '';
		#end
	}

	/** Every slice the fix writes over that tree, as `<file>:remove` or `<file>:edit`. */
	private static function fixed(ambient: String): String {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_empty_ambient_fix', treeOf(ambient, null));
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final files: Array<{ file: String, source: String }> = filesOf(root, ambient, null);
			final rule: EmptyAmbientSource = new EmptyAmbientSource();
			final found: Array<Violation> = CheckFixture.violationsIn(rule, files, new HaxeQueryPlugin());
			final slices: Array<Array<CrossFileEdits>> = rule.crossFileFix(files, found, new HaxeQueryPlugin());
			out = [
				for (slice in slices) for (part in slice) '${part.file.substr(root.length + 1)}:${part.remove == true ? 'remove' : 'edit'}'
			].join(',');
		});
		return out;
		#else
		return '';
		#end
	}

	/** The tree: an ambient source over two modules, the second one `module` when given. */
	private static function treeOf(ambient: String, module: Null<String>): Array<{ name: String, source: String }> {
		return [
			{ name: 'src/aqq/import.hx', source: ambient },
			{ name: 'src/aqq/Oneqq.hx', source: 'package aqq;\n\nclass Oneqq {}\n' },
			{ name: 'src/aqq/Twoqq.hx', source: module ?? 'package aqq;\n\nclass Twoqq {}\n' }
		];
	}

	/** The run's file set over that tree. */
	private static function filesOf(root: String, ambient: String, module: Null<String>): Array<{ file: String, source: String }> {
		return [
			for (entry in treeOf(ambient, module)) { file: '$root/${entry.name}', source: entry.source }
		];
	}

}
