package anyparse.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

import anyparse.query.Refs.RefHit;

/**
 * One resolved member of a type declaration: the member node, the
 * modifier / meta sibling run that precedes it, and the enclosing decl.
 */
private typedef MemberGroup = {
	var member: QueryNode;
	var modifiers: Array<QueryNode>;
	var groupSpan: Span;
}

/**
 * Everything `move` needs after resolution: endpoints, parsed trees,
 * the member group and its cut span, and the indexed file infos.
 */
private typedef MovePrep = {
	var srcFile: String;
	var srcTypeName: String;
	var memberName: String;
	var destTypeName: String;
	var index: SymbolIndex;
	var sourceOf: Map<String, String>;
	var trees: Map<String, QueryNode>;
	var srcTree: QueryNode;
	var srcSource: String;
	var srcDecl: TypeDeclMatch;
	var group: MemberGroup;
	var memberSpan: Span;
	var cut: Span;
	var destFile: String;
	var destDecl: TypeDeclMatch;
	var destSource: String;
	var srcInfo: FileInfo;
	var destInfo: FileInfo;
}

/**
 * Internal result of `resolveMove` — mirrors `MoveSymbol`'s prep enum.
 */
private enum PrepResult {

	POk(prep: MovePrep);
	PErr(message: String);

}

/**
 * Scope-correct, format-preserving move of one STATIC member (method,
 * `var` or `final` field) from one type to another within the SAME
 * PACKAGE — the Apply verb of the god-type decomposition loop:
 * `clusters` proposes a cut, `move-member` executes it one member at a
 * time. Reuses `MoveSymbol`'s result shape and import machinery.
 *
 * ## What is rewritten
 *
 *  - The member's decl (with its doc comment and modifier / `@:meta`
 *    run) is cut from the source type and appended to the destination
 *    type's body.
 *  - Every qualified access `Src.member` across the scope becomes
 *    `Dest.member` (receiver idents shadowed by a local value binding
 *    are left alone, mirroring `CrossRename`).
 *  - Bare accesses to the member inside the source file become
 *    `Dest.member` (scope-resolved through `Refs`, so shadowing locals
 *    are untouched); bare SELF-references inside the moved body stay
 *    bare — they resolve at the destination.
 *  - Bare accesses INSIDE the moved body to OTHER members of the source
 *    type are qualified as `Src.other` (same-package visible at the
 *    destination). When any such member is private, the moved decl gains
 *    an `@:access(<pkg>.<Src>)` line and the advisory says so.
 *  - A private (or default-visibility) member that still has callers
 *    after the move is promoted to `public` at the destination, noted
 *    in the advisory. With no remaining callers the visibility is kept.
 *  - The destination file gains the type-position imports the moved
 *    body depends on (best-effort, `MoveSymbol.dependencyImportsToCarry`);
 *    a rewritten caller file in ANOTHER package gains an import of the
 *    destination type.
 *
 * ## Refusals (correctness boundary)
 *
 * Instance members (no `static` modifier) are refused — their `this`
 * semantics do not survive a move. A cross-package destination is
 * refused for the same reason as `MoveSymbol`. A `using` of the source
 * type anywhere in scope is refused (extension-call sites are not
 * findable syntactically), as is a static import
 * (`import pkg.Mod.Src.member`). A destination that already declares a
 * member of the same name is refused.
 *
 * ## Atomicity and purity
 *
 * Mirrors `MoveSymbol`: the op never touches the filesystem, every
 * rewritten file is re-parsed before any is returned, and a re-parse
 * failure turns the whole move into an `Err` — all files or none.
 */
@:nullSafety(Strict)
final class MoveMember {

	private static final ADVISORY: String = 'import-carrying is best-effort (type-position dependencies only) — a missed import fails the destination compile loudly; references through strings, Reflect, or macro-built identifiers are not rewritten.';

