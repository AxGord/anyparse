package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.ReplaceNode.ReplaceTarget;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Add one `@:metadata` entry to an existing declaration — the annotation
 * counterpart of `AddImport`, and the verb the mutation-op family was missing
 * on the type header.
 *
 * ## Why it is not `add-element` or `patch`
 *
 * Both already reach the position and both get it wrong, for two DIFFERENT
 * reasons, and each failure looks like the other's:
 *
 *  - `patch --select 'ClassDecl:X'` resolves the FORM node. A `final class X`
 *    projects as `FinalDecl(ClassForm X)` — a WRAPPER, not the modifier-sibling
 *    run `declGroupSpan` folds — so the searchable slice starts at `class` and a
 *    fragment naming `final class X` "does not occur". Anchor on `class X`
 *    instead and the metadata lands INSIDE the wrapper (`final @:meta class X`),
 *    which does not parse.
 *  - `add-element --before` inserts a SIBLING, so it deliberately clears a
 *    leading doc comment (`RefactorSupport.docExtendedSpan`) rather than landing
 *    between the doc and what it documents. Right for a sibling declaration,
 *    wrong for metadata: an annotation belongs BELOW the doc, and above the
 *    modifiers. On the `FinalDecl` shape it also inserts at the form node's
 *    start and produces the same unparseable header.
 *
 * ## What it does
 *
 * The entry is spliced at the END of the declaration's existing metadata run —
 * below its doc comment, above `public` / `static` / `final` and the declaration
 * keyword — at module level and at member level alike. A second entry of the
 * same NAME is refused, the way `AddImport` refuses an import already there.
 * The result goes through `RefactorSupport.canonicalize`, so it is
 * writer-formatted, re-parse-validated and canonical-gated.
 *
 * Removal has an op already: `remove-element --select 'MetaCall:@:name'` (or
 * `Meta:@:name`) deletes the annotation alone — `declGroupSpan` stopped walking
 * forward off an annotation exactly so that it would.
 */
@:nullSafety(Strict)
final class AddMeta {

