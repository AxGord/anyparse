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
 * One member being moved: its resolved group, member-node span, cut
 * span, and staticness (instance members obey the sibling-fields
 * contract — see the class doc).
 */
private typedef MovedMember = {
	var name: String;
	var group: MemberGroup;
	var span: Span;
	var cut: Span;
	var isStatic: Bool;
}

/**
 * A destination field to mirror under `--scaffold`: its name and the
 * verbatim source of its declared type on the source type.
 */
private typedef ScaffoldField = {
	var name: String;
	var type: String;
}

/**
 * Accumulator for `scanSibling`: satisfied final-field deps, moved
 * members needing `@:access`, and the three violation buckets that are
 * reported TOGETHER so one run surfaces the whole dependency closure.
 */
private typedef SiblingScanState = {
	var fieldDeps: Array<String>;
	var accessMembers: Array<String>;
	var staysBehind: Array<String>;
	var mutableDeps: Array<String>;
	var missingDestFields: Array<String>;
}

/**
 * Everything `move` needs after resolution: endpoints, parsed trees,
 * the resolved moved-member set (source order), and the indexed file
 * infos.
 */
private typedef MovePrep = {
	var srcFile: String;
	var srcTypeName: String;
	var destTypeName: String;
	var index: SymbolIndex;
	var sourceOf: Map<String, String>;
	var trees: Map<String, QueryNode>;
	var srcTree: QueryNode;
	var srcSource: String;
	var srcDecl: TypeDeclMatch;
	var moved: Array<MovedMember>;
	var closureAdded: Array<String>;
	var destFile: String;
	var destDecl: TypeDeclMatch;
	var destSource: String;
	var srcInfo: FileInfo;
	var destInfo: FileInfo;
}

private enum PrepResult {

	POk(prep: MovePrep);
	PErr(message: String);

}

/**
 * Internal result of `resolveViaField`: an existing routing field, a
 * name to scaffold (`--scaffold`), or a refusal.
 */
private enum ViaResult {

	VOk(name: String);
	VScaffold(name: String);
	VErr(message: String);

}

