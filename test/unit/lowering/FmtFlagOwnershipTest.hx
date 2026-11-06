package unit.lowering;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;

using StringTools;

/**
 * The `@:fmt` ownership pin — `docs/strategies.md` against the macro package.
 *
 * `@:fmt` has no dispatcher. A grammar DECLARES a flag on a rule type or a field and the
 * macro ASKS FOR it at the point in an emit body that cares, so the two halves are
 * independent declarations that nothing forces to agree. Both directions of disagreement
 * are silent: a flag no module names is an INERT declaration (the grammar says something
 * and the writer does not listen), and a flag a module names that no grammar declares is a
 * handler with no caller. Neither is a compile error, neither shows in the corpus, and the
 * inventory in `docs/strategies.md` was written from the DECLARED side only — which is how
 * it came to be missing `clearBracePolicy`, a flag declared twice and read once.
 *
 * So the guard compares the doc against a scan of `src/anyparse/macro`, and the scan is
 * deliberately COARSE: any string literal in a macro module whose text equals an inventory
 * name counts as that module naming the flag. A flag reaches its handler as a literal
 * argument (`fmtHasFlag('nestBody')`), as an element of a candidate array
 * (`firstFmtFlag(node, ['functionTypeHaxe3', 'intervalPolicy'])`), through a module
 * constant, and through a `flagNames` parameter one call further out — a scan that follows
 * only the first shape reports 39 false inert flags, which is what a narrower first
 * version of this test did. Over-approximating "names it" keeps every claim here on the
 * safe side: the test can fail to notice a dead handler, it cannot invent one.
 *
 * The per-module flag NAMES are the second half, and they are what makes this a guard on the
 * MODULE BOUNDARIES rather than only on the vocabulary: fold `WriterPolicyLowering` back
 * into `WriterLowering` and the module list and two name sets change, with the failure
 * naming the module. The record is `test/testkit/fmt-ownership.json`, one name per line;
 * `APQ_OWNERSHIP_RECORD=1` rewrites it from the scan.
 */
class FmtFlagOwnershipTest extends Test {

	/** `MetaInspect` declares the readers themselves, so its parameter names are not flag reads. */
	private static inline final READER_MODULE: String = 'MetaInspect';

	private static inline final MACRO_DIR: String = 'src/anyparse/macro';
	private static inline final STRATEGIES_DOC: String = 'docs/strategies.md';

	/** Below this the inventory block was emptied or mis-parsed, and every set comparison would pass vacuously. */
	private static inline final MIN_INVENTORY_FLAGS: Int = 200;

	/** Per module, the flag NAMES it reads, one per line, so two branches adding different flags merge without a conflict. */
	private static inline final RECORD_FILE: String = 'test/testkit/fmt-ownership.json';

	/** Set to `1` to rewrite `RECORD_FILE` from the scan. */
	private static inline final RECORD_ENV: String = 'APQ_OWNERSHIP_RECORD';

	/**
	 * Flags a module names that no shipped grammar declares — a handler standing ready for
	 * a grammar that has not asked yet. They are deliberately OUT of the inventory (which
	 * is the declared-side list), and pinned here so the same reading also covers a handler
	 * whose grammar declaration was deleted.
	 */
	private static final HANDLER_ONLY_FLAGS: Array<String> = [
		'blankLinesBeforeCtor',
		'blankLinesBeforeCtorIf',
		'fill',
		'fillDoubleIndent'
	];

