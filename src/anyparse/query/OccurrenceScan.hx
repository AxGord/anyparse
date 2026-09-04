package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.OccurrenceScan.OccurrenceClass;
import anyparse.query.Refs.RefHit;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * One word-boundary occurrence of a NAME in a source, and what may be done with it. The
 * question this module owns is not "where does the name appear" — that is a text scan
 * (`SourceText.identTokenOffset`) — but "what KIND of place is this occurrence in": active
 * code, the raw bytes of an unparsed conditional region, a comment, a string that names the
 * identifier, a string that merely contains the word, or a tool directive.
 *
 * That classification is the completeness gate a rename owes: only a class that can carry a
 * REFERENCE blocks the rewrite (see `RefactorSupport.OccurrenceClass`). The range predicates
 * built on it — `referencedInRange`, `referencedUnqualifiedInRange`, `nameBoundInRange` — are
 * the conservative "is this name used / bound here" primitives the dead-code checks share, and
 * they live here rather than beside the text scan because each one is a statement about
 * BINDING, not about bytes.
 */
@:nullSafety(Strict)
final class OccurrenceScan {

	/** The numeric escapes that spell the interpolation trigger `$` (see `interpolationEscapeBefore`). */
	private static final DOLLAR_ESCAPES: Array<String> = ['\\x24', '\\u0024'];

	/**
	 * Does `name` occur as a word-boundary identifier token within
	 * `source[from, end)` at an offset that lies inside none of `excluded`?
	 * The conservative "is this name referenced" primitive shared by the
	 * dead-code checks: `unused-import` scans the whole file excluding the
	 * import statements; `unused-local` scans a declaration's enclosing scope
	 * excluding the declaration itself. Word-boundary = a non-identifier char on
	 * both sides, so `name` does not match inside `nameSuffix`. A textual scan
	 * (not an AST projection) is deliberate: it catches reference forms the
	 * grammar hides under non-obvious ctors (`'$name'` simple interpolation,
	 * macro reification) at the cost of also counting the name in comments /
	 * strings — which only ever keeps a binding, never wrongly deletes one.
	 * `end` is clamped to the source length. A dotted path's tail counts too
	 * (`this.name` IS a read of member `name`); the callers for which it is not —
	 * `unused-import`, since an import binds a SIMPLE name — take
	 * `referencedUnqualifiedInRange` instead.
	 *
	 * One boundary is not spelled with a boundary CHARACTER: a numeric escape
	 * (`\x24`, `$`) that decodes to the interpolation trigger `$` ends in a
	 * hex digit, so a plain word-boundary test reads `'\x24name'` as one long
	 * token and misses a real read (see `interpolationEscapeBefore`).
	 */
	public static inline function referencedInRange(source: String, name: String, from: Int, end: Int, excluded: Array<Span>): Bool {
		return scanReference(source, name, from, end, excluded, null);
	}

	/**
	 * `referencedInRange` restricted to occurrences that stand as a SIMPLE name —
	 * an occurrence whose preceding non-whitespace character is a qualification
	 * `.` does not count. The test `unused-import` needs: a Haxe import binds a
	 * simple name, while a dotted path resolves from its ROOT
	 * (`haxe.macro.Context.currentPos()` needs no import at all), so a tail
	 * segment never goes through one. The ROOT of a path is not dot-preceded and
	 * still counts — `Mod.VALUE` is exactly what `import pkg.Mod;` provides.
	 *
	 * A SINGLE dot qualifies. `...` is the range / rest operator, not a
	 * qualifier: in `for (i in 0...Limit.MAX)` the name IS dot-preceded, yet it
	 * is a bare reference — reading that as qualification would delete an import
	 * the build needs. Safe navigation (`o?.f`) and a field access inside string
	 * interpolation (`'${o.f}'`) are single-dot field accesses and are correctly
	 * skipped by the same test.
	 *
	 * A SEPARATE method rather than a tightening of `referencedInRange`: the
	 * shared predicate's over-counting is load-bearing for its other callers —
	 * `unused-private` reads `this.field` as a genuine reference, and a stricter
	 * answer there would delete a live member.
	 *
	 * `commentRegions` (`collectCommentRegions`, hoisted once per file by the
	 * caller) is REQUIRED, not a convenience: a line comment ending in a sentence
	 * period puts a `.` directly before the next line's first token, and reading
	 * that as qualification deletes an import the build needs. It is the only
	 * inert construct that can end in a bare `.` — a string / regex / block
	 * comment closes with its own delimiter — but the mask is exact for all of
	 * them and costs one scan per file.
	 */
	public static inline function referencedUnqualifiedInRange(
		source: String, name: String, from: Int, end: Int, excluded: Array<Span>, commentRegions: Array<Span>
	): Bool {
		return scanReference(source, name, from, end, excluded, commentRegions);
	}

