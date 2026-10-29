package anyparse.check.common.imports;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.CrossFileFix;
import anyparse.check.Check.FixEdit;
import anyparse.query.SourceComments;
import anyparse.query.SymbolIndex;

/**
 * Flags an AMBIENT import source that binds nothing — empty, blank, or nothing but comments — and deletes
 * it when nothing but whitespace is left.
 *
 * Such a file is what an emptying fix leaves behind: `unused-import` deletes the last statement and the
 * file stays. A source carrying comments is reported and left to a human, since deleting it deletes them
 * too; one carrying anything else, a conditional block for one, is not empty and not reported. Whether a
 * file IS an ambient source is the grammar's to say (`GrammarPlugin.ambientImportGovernance`).
 */
@:nullSafety(Strict)
final class EmptyAmbientSource extends RuleBase implements CrossFileFix {

	private static inline final RULE_ID: String = 'empty-ambient-source';

	/** The message of a source with nothing but whitespace in it — the one finding the fix deletes. */
	private static inline final MSG_BLANK: String = 'ambient import source binds nothing — delete it';

	/** The message of a source with comments and nothing else. */
	private static inline final MSG_COMMENTS: String = 'ambient import source binds nothing but carries comments — delete it by hand';

	/** Why the comment-only finding is never deleted. */
	private static inline final DECLINE_COMMENTS: String = 'the comments would go with the file, and whether they still say something '
		+ 'is a reader\'s call';

	public function new() {
		super(RULE_ID, 'an ambient import source with no statement in it', RuleCategory.Imports);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final out: Array<Violation> = [];
		for (entry in files) if (plugin.ambientImportGovernance(entry.file) != null) {
			final blank: Null<Bool> = blankness(entry.source, plugin);
			if (blank != null) out.push({
				file: entry.file,
				span: new Span(0, entry.source.length),
				rule: RULE_ID,
				severity: Severity.Warning,
				message: blank ? MSG_BLANK : MSG_COMMENTS,
				declineReason: blank ? null : DECLINE_COMMENTS
			});
		}
		return out;
	}

	/** The whole fix is cross-file — deleting a file is no edit inside it. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function crossFileFix(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<Array<CrossFileEdits>> {
		return [
			for (v in violations)
				if (v.rule == RULE_ID && files.exists(entry -> entry.file == v.file && entry.source.trim().length == 0))
					[{ file: v.file, edits: [], remove: true }]
		];
	}

	/**
	 * True when `source` is nothing but whitespace, false when it is comments and whitespace, null when it
	 * holds anything else. The comments are the grammar's lexical regions, so no comment syntax is assumed.
	 */
	private static function blankness(source: String, plugin: GrammarPlugin): Null<Bool> {
		if (source.trim().length == 0) return true;
		final comments: Array<Span> = SourceComments.collectCommentRegions(plugin.lexicalRegions(source));
		var at: Int = 0;
		for (span in comments) {
			if (source.substring(at, span.from).trim().length > 0) return null;
			at = span.to;
		}
		return source.substr(at).trim().length == 0 ? false : null;
	}

}
