package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ResolvedType;
import anyparse.runtime.Span;

using Lambda;

/**
 * The index's RAW-TEXT side: the questions answered over source BYTES rather than over a parsed
 * tree. Two of them cannot be answered any other way. A file the parser SKIPPED has no tree at all,
 * so "could this name be referenced there" is a word-boundary scan by construction; and an
 * `@:access` grant a rename must clear is read out of the granting file's own text through the
 * grammar's lexical regions, so a mention inside a comment or a string cannot count as one.
 *
 * Split out of `SymbolIndex`: it holds the sources, the skipped-file list and the grammar, and asks the
 * type model one thing — the supertypes a grant may name to reach a type (`grantTargetsOf`). Its memos
 * are instance state on the run-scoped index, never process-scoped.
 */
@:nullSafety(Strict)
final class RawSourceScan {

	/**
	 * Per-file memo of `OccurrenceScan.inertMask`, keyed by file path. `nameOccursOutside` asks
	 * for a file's mask once per (candidate, file) pair across a project-wide dead-code sweep
	 * (`UnusedPrivate.provablyDeadProjectWide`) — the mask is a pure function of that file's own
	 * bytes, so the SECOND candidate to visit a file gets the first candidate's answer instead of
	 * relexing it. Run-scoped instance state, on the same footing as `_grantScanSource` below.
	 */
	private final _matchMaskByFile: Map<String, Array<Span>> = [];

	/** The access path (`pkg.Type`, a sub-type included) of every indexed declaration, by the type's simple name. */
	private final _typePathsByName: Map<String, Array<String>> = [];

	/** Per name a PROJECT reification spells, the types whose reifications spell it (`FileInfo.reifications`). */
	private final _reifiedBy: Map<String, Array<String>> = [];

	/** `grantTargetsOf`'s answer per type name once asked. */
	private final _grantTargets: Map<String, Array<GrantTarget>> = [];

	/** Every indexed declaration's access path, as a set — what tells a grant naming a known type from one naming anything else. */
	private final _declaredPaths: Map<String, Bool> = [];

	/** `waivedNamesOf`'s answer per waiver file once asked — null for a file that does not parse. */
	private final _waivedNamesByFile: Map<String, Null<Array<String>>> = [];

	/** Every indexed file's `FileInfo`, handed over by the owning index. */
	private final _files: Array<FileInfo>;

	/** The paths the parser could not read, handed over by the owning index. */
	private final _skipped: Array<String>;

	/**
	 * The scope's THIRD-PARTY half — a `resolutionLibs` / std path -> true — handed over by the
	 * owning index, empty for an index built over project sources alone. The discriminator the
	 * per-owner narrowing keys on, and the raw-text twin of `FieldWriteIndex._thirdParty`.
	 */
	private final _thirdParty: Map<String, Bool>;

	/** Per-file source text, handed over by the owning index. */
	private final _sources: Map<String, String>;

	/** The grammar the index was built for, asked for a file's lexical regions. */
	private final _plugin: GrammarPlugin;

	/** The owning index's declaration layer, walked for the supertypes a grant may name (`grantTargetsOf`). */
	private final _refs: TypeRefIndex;

	/** The owning index's trait layer, asked whether a grantee's type is built by a macro (`privilegedFileSpells`). */
	private final _traits: TypeTraits;

	/** Every retained source writing the grammar's privacy waiver in code (`waiverFilesOf`), sorted. */
	private final _waiverFiles: Array<String>;

	/** The answer `sourceCarriesAllowGrant` gave for `_grantScanSource`. */
	private var _grantScanAnswer: Bool = false;

	/** The last source `sourceCarriesAllowGrant` was asked about, or null before the first ask. */
	private var _grantScanSource: Null<String>;