	/**
	 * Move `memberName` from `srcTypeName` (declared in `srcFile`) to
	 * `destTypeName` (declared anywhere under scope, same package).
	 * Returns `Ok` with the per-file rewrites (source, destination and
	 * every rewritten caller file) plus a non-null advisory, or `Err`.
	 */
	public static function move(
		srcFile: String, srcTypeName: String, memberName: String, destTypeName: String,
		scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin, typeRefShape: TypeRefShape
	): MoveResult {
		if (srcTypeName == destTypeName) return Err('source and destination type are the same — nothing to move');
		final prep: MovePrep = switch resolveMove(srcFile, srcTypeName, memberName, destTypeName, scopeFiles, plugin) {
			case PErr(message): return Err(message);
			case POk(p): p;
		};
		final captures: Array<String> = casePatternCaptures(prep.srcTree);
		if (captures.contains(memberName))
			return Err(
				'a switch case pattern in $srcFile binds "$memberName" — reference resolution cannot tell the '
				+ 'capture from the member; rename the capture first'
			);
		final editsByFile: Map<String, Array<{ span: Span, text: String }>> = [];
		final movedTextEdits: Array<{ span: Span, text: String }> = [];
		final callerFilesNeedingImport: Array<String> = [];
		var outsideCallers: Int = collectQualifiedEdits(prep, plugin, editsByFile, movedTextEdits, callerFilesNeedingImport);
		outsideCallers += collectBareCallerEdits(prep, plugin, editsByFile);

		final movedSlice: String = prep.srcSource.substring(prep.cut.from, prep.cut.to);
		final advisoryExtras: Array<String> = [];
		promotionEdit(prep, outsideCallers, movedTextEdits, advisoryExtras);
		final sibling: { error: Null<String>, needsAccess: Bool } = collectSiblingEdits(prep, movedSlice, captures, plugin, movedTextEdits);
		final siblingError: Null<String> = sibling.error;
		if (siblingError != null) return Err(siblingError);
		if (sibling.needsAccess) accessEdit(prep, movedTextEdits, advisoryExtras);

		// Build the moved text (shift collected edits into slice space).
		final shifted: Array<{ span: Span, text: String }> = [
			for (e in movedTextEdits) { span: new Span(e.span.from - prep.cut.from, e.span.to - prep.cut.from), text: e.text }
		];
		final movedBlock: String = trimBlankEdges(RefactorSupport.applyEdits(movedSlice, shifted));

		// Source cut + destination insert: replace the whitespace run before
		// the closing `}` with a normalized frame — blank line, member, blank line.
		editsFor(editsByFile, prep.srcFile).push({ span: prep.cut, text: '' });
		final bodyClose: Null<Int> = typeBodyClose(prep.destSource, prep.destDecl);
		if (bodyClose == null) return Err('"$destTypeName" has no brace body to receive the member');
		var wsStart: Int = bodyClose;
		while (wsStart > 0 && RefactorSupport.isSpace(StringTools.fastCodeAt(prep.destSource, wsStart - 1))) wsStart--;
		editsFor(editsByFile, prep.destFile).push({ span: new Span(wsStart, bodyClose), text: '\n\n$movedBlock\n\n' });

		pushImportEdits(prep, typeRefShape, callerFilesNeedingImport, plugin, editsByFile);
		return applyAndValidate(editsByFile, prep.sourceOf, plugin, memberName, advisoryExtras);
	}

	/**
	 * The unique type decl named `typeName` in `tree`, or null on 0 / 2+.
	 */
	private static function uniqueTypeDecl(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		final matches: Array<TypeDeclMatch> = typeDeclsNamed(tree, typeName);
		return matches.length == 1 ? matches[0] : null;
	}