	/**
	 * Every flag the shipped grammars declare is named by at least one macro module.
	 *
	 * The direction that catches an INERT declaration: a grammar keeps carrying
	 * `@:fmt(someFlag)` after the handler that read it was deleted, and the only symptom is
	 * layout that silently stops responding to the annotation.
	 */
	public function testEveryDeclaredFlagIsNamedBySomeMacroModule(): Void {
		final root: String = CliFixture.repoRoot();
		final inventory: Array<String> = inventoryFlags(root);
		Assert.isTrue(
			inventory.length >= MIN_INVENTORY_FLAGS,
			'the @:fmt inventory block in $STRATEGIES_DOC parsed as ${inventory.length} flags - '
			+ 'below $MIN_INVENTORY_FLAGS the comparisons below would pass vacuously'
		);
		final named: Map<String, Array<String>> = ownershipScan(root, inventory);
		final all: Array<String> = [];
		for (flags in named) for (flag in flags) if (!all.contains(flag)) all.push(flag);
		for (flag in inventory)
			Assert.isTrue(
				all.contains(flag),
				'@:fmt($flag) is declared by a grammar and named by no module under $MACRO_DIR - '
				+ 'the declaration is inert: delete it, or restore the handler that read it'
			);
	}

	/**
	 * The record names exactly the modules that name a flag, with exactly the flags the scan
	 * gives.
	 *
	 * This is the module-boundary half: moving a handler between modules, or folding one
	 * back in, changes a name set here before it changes anything else observable.
	 */
	public function testOwnershipRecordMatchesTheMacroPackage(): Void {
		final root: String = CliFixture.repoRoot();
		final named: Map<String, Array<String>> = ownershipScan(root, inventoryFlags(root));
		final path: String = '$root/$RECORD_FILE';
		if (Sys.getEnv(RECORD_ENV) == '1') {
			File.saveContent(path, renderRecord(named));
			Assert.pass();
			return;
		}
		final recorded: Map<String, Array<String>> = readRecord(path);
		final modules: Array<String> = [for (module in named.keys()) module];
		for (module in recorded.keys()) if (!modules.contains(module)) modules.push(module);
		modules.sort(compareStrings);
		for (module in modules) {
			final actual: Array<String> = named[module] ?? [];
			final expected: Array<String> = recorded[module] ?? [];
			final added: Array<String> = [for (flag in actual) if (!expected.contains(flag)) flag];
			final lost: Array<String> = [for (flag in expected) if (!actual.contains(flag)) flag];
			Assert.isTrue(
				added.length == 0 && lost.length == 0,
				'$MACRO_DIR/$module.hx: names [${added.join(', ')}] that $RECORD_FILE lacks, '
				+ 'and [${lost.join(', ')}] that it no longer names - re-record with $RECORD_ENV=1'
			);
		}
	}

	/**
	 * The handler-only flags are still named by a module and still absent from the
	 * inventory.
	 *
	 * Either half moving is a real event: a grammar starting to declare one means it
	 * belongs in the inventory, and a handler losing its last mention means the flag is
	 * gone entirely.
	 */
	public function testHandlerOnlyFlagsAreNamedButUndeclared(): Void {
		final root: String = CliFixture.repoRoot();
		final inventory: Array<String> = inventoryFlags(root);
		final named: Map<String, Array<String>> = ownershipScan(root, HANDLER_ONLY_FLAGS);
		final all: Array<String> = [];
		for (flags in named) for (flag in flags) if (!all.contains(flag)) all.push(flag);
		for (flag in HANDLER_ONLY_FLAGS) {
			Assert.isTrue(
				all.contains(flag),
				'no module under $MACRO_DIR names $flag any more - the handler is gone, drop it from '
				+ 'HANDLER_ONLY_FLAGS and from $STRATEGIES_DOC'
			);
			Assert.isFalse(
				inventory.contains(flag),
				'$flag is now in the declared inventory - move it out of the handler-only list here and in $STRATEGIES_DOC'
			);
		}
	}

	/**
	 * The flag names inside the fenced block that follows `**The inventory.**` in
	 * `docs/strategies.md`, with the `(…)` / `[(…)]` argument markers stripped.
	 */
	private function inventoryFlags(root: String): Array<String> {
		final doc: String = File.getContent('$root/$STRATEGIES_DOC');
		final marker: Int = doc.indexOf('**The inventory.**');
		if (marker < 0) return [];
		final open: Int = doc.indexOf('```', marker);
		if (open < 0) return [];
		final start: Int = doc.indexOf('\n', open) + 1;
		final close: Int = doc.indexOf('```', start);
		if (close < 0) return [];
		final out: Array<String> = [];
		for (word in doc.substring(start, close).split(',')) {
			final name: String = identifierHead(word);
			if (name != '' && !out.contains(name)) out.push(name);
		}
		return out;
	}

