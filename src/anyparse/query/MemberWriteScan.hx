package anyparse.query;

import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;

using StringTools;

/**
 * Conservative text scans for the cross-file questions a member-access rewrite has to answer:
 * "is this member NAME written here" (does a SUBTYPE write an inherited member, does an
 * `@:access` GRANTEE write it), and the weaker "is it MENTIONED here at all".
 *
 * ## Why the checks need this
 *
 * `prefer-final-field`, `prefer-final-public-field` and `prefer-read-only-field` all
 * tighten a field's write access (`final`, `(default, null)`), and all three used to bail
 * on the mere EXISTENCE of a subtype (`SymbolIndex.hasSubtype`) or of an `@:access` grant.
 * That is the wrong question by a wide margin: an empty `class D extends C {}` blocked
 * every field of `C`, and the answer changed with the lint scope, since a single-file run
 * cannot see the subtype at all. Only a WRITE breaks any of the three rewrites — a read
 * survives `final` and keeps the public read access of `(default, null)`.
 *
 * A structural write index cannot answer it alone. An unbound bare `x = 1` in a subtype
 * IS attributed back to the declaring type, but `this.x = …` and a subtype-typed receiver
 * (`d.x = …` on `d:D`) are attributed to the SUBTYPE — so asking the index about the owner
 * misses them. Hence a text scan over each subtype's declaration slice, plus asking the
 * index about the subtype itself (`subtypeWriteReaches`) for the writes that live in a
 * third file and are nowhere in the subtype's body.
 *
 * ## Soundness
 *
 * The scan is conservative and COMPLETE: it treats the name followed by any assignment
 * operator (`=`, `+=`, … but not `==` / `<=` / `!=` / `=>`) or adjacent to `++` / `--` as
 * a write, matching `this.x = …`, `obj.x = …`, `x++` and `++x` alike, and skips whitespace
 * AND interposed comments between the name and the operator. It over-counts — a same-named
 * local, or the name in a comment or string, reads as a write — which only ever KEEPS the
 * looser access, never produces a rewrite the compiler rejects.
 */
@:nullSafety(Strict)
final class MemberWriteScan {

	public static inline function subtypeMayWrite(owner: String, name: String, index: SymbolIndex, plugin: GrammarPlugin): Bool {
		return scopeOf(
			index, plugin
		)
			.subtypeDeclMatches(
				owner, name,
				(subtype, src, span, redeclares) -> redeclares || subtypeReach(scopeOf(index, plugin), subtype, name, src, span)
			);
	}

	/**
	 * `subtypeMayWrite`, plus the writes a declaration-slice scan structurally CANNOT see:
	 * a resolved `recv.name = …` whose receiver is typed as a SUBTYPE is recorded by
	 * `FieldWriteIndex` against that subtype, so it lives in a third file that never
	 * mentions `owner` and is absent from the subtype's own body. Asking the write index
	 * about each subtype closes it. This second arm is why a PUBLIC field needs more than
	 * the body scan a private one does — a private member is not reachable through an
	 * outside receiver in the first place.
	 */
	public static inline function subtypeWriteReaches(
		owner: String, name: String, index: SymbolIndex, writeIndex: FieldWriteIndex, plugin: GrammarPlugin
	): Bool {
		return scopeOf(
			index, plugin
		)
			.subtypeDeclMatches(
				owner, name,
				(subtype, src, span, redeclares) ->
					redeclares || writeIndex.writtenAnywhere(subtype, name)
					|| subtypeReach(scopeOf(index, plugin), subtype, name, src, span)
			);
	}

	/**
	 * Whether any (transitive) subtype of `owner` MENTIONS the inherited member `name` at all —
	 * the weaker question a rule changing how a member is REACHED must ask, where the write scans
	 * above ask about mutability. A subtype reads a private INSTANCE field unqualified and it
	 * resolves; the same bare read of a private STATIC of the superclass is `Unknown identifier`
	 * (measured on Haxe 4.3.7, `--interp` and `-cpp` alike), so `instance final -> static final`
	 * needs every such read rewritten to `Owner.NAME` — an edit `Check.fix` cannot make, since it
	 * is handed one file. A mention therefore refuses outright.
	 *
	 * Fails closed on the same terms as `subtypeMayWrite`: an unresolvable hierarchy, a subtype
	 * whose source was not retained, a REdeclaration of the name, and an `@:build` in the
	 * subtype's file (a macro can inject a read no text scan sees) all answer true. Same index
	 * choice too — the resolution scope when one is configured, else the report index.
	 */
	public static inline function subtypeMayReference(owner: String, name: String, index: SymbolIndex, plugin: GrammarPlugin): Bool {
		return scopeOf(
			index, plugin
		)
			.subtypeDeclMatches(
				owner, name,
				(subtype, src, span, redeclares) ->
					redeclares || mayReference(src, name, span.from, span.to)
					|| scopeOf(index, plugin).accessGrantMatches(subtype, granted -> mayReference(granted, name, 0, granted.length))
			);
	}

