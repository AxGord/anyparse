package anyparse.check.common.docs;

import anyparse.check.Check.DefaultOff;
import anyparse.check.scan.CheckScan;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.ParseGate;
import anyparse.query.SymbolIndex;

using anyparse.util.Strings;

/**
 * Flags a `/**`-opened doc block written between the `package` statement and the
 * module's `import` / `using` lines. The compiler attaches a doc to the declaration
 * it IMMEDIATELY precedes, so a block separated from the module's type by the import
 * run documents nothing — a DEAD doc, invisible to every IDE and doc generator, which
 * still reads as documentation to the next human. `Severity.Warning`; `--fix` MOVES the
 * block verbatim into the type declaration's leading trivia.
 *
 * It also flags a doc block written INSIDE a declaration's leading `@:meta` / modifier run
 * (a top-level type's or a member's): the compiler reads a doc only at the run's start, so
 * this one is not the declaration's — it is dropped, or in a type body handed to the next
 * member that has no doc of its own. `--fix` moves it there unless a doc already sits above the run (two docs
 * are never merged), the run holds two such blocks, or the block shares a line with code.
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
final class MisplacedTypeDoc extends RuleBase implements DefaultOff {

	private static inline final RULE_ID: String = 'misplaced-type-doc';

	/** The header decls a misplaced doc must sit between: the package statement plus at least one import. */
	private static inline final MIN_HEADER_DECLS: Int = 2;

	/**
	 * The doc opener, for the cheap PREFILTER only — a byte probe of the header gap that
	 * skips the whole-source comment scan for a file with no candidate. What actually
	 * counts as documentation is `RefactorSupport.isDocBlock`, which asks the lexer.
	 */
	private static final DOC_OPEN: String = '/**';

	public function new() {
		super(
			RULE_ID,
			'a doc comment the compiler never attaches: between the package statement and the imports, or inside a declaration\'s '
			+ 'metadata run',
			RuleCategory.Docs
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final found: Null<Stranded> = strandedDoc(entry.source, plugin, seams);
			if (found != null) violations.push({
				file: entry.file,
				span: new Span(found.doc.from, found.doc.to),
				rule: RULE_ID,
				severity: Severity.Warning,
				message: 'this doc comment is separated from \'${found.name}'
				+ '\' by the imports, so it documents nothing; move it to the declaration'
			});
			for (between in betweenMetaDocs(entry.source, plugin, seams)) violations.push({
				file: entry.file,
				span: new Span(between.doc.from, between.doc.to),
				rule: RULE_ID,
				severity: Severity.Warning,
				message: 'this doc comment sits inside its declaration\'s metadata / modifier run, so it is not this declaration\'s doc'
				+ ' (the compiler drops it, or hands it to the next undocumented member); '
				+ (between.refusal ?? 'move it before the first entry')
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
		final edits: Array<{ span: Span, text: String }> = [];
		final found: Null<Stranded> = strandedDoc(source, plugin, seams);
		final block: Null<Span> = found == null ? null : wholeLineSpan(source, found.doc);
		if (found != null && block != null) {
			final separator: String = blankLineBefore(source, found.anchor) ? '' : '\n';
			edits.push({ span: block, text: '' });
			edits.push(
				{ span: new Span(found.anchor, found.anchor), text: '$separator${source.substring(found.doc.from, found.doc.to)}\n' }
			);
		}
		for (between in betweenMetaDocs(source, plugin, seams)) {
			final line: Null<Span> = wholeLineSpan(source, between.doc);
			if (between.refusal != null || line == null || (found != null && found.anchor == between.anchor)) continue;
			final indent: String = source.substring(source.lineStart(between.anchor), between.anchor);
			edits.push({ span: line, text: '' });
			edits.push(
				{ span: new Span(between.anchor, between.anchor), text: '${source.substring(between.doc.from, between.doc.to)}\n$indent' }
			);
		}
		return edits;
	}

	/**
	 * The module's stranded doc block plus the anchor to move it to, or null when any gate
	 * declines. Every gate is documented on the class; the order here is cheapest-first —
	 * tree shape, then a substring probe of the gap, and only then the whole-source comment
	 * scan (which no ordinary file ever reaches).
	 */
	private static function strandedDoc(source: String, plugin: GrammarPlugin, seams: Seams): Null<Stranded> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return null;
		final header: Null<Header> = headerOf(tree, seams);
		if (header == null || header.decls.length < MIN_HEADER_DECLS) return null;
		final packageDecl: QueryNode = header.decls[0];
		if (packageDecl.kind != seams.packageKind) return null;
		final gapFrom: Null<Span> = packageDecl.span;
		final gapTo: Null<Span> = header.decls[1].span;
		if (gapFrom == null || gapTo == null) return null;
		if (source.substring(gapFrom.to, gapTo.from).indexOf(DOC_OPEN) < 0) return null;
		final comments: Array<CommentTok> = SourceComments.collectCommentTokens(plugin.lexicalRegions(source));
		final docs: Array<CommentTok> = [
			for (tok in comments) if (SourceComments.isDocBlock(source, tok) && tok.from >= gapFrom.to && tok.to <= gapTo.from) tok
		];
		return if (docs.length != 1)
			null
		else if (CheckScan.hasDocBefore(source, CheckScan.docBlockEnds(source, plugin.lexicalRegions(source)), header.anchor))
			null
		else
			{ doc: docs[0], anchor: header.anchor, name: header.name };
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
			} else if (CheckScan.isLeadingAnnotation(child, seams.modifiers) || guardedPrefixRun(child, seams)) {
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
	 * Whether `node` is a conditional-compilation region holding NOTHING but declaration
	 * PREFIX material — annotations (`#if !macro @:keep #end`), modifiers, and the bare
	 * declaration-starting keywords (`#if (haxe_ver >= 4.2) enum #else @:enum #end`).
	 *
	 * Such a region is part of the type's leading run, exactly like a bare `@:keep`.
	 * Counting it as an ordinary top-level declaration instead put it in the "first
	 * import" slot, so a doc comment written directly above it looked stranded between
	 * the package statement and the imports; the fix then moved that doc BELOW the
	 * region, i.e. below the metadata — where the compiler no longer attaches it. The
	 * doc silently stopped existing, and nothing reported it: not the writer, not the
	 * linter, not the compiler.
	 *
	 * The KEYWORD half is the same defect one grammar seam over. `enum` / `abstract` /
	 * `final` can each introduce a type of their own, so the grammar captures them as bare
	 * tokens (`seams.declPrefixKeywords`) rather than as modifier siblings — and an
	 * annotation-only test saw a region with a `haxe_ver` gate around `enum` as a second
	 * header declaration. The doc stayed attached there (`-D dox -xml` reports `haxe_doc`
	 * either way), so the damage was a wrong normalisation rather than a dead doc: `--fix`
	 * hoisted the region ABOVE the doc, inverting the tree's accepted order of doc, then
	 * metadata and modifiers, then the type.
	 *
	 * An EMPTY region is not one: it guards nothing, so treating it as annotation
	 * trivia would let the rule reach past it. A region holding a real declaration
	 * (`#if x class B {} #end`) is not one either — that IS a sibling declaration, and
	 * the whitelist is what keeps the two apart.
	 */
	private static function guardedPrefixRun(node: QueryNode, seams: Seams): Bool {
		return node.kind == seams.conditionalKind
			&& node.children.length != 0
			&& node.children.foreach(
				child ->
					CheckScan.isLeadingAnnotation(child, seams.modifiers)
					|| seams.metaKinds.contains(child.kind)
					|| seams.declPrefixKeywords.contains(child.kind)
			);
	}

	/**
	 * The whole-line region `tok` occupies — its line start through the newline after its
	 * close — or null when the block does not OWN those lines (code beside it on either
	 * end), in which case a line-granular move would take that code with it.
	 */
	private static function wholeLineSpan(source: String, tok: CommentTok): Null<Span> {
		final lineStart: Int = source.lineStart(tok.from);
		if (source.substring(lineStart, tok.from).trim() != '') return null;
		final newline: Int = source.indexOf('\n', tok.to);
		return if (newline < 0)
			null
		else if (source.substring(tok.to, newline).trim() != '')
			null
		else
			new Span(lineStart, newline + 1);
	}

	/** Whether a blank line already separates `pos` from the code above it. */
	private static function blankLineBefore(source: String, pos: Int): Bool {
		var newlines: Int = 0;
		var i: Int = pos - 1;
		while (i >= 0 && SourceText.isSpace(source.fastCodeAt(i))) {
			if (source.fastCodeAt(i) == '\n'.code) newlines++;
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
		final nameHosts: Array<String> = (shape.visibilityContainerKinds ?? []).concat(shape.interfaceDeclKinds ?? []);
		final descend: Array<String> = typeDecls.concat(nameHosts);
		final anon: Null<String> = shape.anonTypeKind;
		if (anon != null) descend.push(anon);
		final conditional: Null<String> = shape.conditionalMemberKind;
		if (conditional != null) descend.push(conditional);
		return {
			typeDecls: typeDecls,
			nameHosts: nameHosts,
			descend: descend,
			modifiers: modifiers,
			packageKind: packageKind,
			conditionalKind: shape.conditionalMemberKind,
			metaKinds: plugin.metaShape().metaKinds,
			declPrefixKeywords: shape.condDeclPrefixKeywordKinds ?? []
		};
	}

	/**
	 * Every doc block written INSIDE a declaration's leading `@:meta` / modifier run — after
	 * its first entry, before the declaration — for the module's top-level declarations and
	 * each type's members (through member containers and conditional regions). The compiler
	 * reads a doc only at the run's start, so such a block is dropped or, in a type body, handed
	 * to the next undocumented member. `refusal` says why the fix may not move it, if it may not.
	 */
	private static function betweenMetaDocs(source: String, plugin: GrammarPlugin, seams: Seams): Array<BetweenDoc> {
		if (source.indexOf(DOC_OPEN) < 0) return [];
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return [];
		final runs: Array<Span> = CheckScan.leadingRuns(
			tree, seams.descend, node -> CheckScan.isLeadingAnnotation(node, seams.modifiers) || guardedPrefixRun(node, seams)
		);
		if (runs.length == 0) return [];
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final comments: Array<CommentTok> = SourceComments.collectCommentTokens(regions);
		final docEnds: Map<Int, Bool> = CheckScan.docBlockEnds(source, regions);
		final out: Array<BetweenDoc> = [];
		for (run in runs) {
			final docs: Array<CommentTok> = [
				for (tok in comments) if (tok.from > run.from && tok.to <= run.to && SourceComments.isDocBlock(source, tok)) tok
			];
			final above: Bool = CheckScan.hasDocBefore(source, docEnds, run.from);
			for (doc in docs) out.push({ doc: doc, anchor: run.from, refusal: refusalOf(source, doc, docs.length, above) });
		}
		return out;
	}

	/** Why a between-run doc may not be moved, as the finding's advice, or null when the fix may move it. */
	private static function refusalOf(source: String, doc: CommentTok, docsInRun: Int, docAbove: Bool): Null<String> {
		return if (docAbove)
			'the declaration already has a doc above the run: merge the two by hand'
		else if (docsInRun > 1)
			'the run holds more than one doc block: merge them by hand'
		else if (wholeLineSpan(source, doc) == null)
			'it shares a line with code: move it before the first entry by hand'
		else
			null;
	}

}

/** A comment token from `RefactorSupport.collectCommentTokens`. */
private typedef CommentTok = { from: Int, to: Int, isLine: Bool };

/** A confirmed finding: the stranded block, the offset to move it to, and the type it belongs to. */
private typedef Stranded = { final doc: CommentTok; final anchor: Int; final name: String; };

/** A doc block inside a declaration's leading run, the run's start it belongs at, and why the fix may not move it (null when it may). */
private typedef BetweenDoc = { final doc: CommentTok; final anchor: Int; final refusal: Null<String>; };

/** The header decls preceding a module's sole type, plus that type's doc anchor and reported name. */
private typedef Header = { final decls: Array<QueryNode>; final anchor: Int; final name: String; };

/** Resolved kind-sets the header walk threads through. */
private typedef Seams = {

	final typeDecls: Array<String>;
	final nameHosts: Array<String>;

	/**
	 * The kinds whose children may hold declarations with a leading run: types,
	 * member containers, a typedef's anonymous structure, conditional regions.
	 */
	final descend: Array<String>;
	final modifiers: Array<String>;
	final packageKind: String;

	/** The conditional-compilation region kind, or null when the grammar has none — see `guardedPrefixRun`. */
	final conditionalKind: Null<String>;

	/**
	 * The annotation node kinds (`MetaShape.metaKinds`). `isLeadingAnnotation` reads a
	 * node's NAME, which a metadata node only carries in some of its spellings —
	 * `@:keep` inside a conditional region projects as a nameless wrapper — so the
	 * kind set is what makes the guarded-run test see it.
	 */
	final metaKinds: Array<String>;

	/**
	 * The bare declaration-starting keyword kinds a conditional region may contribute to the
	 * declaration after it (`RefShape.condDeclPrefixKeywordKinds`: Haxe `EnumKw` / `AbstractKw`
	 * / `FinalKw`). They carry neither a name nor a modifier kind, so `guardedPrefixRun` reads
	 * them off this set — without it a `#if (haxe_ver >= 4.2) enum #else @:enum #end` region
	 * reads as a second header declaration. Empty when the grammar leaves the seam unset.
	 */
	final declPrefixKeywords: Array<String>;

};
