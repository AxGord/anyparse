package unit.query;

import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import sys.io.File;
import unit.cli.CliFixture;

using Lambda;
using StringTools;

/**
 * The Haxe compiler oracle (`anyparse.check.haxe.oracle`) and the typed facts built on it (`anyparse.check.haxe.facts`) are reached
 * from generic code only through the `OracleProvider` door. A module outside `check/haxe` and `grammar/haxe` that imports
 * one of them names the Haxe compiler where a language-neutral layer stands.
 *
 * Both pins are `guard`s: what a module imports is the text of the source, which no cut of a compiled type changes.
 */
@:nullSafety(Strict)
final class OracleImportOwnerGuardTest extends Test {

	/** The layer swept, relative to the repository root. */
	private static final LAYER: String = 'src/anyparse';

	/** The directories that may import the Haxe oracle: the Haxe language packages. */
	private static final OWNERS: Array<String> = ['check/haxe/', 'grammar/haxe/'];

	/** The packages only the owners may import from. */
	private static final GUARDED: Array<String> = ['anyparse.check.haxe.oracle.', 'anyparse.check.haxe.facts.'];

	/** The statement kinds whose node name is the path they bring in. */
	private static final PATH_KINDS: Array<String> = ['ImportDecl', 'ImportWildDecl', 'UsingDecl', 'UsingWildDecl'];

	@:pin('guard')
	public function testOnlyTheHaxeOraclesOwnersImportTheHaxeOracle(): Void {
		final root: String = CliFixture.repoRoot();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final found: Array<String> = [];
		for (path in SourceTree.collect('$root/$LAYER').map(p -> p.substr(root.length + LAYER.length + 2))) if (!OWNERS.exists(owner ->
			path.startsWith(owner)
		)) {
			final source: String = File.getContent('$root/$LAYER/$path');
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
			if (tree == null) {
				found.push('$path does not parse, so its imports are unread');
				continue;
			}
			for (name in guardedImports(tree)) found.push('$path imports $name');
		}
		Assert.equals('', found.join('\n'), 'ask the module\'s OracleProvider instead of naming the Haxe oracle');
	}

	@:pin('guard')
	public function testEveryStatementNamingAGuardedPackageIsReportedAndAnotherIsNot(): Void {
		final source: String = 'package a;\nimport anyparse.check.haxe.oracle.OracleCoverage;\n'
			+ 'import anyparse.check.haxe.facts.TypedFactsProbe;\nimport anyparse.check.haxe.oracle.*;\n'
			+ 'using anyparse.check.haxe.facts.TypedFactsProbe;\nusing anyparse.check.haxe.facts.*;\n'
			+ 'import anyparse.check.haxe.oracle.CompilerOracle as Compiler;\n'
			+ 'import anyparse.check.haxe.oracle.CompilerOracle in Compiler2;\n'
			+ 'import anyparse.check.LintConfig.OracleConfig;\nimport anyparse.query.OracleProvider;\nclass C {}';
		final tree: Null<QueryNode> = ParseGate.parseOrNull(new HaxeQueryPlugin(), source);
		Assert.notNull(tree);
		if (tree == null) return;
		Assert.same([
			'anyparse.check.haxe.oracle.OracleCoverage',
			'anyparse.check.haxe.facts.TypedFactsProbe',
			'anyparse.check.haxe.oracle.*',
			'anyparse.check.haxe.facts.TypedFactsProbe',
			'anyparse.check.haxe.facts.*',
			'anyparse.check.haxe.oracle.CompilerOracle',
			'anyparse.check.haxe.oracle.CompilerOracle'
		], guardedImports(tree));
	}

	/**
	 * The paths of the statements of `tree` that name a guarded package, in source order. An alias import keeps only its
	 * alias as the node's name, so its path is the node's `target`.
	 */
	private static function guardedImports(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		function visit(node: QueryNode): Void {
			final path: Null<String> = node.target ?? (PATH_KINDS.contains(node.kind) ? node.name : null);
			if (path != null && GUARDED.exists(prefix -> path.startsWith(prefix))) out.push(path);
			for (child in node.children) visit(child);
		}
		visit(tree);
		return out;
	}

}