	/** Whether any file granting itself `@:access(owner)` MENTIONS `name` — `accessGrantMayWrite`'s read counterpart (see `subtypeMayReference`). */
	public static inline function accessGrantMayReference(owner: String, name: String, index: SymbolIndex, plugin: GrammarPlugin): Bool {
		return scopeOf(index, plugin).accessGrantMatches(owner, src -> mayReference(src, name, 0, src.length));
	}

	/**
	 * Whether any file granting itself `@:access(owner)` may write `name`. The grant is
	 * file-scoped — every member of such a file reaches the type's privates — so the whole
	 * grantee source is scanned, unlike a subtype's declaration slice.
	 */
	public static inline function accessGrantMayWrite(owner: String, name: String, index: SymbolIndex, plugin: GrammarPlugin): Bool {
		return scopeOf(index, plugin).accessGrantMatches(owner, src -> mayWrite(src, name, 0, src.length));
	}

	/**
	 * Whether `source` carries a `@:build` / `@:autoBuild` — a macro can add a member the
	 * text scan cannot see, so a file with one counts as a possible writer. A mention inside
	 * a comment or string over-counts, which only ever keeps the looser access. The one shape
	 * this cannot see is metadata injected by the BUILD (`--macro addMetadata(...)` in an
	 * hxml); that is outside any source scan, and the compiler oracle is the net for it.
	 */
	public static inline function carriesBuildMacro(source: String): Bool {
		return source.indexOf('@:build') >= 0 || source.indexOf('@:autoBuild') >= 0;
	}

	/**
	 * Whether `name` is written anywhere in `source` outside `exclude` (typically its own
	 * declaration), over the offsets `from ... to` only. A candidate name must lie WHOLLY
	 * inside the range; the operator scan that follows it may run past `to`, and the
	 * word-boundary tests read the real neighbouring characters rather than the range edges.
	 */
	public static function writtenInRange(source: String, name: String, exclude: Null<Span>, from: Int, to: Int): Bool {
		final n: Int = source.length;
		final len: Int = name.length;
		if (len == 0) return false;
		var at: Int = from;
		while (true) {
			final idx: Int = source.indexOf(name, at);
			if (idx < 0 || idx + len > to) return false;
			at = idx + len;
			final boundedBefore: Bool = idx == 0 || !RefactorSupport.isIdentChar(source.fastCodeAt(idx - 1));
			final boundedAfter: Bool = at >= n || !RefactorSupport.isIdentChar(source.fastCodeAt(at));
			if (!boundedBefore || !boundedAfter) continue;
			if (exclude != null && idx >= exclude.from && idx < exclude.to) continue;
			if (precededByIncrDecr(source, idx) || followedByAssign(source, at)) return true;
		}
	}

	/**
	 * Whether any (transitive) subtype of `owner` may write the inherited member `name`.
	 * True when the hierarchy cannot be resolved (`SymbolIndex.subtypeDeclMatches` reports
	 * an unretained source or a simple-name collision) and when a subtype REDECLARES the
	 * name — an ambiguously-named member is exactly what a write scan cannot rule out.
	 * The index the SUBTYPE questions run against: the resolution scope when one is
	 * configured (`resolutionLibs` / `resolutionRoots` — a subtype declared in a library
	 * root counts), else the report index. Resolved HERE rather than by each check so a
	 * check never holds a resolution index: handing one to `skippedFiles` would silence the
	 * rule on every project with libraries (they routinely contain skip-parsing files), and
	 * that mistake is now unrepresentable. Resolving at the point of use also keeps the
	 * build LAZY — `resolutionIndex()` memoises on the plugin, and a run whose candidates
	 * all bail before the subtype question never pays for it.
	 */
	private static inline function scopeOf(index: SymbolIndex, plugin: GrammarPlugin): SymbolIndex {
		return RefactorSupport.resolutionIndexOf(plugin) ?? index;
	}