	/**
	 * Add `meta` (`@:name`, `@:name(args)` or `@name`) to the declaration
	 * addressed by `target` in `source`. `reformat` opts into a whole-file
	 * canonicalisation when the source is not writer-canonical. PURE — returns
	 * `Ok(rewritten)` or an `Err`; the caller writes.
	 */
	public static function addMeta(
		source: String, target: ReplaceTarget, meta: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final text: String = meta.trim();
		final name: Null<String> = metaName(text);
		if (name == null) return Err('"$meta" is not a metadata entry — expected `@:name`, `@:name(args)` or `@name`');
		final nameNN: String = name;

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final resolved: QueryNode = switch ReplaceNode.resolveTarget(source, tree, target, plugin) {
			case Resolved(n): n;
			case Failed(message): return Err(message);
		};

		final host: Null<QueryNode> = declarationHost(tree, resolved);
		if (host == null) return Err('the resolved ${resolved.kind} node has no source span to annotate');
		final hostNN: QueryNode = host;

		final parent: Null<QueryNode> = TreePath.parentOf(tree, hostNN);
		final run: Array<QueryNode> = prefixRun(parent, hostNN);
		for (sibling in run) if (MemberKinds.META_KINDS.contains(sibling.kind) && sibling.name == nameNN)
			return Err('already annotated: $nameNN');

		final at: Null<Int> = insertOffset(run, hostNN);
		if (at == null) return Err('the resolved ${resolved.kind} node has no source span to annotate');
		final atNN: Int = at;

		// NON-zero-width on purpose. `RefactorSupport.docSplittingEdit` refuses a
		// zero-width newline-carrying insert that lands between a `/**` block and the
		// declaration it documents — correct for a SIBLING, which would steal the doc,
		// and exactly wrong here: metadata is part of the declaration the doc already
		// describes. Consuming the declaration's first byte and re-emitting it says
		// that in the shape of the edit rather than by exempting this op from the guard.
		final edit: { span: Span, text: String } = {
			span: new Span(atNN, atNN + 1),
			text: '$text\n${lineIndentAt(source, atNN)}${source.charAt(atNN)}'
		};
		return CanonicalEdit.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * The `@:name` / `@name` an entry declares, or null when `text` is not one.
	 * Only the NAME is validated: the argument list is spliced verbatim and the
	 * re-parse in `canonicalize` is what rejects a malformed one, so this does not
	 * become a second, worse parser for expressions.
	 */
	private static function metaName(text: String): Null<String> {
		if (!text.startsWith('@')) return null;
		var i: Int = text.charAt(1) == ':' ? 2 : 1;
		final from: Int = i;
		while (i < text.length && SourceText.isIdentChar(text.fastCodeAt(i))) i++;
		if (i == from) return null;
		// A dotted name (`@:foo.bar`) is one entry; the grammar carries the whole path.
		while (i < text.length && text.charAt(i) == '.') {
			i++;
			final seg: Int = i;
			while (i < text.length && SourceText.isIdentChar(text.fastCodeAt(i))) i++;
			if (i == seg) return null;
		}
		final rest: String = text.substr(i).trim();
		return rest == '' || rest.startsWith('(') ? text.substring(0, i) : null;
	}

	/**
	 * The node whose prefix run the entry joins: the addressed node, lifted past a
	 * modifier WRAPPER (`final class X` is `FinalDecl(ClassForm X)`, so the form node
	 * an address resolves to starts AFTER the keyword), and lowered past an annotation
	 * the caller happened to address (`--select 'MetaCall:@:keep'` names the entry, and
	 * the only declaration it can mean is the one it prefixes). Null when the node
	 * carries no span.
	 */
	private static function declarationHost(tree: QueryNode, node: QueryNode): Null<QueryNode> {
		var host: QueryNode = node;
		var parent: Null<QueryNode> = TreePath.parentOf(tree, host);
		// The climb asks `typeDeclOf`, not "is my parent a single-child node that starts
		// earlier". That looser test was true of a `#if` region wrapping ONE type as well,
		// so a guarded class put its entry ABOVE the `#if` line — and on a target where the
		// condition is false the entry then annotates whatever declaration follows `#end`.
		// Measured: `@:keep` asked for on a `#if sys`-guarded class landed on the NEXT
		// class for every non-sys target, at rc 0, past the parse gate.
		while (parent != null) {
			final p: QueryNode = parent;
			final outer: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(p);
			if (outer == null || outer.nameNode != host) break;
			host = p;
			parent = TreePath.parentOf(tree, host);
		}
		if (parent != null && MemberKinds.META_KINDS.contains(host.kind)) {
			final siblings: Array<QueryNode> = parent.children;
			var i: Int = siblings.indexOf(host);
			while (i >= 0 && i < siblings.length && MemberKinds.isModifierOrMetaKind(siblings[i].kind)) i++;
			if (i > 0 && i < siblings.length) host = siblings[i];
		}
		return host.span == null ? null : host;
	}

	/** The modifier / metadata siblings preceding `host`, in source order. */
	private static function prefixRun(parent: Null<QueryNode>, host: QueryNode): Array<QueryNode> {
		if (parent == null) return [];
		final siblings: Array<QueryNode> = parent.children;
		final i: Int = siblings.indexOf(host);
		if (i < 0) return [];
		var start: Int = i;
		while (start > 0 && MemberKinds.isModifierOrMetaKind(siblings[start - 1].kind)) start--;
		return siblings.slice(start, i);
	}

	/**
	 * Where the entry goes: past every metadata entry already there, before the first
	 * modifier keyword, else at the declaration itself. Appending keeps the file's own
	 * order (the way `AddImport` appends to an import run) and keeps the run in the one
	 * order Haxe accepts — annotations, then modifiers, then the keyword.
	 */
	private static function insertOffset(run: Array<QueryNode>, host: QueryNode): Null<Int> {
		for (sibling in run) if (!MemberKinds.META_KINDS.contains(sibling.kind)) return sibling.span?.from;
		return host.span?.from;
	}

	/** The whitespace between the start of `at`'s line and `at`. */
	private static function lineIndentAt(source: String, at: Int): String {
		var i: Int = at;
		while (i > 0 && source.charAt(i - 1) != '\n') i--;
		final lineStart: Int = i;
		while (i < at && (source.charAt(i) == ' ' || source.charAt(i) == '\t')) i++;
		return source.substring(lineStart, i);
	}

}
