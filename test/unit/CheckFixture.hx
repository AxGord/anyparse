package unit;

import anyparse.check.Check;
import anyparse.check.LintConfig;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CachingGrammarPlugin.ResolutionScope;
import anyparse.query.CanonicalEdit;
import anyparse.query.GrammarPlugin;
import anyparse.query.IndexScope;
import anyparse.query.SymbolIndex;
import anyparse.query.cli.command.LintCommand;
import anyparse.runtime.Span;
import utest.Assert;

using Lambda;

/**
 * Shared in-memory harness for the analysis-check test suites.
 *
 * A check test exercises `run` on an inline source and then, for a fixable check,
 * applies `fix`'s edits back onto that source and asserts the rewritten text. Both
 * halves are the same two moves in every suite — order the edits last-first so an
 * earlier span keeps its offsets, then splice them in — so they live here once
 * instead of once per test class.
 */
@:nullSafety(Strict)
final class CheckFixture {

	/**
	 * The two characters that close a `final e = macro …;` quotation — where the runtime half of a
	 * gate fixture begins. The LAST occurrence is the threshold: a `};` can legitimately appear
	 * INSIDE the quotation (an object literal, a nested lambda), never in the runtime half of the
	 * fixtures this serves, so `lastIndexOf` keeps the assertion tight where `indexOf` would let a
	 * quoted finding past an early inner `};`.
	 */
	private static inline final QUOTATION_END: String = '};';

	/**
	 * The run host every production lint goes through: a `CachingGrammarPlugin` (the `SymbolIndexHost`) over the
	 * Haxe plugin, carrying `resolution` when given and no resolution scope otherwise. A test that needs the plugin
	 * itself — to build an index beside the run, to read a tree — asks for this one and passes it on.
	 */
	public static function host(?resolution: ResolutionScope): CachingGrammarPlugin {
		return LintCommand.wrapResolution(new HaxeQueryPlugin(), resolution);
	}

	/**
	 * `check`'s findings over `source` as `C.hx`, read the way production reads them: through `Linter.collect`
	 * (the reification and suppression gates) on a run host. `plugin` defaults to a fresh `host()`; a plugin
	 * that is not already a host is wrapped in one, as `Linter.run` does.
	 */
	public static function violations(check: Check, source: String, ?plugin: GrammarPlugin): Array<Violation> {
		return violationsIn(check, [{ file: 'C.hx', source: source }], plugin);
	}

	/**
	 * `violations` over a whole file set. `resolveConfig`, when given, is the per-file config the run reads, as
	 * `Linter.run` hands it: set on a `ConfigAware` check AND passed to `collect`, whose `FileGated` and
	 * `languageVersion` gates read the same answer. Enablement is not applied — the test selected the check, as
	 * `--rule` does.
	 */
	public static function violationsIn(
		check: Check, files: Array<{ file: String, source: String }>, ?plugin: GrammarPlugin, ?resolveConfig: (String) -> LintConfig
	): Array<Violation> {
		if (resolveConfig != null && check is ConfigAware) (cast check: ConfigAware).setConfigResolver(resolveConfig);
		return Linter.collect(files, hosted(plugin), [check], resolveConfig, false);
	}

	/**
	 * One `run` + `fix` pass the way `lint --fix` makes it: the findings `violationsIn` reads over `files`, and
	 * `check.fix` over the findings in `file` (default: the first file) with the same host and the REPORT index
	 * of `files` — the index `LintFixDriver` hands every fix.
	 */
	public static function fixRun(
		check: Check, files: Array<{ file: String, source: String }>, ?file: String, ?plugin: GrammarPlugin,
		?resolveConfig: (String) -> LintConfig
	): FixRun {
		final run: GrammarPlugin = hosted(plugin);
		final target: String = file ?? files[0].file;
		final source: Null<String> = files.find(f -> f.file == target)?.source;
		if (source == null) throw 'fixRun: "$target" is not in the file set';
		final found: Array<Violation> = violationsIn(check, files, run, resolveConfig).filter(v -> v.file == target);
		return { violations: found, edits: check.fix(source, found, run, IndexScope.report(files, run)) };
	}