	/**
	 * Offset of the first word-boundary occurrence of `name` within
	 * `[span.from, span.to)` that lives in code the compiler sees, or -1
	 * when the window holds none. Identical to `identTokenOffset` except
	 * that a match inside COMMENT trivia is skipped, so a comment sitting
	 * between a receiver and its member never wins the race for the member
	 * token (the window a caller derives from two AST spans also contains
	 * every byte of trivia between them).
	 *
	 * String literals and `#if` bodies are deliberately NOT skipped: a
	 * `${obj.member}` interpolation and a conditionally compiled access are
	 * both live references a rename has to reach.
	 */
	public static function activeCodeIdentTokenOffset(source: String, span: Span, name: String, regions: Array<LexRegion>): Int {
		var from: Int = span.from;
		while (from < span.to) {
			final at: Int = SourceText.identTokenOffset(source, new Span(from, span.to), name);
			if (at < 0 || !LexicalRegions.offsetWithinComment(at, regions)) return at;
			from = at + 1;
		}
		return -1;
	}

	/**
	 * The span of the first standalone `name` token within `source[from, stop)` that a `$`
	 * does NOT precede, or null when the window holds none — the BINDER a self-scoped
	 * construct spells first (`for (item in …)`, `var name = …`).
	 *
	 * Word-boundary matching rides on `identTokenOffset`, so the token model stays in one
	 * place; the only thing this adds is the `$` rejection. That one gate is what separates a
	 * binder scan from a REFERENCE scan: `'$name'` is a simple interpolation READ, and a
	 * caller that accepted it would place the binder token inside a string literal — claiming
	 * a shadowed region the declaration never owns (`unused-local`) or renaming an occurrence
	 * that is not the declaration (`guard-continue`'s de-nest). The opposite direction is
	 * `referencedInRange`, which deliberately COUNTS `$name` (and even the `\x24name` escape
	 * spelling) because there a missed read costs a wrongly deleted binding.
	 */
	public static function binderTokenSpan(source: String, from: Int, stop: Int, name: String): Null<Span> {
		var at: Int = from;
		while (at < stop) {
			final hit: Int = SourceText.identTokenOffset(source, new Span(at, stop), name);
			if (hit < 0) return null;
			if (hit == 0 || source.fastCodeAt(hit - 1) != '$'.code) return new Span(hit, hit + name.length);
			at = hit + 1;
		}
		return null;
	}

	/**
	 * Push a `[from, from+length)` span into `out`, deduped by `from`: a
	 * non-negative `from` not already in `seen` is recorded and appended.
	 * The dedup-and-collect idiom shared by the occurrence collectors of
	 * `Rename` and `CrossRename` (the same identifier-token offset can be
	 * surfaced by more than one walker).
	 */
	public static function pushUniqueSpan(out: Array<Span>, seen: Array<Int>, from: Int, length: Int): Void {
		if (from < 0 || seen.contains(from)) return;
		seen.push(from);
		out.push(new Span(from, from + length));
	}

	/**
	 * The spans of every MODULE-PATH declaration in `tree` (`RefShape.modulePathKinds` — Haxe's
	 * `package` / `import`). Their text is a dotted path, so a word-boundary identifier match
	 * inside one is a package segment or a type name, never a use of a local or a member: a
	 * completeness scan excludes these the way it excludes an occurrence already attributed
	 * elsewhere. Empty for a grammar that declares no such kinds.
	 */
	public static function modulePathSpans(tree: QueryNode, shape: RefShape): Array<Span> {
		final kinds: Null<Array<String>> = shape.modulePathKinds;
		if (kinds == null || kinds.length == 0) return [];
		final out: Array<Span> = [];
		collectModulePathSpans(tree, kinds, out);
		return out;
	}

