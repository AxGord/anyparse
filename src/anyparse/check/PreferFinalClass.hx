package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a class declaration carrying the `@:final` metadata tag — the user's rule: use
 * `final class`, not the `@:final` meta, for a class not designed for inheritance.
 * `Severity.Info` (a style cleanup), with an autofix that removes the `@:final` meta and
 * inserts the `final` modifier before the `class` keyword. When the class ALREADY carries
 * the `final` modifier (a redundant `@:final final class`), the fix removes the meta only.
 *
 * Grammar-agnostic over `RefShape.finalClassMetaName` / `plainClassDeclKind` /
 * `finalClassDeclKind` (any unset -> no-op) plus `MetaShape.metaKinds`.
 *
 * ## What is flagged
 *
 * A meta node named `finalClassMetaName` whose decorated declaration — the nearest
 * following sibling that is not itself a meta, in SOURCE order (by span, so child-array
 * order and intervening metas / doc comments do not mislead) — is a plain class
 * (`plainClassDeclKind`) or an already-`final` class (`finalClassDeclKind`). The finding
 * spans only the `@:final` meta token, not the class body, so a `// noqa` inside the body
 * cannot swallow it.
 *
 * ## Deliberate misses
 *
 * - `@:final` on an interface / enum / enum abstract / typedef / `abstract class` — none is a
 *   class the `final` modifier applies to (`final abstract class` is not valid Haxe), so the
 *   meta is left alone.
 * - `@:final` on a method or field (a final method / field) — its decorated decl is a member,
 *   not a class.
 * - A `final class` with no `@:final` meta — already idiomatic.
 */
@:nullSafety(Strict)
final class PreferFinalClass implements Check {

	private static final MODIFIER: String = 'final ';

	public function new() {}

	public function id(): String {
		return 'prefer-final-class';
	}

	public function description(): String {
		return 'a class carrying the @:final meta — prefer the final class modifier';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final metaName: Null<String> = shape.finalClassMetaName;
		final plainKind: Null<String> = shape.plainClassDeclKind;
		final finalKind: Null<String> = shape.finalClassDeclKind;
		if (metaName == null || plainKind == null || finalKind == null) return [];
		final metaKinds: Array<String> = plugin.metaShape().metaKinds;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			for (c in collect(tree, metaName, metaKinds, plainKind, finalKind)) violations.push({
				file: entry.file,
				span: c.metaSpan,
				rule: 'prefer-final-class',
				severity: Severity.Info,
				message: c.redundant
					? 'redundant @:final meta on an already-final class — remove it'
					: 'use the final class modifier instead of the @:final meta'
			});
		}
		return violations;
	}

	/**
	 * Rewrite each flagged class. A plain class gets its `@:final` meta removed and a `final `
	 * modifier inserted before the class keyword; a redundant `@:final final class` gets the
	 * meta removed only. The tree is re-parsed and the candidates re-collected, so each edit is
	 * keyed to the still-present meta span (a guard against any stale span) and its decl
	 * position is re-derived from the same source.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final metaName: Null<String> = shape.finalClassMetaName;
		final plainKind: Null<String> = shape.plainClassDeclKind;
		final finalKind: Null<String> = shape.finalClassDeclKind;
		if (metaName == null || plainKind == null || finalKind == null) return [];
		final metaKinds: Array<String> = plugin.metaShape().metaKinds;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return [];
		final byKey: Map<String, Candidate> = [];
		for (c in collect(tree, metaName, metaKinds, plainKind, finalKind)) byKey['${c.metaSpan.from}:${c.metaSpan.to}'] = c;
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final c: Null<Candidate> = byKey['${span.from}:${span.to}'];
			if (c != null) for (e in editsFor(c, source)) edits.push(e);
		}
		return edits;
	}

	/**
	 * The one- or two-edit fix for `c`. The meta and its trailing whitespace are cut back to
	 * the first following non-whitespace character (so no blank residue). A redundant class is
	 * that single deletion. A plain class also inserts `final ` before the class keyword: as
	 * ONE combined `[meta, keyword)` replacement when only whitespace separates them (a
	 * zero-width insert adjacent to the deletion would be dropped by the edit-dedup), else as
	 * two disjoint edits so a doc comment or another meta sitting between is preserved.
	 */
	private static function editsFor(c: Candidate, source: String): Array<{ span: Span, text: String }> {
		final metaFrom: Int = c.metaSpan.from;
		final cutTo: Int = firstNonWs(source, c.metaSpan.to);
		return c.redundant
			? [{ span: new Span(metaFrom, cutTo), text: '' }]
			: cutTo == c.declFrom ? [{ span: new Span(metaFrom, c.declFrom), text: MODIFIER }] : [
				{ span: new Span(metaFrom, cutTo), text: '' },
				{ span: new Span(c.declFrom, c.declFrom), text: MODIFIER }
			];
	}

	/** Every `@:final`-on-class candidate in `tree`, in pre-order. */
	private static function collect(
		tree: QueryNode, metaName: String, metaKinds: Array<String>, plainKind: String, finalKind: String
	): Array<Candidate> {
		final out: Array<Candidate> = [];
		walk(tree, metaName, metaKinds, plainKind, finalKind, out);
		return out;
	}

	private static function walk(
		node: QueryNode, metaName: String, metaKinds: Array<String>, plainKind: String, finalKind: String, out: Array<Candidate>
	): Void {
		final children: Array<QueryNode> = node.children;
		for (child in children) if (metaKinds.contains(child.kind) && child.name == metaName) {
			final decl: Null<QueryNode> = nearestNonMetaFollowing(children, child, metaKinds);
			final ms: Null<Span> = child.span;
			if (decl != null && ms != null) {
				final metaSpan: Span = ms;
				final dk: String = decl.kind;
				final ds: Null<Span> = decl.span;
				if ((dk == plainKind || dk == finalKind) && ds != null) out.push({
					metaSpan: metaSpan,
					redundant: dk == finalKind,
					declFrom: ds.from
				});
			}
		}
		for (child in children) walk(child, metaName, metaKinds, plainKind, finalKind, out);
	}

	/**
	 * The nearest following sibling of `meta`, in source order, that is not itself a meta node
	 * — the declaration the meta decorates. Spans are used (not child-array position, which the
	 * plugin does not guarantee to match source order) and the intervening meta run is skipped,
	 * so `@:final @:keep class`, `@:keep @:final class`, and a `@:final` before a doc-commented
	 * class all resolve the class. A `@:final` before a typedef / enum returns that decl (not a
	 * later class), so the caller's kind check correctly leaves it alone.
	 */
	private static function nearestNonMetaFollowing(
		siblings: Array<QueryNode>, meta: QueryNode, metaKinds: Array<String>
	): Null<QueryNode> {
		final ms: Null<Span> = meta.span;
		if (ms == null) return null;
		final after: Int = ms.from;
		var best: Null<QueryNode> = null;
		var bestFrom: Int = 0;
		for (s in siblings) if (!metaKinds.contains(s.kind)) {
			final ss: Null<Span> = s.span;
			if (ss != null && ss.from > after && (best == null || ss.from < bestFrom)) {
				best = s;
				bestFrom = ss.from;
			}
		}
		return best;
	}

	/** The first index at or after `from` whose character is not whitespace (clamped to length). */
	private static function firstNonWs(source: String, from: Int): Int {
		var i: Int = from;
		while (i < source.length && StringTools.isSpace(source, i)) i++;
		return i;
	}

}

private typedef Candidate = {
	var metaSpan: Span;
	var redundant: Bool;
	var declFrom: Int;
};
