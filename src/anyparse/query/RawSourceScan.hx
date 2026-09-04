package anyparse.query;

import anyparse.query.SymbolIndex.FileInfo;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The index's RAW-TEXT side: the questions answered over source BYTES rather than over a parsed
 * tree. Two of them cannot be answered any other way. A file the parser SKIPPED has no tree at all,
 * so "could this name be referenced there" is a word-boundary scan by construction; and an
 * `@:access` grant a rename must clear is read out of the granting file's own text through the
 * grammar's lexical regions, so a mention inside a comment or a string cannot count as one.
 *
 * Split out of `SymbolIndex`, and the one layer that consults no other: it holds the sources, the
 * skipped-file list and the grammar, and asks nothing of the type model. The one-entry memo it
 * keeps is instance state on the run-scoped index, never process-scoped.
 */
@:nullSafety(Strict)
final class RawSourceScan {

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** The paths the parser could not read, handed over by the owning index. */
	private final _skipped: Array<String>;

	/** Per-file source text, handed over by the owning index. */
	private final _sources: Map<String, String>;

	/** The grammar the index was built for, asked for a file's lexical regions. */
	private final _plugin: GrammarPlugin;

	/** The answer `sourceCarriesAllowGrant` gave for `_grantScanSource`. */
	private var _grantScanAnswer: Bool = false;

	/** The last source `sourceCarriesAllowGrant` was asked about, or null before the first ask. */
	private var _grantScanSource: Null<String>;

	/** Built once by the owning `SymbolIndex`, which hands over the shared, immutable index data. */
	public function new(files: Array<FileInfo>, skipped: Array<String>, sources: Map<String, String>, plugin: GrammarPlugin) {
		_files = files;
		_skipped = skipped;
		_sources = sources;
		_plugin = plugin;
	}

	/**
	 * Does any indexed file grant itself `@:access(typeName)` (matched by simple
	 * name)? The second gate — such a file can read the type's private members.
	 */
	public function hasAccessGrant(typeName: String): Bool {
		return _files.exists(f -> f.accessGrants.contains(typeName));
	}

	/**
	 * Whether `matches` holds for the WHOLE source of any indexed file granting itself
	 * `@:access(typeName)`. The grant is file-scoped — every member of such a file reaches
	 * the type's privates — so the scan must be too, unlike the declaration-span scan a
	 * subtype gets. True without consulting `matches` when such a file's source was not
	 * retained. The precise counterpart of `hasAccessGrant`, for a caller that can say what
	 * it actually fears from a grantee rather than vetoing on the grant's existence.
	 */
	public function accessGrantMatches(typeName: String, matches: (source:String) -> Bool): Bool {
		for (fi in _files) if (fi.accessGrants.contains(typeName)) {
			final src: Null<String> = _sources[fi.file];
			if (src == null || matches(src)) return true;
		}
		return false;
	}

	/**
	 * Whether `name` occurs as a word-boundary identifier token in ANY indexed
	 * source, ignoring offsets inside `excludedSpan` of `excludedFile` (a member's
	 * own declaration). A raw-text scan (sees inside `#if` regions, comments and
	 * strings), so a `false` result proves `name` unreferenced in every branch of
	 * every indexed file — the cross-file zero-occurrence proof `unused-private`'s
	 * `--fix` uses to lift its whole-file conditional-compilation veto.
	 */
	public function nameOccursOutside(name: String, excludedFile: String, excludedSpan: Span): Bool {
		for (file => src in _sources) {
			final excluded: Array<Span> = file == excludedFile ? [excludedSpan] : [];
			if (OccurrenceScan.referencedInRange(src, name, 0, src.length, excluded)) return true;
		}
		return false;
	}