	/**
	 * Does `source` reference `name` as a member access — a `.name` with a `.`
	 * immediately before and a word boundary after? This is the form a `using`'s
	 * extension method takes whether it is called (`s.trim()`) or captured as a
	 * value (`var f = s.trim`), so the `unused-import` check uses it to decide a
	 * `using` is live. Deliberately does NOT require a trailing `(`: a captured
	 * function reference is just as much a use, and skipping the check also avoids
	 * missing a call separated from its name by a comment. Like `referencedInRange`
	 * it is a textual scan that also counts the form inside a comment / string —
	 * which only ever keeps a `using`, never wrongly deletes one (the safe
	 * direction for an autofix).
	 *
	 * `skipReceiver`, when given, excludes an occurrence whose receiver is exactly
	 * that simple name. Its caller has already established that the name is not
	 * referenced bare, so every occurrence of it is dot-qualified — which makes
	 * `Limit.MAX` on a `using a.b.Limit` a fully-qualified STATIC access reaching
	 * the type through no import at all, not the extension call the `using` enables.
	 */
	public static function methodCalledInSource(source: String, name: String, ?skipReceiver: String): Bool {
		final len: Int = name.length;
		if (len == 0) return false;
		final skip: String = skipReceiver ?? '';
		inline function qualifiedBySkip(dotAt: Int): Bool {
			final start: Int = dotAt - skip.length;
			return skip.length > 0 && start >= 0 && source.substr(start, skip.length) == skip
				&& (start == 0 || !SourceText.isIdentChar(source.fastCodeAt(start - 1)));
		}
		var i: Int = 0;
		while (true) {
			final at: Int = source.indexOf(name, i);
			if (at < 0) return false;
			i = at + 1;
			if (at == 0 || source.fastCodeAt(at - 1) != '.'.code) continue;
			final afterIdx: Int = at + len;
			if (afterIdx < source.length && SourceText.isIdentChar(source.fastCodeAt(afterIdx))) continue;
			if (!qualifiedBySkip(at - 1)) return true;
		}
	}

	/** Is `offset` inside any of `spans` (`from`-inclusive, `to`-exclusive)? */
	public static function offsetWithinAny(offset: Int, spans: Array<Span>): Bool {
		return spans.exists(s -> offset >= s.from && offset < s.to);
	}

