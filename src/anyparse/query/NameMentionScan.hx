package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * "Does this SOURCE spell this NAME where the compiler would bind it?" — the one raw-text
 * question the move family asks of a file, in the three shapes its call sites need, plus the
 * PROVEN parse-tree counterpart that answers the same question without the text scan's
 * imprecision.
 *
 * It lives in one module because the family kept growing hand-rolled copies that disagreed. Each
 * copy assembled its own exclusion set and each drifted separately: `qualifiedPathRefusal` and
 * `namesAnyOf` were taught to skip comment interiors in S80 while `referencedInDest` was left
 * counting them, so ONE doc line naming a dependency refused a legitimate carry with advice that
 * means nothing for prose (T535). A reader adding a fourth spelling of the question has to look
 * at the other three first.
 *
 * THE MASK IS ONE, AND IT IS A PROPERTY OF THE LANGUAGE, NOT OF THE CALLER. A comment is never
 * compiled, so an occurrence inside one can never be the reference any of these gates exists for
 * — true whether the answer WRITES an import or REFUSES the move. A STRING is the other way: it
 * can be read back by `Reflect` or a macro and nothing in the repair walk rewrites one, so it
 * counts, and it counts on both sides too. That is why the polarity of a caller does not appear
 * in these names: it decides which errors are TOLERABLE, never which occurrences are references.
 *
 * The polarity does decide which of the two scans a caller may ask. The text scan over-counts by
 * construction — a string, an interpolation-escape spelling, a name inside an unparsed `#if`
 * branch — which keeps an import that is merely redundant, and refuses a move that is merely
 * legitimate. Where a wrong answer WRITES, that direction is free; where it REFUSES a move a user
 * asked for, `nodeNamesAny` over `provenRefKinds` is the answer to ask instead, and
 * `MoveSymbol.moveType` asks exactly that for the module-private arm.
 */
@:nullSafety(Strict)
final class NameMentionScan {

	/**
	 * Does `source` name any of `names` by its bare name, outside `excluded` spans and outside its
	 * comments?
	 *
	 * The question a MODULE statement's fate turns on: repointing or removing one takes away every
	 * type the module declares, so what decides is whether the file still names ANY of them. The
	 * statementless repair walk, the source file's own re-import and the destination collision scan
	 * ask it too, so all of them answer alike.
	 *
	 * `regions` are passed on to the scan as well, for a SECOND and unrelated job: deciding whether
	 * a `.` in front of an occurrence is a real qualifier or a comment's own full stop. Dropping
	 * them there uncounts a real code reference on the line BELOW a comment ending in a period —
	 * pinned by `testACommentsTrailingPeriodDoesNotHideTheReferenceOwedARepairImport`, which is what
	 * separates a comment-ADJACENT reference (counted) from a comment-INTERIOR mention (not).
	 */
	public static function sourceNamesAny(source: String, names: Array<String>, excluded: Array<Span>, regions: Array<LexRegion>): Bool {
		final comments: Array<Span> = SourceComments.collectCommentRegions(regions);
		final outside: Array<Span> = excluded.concat(comments);
		return names.exists(n -> OccurrenceScan.referencedUnqualifiedInRange(source, n, 0, source.length, outside, comments));
	}

	/**
	 * Does the DESTINATION's own code name `name` outside its import statements — the test that
	 * decides whether a differing binding is OBSERVABLE there, and therefore whether carrying a
	 * dependency import would silently rebind that file's own references.
	 *
	 * The mask this adds over `sourceNamesAny` is the destination's own header type parameters. A
	 * type that declares `name` as one spells it all over its own body and the scan cannot tell
	 * that from a reference to a module of that name, so those declarations' spans are excluded
	 * alongside the import statements. Excluded by SPAN rather than by a file-wide flag:
	 * `class Box<Date>` says nothing about a `Date` a SIBLING type in the same module writes, and
	 * cancelling the whole file on it left that sibling's carry unrefused (compile-run to a changed
	 * runtime class with rc 0).
	 *
	 * And only for a type that declares NO STATIC member, because a class type parameter is not in
	 * scope inside one — `class Box<Date> { static function tag() return Date.now(); }` compiles and
	 * answers the STDLIB `Date`, measured on 4.3.7 — so a static member's `Date` is an ambient
	 * reference the exclusion would hide. The index carries a member's start offset but not its end,
	 * so the span cannot be cut around the statics; refusing to exclude at all when the type has any
	 * is the direction that costs a refusal rather than a rebind.
	 */
	public static function destinationNamesType(destSource: String, destInfo: FileInfo, name: String, regions: Array<LexRegion>): Bool {
		final excluded: Array<Span> = [for (imp in destInfo.imports) imp.span];
		for (t in destInfo.types) if (t.typeParamNames.contains(name) && !t.members.exists(m -> m.isStatic)) excluded.push(t.span);
		return sourceNamesAny(destSource, [name], excluded, regions);
	}

