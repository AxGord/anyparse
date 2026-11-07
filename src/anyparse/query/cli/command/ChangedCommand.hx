package anyparse.query.cli.command;

import anyparse.proc.HaxeRun;
import anyparse.query.cli.DeclarationDelta;
import anyparse.query.cli.GitRevision;

/** What `apq changed` was asked. */
private typedef ChangedOpts = {

	final lang: String;
	final namesOnly: Bool;

	/** `--diff`: each changed declaration's lines follow its summary line. */
	final diff: Bool;

	/** The declaration `--diff <file>#<selector>` names: shown in full, and the only one shown. */
	final selector: Null<String>;
	final ref: String;
	final paths: Array<String>;

}

/** One file's reading: what changed and the names a reader looks up, or why it could not be read. */
private typedef FileReading = {
	final names: Array<String>;
	final ?delta: FileDelta;
	final ?failure: String;
}

/**
 * `apq changed` — what each file changed against a git revision, by meaning: layout only, imports only, one consistent
 * rename, or the declarations added, removed and changed, matched by name (`DeclarationDelta`).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class ChangedCommand implements CliCommand implements LanguageFree {

	/** The unchanged lines `--diff` keeps around an edit when no declaration is named. */
	private static inline final DIFF_CONTEXT: Int = 2;

	public function new() {}

	public function name(): String {
		return 'changed';
	}

	public function summary(): String {
		return 'What each file changed against a git revision: layout, imports, a rename, or declarations by name';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--names'], ['--diff']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		final opts: Null<ChangedOpts> = parseArgs(args);
		if (opts == null) return ExitCode.EXIT_OK;
		final range: Null<Array<String>> = revisionsOf(opts.ref);
		if (range == null) {
			CliIo.stderr('apq changed: "${opts.ref}" names no revision range git can resolve\n');
			return ExitCode.EXIT_RUNTIME;
		}
		final listed: HaxeRun = GitRevision.diffNameStatus(range, opts.paths);
		if (listed.failure != '' || listed.status != 0) {
			CliIo.stderr('apq changed: git diff against "${opts.ref}" failed: ${listed.failure}${listed.err}\n');
			return ExitCode.EXIT_RUNTIME;
		}
		final entries: Array<ChangedPath> = GitRevision.parseNameStatus(listed.out);
		final names: Array<String> = [];
		final report: Array<String> = [];
		final tally: Map<String, Int> = [];
		final changed: Array<String> = [];
		var selected: Int = 0;
		for (entry in entries) {
			final read: FileReading = readEntry(entry, range[0], range.length > 1 ? range[1] : null, opts.lang);
			final delta: Null<FileDelta> = read.delta;
			if (delta == null) {
				CliIo.stderr('apq changed: ${read.failure}\n');
				return ExitCode.EXIT_RUNTIME;
			}
			for (name in read.names) if (!names.contains(name)) names.push(name);
			final label: String = labelOf(entry, delta);
			tally[label] = (tally[label] ?? 0) + 1;
			final shown: Array<DeclarationChange> = shownOf(entry, delta, opts.selector);
			selected += shown.length;
			for (change in delta.declarations) changed.push(change.selector);
			report.push(renderEntry(entry, label, delta, shown, opts));
		}
		if (opts.selector != null && selected == 0) {
			CliIo.stderr('apq changed: no changed declaration "${opts.selector}" — changed: ${changed.join(', ')}\n');
			return ExitCode.EXIT_RUNTIME;
		}
		if (opts.namesOnly) {
			for (name in names) CliIo.sysPrint('$name\n');
			return ExitCode.EXIT_OK;
		}
		final classes: Array<String> = [for (label => count in tally) '$label $count'];
		classes.sort(CliIo.compareStrings);
		CliIo.sysPrint('changed against ${opts.ref}: ${entries.length} file(s)${classes.length == 0 ? '' : ' — ' + classes.join(', ')}\n');
		for (block in report) CliIo.sysPrint(block);
		return ExitCode.EXIT_OK;
	}

	public function usage(): Void {
		CliIo.sysPrint('Usage: apq changed [options] <base-ref>[..<tip-ref> | ...<tip-ref>] [<path>...]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --names             Print only the names of the changed declarations, one per line\n');
		CliIo.sysPrint(
			'  --diff <file>[#<sel>]  Add <file> to the paths and print each changed declaration\'s lines as the writer emits them\n'
		);
		CliIo.sysPrint('                      (- gone, + new, two lines of context, ... for the rest); with #<sel> only the declaration\n');
		CliIo.sysPrint('                      whose address, dotted name path or name is <sel>, in full, in every listed file\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin for a file no extension routes (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Every file `git diff <base-ref>` reports (the working tree against the revision, or\n');
		CliIo.sysPrint('<tip-ref> against it, or for `...` their merge base against <tip-ref>; paths relative to the current\n');
		CliIo.sysPrint('directory), classed by what it changed:\n');
		CliIo.sysPrint('  layout        the writer emits the same text for both versions\n');
		CliIo.sysPrint('  imports       only the package / import header differs, its order included\n');
		CliIo.sysPrint('  renamed       one consistent identifier substitution, every spelling of it bound to a\n');
		CliIo.sysPrint('                declaration in the file, printed as old -> new\n');
		CliIo.sysPrint('  declarations  each declaration added (+), removed (-) or changed (~), matched by\n');
		CliIo.sysPrint('                NAME, with its --select address and line counts\n');
		CliIo.sysPrint('  values        a data document (JSON): each key path added (+), removed (-) or changed (~ old -> new),\n');
		CliIo.sysPrint('                a digest shortened, with `+added -removed ~changed` counts\n');
		CliIo.sysPrint('  text          a file the grammar does not read: a line count only\n');
		CliIo.sysPrint('A moved file prints `<- <old path>` — when a <path> filter names both of its paths.\n');
		CliIo.sysPrint('Untracked files are not reported.\n');
	}

	/** The options of one run, or null when it asked for the usage text and got it. */
	private function parseArgs(args: Array<String>): Null<ChangedOpts> {
		var lang: String = 'haxe';
		var namesOnly: Bool = false;
		var diff: Bool = false;
		var selector: Null<String> = null;
		var ref: Null<String> = null;
		final paths: Array<String> = [];
		for (arg in new ChangedCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--diff':
					diff = true;
					final target: String = arg.value();
					final hash: Int = target.indexOf('#');
					final file: String = hash < 0 ? target : target.substr(0, hash);
					if (hash >= 0) selector = target.substr(hash + 1);
					if (file != '') paths.push(file);
				case '--names':
					namesOnly = true;
				case '-h', '--help':
					usage();
					return null;
				case null:
					if (ref == null)
						ref = a
					else
						paths.push(a);
			}
		}
		if (ref == null) throw new UsageFailure('missing <base-ref>');
		if (diff && namesOnly) throw new UsageFailure('--diff and --names are exclusive');
		return {
			lang: lang,
			namesOnly: namesOnly,
			diff: diff,
			selector: selector,
			ref: ref,
			paths: paths
		};
	}

	private static inline function isWhole(entry: ChangedPath): Bool {
		return entry.status == 'A' || entry.status == 'D';
	}

	/** Both versions of `entry` and what changed between them; the working tree stands in for a missing `tip`. */
	private static function readEntry(entry: ChangedPath, base: String, tip: Null<String>, lang: String): FileReading {
		final before: Null<String> = entry.status == 'A' ? '' : GitRevision.sourceAt(base, entry.basePath);
		if (before == null) return { names: [], failure: '${entry.basePath} is not readable at "$base"' };
		final now: Null<String> = if (entry.status == 'D')
			''
		else if (tip == null)
			CliIo.readFile(entry.path)
		else
			GitRevision.sourceAt(tip, entry.path);
		if (now == null) return { names: [], failure: '${entry.path} is not readable at "$tip"' };
		final plugin: GrammarPlugin = CliArgs.pickPluginFor(lang, entry.path);
		// a data document's keys are no names a reader looks up in the code
		if (DataDelta.reads(plugin.refShape())) return { names: [], delta: DataDelta.compare(plugin, before, now) };
		if (!entry.path.toLowerCase().endsWith(CliArgs.sourceExtensionOf(plugin.langName())))
			return { names: [], delta: DeclarationDelta.compareText(before, now) };
		final delta: FileDelta = DeclarationDelta.compare(plugin, before, now, CliArgs.discoverFormatConfig(entry.path));
		// another grammar's keys, a data file of this one, are no names a reader looks up in the code
		final whole: Bool = entry.status == 'A' || entry.status == 'D';
		return { names: plugin.langName() == lang ? DeclarationDelta.namesOf(delta, whole) : [], delta: delta };
	}

	private static function labelOf(entry: ChangedPath, delta: FileDelta): String {
		return switch entry.status {
			case 'A': 'new';
			case 'D': 'deleted';
			case _: delta.change;
		};
	}

	/**
	 * The revisions `ref` compares, as git reads them: `A..B` is A against B, `A...B` is their merge base against B, a
	 * side left empty is `HEAD`, and a bare revision is compared with the working tree. Null when git resolves no merge base.
	 */
	private static function revisionsOf(ref: String): Null<Array<String>> {
		final symmetric: Bool = ref.indexOf('...') >= 0;
		final sides: Array<String> = ref.split(symmetric ? '...' : '..');
		if (sides.length == 1) return sides;
		final from: String = sides[0] == '' ? 'HEAD' : sides[0];
		final to: String = sides[1] == '' ? 'HEAD' : sides[1];
		if (!symmetric) return [from, to];
		final base: HaxeRun = GitRevision.git(['merge-base', from, to]);
		return base.failure == '' && base.status == 0 ? [base.out.trim(), to] : null;
	}

	private static function renderEntry(
		entry: ChangedPath, label: String, delta: FileDelta, shown: Array<DeclarationChange>, opts: ChangedOpts
	): String {
		final moved: String = entry.basePath != entry.path ? '  <- ${entry.basePath}' : '';
		final counts: String = countsOf(label, delta);
		final out: StringBuf = new StringBuf();
		out.add('${entry.status} ${entry.path}$moved  $label$counts\n');
		final whole: Bool = isWhole(entry);
		if (!whole) {
			for (line in delta.headerRemoved) out.add('    - $line\n');
			for (line in delta.headerAdded) out.add('    + $line\n');
			if (delta.headerReordered) out.add('    import order changed\n');
		}
		for (renaming in delta.renames) out.add('    rename ${renaming.from} -> ${renaming.to}\n');
		for (change in delta.values) out.add('    ${valueRow(change)}\n');
		// a file added or deleted whole shows its lines only for the declaration a selector names
		final lines: Bool = opts.diff && (!whole || opts.selector != null);
		for (change in shown) {
			out.add('    ${change.status} ${change.selector}  ${sizeOf(change)}\n');
			// a member that only moved has no edit to show; its lines are named on request
			final unedited: Bool = change.status == Changed && change.added + change.removed == 0;
			if (lines && (!unedited || opts.selector != null))
				for (row in DeclarationDelta.hunk(change.before, change.after, opts.selector == null ? DIFF_CONTEXT : null))
					out.add('        $row\n');
		}
		return out.toString();
	}

	/** The declarations of `delta` a report names: a file added or deleted whole, its module-level ones; a selector, the ones it names. */
	private static function shownOf(entry: ChangedPath, delta: FileDelta, selector: Null<String>): Array<DeclarationChange> {
		final whole: Bool = isWhole(entry);
		return [
			for (change in delta.declarations)
				if (
					(selector != null || !whole || change.depth <= 0)
					&& (selector == null || change.selector == selector || change.key == selector || change.name == selector)
				)
					change
		];
	}

	/** One changed key path as a row: `+ path  value`, `- path  value`, `~ path  old -> new`. */
	private static function valueRow(change: ValueChange): String {
		return switch change.status {
			case Added: '+ ${change.path}  ${change.after}';
			case Removed: '- ${change.path}  ${change.before}';
			case Changed:
				change.before == '' && change.after == '' ? '~ ${change.path}' : '~ ${change.path}  ${change.before} -> ${change.after}';
		};
	}

	/** `  +a -r ~c`: how many key paths were added, removed and changed. */
	private static function valueCounts(values: Array<ValueChange>): String {
		final tally: Map<DeclarationStatus, Int> = [];
		for (change in values) tally[change.status] = (tally[change.status] ?? 0) + 1;
		return '  +${tally[Added] ?? 0} -${tally[Removed] ?? 0} ~${tally[Changed] ?? 0}';
	}

	/** The counts after a file's label: none for a change that moved no value, else lines or, for a data document, key paths. */
	private static function countsOf(label: String, delta: FileDelta): String {
		return switch label {
			case ChangeClass.Layout, ChangeClass.Unchanged: '';
			case ChangeClass.Values: valueCounts(delta.values);
			case _: '  +${delta.added} -${delta.removed}';
		};
	}

	/**
	 * A changed declaration's size column: its line counts, or `(moved)` where
	 * only its place changed; `(moved)` follows the counts of an edited one.
	 */
	private static function sizeOf(change: DeclarationChange): String {
		return switch change.status {
			case Changed:
				change.added + change.removed == 0 && change.moved
					? '(moved)'
					: '+${change.added} -${change.removed}${change.moved ? ' (moved)' : ''}';
			case Added: '${change.spanLines} line(s)';
			case Removed: '${change.spanLines} line(s), base';
		};
	}

}
