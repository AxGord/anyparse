package unit.dev;

import anyparse.query.cli.CliRegistry;
import dev.ConfigKeys;
import dev.Dev;
import dev.DocsGen;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/** `dev docs-gen`: the guide's generated regions equal what the registries render, and a stale one is refused. */
@:nullSafety(Strict)
final class DocsGenTest extends Test {

	private static final BEGIN: String = '<!-- docs-gen:begin part -->';
	private static final END: String = '<!-- docs-gen:end part -->';

	@:pin('control')
	@:killer('M-DOCS-GEN-SECTIONS-RULE-OPTIONS-EMPTY')
	public function testEveryCommittedRegionIsTheGeneratedOne(): Void {
		Assert.same([], DocsGen.apply('.', DocsGen.sections(), false));
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-SPLICE-DROPS-TAIL')
	public function testASpliceReplacesOnlyItsRegion(): Void {
		final page: String = 'head\n$BEGIN\nold\n$END\ntail\n';
		Assert.equals('head\n$BEGIN\nnew\n$END\ntail\n', DocsGen.splice(page, 'part', 'new\n'));
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-SPLICE-NO-MARKER-ACCEPTED')
	public function testAPageWithoutTheMarkersIsRefused(): Void {
		Assert.raises(DocsGen.splice.bind('no markers here\n', 'part', 'x\n'), Exception);
		Assert.raises(() -> DocsGen.splice('$END\n$BEGIN\n', 'part', 'x\n'), Exception);
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-CHECK-WRITES')
	public function testACheckNamesTheStalePageAndWritesNothing(): Void {
		TempDir.with(dir -> {
			final page: String = Path.join([dir.path, 'page.md']);
			File.saveContent(page, '$BEGIN\nstale\n$END\n');
			final all: Array<GeneratedSection> = [{ path: 'page.md', name: 'part', body: 'fresh\n' }];
			Assert.same(['page.md'], DocsGen.apply(dir.path, all, false));
			Assert.equals('$BEGIN\nstale\n$END\n', File.getContent(page));
			Assert.same(['page.md'], DocsGen.apply(dir.path, all, true));
			Assert.equals('$BEGIN\nfresh\n$END\n', File.getContent(page));
		});
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-CURRENT-PAGE-REPORTED')
	public function testACurrentPageIsNotReported(): Void {
		TempDir.with(dir -> {
			File.saveContent(Path.join([dir.path, 'page.md']), '$BEGIN\nfresh\n$END\n');
			final all: Array<GeneratedSection> = [{ path: 'page.md', name: 'part', body: 'fresh\n' }];
			Assert.same([], DocsGen.apply(dir.path, all, false));
		});
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-TWO-REGIONS-ONE-PAGE')
	public function testTwoRegionsOfOnePageAreBothWritten(): Void {
		TempDir.with(dir -> {
			final page: String = Path.join([dir.path, 'page.md']);
			File.saveContent(page, '$BEGIN\n$END\n<!-- docs-gen:begin more -->\n<!-- docs-gen:end more -->\n');
			final all: Array<GeneratedSection> = [
				{ path: 'page.md', name: 'part', body: 'one\n' },
				{ path: 'page.md', name: 'more', body: 'two\n' }
			];
			Assert.same(['page.md'], DocsGen.apply(dir.path, all, true));
			Assert.equals('$BEGIN\none\n$END\n<!-- docs-gen:begin more -->\ntwo\n<!-- docs-gen:end more -->\n', File.getContent(page));
		});
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-COMMAND-FLAGS-DROPPED')
	public function testTheCommandTableListsEachCommandWithItsFlags(): Void {
		final table: String = DocsGen.commandTable(CliRegistry.commands());
		final refs: Null<String> = table.split('\n').find(row -> row.startsWith('| `refs` |'));
		Assert.notNull(refs);
		Assert.stringContains('`--decls`', refs ?? '');
		Assert.stringContains(CliRegistry.find('refs')?.summary() ?? '?', refs ?? '');
		Assert.equals(CliRegistry.commands().length + 2, table.split('\n').filter(row -> row.startsWith('|')).length);
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-RULE-WITHOUT-OPTIONS-LISTED')
	public function testTheRuleTableListsOnlyRulesThatReadOptions(): Void {
		final table: String = DocsGen.ruleOptionTable(['import-order' => ['order', 'usingAfterImports'], 'unused-import' => []]);
		Assert.stringContains('| `import-order` | `imports` | `order` `usingAfterImports` |', table);
		Assert.isFalse(table.contains('`unused-import`'));
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-CONFIG-KEY-TYPE-FLATTENED')
	public function testTheConfigKeysComeFromTheTypedSchemaWithSimpleTypeNames(): Void {
		final keys: Array<ConfigKey> = ConfigKeys.declared();
		Assert.isTrue(keys.exists(key -> key.name == 'rules' && key.type == 'Map<String, JValue>'));
		Assert.isTrue(keys.exists(key -> key.name == 'inherit' && key.type == 'Bool'));
	}

	@:pin('control')
	@:killer('M-DOCS-GEN-MAIN-NEVER-WRITES')
	public function testTheCommandWritesThenChecksItsPages(): Void {
		TempDir.with(dir -> {
			for (section in DocsGen.sections()) {
				final path: String = Path.join([dir.path, section.path]);
				FileSystem.createDirectory(Path.directory(path));
				File.saveContent(path, '<!-- docs-gen:begin ${section.name} -->\nstale\n<!-- docs-gen:end ${section.name} -->\n');
			}
			Assert.equals(1, Dev.run(['docs-gen', '--check', '--root', dir.path]));
			Assert.equals(0, Dev.run(['docs-gen', '--root', dir.path]));
			Assert.equals(0, Dev.run(['docs-gen', '--check', '--root', dir.path]));
		});
	}

}