	/**
	 * Whether any SKIP-PARSED file's raw text mentions `name` as a whole word.
	 *
	 * The confinement gates — `prefer-final-field`, `prefer-read-only-field`,
	 * `prefer-final-public-field`, `unused-private` and their kin — all ask the same thing: could
	 * a file the index cannot read hold a reference or a write the in-file proof missed? They used
	 * to answer it with `skippedFiles().length > 0`, a whole-PROJECT veto: ONE unparseable file
	 * anywhere in the scope silenced those rules for every other file. Measured on an 855-file
	 * tree, adding a directory with three such files to the scope removed 1147 findings and the
	 * `prefer-final-field` family entirely — a SUPERSET scope reporting FEWER findings, with
	 * nothing said about it.
	 *
	 * The question is per-NAME, and the identifier is what answers it: a reference or a write to
	 * `name` — through a subtype, an `@:access` grant, `@:allow`, or reflection by string — must
	 * spell `name` in the file's text. So a skipped file that never contains the identifier cannot
	 * be the writer, whatever it declares. Keying on the MEMBER name rather than the owning type's
	 * dodges the alias hole (a skipped file may extend a `typedef` of the owner and never spell the
	 * owner's name; it cannot write the member without spelling the member).
	 *
	 * Conservative in the same direction as before wherever it cannot see: a skipped file whose
	 * source was not retained answers true.
	 */
	public function skippedMayReference(name: String): Bool {
		return name.length == 0 ? _skipped.length > 0 : _skipped.exists(file -> skippedSourceMentions(_sources[file], name));
	}

	/**
	 * The same question in the shape a REFUSAL needs: WHICH skipped files may reference any of
	 * `names`, rather than whether one does.
	 *
	 * A gate that only refuses needs the `Bool`; a gate that must TELL the user why needs the
	 * subject. `naming`'s cross-file rename is the second kind — it asks about three identifiers at
	 * once (the member's current name, its owner's, and the corrected name it would introduce) and
	 * writes the answer into `Violation.declineReason`, where "some file did not parse" with no file
	 * named is barely better than the whole-run veto it replaced.
	 *
	 * An empty name means the same here as there — every skipped file, since nothing was asked.
	 */
	public function skippedFilesMentioning(names: Array<String>): Array<String> {
		return _skipped.filter(file -> names.exists(name -> name.length == 0 || skippedSourceMentions(_sources[file], name)));
	}

	/**
	 * `RefactorSupport.carriesAllowGrant` for `source`, answered from a ONE-SLOT memo on this
	 * index.
	 *
	 * The grant scan is a property of the FILE and every consumer asks it once per MEMBER, so a
	 * check walking members paid one whole-source `indexOf` per member of every file it looked at.
	 * Measured on one 416 KB source with 644 members: 423 ms of a 2.4 s `lint --all`, ~19 %.
	 *
	 * ONE slot, and the index instance owns it: `SymbolIndex.build` allocates a fresh instance per
	 * check run, and the only index anything holds on to is the resolution one a
	 * `CachingGrammarPlugin` memoises on ITSELF and re-sets per `--fix` pass — so a memo here dies
	 * with the run that made it, which is what the first invariant asks, and the process-scoped
	 * cache it forbids is what none of this is.
	 *
	 * One slot is enough because a member walk asks about one file's source until it moves to the
	 * next; an interleaved walk simply misses and rescans, which is what it did before this existed.
	 * The answer is a pure function of the source text, so a miss costs time and never correctness.
	 */
	public function sourceCarriesAllowGrant(source: String): Bool {
		if (_grantScanSource == source) return _grantScanAnswer;
		_grantScanSource = source;
		_grantScanAnswer = RefactorSupport.carriesAllowGrant(source, _plugin);
		return _grantScanAnswer;
	}

	/** Whether `c` can be part of an identifier — the word boundary `mentionsWord` tests against. */
	private static inline function isWordChar(c: Int): Bool {
		return c == '_'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code || c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Whether a skip-parsed file whose retained `source` this is may reference `name` — the one
	 * predicate `skippedMayReference` and `skippedFilesMentioning` both answer with, so neither can
	 * drift from the other. A file whose source was not retained answers true: unreadable is not
	 * absent.
	 */
	private static inline function skippedSourceMentions(source: Null<String>, name: String): Bool {
		return source == null || mentionsWord(source, name);
	}

	private static function mentionsWord(source: String, name: String): Bool {
		var at: Int = source.indexOf(name);
		while (at >= 0) {
			final before: Int = at - 1;
			final after: Int = at + name.length;
			final leftFree: Bool = before < 0 || !isWordChar(source.fastCodeAt(before));
			final rightFree: Bool = after >= source.length || !isWordChar(source.fastCodeAt(after));
			if (leftFree && rightFree) return true;
			at = source.indexOf(name, at + 1);
		}
		return false;
	}

}
