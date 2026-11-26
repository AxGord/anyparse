package unit.dev;

import anyparse.grammar.haxe.query.HaxeQueryPlugin;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import dev.Decision;
import dev.TolerantPaths;
import sys.io.File;
import unit.cli.CliFixture;

using StringTools;

/**
 * The list of `TolerantPaths` stays honest: no test names a path of it, so no commit that touches only those paths can
 * change what a test reads. A test that does name one writes it into a scratch repository, never reads the real tree; it is
 * recorded here with that reason, and the record only shrinks.
 */
@:nullSafety(Strict)
final class TolerantPathsHonestyTest extends Test {

	/** This file: its literals are the list and the records themselves. */
	private static final SELF: String = 'test/unit/dev/TolerantPathsHonestyTest.hx';

	/** The test files that spell a tolerated path, each as a fixture of a scratch repository. */
	private static final FIXTURES: Array<String> = [
		'test/unit/dev/LandCandidateTest.hx',
		'test/unit/dev/LandProseTest.hx',
		'test/unit/dev/LandTolerantMainTest.hx',
		'test/unit/dev/TolerantPathsTest.hx'
	];

	/** The test files that name the ledger through `Decision.LEDGER`, each over a scratch repository. */
	private static final LEDGER_FIXTURES: Array<String> = ['test/unit/dev/DecisionTest.hx', 'test/unit/dev/MainCommitTest.hx'];

	/**
	 * The test files that spell the root of the docs tree: a category, a
	 * corpus directory or a scratch repository's, not a walk of the tree.
	 */
	private static final DOCS_ROOT: Array<String> = [
		'test/unit/check/RuleCategoryTest.hx',
		'test/unit/cli/LintCategoryCliTest.hx',
		'test/unit/dev/LandProseTest.hx',
		'test/unit/dev/MainCommitTest.hx',
		'test/unit/dev/TolerantPathsTest.hx',
		'test/unit/grammar/MermaidRoundTripTest.hx'
	];

	/** The spellings of a path by one of its parts, which a literal of the whole path would not catch. */
	private static final PARTS: Array<String> = ['journal', 'decisions.md', 'decisions'];

	@:pin('control')
	@:killer('M-TOLERANT-HONESTY-BLIND')
	public function testNoTestNamesATolerantPathBeyondTheRecordedFixtures(): Void {
		final spelled: Array<String> = [];
		for (path => literals in literalsOfTests()) for (text in literals) if (names(text)) {
			spelled.push(path);
			Assert.isTrue(
				FIXTURES.contains(path), '$path spells the tolerated path \'$text\': a test may read it, so it is no tolerated path'
			);
		}
		for (path in FIXTURES) Assert.isTrue(spelled.contains(path), '$path no longer spells a tolerated path - drop it from FIXTURES');
	}

	@:pin('control')
	@:killer('M-TOLERANT-HONESTY-LEDGER-BLIND')
	public function testNoTestNamesTheLedgerThroughItsConstantBeyondTheRecordedFixtures(): Void {
		final root: String = CliFixture.repoRoot();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final named: Array<String> = [];
		for (path in SourceTree.collect('$root/test')) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, File.getContent(path));
			Assert.notNull(tree, '$path parses');
			if (tree == null || path.endsWith(SELF)) continue;
			function visit(node: QueryNode): Void {
				if (node.name == 'LEDGER') named.push(path.substr(root.length + 1));
				for (child in node.children) visit(child);
			}
			visit(tree);
		}
		for (path in named) Assert.isTrue(LEDGER_FIXTURES.contains(path), '$path names `Decision.LEDGER`: a test reads the ledger');
		for (path in LEDGER_FIXTURES)
			Assert.isTrue(named.contains(path), '$path no longer names the ledger - drop it from LEDGER_FIXTURES');
		Assert.isTrue(TolerantPaths.covers(Decision.LEDGER), 'the ledger is the list\'s first path');
	}

	public function testTheRootOfTheDocsTreeIsSpelledOnlyWhereItIsNoWalkOfIt(): Void {
		final spelled: Array<String> = [];
		for (path => literals in literalsOfTests()) for (text in literals) if (text == 'docs' || text == 'docs/') {
			spelled.push(path);
			Assert.isTrue(DOCS_ROOT.contains(path), '$path spells \'$text\': a walk of docs/ would read the ledger and the journal');
		}
		for (path in DOCS_ROOT) Assert.isTrue(spelled.contains(path), '$path no longer spells the docs root - drop it from DOCS_ROOT');
	}

	/** Whether `text` holds a tolerated path, or is the directory or the file of one by its name alone. */
	private static function names(text: String): Bool {
		for (tolerated in TolerantPaths.PATHS) if (text.contains(tolerated) || text == tolerated.substr(0, tolerated.length - 1))
			return true;
		return PARTS.contains(text);
	}

	/** The raw text of every string literal of every test file, by path relative to the repository root. */
	private static function literalsOfTests(): Map<String, Array<String>> {
		final root: String = CliFixture.repoRoot();
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final literalKinds: Array<String> = plugin.refShape().stringLiteralKinds ?? [];
		final out: Map<String, Array<String>> = [];
		for (path in SourceTree.collect('$root/test')) {
			final raw: String = File.getContent(path);
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, raw);
			Assert.notNull(tree, '$path parses');
			if (tree == null || path.endsWith(SELF)) continue;
			final texts: Array<String> = [];
			function visit(node: QueryNode): Void {
				final span: Null<Span> = node.span;
				if (literalKinds.contains(node.kind) && span != null && span.to - span.from >= 2)
					texts.push(raw.substring(span.from + 1, span.to - 1));
				for (child in node.children) visit(child);
			}
			visit(tree);
			out[path.substr(root.length + 1)] = texts;
		}
		return out;
	}

}