	/**
	 * All direct members of a type decl with their modifier / meta runs.
	 */
	private static function membersOf(decl: TypeDeclMatch): Array<MemberGroup> {
		final out: Array<MemberGroup> = [];
		final siblings: Array<QueryNode> = decl.nameNode.children;
		for (i => node in siblings) {
			final span: Null<Span> = node.span;
			if (span == null) continue;
			if (!RefactorSupport.isFieldMemberKind(node.kind) && !RefactorSupport.FN_DECL_KINDS.contains(node.kind)) continue;
			final groupSpan: Span = RefactorSupport.declGroupSpan(node, decl.nameNode, span);
			final modifiers: Array<QueryNode> = [
				for (j in 0...i) {
					final s: Null<Span> = siblings[j].span;
					if (s != null && s.from >= groupSpan.from && s.to <= span.from) siblings[j];
				}
			];
			out.push({ member: node, modifiers: modifiers, groupSpan: groupSpan });
		}
		return out;
	}

	/**
	 * The member group named `memberName` on `decl`, or null.
	 */
	private static function memberGroupOf(decl: TypeDeclMatch, memberName: String): Null<MemberGroup> {
		return membersOf(decl).find(g -> g.member.name == memberName);
	}

	/**
	 * Offsets of `Src` receiver idents in `Src.member` field accesses,
	 * skipping receivers resolved to a value binding (a local named like
	 * the type) — the `CrossRename` static-receiver rule.
	 */
	private static function qualifiedReceiverOffsets(
		source: String, tree: QueryNode, srcTypeName: String, memberName: String, plugin: GrammarPlugin
	): Array<Int> {
		final valueResolved: Array<Int> = [
			for (h in Refs.find(srcTypeName, tree, plugin.refShape()))
				if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.bindingSpan != null) h.span.from
		];
		final out: Array<Int> = [];
		function walk(node: QueryNode): Void {
			final children: Array<QueryNode> = node.children;
			if (node.kind == 'FieldAccess' && node.name == memberName && children.length > 0) {
				final recv: QueryNode = children[0];
				final recvSpan: Null<Span> = recv.span;
				if (recv.kind == 'IdentExpr' && recv.name == srcTypeName && recvSpan != null && !valueResolved.contains(recvSpan.from)) {
					final offset: Int = RefactorSupport.identTokenOffset(source, recvSpan, srcTypeName);
					if (!out.contains(offset)) out.push(offset);
				} else if (recv.kind == 'FieldAccess' && recv.name == srcTypeName && recvSpan != null) {
					// Fully-qualified receiver `pkg.Src.member` — rewrite the
					// last segment (same package, so `pkg.Dest` stays correct).
					final offset: Int = RefactorSupport.identTokenOffset(source, recvSpan, srcTypeName);
					if (!out.contains(offset)) out.push(offset);
				}
			}
			for (c in children) walk(c);
		}
		walk(tree);
		return out;
	}

	/**
	 * Search every scope file for the unique decl of `typeName`.
	 */
	private static function findTypeAcrossScope(
		scopeFiles: Array<{ file: String, source: String }>, trees: Map<String, QueryNode>, typeName: String
	): FindTypeResult {
		var found: Null<{ file: String, decl: TypeDeclMatch }> = null;
		for (entry in scopeFiles) {
			final tree: Null<QueryNode> = trees[entry.file];
			if (tree == null) continue;
			final matches: Array<TypeDeclMatch> = typeDeclsNamed(tree, typeName);
			if (matches.length > 1) return FErr('type "$typeName" is declared ${matches.length} times in ${entry.file}');
			if (matches.length == 1) {
				if (found != null) return FErr('type "$typeName" is declared in both ${found.file} and ${entry.file} — ambiguous');
				found = { file: entry.file, decl: matches[0] };
			}
		}
		return FOk(found);
	}

	/**
	 * Offset of the type body's closing `}` — the `AddMember` back-scan.
	 */
	private static function typeBodyClose(source: String, decl: TypeDeclMatch): Null<Int> {
		final bodySpan: Span = decl.nameNode.span ?? decl.fullSpan;
		var bodyClose: Int = bodySpan.to - 1;
		if (bodyClose >= source.length) bodyClose = source.length - 1;
		while (bodyClose >= bodySpan.from && RefactorSupport.isSpace(StringTools.fastCodeAt(source, bodyClose))) bodyClose--;
		return bodyClose < bodySpan.from || StringTools.fastCodeAt(source, bodyClose) != '}'.code ? null : bodyClose;
	}

	private static function editsFor(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, file: String
	): Array<{ span: Span, text: String }> {
		final existing: Null<Array<{ span: Span, text: String }>> = editsByFile[file];
		if (existing != null) return existing;
		final created: Array<{ span: Span, text: String }> = [];
		editsByFile[file] = created;
		return created;
	}

	private static function lineStartOf(source: String, offset: Int): Int {
		var i: Int = offset;
		while (i > 0 && StringTools.fastCodeAt(source, i - 1) != '\n'.code) i--;
		return i;
	}

	/**
	 * Strip leading blank lines and every trailing newline (the insert
	 * frame supplies its own).
	 */
	private static function trimBlankEdges(block: String): String {
		var from: Int = 0;
		while (from < block.length) {
			final c: Int = StringTools.fastCodeAt(block, from);
			if (c == '\n'.code || c == '\r'.code)
				from++
			else
				break;
		}
		var to: Int = block.length;
		while (to > from) {
			final c: Int = StringTools.fastCodeAt(block, to - 1);
			if (c == '\n'.code || c == '\r'.code)
				to--
			else
				break;
		}
		return block.substring(from, to);
	}

	private static function lastSegment(path: String): String {
		final dot: Int = path.lastIndexOf('.');
		return dot == -1 ? path : path.substring(dot + 1);
	}

	/**
	 * Resolve endpoints and run every guard: source type + member (must be
	 * static), unique same-package destination without a name collision,
	 * parseable scope, no `using` / static import of the source type.
	 */
	private static function resolveMove(
		srcFile: String, srcTypeName: String, memberName: String, destTypeName: String,
		scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): PrepResult {
		final index: SymbolIndex = SymbolIndex.build(scopeFiles, plugin);
		final skipped: Array<String> = index.skippedFiles();
		if (skipped.length > 0) return PErr('cannot move across scope: ${skipped.length} file(s) do not parse: ${skipped.join(', ')}');
		final sourceOf: Map<String, String> = [for (entry in scopeFiles) entry.file => entry.source];
		final srcSource: Null<String> = sourceOf[srcFile];
		if (srcSource == null) return PErr('source file $srcFile is not in the scope file set');
		final trees: Map<String, QueryNode> = [];
		for (entry in scopeFiles) trees[entry.file] = try plugin.parseFile(entry.source) catch (exception: Exception) {
			return PErr('${entry.file} does not parse: ${exception.message}');
		}
		final srcTree: Null<QueryNode> = trees[srcFile];
		if (srcTree == null) return PErr('source file $srcFile is not indexed');
		final srcDecl: Null<TypeDeclMatch> = uniqueTypeDecl(srcTree, srcTypeName);
		if (srcDecl == null) return PErr('no unique type "$srcTypeName" in $srcFile');
		final group: Null<MemberGroup> = memberGroupOf(srcDecl, memberName);
		if (group == null) return PErr('type "$srcTypeName" has no member "$memberName"');
		if (!group.modifiers.exists(m -> m.kind == 'Static'))
			return PErr('member "$memberName" is not static — this increment moves static members only');
		final memberSpan: Null<Span> = group.member.span;
		if (memberSpan == null) return PErr('member "$memberName" carries no span');
		final destHit: Null<{ file: String, decl: TypeDeclMatch }> = switch findTypeAcrossScope(scopeFiles, trees, destTypeName) {
			case FErr(message): return PErr(message);
			case FOk(hit): hit;
		};
		if (destHit == null) return PErr('no type "$destTypeName" declared under scope');
		final destSource: Null<String> = sourceOf[destHit.file];
		if (destSource == null) return PErr('destination file ${destHit.file} is not in the scope file set');
		if (memberGroupOf(destHit.decl, memberName) != null) return PErr('type "$destTypeName" already declares a member "$memberName"');
		final srcInfo: Null<FileInfo> = index.fileInfo(srcFile);
		final destInfo: Null<FileInfo> = index.fileInfo(destHit.file);
		if (srcInfo == null || destInfo == null) return PErr('scope files are not indexed');
		if (srcInfo.pkg != destInfo.pkg)
			return PErr(
				'cross-package move not supported in this increment '
				+ '(source package "${srcInfo.pkg}" != destination package "${destInfo.pkg}")'
			);
		final guard: Null<String> = scopeGuardError(scopeFiles, index, srcTypeName, memberName, destTypeName);
		if (guard != null) return PErr(guard);
		// Re-bind the null-checked locals: Strict does not propagate
		// narrowing into anonymous struct fields.
		final srcSourceNN: String = srcSource;
		final srcTreeNN: QueryNode = srcTree;
		final srcDeclNN: TypeDeclMatch = srcDecl;
		final groupNN: MemberGroup = group;
		final memberSpanNN: Span = memberSpan;
		final destSourceNN: String = destSource;
		final srcInfoNN: FileInfo = srcInfo;
		final destInfoNN: FileInfo = destInfo;
		return POk({
			srcFile: srcFile,
			srcTypeName: srcTypeName,
			memberName: memberName,
			destTypeName: destTypeName,
			index: index,
			sourceOf: sourceOf,
			trees: trees,
			srcTree: srcTreeNN,
			srcSource: srcSourceNN,
			srcDecl: srcDeclNN,
			group: groupNN,
			memberSpan: memberSpanNN,
			cut: cutSpanOf(srcSourceNN, groupNN),
			destFile: destHit.file,
			destDecl: destHit.decl,
			destSource: destSourceNN,
			srcInfo: srcInfoNN,
			destInfo: destInfoNN,
		});
	}

	/**
	 * The scope-wide refusals: a `using` of the source type (extension-call
	 * sites are not findable) or a static import of the member.
	 */
	private static function scopeGuardError(
		scopeFiles: Array<{ file: String, source: String }>, index: SymbolIndex, srcTypeName: String, memberName: String,
		destTypeName: String
	): Null<String> {
		for (entry in scopeFiles) {
			final info: Null<FileInfo> = index.fileInfo(entry.file);
			if (info == null) continue;
			for (imp in info.imports) {
				if (imp.kind == ImportKind.Using && lastSegment(imp.raw) == srcTypeName)
					return '${entry.file} has "using ${imp.raw}" — extension-call sites are not findable, refusing';
				if (imp.kind == ImportKind.Using && lastSegment(imp.raw) == destTypeName)
					return '${entry.file} has "using ${imp.raw}" — moving a member into a type under `using` could '
						+ 'hijack extension calls, refusing';
				if (imp.kind == ImportKind.Import && StringTools.endsWith(imp.raw, '.$srcTypeName.$memberName'))
					return '${entry.file} has a static import "${imp.raw}" — refusing';
			}
		}
		return null;
	}

	/**
	 * Doc comment + modifier run + decl, whole lines; a member framed by
	 * blank lines on both sides leaves a double blank at the cut, so the
	 * following blank line is swallowed.
	 */
	private static function cutSpanOf(srcSource: String, group: MemberGroup): Span {
		final lineCut: Span = RefactorSupport.lineExtendedSpan(srcSource, RefactorSupport.docExtendedSpan(srcSource, group.groupSpan));
		final blankBefore: Bool = lineCut.from >= 2 && StringTools.fastCodeAt(srcSource, lineCut.from - 2) == '\n'.code;
		final blankAfter: Bool = lineCut.to < srcSource.length && StringTools.fastCodeAt(srcSource, lineCut.to) == '\n'.code;
		return blankBefore && blankAfter ? new Span(lineCut.from, lineCut.to + 1) : lineCut;
	}

	/**
	 * Qualified `Src.member` receivers across the scope: outside the cut
	 * they are rewritten in place (counted as remaining callers, with the
	 * caller file remembered for the import pass); inside the cut they are
	 * rewritten within the moved text.
	 */
	private static function collectQualifiedEdits(
		prep: MovePrep, plugin: GrammarPlugin, editsByFile: Map<String, Array<{ span: Span, text: String }>>,
		movedTextEdits: Array<{ span: Span, text: String }>, callerFilesNeedingImport: Array<String>
	): Int {
		var outsideCallers: Int = 0;
		for (file => tree in prep.trees) {
			final source: Null<String> = prep.sourceOf[file];
			if (source == null) continue;
			for (offset in qualifiedReceiverOffsets(source, tree, prep.srcTypeName, prep.memberName, plugin)) {
				final edit: { span: Span, text: String } = {
					span: new Span(offset, offset + prep.srcTypeName.length),
					text: prep.destTypeName,
				};
				if (file == prep.srcFile && offset >= prep.cut.from && offset < prep.cut.to) {
					movedTextEdits.push(edit);
				} else {
					editsFor(editsByFile, file).push(edit);
					// A caller inside the destination file needs no promotion —
					// after the move it is a same-type qualified access.
					if (file != prep.destFile) outsideCallers++;
					if (file != prep.destFile && file != prep.srcFile && !callerFilesNeedingImport.contains(file))
						callerFilesNeedingImport.push(file);
				}
			}
		}
		return outsideCallers;
	}

	/**
	 * Bare accesses to the member in the source file, scope-resolved to
	 * THIS binding: qualified to the destination. Bare self-references
	 * inside the cut move along and stay bare.
	 */
	private static function collectBareCallerEdits(
		prep: MovePrep, plugin: GrammarPlugin, editsByFile: Map<String, Array<{ span: Span, text: String }>>
	): Int {
		var outsideCallers: Int = 0;
		for (hit in Refs.find(prep.memberName, prep.srcTree, plugin.refShape())) {
			if (hit.kind == RefKind.Decl) continue;
			final binding: Null<Span> = hit.bindingSpan;
			if (binding == null || binding.from != prep.memberSpan.from) continue;
			if (hit.span.from >= prep.cut.from && hit.span.from < prep.cut.to) continue;
			editsFor(editsByFile, prep.srcFile).push({
				span: new Span(hit.span.from, hit.span.from),
				text: '${prep.destTypeName}.',
			});
			outsideCallers++;
		}
		return outsideCallers;
	}

	/**
	 * Bare accesses INSIDE the moved body to other members of the source
	 * type: qualified as `Src.other`. `needsAccess` is true when any
	 * referenced sibling is non-public (the caller then adds `@:access`);
	 * `error` refuses when a case pattern captures a sibling name (the
	 * resolver cannot tell the capture from the member).
	 */
	private static function collectSiblingEdits(
		prep: MovePrep, movedSlice: String, captures: Array<String>, plugin: GrammarPlugin,
		movedTextEdits: Array<{ span: Span, text: String }>
	): { error: Null<String>, needsAccess: Bool } {
		final candidates: Array<MemberGroup> = [
			for (sibling in membersOf(prep.srcDecl)) {
				final siblingName: Null<String> = sibling.member.name;
				if (
					siblingName != null && sibling.member.span != null && siblingName != prep.memberName
					&& movedSlice.indexOf(siblingName) != -1
				)
					sibling;
			}
		];
		if (candidates.length == 0) return { error: null, needsAccess: false };
		// Conservative: a captured sibling name refuses even before hit
		// filtering — Refs cannot tell the capture from the member.
		for (sibling in candidates) {
			final siblingName: String = sibling.member.name ?? '';
			if (captures.contains(siblingName)) return {
				error: 'a switch case pattern in ${prep.srcFile} binds "$siblingName" — cannot safely qualify the '
					+ 'moved body\'s reference to it; rename the capture first',
				needsAccess: false,
			};
		}
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti(
			[for (s in candidates) s.member.name ?? ''], prep.srcTree, plugin.refShape()
		);
		var needsAccess: Bool = false;
		for (sibling in candidates) if (qualifySiblingHits(prep, sibling, hitsByName[sibling.member.name ?? ''] ?? [], movedTextEdits))
			needsAccess = true;
		return { error: null, needsAccess: needsAccess };
	}

	/**
	 * A non-public member with remaining callers must be public at the
	 * destination: flip an explicit `private`, or prepend `public` to a
	 * default-visibility decl.
	 */
	private static function promotionEdit(
		prep: MovePrep, outsideCallers: Int, movedTextEdits: Array<{ span: Span, text: String }>, advisoryExtras: Array<String>
	): Void {
		if (prep.group.modifiers.exists(m -> m.kind == 'Public') || outsideCallers == 0) return;
		final privateSpan: Null<Span> = prep.group.modifiers.find(m -> m.kind == 'Private')?.span;
		if (privateSpan != null) {
			movedTextEdits.push({ span: privateSpan, text: 'public' });
		} else {
			// Insert after any leading @:meta run — `public` before a meta
			// line would not parse.
			final at: Int = prep.group.modifiers.find(m -> m.kind != 'Meta')?.span?.from ?? prep.memberSpan.from;
			movedTextEdits.push({ span: new Span(at, at), text: 'public ' });
		}
		advisoryExtras.push('visibility promoted to public ($outsideCallers caller site(s) remain outside "${prep.destTypeName}")');
	}

	/**
	 * An `@:access(<pkg>.<Src>)` line above the moved decl (after its doc
	 * comment) — the moved body references private members of the source.
	 */
	private static function accessEdit(
		prep: MovePrep, movedTextEdits: Array<{ span: Span, text: String }>, advisoryExtras: Array<String>
	): Void {
		final accessPath: String = prep.srcInfo.pkg == '' ? prep.srcTypeName : '${prep.srcInfo.pkg}.${prep.srcTypeName}';
		final lineStart: Int = lineStartOf(prep.srcSource, prep.group.groupSpan.from);
		final indent: String = prep.srcSource.substring(lineStart, prep.group.groupSpan.from);
		// A decl sharing its line with other code (one-line class) gets the
		// meta inline — the "indent" would otherwise capture that code.
		if (isAllWhitespace(indent))
			movedTextEdits.push({ span: new Span(lineStart, lineStart), text: '$indent@:access($accessPath)\n' });
		else
			movedTextEdits.push({
				span: new Span(prep.group.groupSpan.from, prep.group.groupSpan.from),
				text: '@:access($accessPath) ',
			});
		advisoryExtras.push('moved body references private member(s) of "${prep.srcTypeName}" — added @:access($accessPath)');
	}

	/**
	 * Imports: carry the moved body's type-position dependencies to the
	 * destination file; give a rewritten caller file in another package an
	 * import of the destination type.
	 */
	private static function pushImportEdits(
		prep: MovePrep, typeRefShape: TypeRefShape, callerFilesNeedingImport: Array<String>, plugin: GrammarPlugin,
		editsByFile: Map<String, Array<{ span: Span, text: String }>>
	): Void {
		final carried: Array<ImportInfo> = MoveSymbol.dependencyImportsToCarry(
			prep.srcSource, prep.group.groupSpan, prep.srcInfo, prep.destInfo, plugin, typeRefShape, prep.srcTypeName
		);
		if (carried.length > 0) {
			final insertAt: Int = MoveSymbol.importInsertionOffset(prep.destSource, prep.destInfo);
			final lines: String = [
				for (imp in carried) '${imp.kind == ImportKind.Using ? 'using' : 'import'} ${imp.raw};\n'
			].join('');
			editsFor(editsByFile, prep.destFile).push({ span: new Span(insertAt, insertAt), text: lines });
		}
		final destImportPath: String = prep.destTypeName == RefactorSupport.baseNameOf(prep.destFile)
			? prep.destInfo.module
			: '${prep.destInfo.module}.${prep.destTypeName}';
		for (file in callerFilesNeedingImport) {
			final info: Null<FileInfo> = prep.index.fileInfo(file);
			final callerSource: Null<String> = prep.sourceOf[file];
			if (info == null || callerSource == null || info.pkg == prep.destInfo.pkg) continue;
			final edit: Null<{ span: Span, text: String }> = MoveSymbol.addImportEdit(callerSource, info, destImportPath);
			if (edit != null) editsFor(editsByFile, file).push(edit);
		}
	}

	/**
	 * Apply the per-file edits and re-parse every rewrite — all or none.
	 */
	private static function applyAndValidate(
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, sourceOf: Map<String, String>, plugin: GrammarPlugin,
		memberName: String, advisoryExtras: Array<String>
	): MoveResult {
		final changes: Array<MoveChange> = [];
		for (file => edits in editsByFile) {
			final original: Null<String> = sourceOf[file];
			if (original == null) continue;
			final newSource: String = RefactorSupport.applyEdits(original, edits);
			if (newSource == original) continue;
			try
				plugin.parseFile(newSource)
			catch (exception: ParseError)
				return Err('rewritten $file does not parse: ${exception.toString()}')
			catch (exception: Exception)
				return Err('rewritten $file does not parse: ${exception.message}');
			changes.push({ file: file, newSource: newSource });
		}
		if (changes.length == 0) return Err('move of "$memberName" changed nothing');
		final advisory: String = advisoryExtras.length == 0 ? ADVISORY : '${advisoryExtras.join('; ')}. $ADVISORY';
		return Ok(changes, advisory);
	}

	/**
	 * Every ident bound by a switch case PATTERN anywhere in the tree.
	 * `Refs` attributes reads of such captures to a same-named member
	 * binding (CaseBranch is not a scope there), so a move touching one of
	 * these names must refuse rather than silently rewrite match code.
	 */
	private static function casePatternCaptures(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		function walkPattern(node: QueryNode): Void {
			final name: Null<String> = node.name;
			if (node.kind == 'IdentExpr' && name != null && !out.contains(name)) out.push(name);
			for (c in node.children) walkPattern(c);
		}
		function walk(node: QueryNode): Void {
			if (node.kind == 'CaseBranch' && node.children.length > 0) walkPattern(node.children[0]);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	private static function isAllWhitespace(text: String): Bool {
		for (i in 0...text.length) if (!RefactorSupport.isSpace(StringTools.fastCodeAt(text, i))) return false;
		return true;
	}

	/**
	 * Every type decl named `typeName` in `tree` (final-aware).
	 */
	private static function typeDeclsNamed(tree: QueryNode, typeName: String): Array<TypeDeclMatch> {
		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) matches.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return matches;
	}

	/**
	 * Qualify one sibling's inside-cut hits as `Src.<sibling>`; true when
	 * anything was qualified and the sibling is non-public (needs @:access).
	 */
	private static function qualifySiblingHits(
		prep: MovePrep, sibling: MemberGroup, hits: Array<RefHit>, movedTextEdits: Array<{ span: Span, text: String }>
	): Bool {
		final siblingSpan: Null<Span> = sibling.member.span;
		if (siblingSpan == null) return false;
		var qualified: Bool = false;
		for (hit in hits) {
			if (hit.kind == RefKind.Decl) continue;
			final binding: Null<Span> = hit.bindingSpan;
			if (binding == null || binding.from != siblingSpan.from) continue;
			if (hit.span.from < prep.cut.from || hit.span.from >= prep.cut.to) continue;
			movedTextEdits.push({ span: new Span(hit.span.from, hit.span.from), text: '${prep.srcTypeName}.' });
			qualified = true;
		}
		return qualified && !sibling.modifiers.exists(m -> m.kind == 'Public');
	}

}

/**
 * Internal result of the scope-wide destination-type search: `FErr`
 * aborts the move with a message; `FOk(null)` means "not found" (the
 * caller words that error).
 */
private enum FindTypeResult {

	FOk(hit: Null<{ file: String, decl: TypeDeclMatch }>);
	FErr(message: String);

}