	/**
	 * Whether the offsets `from ... to` of `src` may write `name`: either a build macro can
	 * inject a member the text scan cannot see, or the scan finds a write outright.
	 */
	private static inline function mayWrite(src: String, name: String, from: Int, to: Int): Bool {
		return carriesBuildMacro(src) || writtenInRange(src, name, null, from, to);
	}

	/**
	 * Whether the offsets `from ... to` of `src` may MENTION `name`: either a build macro can
	 * inject a reference the text scan cannot see, or the name occurs as a word-boundary token.
	 */
	private static inline function mayReference(src: String, name: String, from: Int, to: Int): Bool {
		return carriesBuildMacro(src) || RefactorSupport.referencedInRange(src, name, from, to, []);
	}

	/** Whether `c` is an operator character that can form an assignment token. */
	private static inline function isOperatorChar(c: Int): Bool {
		return switch c {
			case '='.code, '+'.code, '-'.code, '*'.code, '/'.code, '%'.code, '&'.code, '|'.code, '^'.code, '<'.code, '>'.code, '?'.code,
				'~'.code, '!'.code: true;
			case _: false;
		};
	}

	/**
	 * The ways a write to `owner`'s member `name` can arrive through the SUBTYPE `subtype`
	 * without the write index attributing it to `owner`: inside the subtype's own body, or
	 * from a file granting itself `@:access(subtype)`. The second is not theoretical even
	 * for a PRIVATE member — `@:access(Sub)` in a third file makes `s.p = 5` on `s:Sub`
	 * compile against a `p` declared in `Sub`'s SUPERtype, while a grant scan keyed on the
	 * owner sees nothing (that file's grant list names the subtype, not the owner).
	 */
	private static function subtypeReach(scope: SymbolIndex, subtype: String, name: String, src: String, span: Span): Bool {
		return mayWrite(src, name, span.from, span.to)
			|| scope.accessGrantMatches(subtype, granted -> mayWrite(granted, name, 0, granted.length));
	}

	/**
	 * Whether the non-whitespace token immediately before `idx`, skipping any interposed
	 * block comment, is `++` or `--` (a prefix increment / decrement — a write). Symmetric
	 * with `followedByAssign`'s comment-skipping so a write with a comment between the
	 * operator and the name is not missed.
	 */
	private static function precededByIncrDecr(source: String, idx: Int): Bool {
		var i: Int = idx - 1;
		while (i >= 0) {
			final c: Int = source.fastCodeAt(i);
			if (RefactorSupport.isSpace(c)) {
				i--;
				continue;
			}
			if (c == '/'.code && i >= 1 && source.fastCodeAt(i - 1) == '*'.code) {
				i -= 2;
				while (i >= 1 && (source.fastCodeAt(i - 1) != '/'.code || source.fastCodeAt(i) != '*'.code)) i--;
				i -= 2;
				continue;
			}
			break;
		}
		if (i < 1) return false;
		final c0: Int = source.fastCodeAt(i - 1);
		final c1: Int = source.fastCodeAt(i);
		return (c0 == '+'.code && c1 == '+'.code) || (c0 == '-'.code && c1 == '-'.code);
	}

	/**
	 * Whether the operator token starting (past whitespace and comments) at `pos` is an
	 * assignment: `++` / `--`, or an operator run ending in `=` that is not a comparison
	 * (`==` / `<=` / `>=` / `!=`) or the lambda arrow (`=>`).
	 */
	private static function followedByAssign(source: String, pos: Int): Bool {
		final n: Int = source.length;
		var i: Int = RefactorSupport.skipForwardTrivia(source, pos);
		final start: Int = i;
		while (i < n && isOperatorChar(source.fastCodeAt(i))) i++;
		final token: String = source.substring(start, i);
		return token == '++' || token == '--'
			|| (token.length != 0 && token.fastCodeAt(token.length - 1) == '='.code && token != '==' && token != '<=' && token != '>='
				&& token != '!=' && token != '=>');
	}

}
