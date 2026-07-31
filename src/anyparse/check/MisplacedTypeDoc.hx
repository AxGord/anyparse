package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a `/**`-opened doc block written between the `package` statement and the
 * module's `import` / `using` lines. The compiler attaches a doc to the declaration
 * it IMMEDIATELY precedes, so a block separated from the module's type by the import
 * run documents nothing — a DEAD doc, invisible to every IDE and doc generator, which
 * still reads as documentation to the next human. `Severity.Warning`; `--fix` MOVES the
 * block verbatim into the type declaration's leading trivia.
 *
 * ## Detection
 *
 * The parse tree supplies the module's top-level decls (comments are dropped from the
 * query projection, so the block itself comes from a comment-token scan). The header is
 * every top-level child preceding the sole type declaration's leading modifier / `@:meta`
 * run; the doc must sit in the gap between the FIRST header decl (the package statement)
 * and the second (the first import / using).
 *
 * ## Gates — a doc is moved only when its owner is unambiguous
 *
 *  - DOC STYLE. Only a `/**` block with a non-blank body. A plain `/* … *\/` banner and a
 *    `//` run are license headers and section labels — they belong where they were written.
 *  - THE TYPE HAS NO DOC OF ITS OWN. Two docs are never merged: the one at the declaration
 *    is the live one, and what the stranded block adds is an authoring decision.
 *  - EXACTLY ONE top-level type. With two, which type the doc was written for is a guess.
 *  - ABOVE THE `package` STATEMENT IS A FILE HEADER. Such a block describes the file (a
 *    licence, a provenance note), not the type, so it is never touched — and a module with
 *    no package statement at all has only that position available, so it never fires.
 *  - ONE doc block in the gap. Two adjacent blocks are `fragmented-doc-comment`'s job; it
 *    merges them, and this rule fires on the merged block at the next fixed-point pass.
 *  - The block OWNS ITS LINES (nothing but whitespace beside it). A doc sharing a line with
 *    code cannot move as whole lines, so that finding stays report-only.
 *
 * The file-header gate is POSITIONAL, and deliberately so: it asks where the block was
 * written, not what it says. An attribution or licence note written BELOW the package
 * statement reads as a type doc and is moved onto the type — it stays in the file, one
 * declaration further down, which is why the rule is default OFF.
 *
 * ## Autofix
 *
 * Two edits: the doc's whole-line region is deleted, and its BYTE-IDENTICAL text is
 * re-inserted at the type's doc anchor — above the `@:meta` / modifier run, where the
 * compiler reads a type's doc. A separating blank line is supplied when the anchor does
 * not already have one, matching the spacing every other doc'd declaration carries. The
 * comment text is never reflowed or rewritten: this is a trivia MOVE, so the writer's
 * comment guard sees the same block leave one slot and arrive in another.
 *
 * ## Why the stranded doc is worth moving rather than just reporting
 *
 * `AddImport` splices a new plain import at its ORDERED slot, which for an import sorting
 * first is the current first import's own start — directly below a stranded doc, which is
 * then pinned above a DIFFERENT import than the one it was written next to. Every import
 * insertion drifts it further from its author's intent.
 *
 * Registered ahead of the import rules in `Linter.builtins()` for that reason. The position
 * is a convention rather than a correctness requirement: `ImportBlockOrder`'s movable import
 * chunk stops at a block comment, so its reorder never covers this check's edits and
 * `Cli.computeFileLintEdits` has nothing to defer today. The order keeps that true if either
 * side's chunking ever widens.
 *
 * DEFAULT OFF (`DefaultOff`) — moving a comment is a judgement about what its author meant:
 * opt in with `"misplaced-type-doc": { "enabled": true }`.
 */
@:nullSafety(Strict)
final class MisplacedTypeDoc implements Check implements DefaultOff {

	private static inline final RULE_ID: String = 'misplaced-type-doc';

	/**
	 * The doc opener, for the cheap PREFILTER only — a byte probe of the header gap that
	 * skips the whole-source comment scan for a file with no candidate. What actually
	 * counts as documentation is `RefactorSupport.isDocBlock`, which asks the lexer.
	 */
	private static inline final DOC_OPEN: String = '/**';