	/** Built once by the owning `SymbolIndex`, which hands over the shared, immutable index data. */
	public function new(
		files: Array<FileInfo>, skipped: Array<String>, sources: Map<String, String>, plugin: GrammarPlugin, thirdParty: Map<String, Bool>,
		refs: TypeRefIndex, traits: TypeTraits
	) {
		_refs = refs;
		_traits = traits;
		_files = files;
		_skipped = skipped;
		_sources = sources;
		_plugin = plugin;
		_thirdParty = thirdParty;
		_waiverFiles = waiverFilesOf(sources, plugin, thirdParty);
		for (fi in files) if (!thirdParty.exists(fi.file)) for (r in fi.reifications) for (name in r.names) {
			final fns: Array<String> = _reifiedBy[name] ?? [];
			if (!fns.contains(r.typeName)) fns.push(r.typeName);
			_reifiedBy[name] = fns;
		}
		for (fi in files) for (t in fi.types) {
			final paths: Array<String> = _typePathsByName[t.name] ?? [];
			final path: String = fi.pkg == '' ? t.name : '${fi.pkg}.${t.name}';
			if (!paths.contains(path)) paths.push(path);
			_typePathsByName[t.name] = paths;
			_declaredPaths[path] = true;
		}
	}

	/**
	 * Does any indexed file grant itself private access to `typeName` by naming it — the type, one of its members or a package
	 * enclosing it? The existence veto, kept to what names the type itself. A grant to a superclass and an expression-level
	 * waiver reach it only where they spell the member, so they answer per NAME instead (`privilegeMayReference`).
	 */
	public function hasAccessGrant(typeName: String): Bool {
		final own: GrantTarget = grantTargetsOf(typeName)[0];
		return _files.exists(f -> f.accessGrants.exists(path -> grantReaches(path, own)));
	}

	/**
	 * Whether `matches` holds for the WHOLE source of any indexed file granting itself
	 * private access to `typeName` (`grantsAccessTo`), or of any file carrying an expression-level
	 * waiver (`waiverFilesOf`) that spells `member` — a waiver names no type, so nothing but the
	 * member's name ties such a file to it. The grant is file-scoped — every member of such a file reaches
	 * the type's privates — so the scan must be too, unlike the declaration-span scan a
	 * subtype gets. True without consulting `matches` when such a file's source was not
	 * retained. The precise counterpart of `hasAccessGrant`, for a caller that can say what
	 * it actually fears from a grantee rather than vetoing on the grant's existence.
	 *
	 * A member a project reification spells answers true when a privileged file spells the type holding that reification
	 * (where a waiver annotates, for a waiver file), or grants itself access from a type a build macro builds: a macro's
	 * output is access-checked where it lands, so a privileged caller reaches it without spelling it — through a helper,
	 * a chain of macros or `@:build` / `@:autoBuild` alike. A name the macro computes (`$i{…}`) is out of reach.
	 */
	public function accessGrantMatches(typeName: String, member: String, matches: (source:String) -> Bool): Bool {
		for (file in privilegedFiles(typeName, member)) {
			final src: Null<String> = _sources[file];
			if (src == null || matches(src)) return true;
		}
		final emitters: Null<Array<String>> = _reifiedBy[member];
		return emitters != null && privilegedFiles(typeName).exists(file -> emitters.exists(fn -> privilegedFileSpells(file, fn)));
	}

	/**
	 * Every file that may reach `typeName`'s private members by a privilege rather than by inheritance — each granting
	 * itself access (`grantsAccessTo`), then each carrying an expression-level waiver (`waiverFilesOf`), narrowed to those
	 * spelling `member` when one is given (a waiver names no type, so the member's name is all that ties it to this one).
	 * Deduped, in index order.
	 */
	public function privilegedFiles(typeName: String, ?member: String): Array<String> {
		final out: Array<String> = [for (fi in _files) if (grantsAccessTo(fi, typeName)) fi.file];
		for (file in _waiverFiles) if (!out.contains(file) && (member == null || waiverFileMayReference(file, member))) out.push(file);
		return out;
	}

