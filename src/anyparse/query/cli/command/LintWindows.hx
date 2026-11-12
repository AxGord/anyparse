package anyparse.query.cli.command;

import anyparse.query.cli.command.LintCommand.LintRange;
import anyparse.query.cli.command.LintCommand.LintWindowOf;

/**
 * The one answer to "which lines of which file may a lint run report and fix": `--range`'s one window set for
 * its single file, or, for `--changed-since <rev>`, each file's lines the working tree added or changed against
 * that revision (`CliEdit.changedCodeWindows`).
 *
 * A file the revision does not hold has no narrowing — every line of it is new. A file it holds unchanged gets
 * no window at all, so nothing of it is reported or fixed, and a file whose diff outgrows the line differ, or that lies
 * outside the repository, is treated the same way, because falling back to the
 * whole file is the rewrite of untouched code this narrowing exists to prevent.
 */
@:nullSafety(Strict)
final class LintWindows {

	/**
	 * The window lookup `runLint` narrows by, or null after saying why a revision cannot be compared with
	 * the working tree. A lookup answering null for a file means the whole file.
	 */
	public static function resolver(
		range: Null<LintRange>, changedSince: Null<String>, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): Null<LintWindowOf> {
		if (changedSince == null) return _ -> range;
		final texts: Null<Map<String, Null<String>>> = GitRevision.textsAt(changedSince, files.map(e -> e.file));
		if (texts == null) {
			CliIo.stderr('apq lint: --changed-since "$changedSince": git cannot compare the working tree with it\n');
			return null;
		}
		final windows: Map<String, LintRange> = [];
		for (entry in files) {
			if (!texts.exists(entry.file)) {
				CliIo.stderr('apq lint: ${entry.file} is outside the git repository — left untouched\n');
				windows[entry.file] = [];
				continue;
			}
			final base: Null<String> = texts[entry.file];
			if (base == null) continue;
			final changed: Null<LintRange> = CliEdit.changedCodeWindows(base, entry.source, plugin);
			if (changed == null)
				CliIo.stderr(
					'apq lint: ${entry.file} changed more lines against "$changedSince" than the line diff follows — left untouched\n'
				);
			windows[entry.file] = changed ?? [];
		}
		return file -> windows[file];
	}

}