	/** The header decls a misplaced doc must sit between: the package statement plus at least one import. */
	private static inline final MIN_HEADER_DECLS: Int = 2;

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a doc comment stranded between the package statement and the imports';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final found: Null<Stranded> = strandedDoc(entry.source, plugin, seams);
			if (found == null) continue;
			violations.push({
				file: entry.file,
				span: new Span(found.doc.from, found.doc.to),
				rule: RULE_ID,
				severity: Severity.Warning,
				message: 'this doc comment is separated from \'${found.name}\' by the imports, so it documents nothing; move it to the declaration'
			});
		}
		return violations;
	}

	/**
	 * Delete the stranded block's whole-line region and re-insert its exact text at the
	 * type's doc anchor. Re-derives the finding from `source` rather than reading the
	 * reported spans: the edit needs the doc ANCHOR, which a `Violation` has no slot for.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final found: Null<Stranded> = strandedDoc(source, plugin, seams);
		if (found == null) return [];
		final block: Null<Span> = wholeLineSpan(source, found.doc);
		if (block == null) return [];
		final text: String = source.substring(found.doc.from, found.doc.to);
		final separator: String = blankLineBefore(source, found.anchor) ? '' : '\n';
		return [
			{ span: block, text: '' },
			{ span: new Span(found.anchor, found.anchor), text: '$separator$text\n' }
		];
	}

	/**
	 * The module's stranded doc block plus the anchor to move it to, or null when any gate
	 * declines. Every gate is documented on the class; the order here is cheapest-first —
	 * tree shape, then a substring probe of the gap, and only then the whole-source comment
	 * scan (which no ordinary file ever reaches).
	 */
	private static function strandedDoc(source: String, plugin: GrammarPlugin, seams: Seams): Null<Stranded> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return null;
		final header: Null<Header> = headerOf(tree, seams);
		if (header == null || header.decls.length < MIN_HEADER_DECLS) return null;
		final packageDecl: QueryNode = header.decls[0];
		if (packageDecl.kind != seams.packageKind) return null;
		final gapFrom: Null<Span> = packageDecl.span;
		final gapTo: Null<Span> = header.decls[1].span;
		if (gapFrom == null || gapTo == null) return null;
		if (source.substring(gapFrom.to, gapTo.from).indexOf(DOC_OPEN) < 0) return null;
		final comments: Array<CommentTok> = RefactorSupport.collectCommentTokens(source);
		final docs: Array<CommentTok> = [
			for (tok in comments)
				if (RefactorSupport.isDocBlock(source, tok) && tok.from >= gapFrom.to && tok.to <= gapTo.from) tok
		];
		if (docs.length != 1) return null;
		if (CheckScan.hasDocBefore(source, CheckScan.docBlockEnds(source), header.anchor)) return null;
		return { doc: docs[0], anchor: header.anchor, name: header.name };
	}

	/**
	 * The module's header — every top-level decl preceding the SOLE type declaration's
	 * leading modifier / `@:meta` run — plus that run's start (the doc anchor, where the
	 * compiler reads a type's doc) and the type's name. Null unless the module declares
	 * exactly one top-level type.
	 */
	private static function headerOf(tree: QueryNode, seams: Seams): Null<Header> {
		var runStart: Int = -1;
		var runIndex: Int = -1;
		var found: Null<Header> = null;
		for (i in 0...tree.children.length) {
			final child: QueryNode = tree.children[i];
			if (seams.typeDecls.contains(child.kind)) {
				if (found != null) return null;
				final span: Null<Span> = child.span;
				if (span == null) return null;
				found = {
					decls: tree.children.slice(0, runIndex >= 0 ? runIndex : i),
					anchor: runStart >= 0 ? runStart : span.from,
					name: CheckScan.typeDeclName(child, seams.nameHosts)
				};
			} else if (CheckScan.isLeadingAnnotation(child, seams.modifiers)) {
				final span: Null<Span> = child.span;
				if (runStart < 0 && span != null) {
					runStart = span.from;
					runIndex = i;
				}
				continue;
			}
			runStart = -1;
			runIndex = -1;
		}
		return found;
	}

	/**
	 * The whole-line region `tok` occupies — its line start through the newline after its
	 * close — or null when the block does not OWN those lines (code beside it on either
	 * end), in which case a line-granular move would take that code with it.
	 */
	private static function wholeLineSpan(source: String, tok: CommentTok): Null<Span> {
		final lineStart: Int = RefactorSupport.startOfLine(source, tok.from);
		if (StringTools.trim(source.substring(lineStart, tok.from)) != '') return null;
		final newline: Int = source.indexOf('\n', tok.to);
		if (newline < 0) return null;
		if (StringTools.trim(source.substring(tok.to, newline)) != '') return null;
		return new Span(lineStart, newline + 1);
	}

	/** Whether a blank line already separates `pos` from the code above it. */
	private static function blankLineBefore(source: String, pos: Int): Bool {
		var newlines: Int = 0;
		var i: Int = pos - 1;
		while (i >= 0 && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) {
			if (StringTools.fastCodeAt(source, i) == '\n'.code) newlines++;
			i--;
		}
		return i < 0 || newlines > 1;
	}

	/**
	 * Resolve the type / modifier / package seam kinds, or null when a required one is unset.
	 *
	 * `typeDeclKinds` is the documentable-type set `doc-coverage` reads, and it omits the
	 * enum-abstract kind. There it costs a false NEGATIVE; here it would weaken the
	 * exactly-one-type gate into moving a doc onto the wrong declaration, so
	 * `enumAbstractDeclKind` joins the set for the purpose of COUNTING types.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final packageKind: Null<String> = shape.packageDeclKind;
		final declared: Array<String> = shape.typeDeclKinds ?? [];
		if (declared.length == 0 || packageKind == null) return null;
		final typeDecls: Array<String> = declared.copy();
		final enumAbstract: Null<String> = shape.enumAbstractDeclKind;
		if (enumAbstract != null && !typeDecls.contains(enumAbstract)) typeDecls.push(enumAbstract);
		final modifiers: Array<String> = CheckScan.modifierKinds(shape);
		return {
			typeDecls: typeDecls,
			nameHosts: (shape.visibilityContainerKinds ?? []).concat(shape.interfaceDeclKinds ?? []),
			modifiers: modifiers,
			packageKind: packageKind
		};
	}

}

/** A comment token from `RefactorSupport.collectCommentTokens`. */
private typedef CommentTok = { from: Int, to: Int, isLine: Bool };

/** A confirmed finding: the stranded block, the offset to move it to, and the type it belongs to. */
private typedef Stranded = {
	final doc: CommentTok;
	final anchor: Int;
	final name: String;
};

/** The header decls preceding a module's sole type, plus that type's doc anchor and reported name. */
private typedef Header = {
	final decls: Array<QueryNode>;
	final anchor: Int;
	final name: String;
};

/** Resolved kind-sets the header walk threads through. */
private typedef Seams = {
	final typeDecls: Array<String>;
	final nameHosts: Array<String>;
	final modifiers: Array<String>;
	final packageKind: String;
};