	/**
	 * Classify every word-boundary occurrence of `name` in `source[from...end)`
	 * (offsets inside `excluded` skipped) by lexical context, built on top of the
	 * parse so `#if...#end` regions and trivia are exact. Returns null when
	 * `source` does not parse — the caller then falls back to the raw scan
	 * (fail-closed). See `OccurrenceClass` for what each class means.
	 */
	public static function classifyOccurrences(
		source: String, name: String, plugin: GrammarPlugin, from: Int, end: Int, excluded: Array<Span>
	): Null<Array<ClassifiedOccurrence>> {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return null catch (exception: Exception) return null;
		final out: Array<ClassifiedOccurrence> = [];
		final len: Int = name.length;
		if (len == 0) return out;
		final condSpans: Array<Span> = [];
		collectConditionalSpans(tree, condSpans);
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final stop: Int = end <= source.length ? end : source.length;
		var i: Int = from;
		while (i + len <= stop) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + len > stop) break;
			i = at + 1;
			final afterIdx: Int = at + len;
			final beforeOk: Bool = at == 0 || !SourceText.isIdentChar(source.fastCodeAt(at - 1));
			final afterOk: Bool = afterIdx >= source.length || !SourceText.isIdentChar(source.fastCodeAt(afterIdx));
			if (beforeOk && afterOk && !offsetWithinAny(at, excluded))
				out.push({ span: new Span(at, afterIdx), kind: classifyAt(source, at, len, condSpans, regions) });
		}
		return out;
	}

	/**
	 * Whether `name` is BOUND as an identifier anywhere in `source[from...end)`
	 * outside `excluded` - the precise form of the question a COLLISION gate asks:
	 * "is the target name already taken where this rename lands?". Answered from
	 * the parse (`classifyOccurrences`) instead of raw text, so a comment mention,
	 * an inert string literal and the member-name slot of a dotted access
	 * (`o.name`) are correctly none of them bindings.
	 *
	 * NOT a replacement for `referencedInRange`, whose imprecision is
	 * LOAD-BEARING for its other callers: the `unused-*` family reads a `false`
	 * as "nothing uses this, delete it", and the occurrences skipped here - a
	 * dotted `obj.member` above all - are exactly its real uses. The conservative
	 * direction of the question belongs to the CALL SITE, so the two queries
	 * coexist and only a veto-side caller may use this one.
	 *
	 * Deliberately conservative wherever a precise answer would cost another
	 * scan: CODE inside a `#if` body counts (it hosts real declarations), a
	 * single-quoted literal that can interpolate counts wholesale rather than
	 * resolving which of its parts are code, a comment between the dot and the name
	 * leaves the dotted test false, and a parse failure falls back to
	 * `referencedInRange`. Each of those over-reports, which for a veto gate is a
	 * missed fix - never a wrong one.
	 *
	 * A STRUCTURE-FIELD name is not excluded here: it needs the parse tree, which
	 * this signature does not carry, and its safety is caller-dependent (a
	 * `@:structInit` object literal DOES name the class's own fields). The caller
	 * that can cede it passes `structureFieldNameSpans` in `excluded`.
	 */
	public static function nameBoundInRange(
		source: String, name: String, from: Int, end: Int, excluded: Array<Span>, plugin: GrammarPlugin
	): Bool {
		final classified: Null<Array<ClassifiedOccurrence>> = classifyOccurrences(source, name, plugin, from, end, excluded);
		if (classified == null) return referencedInRange(source, name, from, end, excluded);
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		for (occ in classified) switch occ.kind {
			// A word inside a longer literal binds nothing, whatever the literal interpolates.
			case CommentTrivia, DirectiveComment, StringWord:
			case StringLiteral if (!interpolatingLiteralAt(source, occ.span.from, regions)):
			case _:
				if (!isMemberNamePosition(source, occ.span.from)) return true;
		}
		return false;
	}

	/**
	 * The identifier-token span of every STRUCTURE-FIELD name in `tree` — a member of an
	 * anonymous-structure type (`{ x:Float }`), of an object literal (`{ x: 1 }`) or of a
	 * structure PATTERN (`case { x: n }`), per `shape.structureFieldHostKinds`. Such a name
	 * is reachable only through a receiver, so it binds nothing in the surrounding scope and
	 * a collision gate over a LOCAL / PARAMETER rename may subtract it: a module-level
	 * `typedef Zoom = { x:Float }` otherwise vetoes every `_x -> x` in the file.
	 *
	 * Only the NAME token is returned, never the whole field node — an object literal's VALUE
	 * is ordinary code that may well bind the name. Empty for a grammar leaving the slot unset.
	 *
	 * Not for a FIELD rename: under `@:structInit` an object literal's keys ARE the class's
	 * own field names, so subtracting them would silently break the construction site.
	 */
	public static function structureFieldNameSpans(tree: QueryNode, source: String, shape: RefShape): Array<Span> {
		final out: Array<Span> = [];
		final hosts: Array<String> = shape.structureFieldHostKinds ?? [];
		if (hosts.length > 0) collectStructureFieldNames(tree, source, hosts, out);
		return out;
	}

	/**
	 * The span of a braceless `$name` interpolation read of the binding at `binding` that
	 * `occurrences` does NOT rewrite, or null when every one of them is covered.
	 *
	 * Asked over the resolved hits, not by walking the tree for the name: a read bound to a
	 * SHADOWING binding of the same name is none of this rename's business, and matching on
	 * the name alone refuses it as if it were. The read's node span covers the bytes that
	 * SPELL it (the `$` included), so a rewritten one CONTAINS its occurrence. One is
	 * missing exactly when `identTokenOffset` could not locate the identifier token in the
	 * raw source — an escape-spelled `$` or name — and splicing the rest would leave that
	 * read bound to a name the rewrite has removed.
	 */
	public static function unrewrittenInterpRead(hits: Array<RefHit>, binding: Int, occurrences: Array<Span>): Null<Span> {
		for (h in hits) if (h.interpolated) {
			final bound: Null<Span> = h.bindingSpan;
			if (bound == null || bound.from != binding) continue;
			if (!occurrences.exists(o -> h.span.from <= o.from && o.to <= h.span.to)) return h.span;
		}
		return null;
	}

	/**
	 * The span of a `${ … }` interpolation in `node`'s subtree that carries NO parsed
	 * expression, or null. Only the rescan of an escape-spelled `$` synthesizes one
	 * (`HxInterpProjection`): its interior does not exist contiguously in the source, so no
	 * subtree is built and any identifier read inside it is invisible to every reference
	 * scan — a rewrite touching such a name would silently part-apply. Reported
	 * unconditionally rather than by scanning the interior for a name: the interior may
	 * spell that name with escapes too, so a text scan cannot prove absence.
	 */
	public static function unreadableInterpBlock(node: QueryNode, blockKind: String): Null<Span> {
		if (node.kind == blockKind && node.children.length == 0) return node.span;
		for (c in node.children) {
			final found: Null<Span> = unreadableInterpBlock(c, blockKind);
			if (found != null) return found;
		}
		return null;
	}

	/** The scan behind `referencedInRange` / `referencedUnqualifiedInRange`; a non-null `commentRegions` drops dot-qualified occurrences. */
	private static function scanReference(
		source: String, name: String, from: Int, end: Int, excluded: Array<Span>, commentRegions: Null<Array<Span>>
	): Bool {
		final len: Int = name.length;
		if (len == 0) return false;
		final stop: Int = end <= source.length ? end : source.length;
		var i: Int = from;
		while (i + len <= stop) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + len > stop) return false;
			final beforeOk: Bool = at == 0 || !SourceText.isIdentChar(source.fastCodeAt(at - 1)) || interpolationEscapeBefore(source, at);
			final afterIdx: Int = at + len;
			final afterOk: Bool = afterIdx >= source.length || !SourceText.isIdentChar(source.fastCodeAt(afterIdx));
			if (beforeOk && afterOk && !offsetWithinAny(at, excluded) && !qualifiedBefore(source, at, commentRegions)) return true;
			i = at + 1;
		}
		return false;
	}

	/**
	 * Is the token starting at `at` the TAIL of a dotted path — its preceding
	 * non-whitespace character a qualification `.`? Whitespace is skipped
	 * backwards, since a path may be broken across lines (`haxe.macro\n\t.Context`).
	 * A null `commentRegions` disables the test entirely (the plain
	 * `referencedInRange` scan, which counts every occurrence).
	 *
	 * Two dots are NOT one: a dot preceded by another belongs to `...` (range /
	 * rest), never to a field access, so `0...Limit.MAX` reads `Limit` as the bare
	 * reference it is. And a dot inside a COMMENT qualifies nothing — the period
	 * ending `// … before the process dies.` sits directly before the next line's
	 * first token and would otherwise mark a live call as a qualified tail. Only a
	 * LINE comment can end in a bare `.` that way — every other inert construct
	 * closes with its own delimiter — but the mask is exact for all of them.
	 *
	 * WHITESPACE only, not trivia: a comment spliced between the dot and the name
	 * stops the walk short, so that occurrence reads as unqualified and COUNTS.
	 * The over-counting direction — an import kept, never one deleted.
	 */
	private static function qualifiedBefore(source: String, at: Int, commentRegions: Null<Array<Span>>): Bool {
		if (commentRegions == null) return false;
		var j: Int = at - 1;
		while (j >= 0 && SourceText.isSpace(source.fastCodeAt(j))) j--;
		return j >= 0 && source.fastCodeAt(j) == '.'.code && (j <= 0 || source.fastCodeAt(j - 1) != '.'.code)
			&& !offsetWithinAny(j, commentRegions);
	}

	/**
	 * Whether the text directly before `at` is a numeric escape spelling the
	 * interpolation trigger `$` — `\x24` or `$`. A string literal's escapes are
	 * DECODED before the interpolation scan runs over the result, so `'\x24name'` is a
	 * read of `name` exactly as `'$name'` is; but the escape ends in a hex digit, which
	 * the word-boundary test above reads as "still the same token" and would report as
	 * NO reference — the one direction that costs a wrongly deleted binding.
	 *
	 * Deliberately spelling-based, not decode-based: this scan runs over raw source
	 * with no idea which regions are string literals, so `'\\x24name'` (a literal
	 * backslash, decoding to no `$` at all) also answers yes. That is the harmless
	 * direction — an extra KEPT binding, the same over-counting the textual scan
	 * already accepts for names inside comments.
	 */
	private static function interpolationEscapeBefore(source: String, at: Int): Bool {
		return DOLLAR_ESCAPES.exists(e -> at >= e.length && source.substr(at - e.length, e.length) == e);
	}

	private static function collectModulePathSpans(node: QueryNode, kinds: Array<String>, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		if (kinds.contains(node.kind) && span != null) {
			out.push(span);
			return;
		}
		for (child in node.children) collectModulePathSpans(child, kinds, out);
	}

	/** Collect the span of every `#if...#end` region node into `out` (recursive). */
	private static function collectConditionalSpans(node: QueryNode, out: Array<Span>): Void {
		if (CondRegionScan.isConditionalKind(node.kind)) {
			final s: Null<Span> = node.span;
			if (s != null) out.push(s);
		}
		for (child in node.children) collectConditionalSpans(child, out);
	}

	/**
	 * The lexical class of the occurrence at `at`; see `OccurrenceClass`.
	 *
	 * The LEXICAL class is decided first, and a `#if...#end` region only classifies what
	 * is left: `ConditionalRaw` means "code the resolver could not bind", and a comment or
	 * string inside a conditional region is neither - the lexer reads it the same whichever
	 * branch is live. Asking the conditional first made one commented-out line inside a
	 * `#if` block every rename of that name in the whole FILE (the class scans `0...length`),
	 * including bindings whose scope lay nowhere near the region.
	 */
	private static function classifyAt(
		source: String, at: Int, len: Int, condSpans: Array<Span>, regions: Array<LexRegion>
	): OccurrenceClass {
		for (region in regions) if (at >= region.from && at < region.to) return switch region.kind {
			case StringLit:
				literalNamesIdentifier(source, at, len, region) ? StringLiteral : StringWord;
			// A regex body is inert literal text, and no by-name lookup reads one, but nothing needs
			// the relaxation - the conservative reading stays.
			case RegexLit: StringLiteral;
			case LineComment, BlockComment: SourceComments.isNoqaComment(source, region) ? DirectiveComment : CommentTrivia;
		};
		return offsetWithinAny(at, condSpans) ? ConditionalRaw : ActiveCode;
	}

	/**
	 * Whether the occurrence at `[at, at + len)` inside the string `region` NAMES the identifier
	 * rather than merely containing the word. Two shapes qualify:
	 *
	 *  - the occurrence is the literal's ENTIRE content — the form every by-name lookup takes
	 *    (`Reflect.field(o, 'edit')`, a string-keyed field map, a serialized field name);
	 *  - the occurrence is an interpolation READ — preceded by `$` or by `{` that a `$` precedes.
	 *    Checked whatever the quote character is: this scanner is language-neutral and a spurious
	 *    block is the safe direction.
	 *
	 * Everything else — a word inside a sentence, a fragment of a path or a compound key — cannot
	 * address the member and must not veto its rename.
	 */
	private static function literalNamesIdentifier(source: String, at: Int, len: Int, region: LexRegion): Bool {
		if (at == region.from + 1 && at + len == region.to - 1) return true;
		final prev: Int = at - 1;
		if (prev <= region.from) return false;
		final prevCode: Int = source.fastCodeAt(prev);
		return prevCode == '$'.code || prevCode == '{'.code && prev - 1 > region.from && source.fastCodeAt(prev - 1) == '$'.code;
	}

	/** Walk `node`, appending the name-token span of every direct child of a `hosts` node. */
	private static function collectStructureFieldNames(node: QueryNode, source: String, hosts: Array<String>, out: Array<Span>): Void {
		if (hosts.contains(node.kind)) for (field in node.children) {
			final name: Null<String> = field.name;
			final span: Null<Span> = field.span;
			if (name == null || span == null) continue;
			final at: Int = SourceText.identTokenOffset(source, span, name);
			if (at >= 0) out.push(new Span(at, at + name.length));
		}
		for (child in node.children) collectStructureFieldNames(child, source, hosts, out);
	}

	/**
	 * Whether the string literal containing `at` can interpolate: single-quoted and
	 * carrying a `$` that is not the escaped `$$`. Decided per LITERAL rather than
	 * per occurrence - working out which `${...}` region an occurrence falls in
	 * costs another scan, and the coarse answer only ever vetoes a rename. A
	 * double-quoted literal never interpolates in Haxe, so it is always inert.
	 */
	private static function interpolatingLiteralAt(source: String, at: Int, regions: Array<LexRegion>): Bool {
		for (region in regions) {
			if (region.kind != StringLit || at < region.from || at >= region.to) continue;
			if (source.fastCodeAt(region.from) != "'".code) return false;
			var i: Int = region.from + 1;
			while (i < region.to) {
				if (source.fastCodeAt(i) != '$'.code) {
					i++;
					continue;
				}
				if (i + 1 >= region.to || source.fastCodeAt(i + 1) != '$'.code) return true;
				i += 2;
			}
			return false;
		}
		return false;
	}

	/**
	 * Whether the identifier at `at` sits in the member-name slot of a dotted access
	 * (`o.name`, `o?.name`, `Type.name`) - never a binding of `name` in the
	 * surrounding scope. The range operator is excluded: in `0...name` the name is a
	 * real read. Only whitespace is stepped over, so a comment between the dot and
	 * the name answers false and vetoes - the safe side.
	 */
	private static function isMemberNamePosition(source: String, at: Int): Bool {
		var i: Int = at - 1;
		while (i >= 0 && SourceText.isSpace(source.fastCodeAt(i))) i--;
		return i >= 0 && source.fastCodeAt(i) == '.'.code && (i <= 0 || source.fastCodeAt(i - 1) != '.'.code) && !onImportLine(source, at);
	}

	/**
	 * Whether `at` sits on a line whose first token is `import` or `using`. The last
	 * segment of such a path DOES bind a name in the file's scope, so it is the one
	 * dotted position `isMemberNamePosition` must not wave through - a rename onto it
	 * would shadow the imported type. Line-based on purpose: the region scan the
	 * caller already holds says nothing about statement kind, and an `import` never
	 * shares its line with other code.
	 */
	private static function onImportLine(source: String, at: Int): Bool {
		final head: String = source.substring(SourceText.lineStartOf(source, at), at).ltrim();
		return head.startsWith('import ') || head.startsWith('using ');
	}

}