/**
 * Scope-correct, format-preserving move of one or more members (method,
 * `var` or `final` field) from one type to another within the SAME
 * PACKAGE — the Apply verb of the god-type decomposition loop:
 * `clusters` proposes a cut, `move-member` executes it. Reuses
 * `MoveSymbol`'s result shape and import machinery.
 *
 * ## What is rewritten
 *
 *  - Each member's decl (with its doc comment and modifier / `@:meta`
 *    run) is cut from the source type and appended to the destination
 *    type's body, in source order.
 *  - STATIC members: every qualified access `Src.member` across the
 *    scope becomes `Dest.member` (receiver idents shadowed by a local
 *    value binding are left alone, mirroring `CrossRename`); bare
 *    accesses inside the source file become `Dest.member`.
 *  - INSTANCE members (sibling-fields contract): remaining bare callers
 *    in the source type are rewired through a source-type field of type
 *    `Dest` (`--via`, auto-detected when the type has exactly one);
 *    moved bodies may keep reading FINAL fields that the destination
 *    declares under the same names — the caller must construct the
 *    destination with the same values (advisory). Receiver-qualified
 *    external calls (`x.member()`) are NOT rewritten — they fail the
 *    next compile loudly.
 *  - References between moved members stay bare — they resolve at the
 *    destination. Bare self-references inside a moved body stay bare.
 *  - Bare accesses INSIDE a moved body to STATIC members staying on the
 *    source type are qualified as `Src.other` (same-package visible at
 *    the destination). When any such member is private, the moved decl
 *    gains an `@:access(<pkg>.<Src>)` line and the advisory says so.
 *  - A private (or default-visibility) member that still has callers
 *    after the move is promoted to `public` at the destination, noted
 *    in the advisory. With no remaining callers the visibility is kept.
 *  - The destination file gains the type-position imports the moved
 *    bodies depend on (best-effort, `MoveSymbol.dependencyImportsToCarry`);
 *    a rewritten caller file in ANOTHER package gains an import of the
 *    destination type.
 *
 * ## Refusals (correctness boundary)
 *
 * A moved body that references `this`, calls an instance member staying
 * on the source type, or reads a MUTABLE instance field is refused — the
 * sibling-fields contract covers final fields only. A cross-package
 * destination is refused for the same reason as `MoveSymbol`. A `using`
 * of the source type anywhere in scope is refused (extension-call sites
 * are not findable syntactically), as is a static import
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
	 * DATA-field member kinds (`RefactorSupport.FIELD_MEMBER_KINDS` also
	 * contains function kinds — its name is broader than it reads).
	 */
	private static final DATA_FIELD_KINDS: Array<String> = ['VarMember', 'FinalMember', 'VarField', 'FinalField'];

	private static final FINAL_FIELD_KINDS: Array<String> = ['FinalMember', 'FinalField'];

	/**
	 * Move `memberNames` from `srcTypeName` (declared in `srcFile`) to
	 * `destTypeName` (declared anywhere under scope, same package).
	 * `viaField` names the source-type field of type `destTypeName` that
	 * remaining bare instance callers are rewired through (auto-detected
	 * when the source type has exactly one such field). When `closure` is
	 * set, the move set is first grown to the transitive closure of the
	 * instance methods the seed members call. When `scaffold` is set, a
	 * missing destination final field / constructor and a missing via field
	 * are GENERATED (into an empty destination and the source constructor)
	 * instead of refused.
	 * Returns `Ok` with the per-file rewrites (source, destination and
	 * every rewritten caller file) plus a non-null advisory, or `Err`.
	 */
	public static function move(
		srcFile: String, srcTypeName: String, memberNames: Array<String>, destTypeName: String, viaField: Null<String>, closure: Bool,
		scaffold: Bool, scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin, typeRefShape: TypeRefShape
	): MoveResult {
		if (srcTypeName == destTypeName) return Err('source and destination type are the same — nothing to move');
		if (memberNames.length == 0) return Err('no members named — nothing to move');
		final prep: MovePrep = switch resolveMove(srcFile, srcTypeName, memberNames, destTypeName, closure, scopeFiles, plugin) {
			case PErr(message): return Err(message);
			case POk(p): p;
		};
		final captures: Array<String> = casePatternCaptures(prep.srcTree);
		final guard: Null<String> = moveGuardError(prep, captures);
		if (guard != null) return Err(guard);
		final fqnRefusal: Null<String> = crossPackageFqnRefusal(prep);
		if (fqnRefusal != null) return Err(fqnRefusal);
		final editsByFile: Map<String, Array<{ span: Span, text: String }>> = [];
		final movedTextEdits: Array<{ span: Span, text: String }> = [];
		final callerFilesNeedingImport: Array<String> = [];
		final advisoryExtras: Array<String> = [];
		if (prep.closureAdded.length > 0)
			advisoryExtras.push('--closure pulled in ${prep.closureAdded.length} instance member(s): ${quoted(prep.closureAdded)}');
		final outsideCallersOf: Map<String, Int> = [for (m in prep.moved) m.name => 0];
		for (m in prep.moved) if (m.isStatic)
			outsideCallersOf[m.name] = collectQualifiedEdits(prep, m, plugin, editsByFile, movedTextEdits, callerFilesNeedingImport);

		// Sibling scan first — its missing-dest-final-fields drive both the
		// `new Dest(...)` wiring args and the destination scaffold.
		final sibling: {
			error: Null<String>,
			fieldDeps: Array<String>,
			accessMembers: Array<String>,
			missingDestFields: Array<String>
		} = collectSiblingEdits(prep, captures, scaffold, plugin, movedTextEdits);
		if (sibling.error != null) return Err(sibling.error);
		final scaffoldFields: Array<ScaffoldField> = if (sibling.missingDestFields.length > 0) {
			switch resolveScaffoldFields(prep, sibling.missingDestFields, plugin) {
				case { error: e } if (e != null): return Err(e);
				case { fields: f }: f;
			}
		} else
			[];
		applySiblingOutcome(prep, sibling.accessMembers, sibling.fieldDeps, movedTextEdits, advisoryExtras);

		final rewireError: Null<String> = collectCallerRewires(
			prep, viaField, scaffold, scaffoldFields, plugin, editsByFile, outsideCallersOf, advisoryExtras
		);
		if (rewireError != null) return Err(rewireError);
		for (m in prep.moved) promotionEdit(prep, m, outsideCallersOf[m.name] ?? 0, movedTextEdits, advisoryExtras);

		// Destination scaffold (fields + constructor) — either prepended to
		// the moved-member insert (no dest ctor) or replacing a trivial one.
		final destError: Null<String> = assembleDestination(prep, scaffoldFields, movedTextEdits, editsByFile, advisoryExtras);
		if (destError != null) return Err(destError);
		pushImportEdits(prep, typeRefShape, callerFilesNeedingImport, plugin, editsByFile);
		pushCrossPackageImports(prep, editsByFile, movedTextEdits);
		return applyAndValidate(editsByFile, prep.sourceOf, plugin, memberNames.join(', '), advisoryExtras);
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
		srcFile: String, srcTypeName: String, memberNames: Array<String>, destTypeName: String, closure: Bool,
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
		};
		final srcTree: Null<QueryNode> = trees[srcFile];
		if (srcTree == null) return PErr('source file $srcFile is not indexed');
		final srcDecl: Null<TypeDeclMatch> = uniqueTypeDecl(srcTree, srcTypeName);
		if (srcDecl == null) return PErr('no unique type "$srcTypeName" in $srcFile');
		final destHit: Null<{ file: String, decl: TypeDeclMatch }> = switch findTypeAcrossScope(scopeFiles, trees, destTypeName) {
			case FErr(message): return PErr(message);
			case FOk(hit): hit;
		};
		if (destHit == null) return PErr('no type "$destTypeName" declared under scope');
		final destSource: Null<String> = sourceOf[destHit.file];
		if (destSource == null) return PErr('destination file ${destHit.file} is not in the scope file set');
		final effectiveNames: Array<String> = closure
			? expandInstanceCallClosure(srcDecl, srcTree, srcSource, memberNames, plugin)
			: memberNames;
		final closureAdded: Array<String> = [for (name in effectiveNames) if (!memberNames.contains(name)) name];
		final moved: Array<MovedMember> = [];
		final memberError: Null<String> = resolveMovedMembers(
			srcDecl, destHit.decl, srcSource, srcTypeName, destTypeName, effectiveNames, moved
		);
		if (memberError != null) return PErr(memberError);
		final srcInfo: Null<FileInfo> = index.fileInfo(srcFile);
		final destInfo: Null<FileInfo> = index.fileInfo(destHit.file);
		if (srcInfo == null || destInfo == null) return PErr('scope files are not indexed');
		final pkgErr: Null<String> = crossPackageStaticGuard(srcInfo, destInfo, moved);
		if (pkgErr != null) return PErr(pkgErr);
		final guard: Null<String> = scopeGuardError(scopeFiles, index, srcTypeName, memberNames, destTypeName);
		if (guard != null) return PErr(guard);
		// Re-bind the null-checked locals: Strict does not propagate
		// narrowing into anonymous struct fields.
		final srcSourceNN: String = srcSource;
		final srcTreeNN: QueryNode = srcTree;
		final srcDeclNN: TypeDeclMatch = srcDecl;
		final destSourceNN: String = destSource;
		final srcInfoNN: FileInfo = srcInfo;
		final destInfoNN: FileInfo = destInfo;
		return POk({
			srcFile: srcFile,
			srcTypeName: srcTypeName,
			destTypeName: destTypeName,
			index: index,
			sourceOf: sourceOf,
			trees: trees,
			srcTree: srcTreeNN,
			srcSource: srcSourceNN,
			srcDecl: srcDeclNN,
			moved: moved,
			closureAdded: closureAdded,
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
		scopeFiles: Array<{ file: String, source: String }>, index: SymbolIndex, srcTypeName: String, memberNames: Array<String>,
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
				if (imp.kind == ImportKind.Import && memberNames.exists(name -> StringTools.endsWith(imp.raw, '.$srcTypeName.$name')))
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
		prep: MovePrep, m: MovedMember, plugin: GrammarPlugin, editsByFile: Map<String, Array<{ span: Span, text: String }>>,
		movedTextEdits: Array<{ span: Span, text: String }>, callerFilesNeedingImport: Array<String>
	): Int {
		var outsideCallers: Int = 0;
		for (file => tree in prep.trees) {
			final source: Null<String> = prep.sourceOf[file];
			if (source == null) continue;
			for (offset in qualifiedReceiverOffsets(source, tree, prep.srcTypeName, m.name, plugin)) {
				final edit: { span: Span, text: String } = {
					span: new Span(offset, offset + prep.srcTypeName.length),
					text: prep.destTypeName,
				};
				if (file == prep.srcFile && insideAnyCut(prep, offset)) {
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
	private static function collectBareCallerHits(prep: MovePrep, plugin: GrammarPlugin): Array<{ m: MovedMember, offset: Int }> {
		final out: Array<{ m: MovedMember, offset: Int }> = [];
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti([for (m in prep.moved) m.name], prep.srcTree, plugin.refShape());
		for (m in prep.moved) for (hit in hitsByName[m.name] ?? []) {
			if (hit.kind == RefKind.Decl) continue;
			final binding: Null<Span> = hit.bindingSpan;
			if (binding == null || binding.from != m.span.from) continue;
			if (insideAnyCut(prep, hit.span.from)) continue;
			out.push({ m: m, offset: hit.span.from });
		}
		return out;
	}

	/**
	 * Classifies references from the moved bodies to siblings staying on the
	 * source type (via `scanSibling`): static siblings are qualified `Src.x`
	 * in place; instance-method or mutable-field or missing-final-field
	 * dependencies are collected into `error` (all reported together);
	 * final-field reads the destination mirrors go to `fieldDeps`; moved
	 * members touching a private static sibling go to `accessMembers` (the
	 * caller then adds `@:access`). Refuses up front when a case pattern
	 * captures a sibling name (the resolver cannot tell capture from member).
	 */
	private static function collectSiblingEdits(
		prep: MovePrep, captures: Array<String>, scaffold: Bool, plugin: GrammarPlugin, movedTextEdits: Array<{ span: Span, text: String }>
	): {
		error: Null<String>,
		fieldDeps: Array<String>,
		accessMembers: Array<String>,
		missingDestFields: Array<String>
	} {
		final movedNames: Array<String> = [for (m in prep.moved) m.name];
		final slices: String = [for (m in prep.moved) prep.srcSource.substring(m.cut.from, m.cut.to)].join('\n');
		final candidates: Array<MemberGroup> = [
			for (sibling in membersOf(prep.srcDecl)) {
				final siblingName: Null<String> = sibling.member.name;
				if (
					siblingName != null && sibling.member.span != null && !movedNames.contains(siblingName)
					&& slices.indexOf(siblingName) != -1
				)
					sibling;
			}
		];
		if (candidates.length == 0) return {
			error: null,
			fieldDeps: [],
			accessMembers: [],
			missingDestFields: []
		};
		// Conservative: a captured sibling name refuses even before hit
		// filtering — Refs cannot tell the capture from the member.
		for (sibling in candidates) {
			final siblingName: String = sibling.member.name ?? '';
			if (captures.contains(siblingName)) return {
				error: 'a switch case pattern in ${prep.srcFile} binds "$siblingName" — cannot safely qualify the '
					+ 'moved body\'s reference to it; rename the capture first',
				fieldDeps: [],
				accessMembers: [],
				missingDestFields: [],
			};
		}
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti(
			[for (s in candidates) s.member.name ?? ''], prep.srcTree, plugin.refShape()
		);
		final state: SiblingScanState = {
			fieldDeps: [],
			accessMembers: [],
			staysBehind: [],
			mutableDeps: [],
			missingDestFields: [],
		};
		for (sibling in candidates) scanSibling(prep, sibling, hitsByName[sibling.member.name ?? ''] ?? [], movedTextEdits, state);
		final problems: Array<String> = siblingProblems(prep, state, scaffold);
		return problems.length > 0
			? {
				error: problems.join('; '),
				fieldDeps: [],
				accessMembers: [],
				missingDestFields: []
			}
			: {
				error: null,
				fieldDeps: state.fieldDeps,
				accessMembers: state.accessMembers,
				missingDestFields: state.missingDestFields,
			};
	}

	/**
	 * A non-public member with remaining callers must be public at the
	 * destination: flip an explicit `private`, or prepend `public` to a
	 * default-visibility decl.
	 */
	private static function promotionEdit(
		prep: MovePrep, m: MovedMember, outsideCallers: Int, movedTextEdits: Array<{ span: Span, text: String }>,
		advisoryExtras: Array<String>
	): Void {
		if (m.group.modifiers.exists(mod -> mod.kind == 'Public') || outsideCallers == 0) return;
		final privateSpan: Null<Span> = m.group.modifiers.find(mod -> mod.kind == 'Private')?.span;
		if (privateSpan != null) {
			movedTextEdits.push({ span: privateSpan, text: 'public' });
		} else {
			// Insert after any leading @:meta run — `public` before a meta
			// line would not parse.
			final at: Int = m.group.modifiers.find(mod -> mod.kind != 'Meta')?.span?.from ?? m.span.from;
			movedTextEdits.push({ span: new Span(at, at), text: 'public ' });
		}
		advisoryExtras.push(
			'visibility of "${m.name}" promoted to public ($outsideCallers caller site(s) remain outside "${prep.destTypeName}")'
		);
	}

	/**
	 * An `@:access(<pkg>.<Src>)` line above the moved decl (after its doc
	 * comment) — the moved body references private members of the source.
	 */
	private static function accessEdit(
		prep: MovePrep, m: MovedMember, movedTextEdits: Array<{ span: Span, text: String }>, advisoryExtras: Array<String>
	): Void {
		final accessPath: String = prep.srcInfo.pkg == '' ? prep.srcTypeName : '${prep.srcInfo.pkg}.${prep.srcTypeName}';
		final lineStart: Int = lineStartOf(prep.srcSource, m.group.groupSpan.from);
		final indent: String = prep.srcSource.substring(lineStart, m.group.groupSpan.from);
		// A decl sharing its line with other code (one-line class) gets the
		// meta inline — the "indent" would otherwise capture that code.
		if (isAllWhitespace(indent))
			movedTextEdits.push({ span: new Span(lineStart, lineStart), text: '$indent@:access($accessPath)\n' });
		else
			movedTextEdits.push({
				span: new Span(m.group.groupSpan.from, m.group.groupSpan.from),
				text: '@:access($accessPath) ',
			});
		advisoryExtras.push(
			'moved body of "${m.name}" references private member(s) of "${prep.srcTypeName}" — added @:access($accessPath)'
		);
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
		final carried: Array<ImportInfo> = [];
		for (m in prep.moved)
			for (imp in MoveSymbol.dependencyImportsToCarry(
				prep.srcSource, m.group.groupSpan, prep.srcInfo, prep.destInfo, plugin, typeRefShape, prep.srcTypeName
			)) if (!carried.exists(c -> c.raw == imp.raw && c.kind == imp.kind)) carried.push(imp);
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
	 * Classifies each in-cut reference to one sibling into `state`: a static
	 * sibling is qualified `Src.<sibling>` in place (and its host recorded in
	 * `accessMembers` when the sibling is private); a final-field read goes to
	 * `fieldDeps` if the destination mirrors it, else `missingDestFields`; a
	 * mutable field goes to `mutableDeps`; an instance method goes to
	 * `staysBehind`. Mutates `state` and `movedTextEdits`; returns nothing.
	 */
	private static function scanSibling(
		prep: MovePrep, sibling: MemberGroup, hits: Array<RefHit>, movedTextEdits: Array<{ span: Span, text: String }>,
		state: SiblingScanState
	): Void {
		final siblingSpan: Null<Span> = sibling.member.span;
		if (siblingSpan == null) return;
		final siblingName: String = sibling.member.name ?? '';
		final siblingStatic: Bool = sibling.modifiers.exists(m -> m.kind == 'Static');
		final siblingPublic: Bool = sibling.modifiers.exists(m -> m.kind == 'Public');
		for (hit in hits) {
			if (hit.kind == RefKind.Decl) continue;
			final binding: Null<Span> = hit.bindingSpan;
			if (binding == null || binding.from != siblingSpan.from) continue;
			final host: Null<MovedMember> = prep.moved.find(m -> hit.span.from >= m.cut.from && hit.span.from < m.cut.to);
			if (host == null) continue;
			if (siblingStatic) {
				movedTextEdits.push({ span: new Span(hit.span.from, hit.span.from), text: '${prep.srcTypeName}.' });
				if (!siblingPublic && !state.accessMembers.contains(host.name)) state.accessMembers.push(host.name);
			} else if (DATA_FIELD_KINDS.contains(sibling.member.kind)) {
				// Sibling-fields contract: a moved body may keep reading a
				// FINAL field IF the destination declares a same-named final
				// field wired with the same value at construction.
				if (!FINAL_FIELD_KINDS.contains(sibling.member.kind)) {
					pushUnique(state.mutableDeps, siblingName);
				} else {
					final destField: Null<MemberGroup> = memberGroupOf(prep.destDecl, siblingName);
					if (destField == null || !FINAL_FIELD_KINDS.contains(destField.member.kind))
						pushUnique(state.missingDestFields, siblingName);
					else
						pushUnique(state.fieldDeps, siblingName);
				}
			} else {
				pushUnique(state.staysBehind, siblingName);
			}
		}
	}

	private static inline function insideAnyCut(prep: MovePrep, offset: Int): Bool {
		return prep.moved.exists(m -> offset >= m.cut.from && offset < m.cut.to);
	}

	/**
	 * Whether any moved body references `this` (an `IdentExpr` named `this`
	 * inside a cut span) — such a reference cannot survive a move.
	 */
	private static function thisInsideCuts(prep: MovePrep): Bool {
		var found: Bool = false;
		function walk(node: QueryNode): Void {
			if (found) return;
			final span: Null<Span> = node.span;
			if (node.kind == 'IdentExpr' && node.name == 'this' && span != null && insideAnyCut(prep, span.from)) {
				found = true;
				return;
			}
			for (c in node.children) walk(c);
		}
		walk(prep.srcTree);
		return found;
	}

	/**
	 * Resolves the source-type instance field of type `destTypeName` that
	 * remaining bare instance callers are rewired through: an explicit
	 * `viaField` is validated, otherwise the unique candidate is picked.
	 */
	private static function resolveViaField(prep: MovePrep, viaField: Null<String>, scaffold: Bool, plugin: GrammarPlugin): ViaResult {
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final declared: Map<Int, String> = provider != null ? provider.declaredTypes(prep.srcSource) : [];
		final fields: Array<MemberGroup> = [
			for (g in membersOf(prep.srcDecl))
				if (DATA_FIELD_KINDS.contains(g.member.kind) && !g.modifiers.exists(mod -> mod.kind == 'Static')) g
		];
		if (viaField != null) {
			final g: Null<MemberGroup> = fields.find(f -> f.member.name == viaField);
			if (g == null)
				return scaffold
					? scaffoldViaResult(prep, viaField)
					: VErr('"${prep.srcTypeName}" has no instance field "$viaField" (--via)');
			final gSpan: Null<Span> = g.member.span;
			final declaredType: Null<String> = gSpan != null ? declared[gSpan.from] : null;
			if (declaredType != null && declaredType != prep.destTypeName)
				return VErr('--via field "$viaField" is declared as "$declaredType", not "${prep.destTypeName}"');
			return VOk(viaField);
		}
		final candidates: Array<String> = [
			for (g in fields) {
				final gSpan: Null<Span> = g.member.span;
				final name: Null<String> = g.member.name;
				if (gSpan != null && name != null && declared[gSpan.from] == prep.destTypeName) name;
			}
		];
		return switch candidates {
			case [one]: VOk(one);
			case []: scaffold
				? scaffoldViaResult(prep, deriveViaName(prep.destTypeName))
				: VErr(
					'caller(s) of the moved instance member(s) remain in "${prep.srcTypeName}" but it has no field of '
					+ 'type "${prep.destTypeName}" to route them through — add one '
					+ '(e.g. `private final _x: ${prep.destTypeName}`), wire it in the constructor, pass --via <field>, or --scaffold'
				);
			case many: VErr(
				'multiple fields of type "${prep.destTypeName}" on "${prep.srcTypeName}" (${many.join(', ')}) ' + '— pass --via <field>'
			);
		};
	}

	/**
	 * Up-front refusals independent of the edit collection: a moved member
	 * whose name a case pattern captures, or (for an instance move) a moved
	 * body referencing `this` — which would silently re-bind to the
	 * destination. Returns the message, or null when clear.
	 */
	private static function moveGuardError(prep: MovePrep, captures: Array<String>): Null<String> {
		for (m in prep.moved) if (captures.contains(m.name))
			return 'a switch case pattern in ${prep.srcFile} binds "${m.name}" — reference resolution cannot tell the '
				+ 'capture from the member; rename the capture first';
		return prep.moved.exists(m -> !m.isStatic) && thisInsideCuts(prep)
			? 'a moved body references "this", which would re-bind to "${prep.destTypeName}" — rewrite to bare member access first'
			: null;
	}

	/**
	 * Rewrites the bare in-src callers of every moved member: a static
	 * member qualifies as `Dest.m`, an instance member routes through the
	 * via field on the source type. Returns an error message, or null.
	 */
	private static function collectCallerRewires(
		prep: MovePrep, viaField: Null<String>, scaffold: Bool, scaffoldFields: Array<ScaffoldField>, plugin: GrammarPlugin,
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, outsideCallersOf: Map<String, Int>, advisoryExtras: Array<String>
	): Null<String> {
		final bareHits: Array<{ m: MovedMember, offset: Int }> = collectBareCallerHits(prep, plugin);
		for (h in bareHits) if (h.m.isStatic) {
			editsFor(editsByFile, prep.srcFile).push({ span: new Span(h.offset, h.offset), text: '${prep.destTypeName}.' });
			outsideCallersOf[h.m.name] = (outsideCallersOf[h.m.name] ?? 0) + 1;
		}
		final instanceHits: Array<{ m: MovedMember, offset: Int }> = bareHits.filter(h -> !h.m.isStatic);
		if (instanceHits.length == 0) return null;
		final via: { name: String, scaffold: Bool } = switch resolveViaField(prep, viaField, scaffold, plugin) {
			case VErr(message): return message;
			case VOk(name): { name: name, scaffold: false };
			case VScaffold(name): { name: name, scaffold: true };
		};
		if (via.scaffold) {
			final srcCtor: Null<MemberGroup> = constructorGroupOf(prep.srcDecl);
			final ctorSpan: Null<Span> = srcCtor != null ? srcCtor.member.span : null;
			if (ctorSpan != null && instanceHits.exists(h -> h.offset >= ctorSpan.from && h.offset < ctorSpan.to))
				return 'a moved instance member is called inside the "${prep.srcTypeName}" constructor — the scaffolded via '
					+ 'field would be read before it is initialized; move the call out of the constructor or wire the via field manually';
		}
		for (h in instanceHits) {
			editsFor(editsByFile, prep.srcFile).push({ span: new Span(h.offset, h.offset), text: '${via.name}.' });
			outsideCallersOf[h.m.name] = (outsideCallersOf[h.m.name] ?? 0) + 1;
		}
		if (via.scaffold) {
			final error: Null<String> = scaffoldViaField(prep, via.name, scaffoldFields, editsByFile);
			if (error != null) return error;
			advisoryExtras.push(
				'--scaffold added via field "${via.name}" wired `new ${prep.destTypeName}(...)` in the "${prep.srcTypeName}" constructor'
			);
		} else {
			advisoryExtras.push('bare instance caller(s) in "${prep.srcTypeName}" rewired through "${via.name}"');
		}
		return null;
	}

	/**
	 * Builds each moved member's text block, shifting the collected
	 * source-coordinate edits into the member's slice space.
	 */
	private static function buildMovedBlocks(prep: MovePrep, movedTextEdits: Array<{ span: Span, text: String }>): Array<String> {
		return [
			for (m in prep.moved) {
				final shifted: Array<{ span: Span, text: String }> = [
					for (e in movedTextEdits)
						if (e.span.from >= m.cut.from && e.span.from < m.cut.to)
							{ span: new Span(e.span.from - m.cut.from, e.span.to - m.cut.from), text: e.text }
				];
				trimBlankEdges(RefactorSupport.applyEdits(prep.srcSource.substring(m.cut.from, m.cut.to), shifted));
			}
		];
	}

	/**
	 * Resolves each named member into a `MovedMember` (source order,
	 * non-overlapping cut spans), filling `moved`. Returns an error
	 * message, or null.
	 */
	private static function resolveMovedMembers(
		srcDecl: TypeDeclMatch, destDecl: TypeDeclMatch, srcSource: String, srcTypeName: String, destTypeName: String,
		memberNames: Array<String>, moved: Array<MovedMember>
	): Null<String> {
		for (name in memberNames) {
			if (moved.exists(m -> m.name == name)) return 'member "$name" is listed twice';
			if (name == 'new') return 'cannot move a constructor';
			final group: Null<MemberGroup> = memberGroupOf(srcDecl, name);
			if (group == null) return 'type "$srcTypeName" has no member "$name"';
			final memberSpan: Null<Span> = group.member.span;
			if (memberSpan == null) return 'member "$name" carries no span';
			if (memberGroupOf(destDecl, name) != null) return 'type "$destTypeName" already declares a member "$name"';
			// Re-bind: Strict does not propagate narrowing into anonymous
			// struct fields.
			final groupNN: MemberGroup = group;
			final memberSpanNN: Span = memberSpan;
			moved.push({
				name: name,
				group: groupNN,
				span: memberSpanNN,
				cut: cutSpanOf(srcSource, groupNN),
				isStatic: groupNN.modifiers.exists(m -> m.kind == 'Static'),
			});
		}
		moved.sort((a, b) -> a.cut.from - b.cut.from);
		for (i in 1...moved.length) if (moved[i].cut.from < moved[i - 1].cut.to)
			return 'members "${moved[i - 1].name}" and "${moved[i].name}" resolve to overlapping source spans';
		return null;
	}

	private static inline function quoted(names: Array<String>): String {
		return names.map(n -> '"$n"').join(', ');
	}

	private static inline function pushUnique(names: Array<String>, name: String): Void {
		if (!names.contains(name)) names.push(name);
	}

	/**
	 * `--closure` expansion: grows `seed` to the transitive closure of
	 * instance-METHOD siblings called from the moved bodies (the members
	 * that would otherwise force a "staysBehind" refusal, one per manual
	 * iteration). Static siblings (qualified `Src.x`) and data-field reads
	 * (sibling-fields contract) are NOT pulled in — only non-static
	 * function members reached by a real in-body reference. Terminates by
	 * fixpoint over the finite member set.
	 */
	private static function expandInstanceCallClosure(
		srcDecl: TypeDeclMatch, srcTree: QueryNode, srcSource: String, seed: Array<String>, plugin: GrammarPlugin
	): Array<String> {
		final names: Array<String> = seed.copy();
		final allMembers: Array<MemberGroup> = membersOf(srcDecl);
		final byName: Map<String, MemberGroup> = [];
		for (g in allMembers) {
			final nm: Null<String> = g.member.name;
			if (nm != null) byName[nm] = g;
		}
		while (true) {
			final cuts: Array<Span> = [
				for (name in names) {
					final g: Null<MemberGroup> = byName[name];
					if (g != null) cutSpanOf(srcSource, g);
				}
			];
			final added: Array<String> = instanceCallsInto(allMembers, names, cuts, srcSource, srcTree, plugin);
			if (added.length == 0) break;
			for (name in added) names.push(name);
		}
		return names;
	}

	/**
	 * The non-static function siblings (not already in `names`) reached by
	 * a real in-body reference from within `cuts` — one closure step.
	 */
	private static function instanceCallsInto(
		allMembers: Array<MemberGroup>, names: Array<String>, cuts: Array<Span>, srcSource: String, srcTree: QueryNode,
		plugin: GrammarPlugin
	): Array<String> {
		final slices: String = [for (c in cuts) srcSource.substring(c.from, c.to)].join('\n');
		final candidates: Array<MemberGroup> = [
			for (g in allMembers) {
				final nm: Null<String> = g.member.name;
				if (
					nm != null && g.member.span != null && !names.contains(nm) && RefactorSupport.FN_DECL_KINDS.contains(g.member.kind)
					&& !g.modifiers.exists(mod -> mod.kind == 'Static') && slices.indexOf(nm) != -1
				)
					g;
			}
		];
		if (candidates.length == 0) return [];
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti(
			[for (c in candidates) c.member.name ?? ''], srcTree, plugin.refShape()
		);
		final added: Array<String> = [];
		for (c in candidates) {
			final cSpan: Null<Span> = c.member.span;
			final nm: String = c.member.name ?? '';
			if (cSpan != null && calledFromCuts(hitsByName[nm] ?? [], cSpan, cuts)) pushUnique(added, nm);
		}
		return added;
	}

	/**
	 * Whether any of `hits` (references to the member declared at `declSpan`)
	 * lands inside one of the `cuts` — i.e. the member is called from within
	 * a moved body.
	 */
	private static function calledFromCuts(hits: Array<RefHit>, declSpan: Span, cuts: Array<Span>): Bool {
		for (hit in hits) {
			if (hit.kind == RefKind.Decl) continue;
			final binding: Null<Span> = hit.bindingSpan;
			if (binding == null || binding.from != declSpan.from) continue;
			if (cuts.exists(cut -> hit.span.from >= cut.from && hit.span.from < cut.to)) return true;
		}
		return false;
	}

	/**
	 * The refusal messages for the three violation buckets `scanSibling`
	 * fills — reported together so one run surfaces the whole closure.
	 */
	private static function siblingProblems(prep: MovePrep, state: SiblingScanState, scaffold: Bool): Array<String> {
		final problems: Array<String> = [];
		if (state.staysBehind.length > 0)
			problems.push(
				'moved bodies call instance member(s) ${quoted(state.staysBehind)} which stay on '
				+ '"${prep.srcTypeName}" — add them to the move list or move them first (or pass --closure)'
			);
		if (state.mutableDeps.length > 0)
			problems.push(
				'moved bodies read mutable instance field(s) ${quoted(state.mutableDeps)} — shared mutable state '
				+ 'cannot be mirrored onto "${prep.destTypeName}"; make them final or refactor first'
			);
		// A missing final field on the destination is a hard error UNLESS
		// --scaffold is on, which generates the field + constructor instead.
		if (!scaffold && state.missingDestFields.length > 0)
			problems.push(
				'moved bodies read final field(s) ${quoted(state.missingDestFields)} — "${prep.destTypeName}" must '
				+ 'declare them as same-named final fields (sibling-fields contract) wired in its constructor (or pass --scaffold)'
			);
		return problems;
	}

	/**
	 * Applies `collectSiblingEdits`'s outcome: `@:access` per moved member
	 * whose body reads a private static sibling, plus the final-field-dep
	 * advisory (the caller must construct the destination with the same
	 * values).
	 */
	private static function applySiblingOutcome(
		prep: MovePrep, accessMembers: Array<String>, fieldDeps: Array<String>, movedTextEdits: Array<{ span: Span, text: String }>,
		advisoryExtras: Array<String>
	): Void {
		for (m in prep.moved) if (accessMembers.contains(m.name)) accessEdit(prep, m, movedTextEdits, advisoryExtras);
		if (fieldDeps.length > 0)
			advisoryExtras.push(
				'moved bodies read final field(s) ${quoted(fieldDeps)} — construct "${prep.destTypeName}" with the same values'
			);
	}

	private static inline function deriveViaName(destTypeName: String): String {
		return destTypeName == '' ? '_via' : '_${destTypeName.charAt(0).toLowerCase()}${destTypeName.substr(1)}';
	}

	private static inline function paramNameOf(fieldName: String): String {
		return StringTools.startsWith(fieldName, '_') ? fieldName.substr(1) : fieldName;
	}

	private static inline function constructorGroupOf(decl: TypeDeclMatch): Null<MemberGroup> {
		return memberGroupOf(decl, 'new');
	}

	/**
	 * A `new() {}` with no parameters and an empty body — the auto-emitted
	 * constructor of a fresh `hxq new` class, safe for `--scaffold` to
	 * replace with a real one.
	 */
	private static function isTrivialCtor(source: String, group: MemberGroup): Bool {
		final hasParam: Bool = group.member.children.exists(c -> c.kind == 'Required' || c.kind == 'Optional');
		if (hasParam) return false;
		final body: Null<QueryNode> = group.member.children.find(c -> c.kind == 'BlockBody');
		if (body == null || body.children.length > 0) return false;
		final bodySpan: Null<Span> = body.span;
		// No parameters, no statement children, and nothing but whitespace
		// between the braces — a comment is trivia (not a child) and must
		// not be silently clobbered.
		return bodySpan != null && isAllWhitespace(source.substring(bodySpan.from + 1, bodySpan.to - 1));
	}

	private static function ctorBodyClose(source: String, ctorMember: QueryNode): Null<Int> {
		final span: Null<Span> = ctorMember.span;
		if (span == null) return null;
		var close: Int = span.to - 1;
		if (close >= source.length) close = source.length - 1;
		while (close >= span.from && RefactorSupport.isSpace(StringTools.fastCodeAt(source, close))) close--;
		return close < span.from || StringTools.fastCodeAt(source, close) != '}'.code ? null : close;
	}

	/**
	 * The `private final <name>: <type>;` declarations plus a constructor
	 * assigning each, ready to splice into an empty destination.
	 */
	private static function scaffoldDestBlock(fields: Array<ScaffoldField>): String {
		final fieldLines: String = [for (f in fields) '\tprivate final ${f.name}: ${f.type};'].join('\n');
		final params: String = [for (f in fields) '${paramNameOf(f.name)}: ${f.type}'].join(', ');
		final assigns: String = [
			for (f in fields) {
				final p: String = paramNameOf(f.name);
				'\t\t' + (p == f.name ? 'this.${f.name} = $p;' : '${f.name} = $p;');
			}
		].join('\n');
		return '$fieldLines\n\n\tpublic function new($params) {\n$assigns\n\t}';
	}

	/**
	 * Resolves the verbatim declared type of each named source field via
	 * `TypeInfoProvider.declaredTypeSources`. Returns an error when a field
	 * has no explicit nominal annotation to mirror onto the destination.
	 */
	private static function resolveScaffoldFields(
		prep: MovePrep, names: Array<String>, plugin: GrammarPlugin
	): { error: Null<String>, fields: Array<ScaffoldField> } {
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return { error: 'cannot --scaffold: the grammar does not expose declared field types', fields: [] };
		final typeSources: Map<Int, String> = provider.declaredTypeSources(prep.srcSource);
		final members: Array<MemberGroup> = membersOf(prep.srcDecl);
		final fields: Array<ScaffoldField> = [];
		for (name in names) {
			final g: Null<MemberGroup> = members.find(mm -> mm.member.name == name);
			final gSpan: Null<Span> = g != null ? g.member.span : null;
			final type: Null<String> = gSpan != null ? typeSources[gSpan.from] : null;
			if (type == null) return {
				error: 'cannot --scaffold field "$name": its type on "${prep.srcTypeName}" is not an explicit nominal annotation',
				fields: [],
			};
			final typeNN: String = type;
			fields.push({ name: name, type: typeNN });
		}
		return { error: null, fields: fields };
	}

	/**
	 * Emits the mirrored final fields + constructor onto the destination.
	 * With no destination constructor the block is returned to prepend to
	 * the moved-member insert; with a trivial `new() {}` the block replaces
	 * it in place; a real constructor is refused.
	 */
	private static function applyDestScaffold(
		prep: MovePrep, fields: Array<ScaffoldField>, editsByFile: Map<String, Array<{ span: Span, text: String }>>
	): { error: Null<String>, prependBlock: String } {
		final block: String = scaffoldDestBlock(fields);
		final ctor: Null<MemberGroup> = constructorGroupOf(prep.destDecl);
		if (ctor == null) return { error: null, prependBlock: block };
		if (!isTrivialCtor(prep.destSource, ctor)) return {
			error: '"${prep.destTypeName}" already has a constructor — --scaffold targets an empty destination '
				+ '(a bare `new() {}` or no constructor)',
			prependBlock: '',
		};
		final from: Int = lineStartOf(prep.destSource, ctor.groupSpan.from);
		editsFor(editsByFile, prep.destFile).push({ span: new Span(from, ctor.groupSpan.to), text: block });
		return { error: null, prependBlock: '' };
	}

	/**
	 * Adds the via field to the source type and wires
	 * `<via> = new <Dest>(<fields>);` at the end of its constructor. Refuses
	 * when the source type has no constructor to wire into.
	 */
	private static function scaffoldViaField(
		prep: MovePrep, viaName: String, fields: Array<ScaffoldField>, editsByFile: Map<String, Array<{ span: Span, text: String }>>
	): Null<String> {
		final ctor: Null<MemberGroup> = constructorGroupOf(prep.srcDecl);
		if (ctor == null) return 'cannot --scaffold via field "$viaName": "${prep.srcTypeName}" has no constructor to wire it in';
		final fieldFrom: Int = lineStartOf(prep.srcSource, ctor.groupSpan.from);
		editsFor(editsByFile, prep.srcFile).push({
			span: new Span(fieldFrom, fieldFrom),
			text: '\tprivate final $viaName: ${prep.destTypeName};\n\n',
		});
		final bodyClose: Null<Int> = ctorBodyClose(prep.srcSource, ctor.member);
		if (bodyClose == null) return 'cannot --scaffold via field "$viaName": could not locate the "${prep.srcTypeName}" constructor body';
		var wsStart: Int = bodyClose;
		while (wsStart > 0 && RefactorSupport.isSpace(StringTools.fastCodeAt(prep.srcSource, wsStart - 1))) wsStart--;
		final args: String = [for (f in fields) f.name].join(', ');
		editsFor(editsByFile, prep.srcFile).push({
			span: new Span(wsStart, bodyClose),
			text: '\n\t\t$viaName = new ${prep.destTypeName}($args);\n\t',
		});
		return null;
	}

	/**
	 * Cuts the moved members from the source and pushes the destination
	 * insert: the scaffold block (fields + constructor) when generating,
	 * then a blank-framed run of the moved members before the closing `}`.
	 * Returns an error message, or null.
	 */
	private static function assembleDestination(
		prep: MovePrep, scaffoldFields: Array<ScaffoldField>, movedTextEdits: Array<{ span: Span, text: String }>,
		editsByFile: Map<String, Array<{ span: Span, text: String }>>, advisoryExtras: Array<String>
	): Null<String> {
		var destPrepend: String = '';
		if (scaffoldFields.length > 0) {
			final scaf: { error: Null<String>, prependBlock: String } = applyDestScaffold(prep, scaffoldFields, editsByFile);
			if (scaf.error != null) return scaf.error;
			destPrepend = scaf.prependBlock;
			advisoryExtras.push('--scaffold generated ${scaffoldFields.length} final field(s) + constructor on "${prep.destTypeName}"');
		}
		final blocks: Array<String> = buildMovedBlocks(prep, movedTextEdits);
		for (m in prep.moved) editsFor(editsByFile, prep.srcFile).push({ span: m.cut, text: '' });
		final bodyClose: Null<Int> = typeBodyClose(prep.destSource, prep.destDecl);
		if (bodyClose == null) return '"${prep.destTypeName}" has no brace body to receive the member';
		var wsStart: Int = bodyClose;
		while (wsStart > 0 && RefactorSupport.isSpace(StringTools.fastCodeAt(prep.destSource, wsStart - 1))) wsStart--;
		final destFrame: String = destPrepend == '' ? '\n\n${blocks.join('\n\n')}\n\n' : '\n\n$destPrepend\n\n${blocks.join('\n\n')}\n\n';
		editsFor(editsByFile, prep.destFile).push({ span: new Span(wsStart, bodyClose), text: destFrame });
		return null;
	}


	/**
	 * Wraps a scaffold via name in a `VScaffold`, refusing when the name
	 * already collides with a source member (a duplicate field or an
	 * ambiguous reference would otherwise be generated silently).
	 */
	private static function scaffoldViaResult(prep: MovePrep, name: String): ViaResult {
		return memberGroupOf(prep.srcDecl, name) != null
			? VErr(
				'cannot --scaffold via field "$name": "${prep.srcTypeName}" already declares a member with that name '
				+ '— pass a different --via'
			)
			: VScaffold(name);
	}


	/**
	 * Cross-package refusal: a fully-qualified caller `pkg.Src.member` cannot
	 * be safely repointed, because rewriting only the `Src` segment yields
	 * `pkg.Dest.member` in the SOURCE package — wrong when Dest lives
	 * elsewhere, and silently wrong if the source package happens to declare
	 * its own `Dest`. Refuse when the move is cross-package and any such
	 * caller exists. Null otherwise. Bare `Src.member` callers are safe (they
	 * pick up the destination import).
	 */
	private static function crossPackageFqnRefusal(prep: MovePrep): Null<String> {
		if (prep.srcInfo.pkg == prep.destInfo.pkg) return null;
		final movedNames: Array<String> = [for (m in prep.moved) m.name];
		final offenders: Array<String> = [];
		function walk(node: QueryNode): Void {
			final children: Array<QueryNode> = node.children;
			final nm: Null<String> = node.name;
			if (node.kind == 'FieldAccess' && nm != null && movedNames.contains(nm) && children.length > 0) {
				final recv: QueryNode = children[0];
				if (recv.kind == 'FieldAccess' && recv.name == prep.srcTypeName && !offenders.contains(nm)) offenders.push(nm);
			}
			for (c in children) walk(c);
		}
		for (file => tree in prep.trees) walk(tree);
		return offenders.length == 0
			? null
			: 'cross-package move: member(s) ${quoted(offenders)} are called via a fully-qualified '
				+ '"${prep.srcTypeName}.<member>" receiver — repointing the package segment is unsafe; '
				+ 'convert those call sites to a bare "${prep.srcTypeName}.<member>" (with an import) first';
	}

	/**
	 * Cross-package import wiring: after a static cross-package move the source
	 * file references `Dest` (rewritten callers) and the destination file may
	 * reference `Src` (sibling-qualified `Src.other` calls in the moved body).
	 * Add the missing imports on each side (deduped by `addImportEdit`). A
	 * no-op within one package.
	 */
	private static function pushCrossPackageImports(
		prep: MovePrep, editsByFile: Map<String, Array<{ span: Span, text: String }>>, movedTextEdits: Array<{ span: Span, text: String }>
	): Void {
		if (prep.srcInfo.pkg == prep.destInfo.pkg) return;
		final srcEdits: Array<{ span: Span, text: String }> = editsByFile[prep.srcFile] ?? [];
		if (srcEdits.exists(e -> e.text != '' && StringTools.contains(e.text, prep.destTypeName))) {
			final destPath: String = prep.destTypeName == RefactorSupport.baseNameOf(prep.destFile)
				? prep.destInfo.module
				: '${prep.destInfo.module}.${prep.destTypeName}';
			final edit: Null<{ span: Span, text: String }> = MoveSymbol.addImportEdit(prep.srcSource, prep.srcInfo, destPath);
			if (edit != null) editsFor(editsByFile, prep.srcFile).push(edit);
		}
		if (movedTextEdits.exists(e -> StringTools.contains(e.text, '${prep.srcTypeName}.'))) {
			final srcPath: String = prep.srcTypeName == RefactorSupport.baseNameOf(prep.srcFile)
				? prep.srcInfo.module
				: '${prep.srcInfo.module}.${prep.srcTypeName}';
			final edit: Null<{ span: Span, text: String }> = MoveSymbol.addImportEdit(prep.destSource, prep.destInfo, srcPath);
			if (edit != null) editsFor(editsByFile, prep.destFile).push(edit);
		}
	}


	/**
	 * The refusal for a cross-package move of an INSTANCE member — this
	 * increment repoints qualified static callers and wires the src/dest
	 * imports, but an instance move across packages would also need the via
	 * field's type imported into the source and is deferred. Null within one
	 * package or for an all-static move.
	 */
	private static function crossPackageStaticGuard(srcInfo: FileInfo, destInfo: FileInfo, moved: Array<MovedMember>): Null<String> {
		return srcInfo.pkg != destInfo.pkg && moved.exists(m -> !m.isStatic)
			? 'cross-package move supports static members only in this increment '
				+ '(source package "${srcInfo.pkg}" != destination package "${destInfo.pkg}")'
			: null;
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
