package unit.query;

import anyparse.query.GrammarPlugin;
import unit.cli.CliFixture;

/**
 * The names-first governance answer lists the modules an ambient source governs without opening
 * one, and agrees with the text answer on which they are.
 */
@:nullSafety(Strict)
class AmbientGovernedFilesTest extends Test {

	/** A source and the three modules it governs, one below a nested directory. */
	private static final TREE: Array<{ name: String, source: String }> = [
		{ name: 'src/gnn/import.hx', source: 'import haxe.io.Path;\n' },
		{ name: 'src/gnn/Ann.hx', source: 'package gnn;\n\nclass Ann {}\n' },
		{ name: 'src/gnn/Bnn.hx', source: 'package gnn;\n\nclass Bnn {}\n' },
		{ name: 'src/gnn/sub/Cnn.hx', source: 'package gnn.sub;\n\nclass Cnn {}\n' }
	];

	/** A module the names-first answer cannot open is still named: it reads no module text. */
	@:pin('control')
	@:killer('M-AMBIENT-NAMES-READS-TEXT')
	public function testANamesOnlyAnswerReadsNoModuleText(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_govern_names_unread', TREE);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final locked: String = '$root/src/gnn/Bnn.hx';
			Sys.command('chmod', ['000', locked]);
			final names: Null<AmbientImportGovernedFiles> = new HaxeQueryPlugin().ambientImportGovernedFiles('$root/src/gnn/import.hx');
			Sys.command('chmod', ['644', locked]);
			out = names == null ? 'NONE' : '${names.bounded}:${names.files.contains(locked)}';
		});
		Assert.equals('true:true', out);
		#else
		Assert.pass();
		#end
	}

	/** The text answer, built on the same names, carries the texts it always did and the names agree. */
	@:pin('guard')
	public function testTheTextAnswerKeepsItsTextsAndTheNamesAgree(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.writeTree('apq_govern_names_texts', TREE);
		var out: String = '';
		CliFixture.always(CliFixture.removeDir.bind(root), () -> {
			final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
			final source: String = '$root/src/gnn/import.hx';
			final texts: Null<AmbientImportGovernance> = plugin.ambientImportGovernance(source);
			final names: Null<AmbientImportGovernedFiles> = plugin.ambientImportGovernedFiles(source);
			if (texts == null || names == null) {
				out = 'NONE';
				return;
			}
			final expected: Array<String> = [
				for (entry in TREE) if (entry.name != 'src/gnn/import.hx') '$root/${entry.name}:${entry.source}'
			];
			final seen: Array<String> = texts.governs.map(entry -> '${entry.file}:${entry.source}');
			expected.sort(anyparse.util.Compare.compareString);
			seen.sort(anyparse.util.Compare.compareString);
			final sameNames: Bool = texts.governs.map(entry -> entry.file).join(';') == names.files.join(';');
			out = '${expected.join('|') == seen.join('|')}:$sameNames:${texts.bounded}:${names.bounded}';
		});
		Assert.equals('true:true:true:true', out);
		#else
		Assert.pass();
		#end
	}

	/** An ordinary module governs nothing, in both answers. */
	@:pin('guard')
	public function testAnOrdinaryModuleGovernsNothing(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.isNull(plugin.ambientImportGovernedFiles('src/gnn/Ann.hx'));
		Assert.isNull(plugin.ambientImportGovernance('src/gnn/Ann.hx'));
	}

}