	/**
	 * The offset at which `source` spells the DOTTED `path` as a whole token outside `excluded` and
	 * outside `comments`, or -1 when it holds none.
	 *
	 * The same question as `sourceNamesAny` asked of a fully-qualified path rather than a bare name,
	 * and the caller wants the OFFSET because it reports the file. `excluded` is the caller's job
	 * because only it knows which statements bind the path: an import spelling it is not a code
	 * reference, and an ALIAS statement's `raw` is the alias, so a caller reading `raw` instead of
	 * `SymbolIndex.pathImportedBy` would read the statement's own path as a code reference and refuse
	 * a move over a file that only ever names the type through the alias.
	 */
	public static function qualifiedPathMention(source: String, path: String, excluded: Array<Span>, comments: Array<Span>): Int {
		var from: Int = 0;
		while (true) {
			final at: Int = source.indexOf(path, from);
			if (at < 0) return -1;
			from = at + 1;
			final beforeOk: Bool = at == 0 || !SourceText.isIdentChar(source.fastCodeAt(at - 1));
			final afterIdx: Int = at + path.length;
			final afterOk: Bool = afterIdx >= source.length || !SourceText.isIdentChar(source.fastCodeAt(afterIdx));
			if (beforeOk && afterOk && !OccurrenceScan.offsetWithinAny(at, comments) && !OccurrenceScan.offsetWithinAny(at, excluded))
				return at;
		}
	}

	/**
	 * Does `tree` carry a node of one of `kinds` named by one of `names`, outside `cut`?
	 *
	 * The PROVEN counterpart of `sourceNamesAny`, and the answer a REFUSAL asks: a string literal is
	 * a literal node and a comment is no node at all, so neither of the two things the text scan
	 * over-counts can reach this one.
	 */
	public static function nodeNamesAny(node: QueryNode, names: Array<String>, cut: Span, kinds: Array<String>): Bool {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (
			name != null && span != null && kinds.contains(node.kind) && names.contains(name)
			&& (span.from < cut.from || span.from >= cut.to)
		)
			return true;
		return node.children.exists(c -> nodeNamesAny(c, names, cut, kinds));
	}

	/**
	 * The kinds a PROVEN reference projects as: every type position, plus the bare identifier — which
	 * is what a static receiver, a constructor pattern (`case Red:`) and a value position all reduce
	 * to. The kind set `nodeNamesAny` has to be handed to answer the same question the text scan does.
	 */
	public static function provenRefKinds(plugin: GrammarPlugin, typeRefShape: TypeRefShape): Array<String> {
		final shape: RefShape = plugin.refShape();
		final out: Array<String> = typeRefShape.typeRefKinds.copy();
		// `identKind` is the braced interpolation's inner kind as well as the plain one, but the
		// UNBRACED `'$Moved'` form projects as its own kind, which the shape already names and ~20
		// checks already read. Re-deriving the question here instead of asking cost the refusal on a
		// module-private type whose only remaining reference was `'v=$Moved'` — compile-proved:
		// `Unknown identifier : Moved` after a move this arm reported at rc 0.
		for (kind in [shape.identKind, shape.stringInterpIdentKind]) if (kind != null && !out.contains(kind)) out.push(kind);
		return out;
	}

	/**
	 * The spans a reference scan over `info`'s file must not count: its own import statements, plus
	 * the span a move is about to cut out of it when one is given.
	 *
	 * Every "does this file still name the type" question in the move op starts from THIS exclusion
	 * set — the importer walk, the statementless repair walk and the source file's own re-import.
	 * Until 2026-08-31 the last two asked a DIFFERENT question: a type-position walk over
	 * `parseFileTypeRefs`, which sees `Dep` in `var d: Dep` and NOT in `Dep.go()`. Both answers were
	 * compile-proved wrong on the receiver form at rc 0 — a scope file that reached the moved type
	 * only through `Moved.use()` got no repair import (`Type not found : Moved` in a file the move
	 * never touched), and a source file that kept one after the cut got none either.
	 */
	public static function referenceExclusions(info: FileInfo, ?cut: Span): Array<Span> {
		final out: Array<Span> = [for (imp in info.imports) imp.span];
		if (cut != null) out.push(cut);
		return out;
	}

}