	/**
	 * Whether `fi` grants itself private access to `typeName`. Haxe holds a grant path against the access path (`pkg.Type`,
	 * a sub-type's too) of the declaring class and then of each of its superclasses, with the member after it: a path reaches
	 * the type when it names it or a superclass (`pkg.Type`), a member of one (`pkg.Type.member`) or an enclosing package
	 * (`pkg`), and never through the module a sub-type sits in. A path whose last segment is one of those simple names counts
	 * whatever its package — the conservative direction for every caller, each of which refuses on a grant. A third-party
	 * file is held against the type itself only: it cannot name a subclass, so a grant to its superclass reaches none of that
	 * subclass's members from there.
	 */
	public function grantsAccessTo(fi: FileInfo, typeName: String): Bool {
		if (fi.accessGrants.length == 0) return false;
		final targets: Array<GrantTarget> = grantTargetsOf(typeName);
		final reachable: Array<GrantTarget> = _thirdParty.exists(fi.file) ? [targets[0]] : targets;
		return fi.accessGrants.exists(path -> reachable.exists(t -> grantReaches(path, t)));
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
		return nameOccursOutsideAll(name, [excludedFile => [excludedSpan]]);
	}

	/**
	 * `nameOccursOutside` over SEVERAL excluded regions, possibly in several files: `excluded` maps a
	 * file to the spans of it that do not count. The same raw-text scan, so `false` proves `name`
	 * occurs nowhere else in any indexed source — the shape a "read only inside its own type and its
	 * subtypes" proof needs, where the regions are a type declaration and each of its subtypes'.
	 */
	public function nameOccursOutsideAll(name: String, excluded: Map<String, Array<Span>>): Bool {
		for (file => src in _sources) if (OccurrenceScan.referencedInRange(
			src, name, 0, src.length, excluded[file] ?? [], matchMaskFor(file, src)
		))
			return true;
		return false;
	}