	/**
	 * `check.fix` over `found` — findings already read for `source` as `C.hx` — handed a run host and the
	 * report index of that one file, the way `LintFixDriver` hands them. For a test that reads the findings
	 * first and picks which of them to fix.
	 */
	public static function fixOf(check: Check, source: String, found: Array<Violation>, ?plugin: GrammarPlugin): Array<FixEdit> {
		final run: GrammarPlugin = hosted(plugin);
		return check.fix(source, found, run, IndexScope.report([{ file: 'C.hx', source: source }], run));
	}

	/** `fixRun`'s edits for `source` as `C.hx`. */
	public static function edits(check: Check, source: String, ?plugin: GrammarPlugin): Array<FixEdit> {
		return fixRun(check, [{ file: 'C.hx', source: source }], plugin).edits;
	}

	/**
	 * `source` after `check`'s fix, the edits spliced by `CanonicalEdit.applyEdits` — the one splice every
	 * `--fix` path uses.
	 */
	public static function fixedSource(check: Check, source: String, ?plugin: GrammarPlugin): String {
		return CanonicalEdit.applyEdits(source, edits(check, source, plugin));
	}

	/**
	 * `source` after `check`'s fix, finished through `CanonicalEdit.canonicalize` the way a written fix is
	 * (`reformat` canonicalises the whole file); a refusal throws its message.
	 */
	public static function canonicalFixed(
		check: Check, source: String, reformat: Bool = true, ?optsJson: String, ?plugin: GrammarPlugin
	): String {
		final run: GrammarPlugin = hosted(plugin);
		return switch CanonicalEdit.canonicalize(source, edits(check, source, run), reformat, run, optsJson) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

	/**
	 * The `SymbolIndex` over `files` (third-party files tagged as given), asked of the run host the way a rule asks one
	 * (`IndexScope.over`; `report` when no third-party set is named) — the one door a test takes to an index it hands a
	 * check, a fix or a query, so no test builds one by a path the tool itself never takes.
	 */
	public static function index(
		files: Array<{ file: String, source: String }>, ?plugin: GrammarPlugin, ?thirdPartyFiles: Array<String>
	): SymbolIndex {
		return IndexScope.over(files, hosted(plugin), thirdPartyFiles);
	}

	/**
	 * Assert that `violations` is exactly ONE finding and that it sits AFTER the macro quotation
	 * `source` opens with — the discriminating half of the reification-gate pair the switch-family
	 * checks carry. `source` is a fixture whose trigger shape appears TWICE, once quoted and once as
	 * real code; a check that still descends into the quotation reports both, so the count alone
	 * fails, and a check that reports the wrong one fails the position. `what` names the construct
	 * for the failure message.
	 */
	public static function assertOnlyAfterQuotation(violations: Array<Violation>, source: String, what: String): Void {
		Assert.equals(1, violations.length);
		final span: Null<Span> = violations[0].span;
		Assert.isTrue(
			span != null && span.from > source.lastIndexOf(QUOTATION_END), 'the finding must be the RUNTIME $what, not the quoted one'
		);
	}

	/**
	 * `source` as `C.hx` beside a stand-in for the Haxe std the CLI's implicit resolution scope
	 * carries — the declarations a null proof has to RESOLVE a written `String` or `haxe.io.Eof`
	 * to, since a type proves non-null only through the declaration its name reaches. Neither stub
	 * file holds a construct any null-aware check reports.
	 */
	public static function withStd(source: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'C.hx', source: source },
			{
				file: 'String.hx',
				source: 'extern class String { var length(default, null):Int; function charAt(index:Int):String; '
					+ 'function toString():String; }'
			},
			{ file: 'haxe/io/Eof.hx', source: 'package haxe.io; class Eof { public function new() {} }' }
		];
	}

	/** `plugin` as a run host: itself when it already is one, else wrapped the way `Linter.run` wraps it. */
	private static function hosted(?plugin: GrammarPlugin): GrammarPlugin {
		return plugin == null ? host() : plugin is CachingGrammarPlugin ? plugin : new CachingGrammarPlugin(plugin);
	}

}

/**
 * One `run` + `fix` pass over a fixture, both halves kept: a test reading the decline reasons the
 * fix wrote needs the very `Violation` objects the edits came from.
 */
typedef FixRun = {
	final violations: Array<Violation>;
	final edits: Array<FixEdit>;
};
