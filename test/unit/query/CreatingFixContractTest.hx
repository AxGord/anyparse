package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;
import anyparse.query.NewFile;
import anyparse.query.cli.CliIo;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The half of the fix contract a list of span edits cannot express: a fix that CREATES a file, and
 * the memo that has to let go of a chain such a fix rewrote.
 *
 * A create is refused where an edit is accepted and accepted where an edit is refused — the path
 * must not be there — and its text is settled at the writer's fixed point, so the next writer-emit
 * op on the created file does not call it drifted. Its undo is a DELETE, which no restore of previous
 * bytes can stand in for.
 */
@:nullSafety(Strict)
class CreatingFixContractTest extends Test {

	/** A module under a directory whose ambient source binds the type it extends. */
	private static final CHAIN_TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/aqq/Tqqwwee.hx', source: 'package aqq;\n\nclass Tqqwwee {}\n' },
		{ name: 'src/aqq/Uqqwwee.hx', source: 'package aqq;\n\nclass Uqqwwee {}\n' },
		{ name: 'src/lqq/import.hx', source: 'import aqq.Tqqwwee;\n' },
		{ name: 'src/lqq/Sqqwwee.hx', source: 'package lqq;\n\nclass Sqqwwee {}\n' }
	];

	/** A create refuses a path that is already there — the opposite refusal of an edit, and the reason it is its own member. */
	@:pin('guard')
	public function testACreateRefusesAPathThatIsAlreadyThere(): Void {
		Assert.isNull(CanonicalEdit.stageCrossFileCreates(
			[{ file: 'aqq/Zqqwwee.hx', text: 'import aqq.Tqqwwee;\n' }],
			_ -> true, (_, text) -> NewFile.createRaw(text, new HaxeQueryPlugin())
		));
	}

	/** The created text comes back at the writer's FIXED POINT, not as the caller spelled it. */
	@:pin('guard')
	public function testACreateSettlesItsTextAtTheWriterFixedPoint(): Void {
		final staged: Null<Array<{ file: String, source: String }>> = CanonicalEdit.stageCrossFileCreates(
			[{ file: 'lqq/import.hx', text: 'import   aqq.Tqqwwee;' }],
			_ -> false, (_, text) -> NewFile.createRaw(text, new HaxeQueryPlugin())
		);
		Assert.equals('import aqq.Tqqwwee;\n', staged == null ? 'REFUSED' : staged[0].source);
	}

	/** Content the writer cannot round-trip is refused whole, so a slice never half-creates. */
	@:pin('guard')
	public function testACreateRefusesContentTheWriterCannotSettle(): Void {
		Assert.isNull(CanonicalEdit.stageCrossFileCreates(
			[{ file: 'lqq/import.hx', text: 'import aqq.' }], _ -> false, (_, text) -> NewFile.createRaw(text, new HaxeQueryPlugin())
		));
	}

	/** The undo of a create is a DELETE, and a path already gone counts as deleted — a revert must not stop half way. */
	@:pin('guard')
	public function testDeletingACreatedFileToleratesOneAlreadyGone(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_create_delete', CHAIN_TREE);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final gone: Bool = CliIo.deletePath('$root/src/lqq/import.hx');
			out = '$gone|${sys.FileSystem.exists('$root/src/lqq/import.hx')}|${CliIo.deletePath('$root/src/lqq/import.hx')}';
		});
		Assert.equals('true|false|true', out);
		#else
		Assert.pass();
		#end
	}

	/**
	 * A pass answered from the chain a PREVIOUS pass wrote.
	 *
	 * One decorator instance serves every pass of a `--fix` run, so a memo taken before a pass created
	 * or rewrote an ambient source answers the tree that was — while the plugin behind the decorator
	 * reads the chain from disk fresh, which makes the stale memo a SECOND answer for one file.
	 */
	@:pin('control')
	@:killer('M-AMBIENT-CHAIN-STALE')
	public function testAPassSeesTheChainAPreviousPassWrote(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_chain_invalidate', CHAIN_TREE);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
			final module: String = '$root/src/lqq/Sqqwwee.hx';
			final first: String = chainText(cached, module);
			sys.io.File.saveContent('$root/src/lqq/import.hx', 'import aqq.Uqqwwee;\n');
			final memo: String = chainText(cached, module);
			final direct: String = chainText(new HaxeQueryPlugin(), module);
			cached.invalidateAmbientChain();
			out = '$first|$memo|$direct|${chainText(cached, module)}';
		});
		Assert.equals('aqq.Tqqwwee|aqq.Tqqwwee|aqq.Uqqwwee|aqq.Uqqwwee', out);
		#else
		Assert.pass();
		#end
	}

	/** The path the nearest ambient source of `module` imports, as the plugin answers it. */
	private static function chainText(plugin: GrammarPlugin, module: String): String {
		final sources: Array<AmbientImportSource> = plugin.ambientImportSources(module, 'lqq').sources;
		if (sources.length == 0) return 'NO CHAIN';
		final text: String = sources[0].source;
		return text.substring(text.indexOf(' ') + 1, text.indexOf(';')).trim();
	}

}