	/**
	 * Whether any SKIP-PARSED file's raw text mentions `name` as a whole word.
	 *
	 * The confinement gates — `prefer-final-field`, `prefer-read-only-field`, `prefer-final-public-field`,
	 * `unused-private` and their kin — all ask the same thing: could a file the index cannot read hold a
	 * reference or a write the in-file proof missed? They used to answer it with `skippedFiles().length >
	 * 0`, a whole-PROJECT veto: ONE unparseable file anywhere in the scope silenced those rules for every
	 * other file. Adding a directory with three such files to a scope then removed whole rule families — a
	 * SUPERSET scope reporting FEWER findings, with nothing said about it.
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
	 *
	 * `ownerFile` narrows the scan per OWNER, the way `FieldWriteIndex.admits` narrows the write bail: a
	 * skipped THIRD-PARTY source cannot hold a write into a type the PROJECT declares — it cannot name that
	 * type — so it is dropped for a project-owned candidate. Omit it to ask the unnarrowed question, which
	 * is what a subject that may itself be third-party wants. This is what lets the library into the index
	 * at all: an unnarrowed scan over the resolution scope loses findings to skip-parsing haxelib sources
	 * that merely SPELL a project member's name, and recovers every one of them per owner.
	 */
	public function skippedMayReference(name: String, ?ownerFile: String): Bool {
		return name.length == 0
			? _skipped.exists(file -> admits(file, ownerFile))
			: _skipped.exists(file -> admits(file, ownerFile) && skippedSourceMentions(_sources[file], name));
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
	 *
	 * `ownerFile` narrows per owner exactly as it does there, so the two cannot drift apart.
	 */
	public function skippedFilesMentioning(names: Array<String>, ?ownerFile: String): Array<String> {
		return _skipped.filter(
			file -> admits(file, ownerFile) && names.exists(name -> name.length == 0 || skippedSourceMentions(_sources[file], name))
		);
	}

	/**
	 * `RefactorSupport.carriesAllowGrant` for `source`, answered from a ONE-SLOT memo on this
	 * index.
	 *
	 * The grant scan is a property of the FILE and every consumer asks it once per MEMBER, so a check
	 * walking members paid one whole-source `indexOf` per member of every file it looked at, which on a
	 * large source is a substantial share of a whole `lint --all`.
	 *
	 * ONE slot, and the index instance owns it: an index lives no longer than the run host that memoises it (`IndexScope`,
	 * `CachingGrammarPlugin.indexOver` and its resolution twin, all re-set per `--fix` pass), and a bare plugin builds a fresh
	 * one per call — so a memo here dies with the run that made it, which is what the first invariant asks, and the process-scoped
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

	/**
	 * Whether any file a privilege opens `typeName` to (`privilegedFiles`) spells `member` in code — a grant file anywhere in
	 * it, a waiver file inside what the waiver annotates. True for a file whose source was not retained.
	 */
	public function privilegeMayReference(typeName: String, member: String): Bool {
		return accessGrantMatches(typeName, member, src -> OccurrenceScan.referencedInRange(src, member, 0, src.length, []));
	}

	/**
	 * Whether a skipped `file` counts for a candidate declared in `ownerFile` — the per-owner
	 * narrowing both scans above share. A null owner asks the unnarrowed question; otherwise a
	 * third-party skipped source counts only for a third-party owner. The raw-text twin of
	 * `FieldWriteIndex.admits`, and conservative on the same terms: an index built over project
	 * sources alone has an empty third-party map, so every file counts and the answer is what it
	 * was before this parameter existed.
	 */
	private inline function admits(file: String, ownerFile: Null<String>): Bool {
		return ownerFile == null || !_thirdParty.exists(file) || _thirdParty.exists(ownerFile);
	}

	/**
	 * Whether the waiver file `file` spells `name` inside an expression its waiver annotates (`waivedNamesOf`) — anywhere in
	 * its code when it does not parse, and true when its source was not retained.
	 */
	private function waiverFileMayReference(file: String, name: String): Bool {
		final src: Null<String> = _sources[file];
		if (src == null) return true;
		final waived: Null<Array<String>> = waivedNamesOf(file, src);
		return waived == null
			? OccurrenceScan.referencedInRange(src, name, 0, src.length, [], matchMaskFor(file, src))
			: waived.contains(name);
	}

	/**
	 * Every name spelled inside an expression the grammar's privacy waiver annotates in `file` — the only place the waiver
	 * reaches, so a same-named call one statement further on is not a reach. Null when the file does not parse. Memoised per
	 * file on this run-scoped index.
	 */
	private function waivedNamesOf(file: String, source: String): Null<Array<String>> {
		if (_waivedNamesByFile.exists(file)) return _waivedNamesByFile[file];
		final shape: RefShape = _plugin.refShape();
		final tag: Null<String> = shape.waivesPrivacyMetaName;
		final tree: Null<QueryNode> = tag == null || _skipped.contains(file) ? null : ParseGate.parseOrNull(_plugin, source);
		final out: Null<Array<String>> = if (tree == null || tag == null)
			null
		else {
			final names: Array<String> = [];
			final newKind: Null<String> = shape.newExprKind;
			final ctorName: Null<String> = shape.constructorName;
			collectWaivedNames(tree, tag, newKind == null || ctorName == null ? null : { newKind: newKind, name: ctorName }, false, names);
			names;
		};
		_waivedNamesByFile[file] = out;
		return out;
	}

	/**
	 * `OccurrenceScan.inertMask(source, _plugin)` for `file`, computed once and reused by every
	 * later candidate `nameOccursOutside` walks the index for — see `_matchMaskByFile`.
	 */
	private function matchMaskFor(file: String, source: String): Array<Span> {
		final cached: Null<Array<Span>> = _matchMaskByFile[file];
		if (cached != null) return cached;
		// A file the parser SKIPPED keeps the OLD unmasked treatment: this raw scan is the safety
		// net such a file's reflective / indirect reference leans on when nothing else can prove it
		// live (`ReflectionScan.reflectionSurface` has no AST to pull a literal from, so it falls
		// back to raw source in a DIFFERENT bucket `mentionedInStrings` never reads). Masking a
		// skipped file the same as a parsed one would remove exactly that margin — see
		// `CrossScopeSoundnessTest.unreadableExtras`, which pins unreadable never licensing MORE
		// than readable.
		final built: Array<Span> = _skipped.contains(file) ? [] : OccurrenceScan.inertMask(source, _plugin);
		_matchMaskByFile[file] = built;
		return built;
	}

	/**
	 * `typeName` and every superclass above it (`SupertypeWalk.hops` over each of its declarations), each with the access
	 * paths a grant may name it by; a link no declaration resolves is kept by its written name and marked `unresolved`.
	 * Memoised per name on this run-scoped index.
	 */
	private function grantTargetsOf(typeName: String): Array<GrantTarget> {
		final known: Null<Array<GrantTarget>> = _grantTargets[typeName];
		if (known != null) return known;
		final out: Array<GrantTarget> = [{ name: typeName, paths: _typePathsByName[typeName] ?? [], unresolved: false }];
		final queue: Array<ResolvedType> = SupertypeWalk.declarationsOf(_refs, typeName, null);
		final seen: Array<String> = [];
		var i: Int = 0;
		while (i < queue.length) {
			final cur: ResolvedType = queue[i++];
			if (!_refs.markSeen(cur, seen)) continue;
			final ups: Array<ResolvedType> = SupertypeWalk.hops(_refs, cur);
			for (up in ups) {
				final name: String = up.type.name;
				out.push({ name: name, paths: [up.file.pkg == '' ? name : '${up.file.pkg}.$name'], unresolved: false });
				queue.push(up);
			}
			final raws: Array<String> = cur.type.supertypesRaw;
			for (k in 0...cur.type.supertypes.length) {
				final simple: String = cur.type.supertypes[k];
				if (ups.exists(u -> u.type.name == simple)) continue;
				final raw: String = k < raws.length ? raws[k] : simple;
				out.push({ name: simple, paths: unresolvedPathsOf(simple, raw, cur.file), unresolved: true });
			}
		}
		_grantTargets[typeName] = out;
		return out;
	}

	/**
	 * Whether the grant path `path` reaches `target`: it names the target (last segment the simple name, or one of its access
	 * paths), a member of it — any segment the simple name, for a target no declaration resolves — or a package enclosing one
	 * of those paths. A target no declaration resolves has an unknown package, so any path naming no indexed type or member
	 * of one may enclose it. Only the per-name side reads that answer: `hasAccessGrant` asks the type itself, which resolves.
	 */
	private function grantReaches(path: String, target: GrantTarget): Bool {
		if (path == target.name || path.endsWith('.${target.name}') || (target.unresolved && path.split('.').contains(target.name)))
			return true;
		if (target.paths.exists(t -> t.startsWith('$path.') || path == t || path.startsWith('$t.'))) return true;
		final dot: Int = path.lastIndexOf('.');
		return target.unresolved && !_declaredPaths.exists(path) && (dot < 0 || !_declaredPaths.exists(path.substring(0, dot)));
	}

	/**
	 * Whether the privileged `file` reaches what the type `name` emits: a waiver file spells it inside what the waiver annotates,
	 * a file granting itself access spells it anywhere in its code, or declares a type whose supertype closure carries a build
	 * macro spelling it (`@:autoBuild(Macros.build())`).
	 */
	private function privilegedFileSpells(file: String, name: String): Bool {
		if (_waiverFiles.contains(file) && waiverFileMayReference(file, name)) return true;
		final fi: Null<FileInfo> = _files.find(f -> f.file == file);
		if (fi == null || fi.accessGrants.length == 0) return false;
		final src: Null<String> = _sources[file];
		return src == null
			|| OccurrenceScan.referencedInRange(src, name, 0, src.length, [])
			|| fi.types.exists(t -> _traits.buildClosureSpells(t.name, file, name));
	}

	/** Whether `c` can be part of an identifier — the word boundary `mentionsWord` tests against. */
	public static inline function isWordChar(c: Int): Bool {
		return c == '_'.code || c >= 'a'.code && c <= 'z'.code || c >= 'A'.code && c <= 'Z'.code || c >= '0'.code && c <= '9'.code;
	}

	/**
	 * Whether `source` spells `name` as a whole WORD — the raw-text proof every scan over an unreadable
	 * file reduces to.
	 *
	 * Public because the reflection layer asks it of a scope file the parser could not read
	 * (`ReflectionScan.runtimeName`), where no index has been built over the file at all and
	 * `skippedMayReference` therefore cannot answer.
	 */
	public static function mentionsWord(source: String, name: String): Bool {
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

	/**
	 * Whether a skip-parsed file whose retained `source` this is may reference `name` — the one
	 * predicate `skippedMayReference` and `skippedFilesMentioning` both answer with, so neither can
	 * drift from the other. A file whose source was not retained answers true: unreadable is not
	 * absent.
	 */
	private static inline function skippedSourceMentions(source: Null<String>, name: String): Bool {
		return source == null || mentionsWord(source, name);
	}

	/**
	 * Every retained PROJECT source — parsed or skipped — that writes the grammar's privacy waiver
	 * (`RefShape.waivesPrivacyMetaName`) in CODE, comment, string and regex regions masked. Read from the text rather than the
	 * tree, so a declarations-only parse (which drops function bodies, where the waiver lives) and an unparsed file answer it
	 * alike. A third-party source is left out: it cannot name a project type, so it cannot hold one of its values typed for a
	 * waiver to matter. Read once, when the run-scoped index is built.
	 */
	private static function waiverFilesOf(
		sources: Map<String, String>, plugin: GrammarPlugin, thirdParty: Map<String, Bool>
	): Array<String> {
		final tag: Null<String> = plugin.refShape().waivesPrivacyMetaName;
		final out: Array<String> = tag == null ? [] : [
			for (file => src in sources) if (!thirdParty.exists(file) && writesTagInCode(src, tag, plugin)) file
		];
		out.sort(Reflect.compare);
		return out;
	}

	/** Whether `source` writes the metadata `tag` outside comment, string and regex regions, not as a prefix of a longer tag. */
	private static function writesTagInCode(source: String, tag: String, plugin: GrammarPlugin): Bool {
		var at: Int = source.indexOf(tag);
		if (at < 0) return false;
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		while (at >= 0) {
			final next: Null<Int> = source.charCodeAt(at + tag.length);
			if ((next == null || !isWordChar(next)) && LexicalRegions.regionAt(at, regions) == null) return true;
			at = source.indexOf(tag, at + 1);
		}
		return false;
	}

	/**
	 * Appends to `out` the name of every node under an annotation by `tag` — a node holding the tag as a child waives all its
	 * children. A construction (`ctor.newKind`) spells the constructor's member name rather than the type it builds: `new T()`
	 * under a waiver reaches a private constructor without writing its name.
	 */
	private static function collectWaivedNames(
		node: QueryNode, tag: String, ctor: Null<WaivedConstruction>, waived: Bool, out: Array<String>
	): Void {
		final name: Null<String> = ctor != null && node.kind == ctor.newKind ? ctor.name : node.name;
		if (waived && name != null && !out.contains(name)) out.push(name);
		final opens: Bool = waived || node.children.exists(c -> c.name == tag);
		for (child in node.children) collectWaivedNames(child, tag, ctor, opens, out);
	}

	/**
	 * The access paths a superclass no declaration resolves may be named by: the written path when it is qualified, and the
	 * declaring file's own package. An import of it is not read here — a package grant over an imported, unindexed superclass
	 * is the residual, and a scope declaring the library resolves it by declaration instead.
	 */
	private static function unresolvedPathsOf(simple: String, raw: String, file: FileInfo): Array<String> {
		final own: String = file.pkg == '' ? simple : '${file.pkg}.$simple';
		return raw.indexOf('.') >= 0 && raw != own ? [raw, own] : [own];
	}

}

/** A type a grant may name to reach a private member: the owner itself or one of its superclasses. */
private typedef GrantTarget = {
	final name: String;
	final paths: Array<String>;
	final unresolved: Bool;
};

/** The construction kind and the constructor member name a waiver's `new T()` spells. */
private typedef WaivedConstruction = {
	final newKind: String;
	final name: String;
};