	/** The leading `[A-Za-z_]\w*` of a trimmed inventory entry, or `''` when it has none. */
	private function identifierHead(word: String): String {
		final text: String = word.trim();
		var end: Int = 0;
		while (end < text.length) {
			final c: Int = text.fastCodeAt(end);
			final head: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
			if (!head && !(end > 0 && c >= '0'.code && c <= '9'.code)) break;
			end++;
		}
		return text.substring(0, end);
	}

	/**
	 * Per macro module, which of `flags` its string literals name.
	 *
	 * The literals come from the project's own parser rather than a text scan: a
	 * `@:fmt`-flag literal can sit anywhere an `Expr` can, and the raw span minus its quotes
	 * is the only reading that does not also match the same word inside a doc comment or a
	 * diagnostic message.
	 */
	private function ownershipScan(root: String, flags: Array<String>): Map<String, Array<String>> {
		final out: Map<String, Array<String>> = [];
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final kinds: Array<String> = plugin.refShape().stringLiteralKinds ?? [];
		for (entry in FileSystem.readDirectory('$root/$MACRO_DIR')) if (entry.endsWith('.hx')) {
			final module: String = entry.substring(0, entry.length - '.hx'.length);
			if (module == READER_MODULE) continue;
			final raw: String = File.getContent('$root/$MACRO_DIR/$entry');
			final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, raw);
			Assert.notNull(tree, '$MACRO_DIR/$entry no longer parses - the scan below would silently report it as naming nothing');
			if (tree == null) continue;
			final found: Array<String> = [];
			collectFlagLiterals(tree, raw, kinds, flags, found);
			if (found.length > 0) out[module] = found;
		}
		return out;
	}

	/** Walks `node`, pushing every `flags` member spelled by a string literal into `found`. */
	private function collectFlagLiterals(
		node: QueryNode, raw: String, kinds: Array<String>, flags: Array<String>, found: Array<String>
	): Void {
		final span: Null<Span> = node.span;
		if (span != null && kinds.contains(node.kind)) {
			final text: String = raw.substring(span.from + 1, span.to - 1);
			if (flags.contains(text) && !found.contains(text)) found.push(text);
		}
		for (child in node.children) collectFlagLiterals(child, raw, kinds, flags, found);
	}

	private static function compareStrings(a: String, b: String): Int {
		return if (a < b)
			-1
		else if (a > b)
			1
		else
			0;
	}

	private static function readRecord(path: String): Map<String, Array<String>> {
		final out: Map<String, Array<String>> = [];
		if (!FileSystem.exists(path)) return out;
		final record: FmtOwnershipRecord = FmtOwnershipRecordParser.parse(File.getContent(path));
		for (module => flags in record.modules) out[module] = switch flags {
			case JArray(items): [
				for (item in items) switch item {
					case JString(name): name;
					case _: throw 'fmt-ownership record: a flag of "$module" is not a string';
				}
			];
			case _: throw 'fmt-ownership record: "$module" is not an array';
		};
		return out;
	}

	private static function renderRecord(named: Map<String, Array<String>>): String {
		final modules: Array<String> = [for (module in named.keys()) module];
		modules.sort(compareStrings);
		final blocks: Array<String> = [];
		for (module in modules) {
			final flags: Array<String> = named[module] ?? [];
			flags.sort(compareStrings);
			blocks.push('\t"$module": [\n' + flags.map(flag -> '\t\t"$flag"').join(',\n') + '\n\t]');
		}
		return '{\n"modules": {\n' + blocks.join(',\n') + '\n}\n}\n';
	}

}