/**
 * Lexical classification of one word-boundary occurrence of an identifier. Drives the naming
 * completeness gate: `ActiveCode`, `ConditionalRaw`, `StringLiteral` and `DirectiveComment` block
 * the rename; `StringWord` is ignored; `CommentTrivia` renames along when the name is distinctive
 * enough to be worth rewriting in prose, and is otherwise ignored too.
 *
 * Only a class that can carry a REFERENCE blocks. `StringLiteral` vs `StringWord` draws that line
 * inside a string: a literal that NAMES the identifier can be a by-name lookup
 * (`Reflect.field(o, 'edit')`), a literal that merely contains the word cannot (`t('Can edit')`).
 * A comment is on the far side of the same line — it does not execute at all, so no form of it can
 * make a rename unsafe; the worst case is a sentence that ages. A `noqa` is the exception, and it
 * is not `CommentTrivia` but `DirectiveComment`: it addresses the TOOL, and the tool must obey.
 */
enum abstract OccurrenceClass(Int) {

	final ActiveCode = 0;
	final ConditionalRaw = 1;
	final CommentTrivia = 2;
	final StringLiteral = 3;
	final DirectiveComment = 4;
	final StringWord = 5;

}

/**
 * One classified word-boundary occurrence: the span of the matched identifier
 * and its lexical class.
 */
typedef ClassifiedOccurrence = {
	final span: Span;
	final kind: OccurrenceClass;
};
