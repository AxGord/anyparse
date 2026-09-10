package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.query.GrammarPlugin;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a DOC BLOCK longer than the maximum the project declares — the length at which a
 * contract has stopped being one and become a document. `Severity.Info`.
 *
 * A doc block states what a reader may rely on, in a sentence or three. Past that it is prose
 * with a different owner: a rationale belongs in `docs/`, a chronicle in the commit that made
 * it, and neither survives the next edit of the code it sits above — a document nothing gates
 * rots in place, and a reader who stops trusting one stops reading all of them.
 *
 * ## Doc blocks only
 *
 * A `//` run and a plain `/* … *\/` banner are left alone whatever their length. The doc block
 * is the declared contract surface — the thing a reader arrives at through a type or a member —
 * while a run of line comments belongs to the statements it stands over and is measured by the
 * rules that own that shape. Widening this rule to every comment would report the two together
 * and give the reader no way to tell which answer applies.
 *
 * ## The threshold
 *
 * A project declares its own through `apqlint.json` (`"doc-length": { "max": N }`); the default
 * stands for one that does not. There is no ratio of comment to code here and there will not be
 * one: a share is a metric, and a metric names no block to rewrite.
 *
 * ## Off by default, and no autofix
 *
 * `DefaultOff`, because the length at which prose stops being a contract is a project's own
 * judgement; a project opts in through `apqlint.json`. The `fix` seam yields nothing: which
 * sentences are the contract and which are the essay is the whole of the work.
 */
@:nullSafety(Strict)
final class DocLength implements Check implements ConfigAware implements DefaultOff implements NoAutofix implements VolatileMessage {

	/** This check's `id()`, and the `rule` every finding carries. */
	private static inline final RULE_ID: String = 'doc-length';

	/** The `apqlint.json` option a project overrides the default with. */
	private static inline final MAX_KEY: String = 'max';

	/**
	 * The longest a doc block may be where the project declares nothing.
	 *
	 * It sits far above the median block, deliberately: the rule is meant to name the essays,
	 * not to argue with every paragraph, and a first run whose findings a reader cannot get
	 * through teaches nobody anything.
	 */
	private static inline final DEFAULT_MAX_LINES: Int = 40;

	/** The length of the one block comment whose third character is a star without opening a doc. */
	private static inline final EMPTY_BLOCK_LENGTH: Int = 4;

	/** What every finding asks for, once the length and the threshold have been named. */
	private static inline final ADVICE: String =
		' — a contract is a sentence or three; the rest belongs in `docs/`, in the commit that made it, or nowhere';

	/** The message's lead-in, and the anchor `messageIdentity` masks the block's own length behind. */
	private static inline final LENGTH_LEAD: String = 'doc block is ';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a doc block longer than the maximum number of lines the project declares';
	}

	/** Mask the block's own length; the declared maximum after it is a threshold and stays. */
	public function messageIdentity(message: String): String {
		return MessageMask.maskAfter(message, LENGTH_LEAD);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final source: String = entry.source;
			final max: Int = maxLinesFor(entry.file);
			for (unit in SourceComments.collectCommentUnits(source, plugin.lexicalRegions(source))) if (isDocBlock(source, unit)) {
				final lines: Int = lineCount(source, unit.from, unit.to);
				if (lines <= max) continue;
				violations.push({
					file: entry.file,
					span: new Span(unit.from, unit.to),
					rule: RULE_ID,
					severity: Severity.Info,
					message: '$LENGTH_LEAD$lines lines long, past the declared maximum of $max$ADVICE'
				});
			}
		}
		return violations;
	}

	/** No edit: which sentences are the contract and which are the essay is the whole of the work. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'cutting prose by length keeps whichever sentences came first, and the contract is rarely one of them';
	}

	/** The maximum `file`'s own project declares, or the default when it declares none. */
	private function maxLinesFor(file: String): Int {
		return LintConfig.resolveWith(_resolveConfig, file).intOption(RULE_ID, MAX_KEY) ?? DEFAULT_MAX_LINES;
	}

	/**
	 * Whether `unit` is a doc block — the declared contract surface, as opposed to a line-comment
	 * run or a plain block banner, which this rule never measures.
	 */
	private static function isDocBlock(source: String, unit: CommentTok): Bool {
		return !unit.isLine && unit.to - unit.from > EMPTY_BLOCK_LENGTH && source.fastCodeAt(unit.from + 2) == '*'.code;
	}

	/** How many physical lines `[from, to)` spans, opener and closer lines included. */
	private static function lineCount(source: String, from: Int, to: Int): Int {
		var lines: Int = 1;
		for (i in from ... to) if (source.fastCodeAt(i) == '\n'.code) lines++;
		return lines;
	}

}
