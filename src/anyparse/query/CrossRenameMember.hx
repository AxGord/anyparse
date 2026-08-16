package anyparse.query;

import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.ModulePath;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.OverrideFamilyMember;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/**
 * One resolved member the cursor sits on: its declaring type name, the
 * member name, whether it is `static` / `override`, and the enclosing
 * type declaration (for the same-type name-collision check).
 */
private typedef MemberTarget = {
	var typeName: String;
	var memberName: String;
	var isStatic: Bool;
	var isOverride: Bool;
	var srcDecl: TypeDeclMatch;
}

/**
 * One scope file parsed once — the shared unit passed between phases.
 */
private typedef ParsedFile = {
	final file: String;
	final source: String;
	final tree: QueryNode;
};

/**
 * The located member-token offsets for ONE file plus the diagnostic of the
 * first PROVEN access whose token could not be located. A non-null `error`
 * refuses the whole rename, so a rewrite is never half-applied.
 */
private typedef LocatedOffsets = {
	final offsets: Array<Int>;
	final error: Null<String>;
};

/**
 * Scope-correct, format-preserving cross-file rename of a METHOD or
 * FIELD — the value/method counterpart of `CrossRename` (which renames a
 * TYPE). Both are reached through `apq rename --scope`: the CLI resolves
 * the cursor and dispatches to `CrossRename` when it lands on a type
 * declaration, here when it lands on a member declaration.
 *
 * ## Correctness model — prove every rewrite, never guess
 *
 * A member reference is only rewritten when the operation can PROVE it
 * binds to this member; anything unprovable is left as a loud compile
 * error, never a silent semantic change (the `CrossRename` contract).
 * The forms rewritten:
 *
 *  - The declaration name plus every in-declaring-type reference the
 *    scope resolver binds to it — bare `member` (implicit `this`) reads /
 *    calls and `this.member` field accesses. This is exactly the
 *    single-file occurrence set `Rename` computes, so the declaring file
 *    is delegated to `Rename.renameOccurrences`.
 *  - STATIC members: every qualified access `Src.member` / `pkg.Src.member`
 *    across the scope whose receiver is the type used as a namespace. A BARE
 *    receiver is excluded when a value binding of the same name shadows it; a
 *    DOTTED one must spell the declaring module WHOLE — one of
 *    `RefactorSupport.qualifiedPaths`, never merely the same last segment, or
 *    `other.Src.member` would rewrite with `pkg.Src.member`. Mirrors
 *    `CrossRename`; `MoveMember` still matches by last segment.
 *  - A BARE `case <member>:` pattern whose switch SUBJECT is proven to hold a value of
 *    the source type, by the same resolution the instance receivers go through.
 *    Unqualified, a value of an `enum abstract` reads in a pattern as a reference to the
 *    member, never as a capture.
 *  - INSTANCE members: every `obj.member` whose receiver `obj` resolves
 *    (through the scope resolver + `TypeInfoProvider.declaredTypes`) to a
 *    local / parameter / field DECLARED of the source type. A receiver
 *    whose type does not resolve is left alone — if it really was the
 *    source type the miss surfaces as a compile error, never a wrong
 *    rewrite. A `new T()` receiver resolves through its own type
 *    name and needs no binding at all.
 *  - EVERY branch of a `#if` region that declares the member. The region is a
 *    member HOST, not a member — it holds each branch's members with their own
 *    modifier siblings — so the cursor scan asks `RefactorSupport.eachMemberHost`,
 *    the walk `SymbolIndexBuilder` already uses, and the edit set takes every
 *    declaration from `SymbolIndex.declarationsOf`. A type may repeat a member
 *    name only across branches, so those declarations are ONE logical member;
 *    rewriting the cursor's branch alone leaves every OTHER build target with
 *    accesses no declaration matches, which no single-target compile can catch.
 *
 * ## Refusals (correctness boundary)
 *
 *  - The declaring type must be UNIQUE under the scope (a second type of
 *    the same name would make the simple-name receiver match ambiguous).
 *  - An `override` member is refused — it belongs to a base declaration;
 *    renaming it alone would dangle the override AND miss the base. So is
 *    a member some ANCESTOR in the scope declares: an implementation of
 *    an `abstract` method or an interface method carries no `override`
 *    modifier, so the keyword alone never saw it.
 *  - A member whose name is also captured by a `case` pattern in the
 *    declaring file is refused: sibling case-branch captures flatten into
 *    one scope frame, so the resolver can mis-attribute a bare reference (see
 *    `RefactorSupport.casePatternCaptures`, shared with `MoveMember`). An identifier the
 *    language cannot BIND in a pattern is not a capture and does not refuse.
 *  - The destination name already declared on the type, a constructor
 *    (`new`), an unparseable scope file, or a post-rewrite parse failure
 *    are all refused; the write is atomic (all files or none). "Declared
 *    on the type" counts the OTHER branches of a `#if` region, so renaming
 *    one branch's member onto a name a sibling branch uses is refused even
 *    though the two never coexist in one build — conservative, and it keeps
 *    a rename from quietly merging two members into one.
 *  - A PROVEN access whose member token cannot be located in code is
 *    refused rather than skipped. That token is searched in the window
 *    between the receiver span and the field-access span, which also
 *    holds every byte of trivia between them, so the search runs through
 *    `RefactorSupport.activeCodeIdentTokenOffset` and a comment that
 *    mentions the member never wins the race for it. Refusing on a miss
 *    is what keeps the reported occurrence count equal to what was
 *    actually rewritten.
 *
 * ## Documented residual (loud-fail, not silent)
 *
 * Unresolved instance receivers (chained calls, un-annotated locals,
 * casts), `super`-access, `using`-extension call sites, aliased-import
 * homonyms, a DOTTED static receiver whose path is not one the declaring
 * module makes legal, and overrides declared OUTSIDE the scope are not rewritten —
 * each dangles into a compile error the user can see. The advisory
 * (always non-null on success) reminds them.
 *
 * An `enum abstract` value spelled BARE in a `case` pattern renames with the declaration
 * when the type of the switch subject resolves to the abstract. When it does not, the
 * pattern keeps the old name and the compiler rejects it by name — Haxe never binds an
 * upper-case pattern identifier, so the leftover is loud, never a silent capture.
 *
 * NOT yet rewritten, and the largest remaining residual: an unqualified value the compiler
 * resolves from the EXPECTED TYPE — `return Seam;` inside a function returning the abstract,
 * a ternary arm of such a return, `x == Seam`. Measured over 89 enum abstracts of this repo
 * and of a large app: 193 such sites, 137 of them in return position. Each is a loud
 * `Unknown identifier` after the rename, never a silent capture, because no local binds the
 * name; proving one needs the expected type at the site, which this op does not model.
 *
 * Coordinate convention: `line` / `col` are 1-based, exactly as
 * `apq refs` prints them — identical to `Rename` / `CrossRename`.
 */
@:nullSafety(Strict)
final class CrossRenameMember {

	/** The advisory appended to every successful member rename. */
	private static final ADVISORY: String =
		'member rename resolves instance receivers and switch subjects via declared types only — unresolved receivers and subjects (chained calls, un-annotated locals, casts), an unqualified value the compiler resolves from the EXPECTED type (a bare `return VALUE;` of an enum abstract), super-access, `using` extension calls, aliased-import homonyms, and overrides declared outside this scope are left as loud compile errors; verify by hand.';

	/**
	 * Rename the member declaration at `line:col` (in `cursorFile` /
	 * `cursorSource`) to `newName` across every file in `scopeFiles`.
	 * PURE — never touches the filesystem; the CLI reads the scope and
	 * decides whether to write the returned rewrites. `scopeFiles` SHOULD
	 * include `cursorFile`.
	 */
	public static function crossRenameMember(
		cursorFile: String, cursorSource: String, line: Int, col: Int, newName: String,
		scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin, refShape: RefShape
	): CrossRenameResult {
		if (!RefactorSupport.isIdentifier(newName)) return Err('new name "$newName" is not a valid identifier');

		final cursorTree: QueryNode = try plugin.parseFile(cursorSource) catch (exception: ParseError) return Err(
			'$cursorFile does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('$cursorFile does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(cursorSource, line, col);
		final target: Null<MemberTarget> = resolveMemberAtCursor(cursorTree, cursor, cursorSource, refShape);
		if (target == null)
			return Err(
				'position $line:$col is not on a member declaration (field / method) — cross-file --scope renames a type or a member'
			);
		final t: MemberTarget = target;
		if (t.memberName == newName) return Err('rename "${t.memberName}" -> "$newName" is a no-op');
		if (t.memberName == 'new') return Err('cannot rename a constructor');
		if (t.isOverride)
			return Err('member "${t.memberName}" is an override — rename the base declaration instead (its overrides rename with it)');
		// Refuses a name occupied only by another conditional branch too — deliberately; see
		// `MemberBranchScan.declaresMemberNamed` for why that is not relaxed.
		if (MemberBranchScan.declaresMemberNamed(t.srcDecl, refShape, cursorSource, newName))
			return Err('type "${t.typeName}" already declares a member "$newName"');
		if (RefactorSupport.casePatternCaptures(cursorTree, refShape).contains(t.memberName))
			return Err('cannot rename "${t.memberName}": a case-pattern capture in $cursorFile shares its name (would be mis-rewritten)');

		final parse: ScopeParse = parseScopeFiles(scopeFiles, plugin);
		if (parse.error != null) return Err(parse.error);

		final uniqueErr: Null<String> = checkTypeUniqueness(parse.parsed, cursorFile, t.typeName);
		if (uniqueErr != null) return Err(uniqueErr);
		// The overrides the refusal above promises rename with the base. Built over THIS scope's own
		// in-memory sources, so the op stays pure - no disk, and the index sees exactly what the caller
		// passed. `null` means one same-named declaration's relation to the owner is unprovable: half a
		// family leaves a declaration overriding nothing, so the whole rename is refused.
		final index: SymbolIndex = SymbolIndex.build(scopeFiles, plugin);
		// The `isOverride` refusal above reads the OVERRIDE modifier, which an implementation of an
		// `abstract` method or an interface method never carries - and `overrideFamilyOf` models the
		// family from the BASE down, so neither sees a cursor sitting on such an implementation. Ask
		// the index the upward question directly, or the rename leaves the base declaring a member
		// nothing implements.
		final ancestor: Null<String> = index.declaringAncestorOf(t.typeName, t.memberName);
		if (ancestor != null)
			return Err(
				'member "${t.memberName}" implements a declaration on "$ancestor" — rename that one instead (its implementations rename with it)'
			);
		final family: Null<Array<OverrideFamilyMember>> = index.overrideFamilyOf(t.typeName, t.memberName);
		if (family == null)
			return Err('cannot rename "${t.memberName}": another type declares it and cannot be proven unrelated to "${t.typeName}"');
		final overrides: Array<OverrideFamilyMember> = family;
		// The member's own declarations come next: a `#if` region can declare it once per branch, and
		// each branch is a separate declaration the edit set must carry. The cursor's own declaration
		// is re-listed among them - harmless, since `apply` dedups the resulting offsets.
		for (own in index.declarationsOf(t.typeName, t.memberName)) overrides.push(own);
		// The destination name must be free on every type the edit set touches, not only the cursor's -
		// an override renamed onto a name its own type already declares is a duplicate field.
		for (fm in overrides) if (index.typeDeclaresMember(fm.typeName, newName))
			return Err('type "${fm.typeName}" already declares a member "$newName"');
		// The declaring MODULE. A qualified static access names the owning type THROUGH its module
		// path, so the receiver match needs that path — matching the receiver's last segment instead
		// rewrites `other.Mod.T.MEMBER` for a rename of `pkg.Mod.T.MEMBER`.
		final module: ModulePath = ModuleScan.moduleOf(cursorTree, cursorFile);
		return apply(parse.parsed, cursorFile, t, newName, cursor, plugin, refShape, overrides, index, module);
	}

	/**
	 * Whether the cursor sits on a member declaration this op can rename. The CLI asks it to route an
	 * IN-FILE rename to the member namespace instead of the value one — `Rename` indexes value
	 * bindings and is blind to `obj.member` by design, so it rewrote the declaration and left every
	 * access through a receiver behind. Predicate and op call ONE resolver, so the two cannot diverge.
	 */
	public static function isMemberDeclAtCursor(tree: QueryNode, cursor: Int, source: String, refShape: RefShape): Bool {
		return resolveMemberAtCursor(tree, cursor, source, refShape) != null;
	}

	/**
	 * Resolve the cursor to the member declaration it sits on — a field
	 * or method that is a DIRECT child of a type declaration whose name
	 * token contains the cursor (or whose span starts at it). Returns the
	 * declaring type name, the member name, its static / override flags,
	 * and the enclosing type decl. Null when the cursor is not on a member
	 * declaration (a local function nested in a body is never a direct
	 * type child, so it is excluded).
	 */
	private static function resolveMemberAtCursor(tree: QueryNode, cursor: Int, source: String, refShape: RefShape): Null<MemberTarget> {
		var best: Null<MemberTarget> = null;
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null) {
				final decl: TypeDeclMatch = m;
				// A `#if` region is a member HOST, not a member: it projects as ONE node holding each
				// branch's members with their own modifier siblings. Scanning the type's direct children
				// alone left every guarded member unresolvable here, and the CLI then fell back to the
				// value namespace — which rewrites the declaration and leaves `obj.member` behind.
				RefactorSupport.eachMemberHost(decl.nameNode, host -> {
					final siblings: Array<QueryNode> = host.children;
					for (i => child in siblings) {
						final span: Null<Span> = child.span;
						if (span == null) continue;
						final kind: String = child.kind;
						if (!RefactorSupport.isFieldMemberKind(kind) && !RefactorSupport.FN_DECL_KINDS.contains(kind)) continue;
						final name: Null<String> = child.name;
						if (name == null) continue;
						final childNN: QueryNode = child;
						final spanNN: Span = span;
						if (!RefactorSupport.identTokenContains(childNN, cursor, source) && spanNN.from != cursor) continue;
						final groupSpan: Span = RefactorSupport.declGroupSpan(childNN, host, spanNN);
						var isStatic: Bool = RefactorSupport.implicitlyStaticMember(decl.kind, kind, refShape);
						var isOverride: Bool = false;
						for (j in 0...i) {
							final s: Null<Span> = siblings[j].span;
							if (!(s != null && s.from >= groupSpan.from && s.to <= spanNN.from)) continue;
							if (siblings[j].kind == 'Static') isStatic = true;
							if (siblings[j].kind == 'Override') isOverride = true;
						}
						best = {
							typeName: decl.name,
							memberName: name,
							isStatic: isStatic,
							isOverride: isOverride,
							srcDecl: decl
						};
					}
				});
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * Parse every scope file once; a file that does not parse is turned
	 * into a refusal so the rename stays atomic. Mirrors `CrossRename`.
	 */
	private static function parseScopeFiles(scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin): ScopeParse {
		final parsed: Array<ParsedFile> = [];
		final skipped: Array<String> = [];
		for (entry in scopeFiles) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (exception: ParseError) null
			catch (exception: Exception) null;
			if (tree == null) {
				skipped.push(entry.file);
			} else {
				final parsedTree: QueryNode = tree;
				parsed.push({ file: entry.file, source: entry.source, tree: parsedTree });
			}
		}
		final error: Null<String> = skipped.length > 0
			? 'cannot rename across scope: ${skipped.length} file(s) do not parse: ${skipped.join(', ')}'
			: null;
		return { parsed: parsed, error: error };
	}

	/**
	 * Prove exactly one declaration of `typeName` exists under scope and
	 * that it is the one in `cursorFile` — a second same-named type would
	 * make the simple-name receiver match ambiguous. Returns the refusal
	 * diagnostic or null.
	 */
	private static function checkTypeUniqueness(parsed: Array<ParsedFile>, cursorFile: String, typeName: String): Null<String> {
		var declCount: Int = 0;
		var declInCursorFile: Bool = false;
		for (entry in parsed) {
			final n: Int = countTypeDecls(entry.tree, typeName);
			declCount += n;
			if (n > 0 && entry.file == cursorFile) declInCursorFile = true;
		}
		return if (declCount == 0)
			'no type "$typeName" declared under scope'
		else if (declCount > 1)
			'type "$typeName" is declared in $declCount files under scope — ambiguous, refusing'
		else if (!declInCursorFile)
			'the type "$typeName" at the cursor is not the one declared under scope — refusing'
		else
			null;
	}

	/**
	 * Count type-declaration nodes named `typeName` (final-aware).
	 */
	private static function countTypeDecls(tree: QueryNode, typeName: String): Int {
		var count: Int = 0;
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/**
	 * Collect the member's occurrences in each file, rewrite them to
	 * `newName`, and re-parse before any change is returned (atomicity).
	 * The declaring file adds the single-file occurrence set
	 * (`Rename.renameOccurrences`); every file adds the qualified accesses.
	 */
	private static function apply(
		parsed: Array<ParsedFile>, cursorFile: String, target: MemberTarget, newName: String, cursor: Int, plugin: GrammarPlugin,
		refShape: RefShape, family: Array<OverrideFamilyMember>, index: SymbolIndex, module: ModulePath
	): CrossRenameResult {
		final changes: Array<FileChange> = [];
		for (entry in parsed) {
			final offsets: Array<Int> = [];
			final seen: Array<Int> = [];
			inline function addOff(off: Int): Void if (off >= 0 && !seen.contains(off)) {
				seen.push(off);
				offsets.push(off);
			}
			final resolved: Array<Span> = entry.file == cursorFile
				? Rename.renameOccurrences(entry.source, entry.tree, cursor, refShape)
				: [];
			for (occ in resolved) addOff(occ.from);
			// An override declared in this file: its own declaration plus the bare / `this.` reads its
			// type makes of it, resolved by the same machinery the cursor file uses. Renaming the base
			// without these leaves `override function <old>` overriding nothing.
			for (fm in family) if (fm.file == entry.file)
				for (occ in Rename.renameOccurrences(entry.source, entry.tree, fm.declFrom, refShape)) addOff(occ.from);
			final qualified: LocatedOffsets = qualifiedMemberOffsets(entry.source, entry.tree, target, plugin, refShape, index, module);
			if (qualified.error != null) return Err('${entry.file}: ${qualified.error}');
			for (off in qualified.offsets) addOff(off);
			for (off in patternConstantOffsets(entry.source, entry.tree, target, plugin, refShape, index)) addOff(off);
			if (offsets.length == 0) continue;

			final edits: Array<{ span: Span, text: String }> = [
				for (off in offsets) { span: new Span(off, off + target.memberName.length), text: newName }
			];
			final newSource: String = RefactorSupport.applyEdits(entry.source, edits);

			final newTree: QueryNode = try plugin.parseFile(newSource) catch (exception: ParseError) return Err(
				'rewritten ${entry.file} does not parse: ${exception.toString()}'
			)
			catch (exception: Exception) return Err('rewritten ${entry.file} does not parse: ${exception.message}');

			final capture: Null<String> = Rename.captureDiagnostic(
				newSource, newTree, [for (edit in edits) edit.span], resolved, newName, cursor, refShape
			);
			if (capture != null) return Err('${entry.file}: $capture');

			changes.push({ file: entry.file, newSource: newSource, count: offsets.length });
		}
		return changes.length == 0 ? Err('rename "${target.memberName}" -> "$newName" changed nothing') : Ok(changes, ADVISORY);
	}

	/**
	 * The member-name-token offsets of every QUALIFIED access of `target`
	 * in one file: `Src.member` for a static member, `obj.member` (with
	 * `obj` typed as the source type) for an instance member. A PROVEN
	 * access whose member token cannot be located refuses the whole rename
	 * through the returned `error`.
	 */
	private static function qualifiedMemberOffsets(
		source: String, tree: QueryNode, target: MemberTarget, plugin: GrammarPlugin, refShape: RefShape, index: SymbolIndex,
		module: ModulePath
	): LocatedOffsets {
		return target.isStatic
			? staticMemberOffsets(source, tree, target.typeName, target.memberName, refShape, module)
			: instanceMemberOffsets(source, tree, target.typeName, target.memberName, plugin, refShape, index);
	}

	/**
	 * Static member: the `member`-token offset of every `Src.member` /
	 * `pkg.Src.member` whose receiver is the type used as a namespace. A
	 * receiver ident shadowed by an in-file value binding is excluded
	 * (mirrors `MoveMember.qualifiedReceiverOffsets`). The member token is
	 * located AFTER the receiver span, and only in code, so neither a
	 * receiver containing the member name as a substring nor a comment
	 * sitting between the two is ever mistaken for it.
	 */
	private static function staticMemberOffsets(
		source: String, tree: QueryNode, typeName: String, memberName: String, refShape: RefShape, module: ModulePath
	): LocatedOffsets {
		final valueResolved: Array<Int> = [
			for (h in Refs.find(typeName, tree, refShape))
				if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.bindingSpan != null) h.span.from
		];
		// Which DOTTED receivers legally name this type from THIS file — the whole path, not its last
		// segment: `Boxes` is a module name dozens of packages may each declare.
		final qualified: Array<String> = RefactorSupport.qualifiedPaths(typeName, module, ModuleScan.packageOf(tree));
		final out: Array<Int> = [];
		var error: Null<String> = null;
		function walk(node: QueryNode): Void {
			final children: Array<QueryNode> = node.children;
			if (error == null && node.kind == 'FieldAccess' && node.name == memberName && children.length > 0) {
				final recv: QueryNode = children[0];
				final recvSpan: Null<Span> = recv.span;
				final faSpan: Null<Span> = node.span;
				if (
					recvSpan != null && faSpan != null && RefactorSupport.receiverIsTypeNamespace(recv, typeName, qualified, valueResolved)
				) {
					final off: Int = RefactorSupport.activeCodeIdentTokenOffset(source, new Span(recvSpan.to, faSpan.to), memberName);
					if (off < 0)
						error = unlocatableAccess(source, faSpan, memberName);
					else if (!out.contains(off))
						out.push(off);
				}
			}
			for (c in children) walk(c);
		}
		walk(tree);
		return error == null ? { offsets: out, error: null } : { offsets: [], error: error };
	}

	/**
	 * Instance member: the `member`-token offset of every `obj.member`
	 * whose receiver `obj` is an identifier resolving (scope binding +
	 * `TypeInfoProvider.declaredTypes`) to a declaration of the source
	 * type. `this` / `super` receivers are skipped — the declaring-file
	 * `Rename.renameOccurrences` pass covers `this.member`, and `super`
	 * targets a base member. A receiver whose type does not resolve is
	 * left alone (advisory / loud-fail); a receiver that DOES resolve but
	 * whose member token cannot be located refuses the whole rename.
	 */
	private static function instanceMemberOffsets(
		source: String, tree: QueryNode, typeName: String, memberName: String, plugin: GrammarPlugin, refShape: RefShape,
		index: SymbolIndex
	): LocatedOffsets {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final declared: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];
		final candidates: Array<{ recv: QueryNode, fa: QueryNode }> = memberAccessCandidates(tree, memberName);
		if (candidates.length == 0) return { offsets: [], error: null };

		final recvNames: Array<String> = [];
		for (cand in candidates) {
			final rn: Null<String> = cand.recv.name;
			if (rn != null && !recvNames.contains(rn)) recvNames.push(rn);
		}
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti(recvNames, tree, refShape);
		final out: Array<Int> = [];
		for (cand in candidates) {
			final recvSpan: Null<Span> = cand.recv.span;
			final faSpan: Null<Span> = cand.fa.span;
			if (recvSpan == null || faSpan == null || !receiverIsSourceType(cand.recv, typeName, declared, hitsByName, index)) continue;
			final off: Int = RefactorSupport.activeCodeIdentTokenOffset(source, new Span(recvSpan.to, faSpan.to), memberName);
			if (off < 0) return { offsets: [], error: unlocatableAccess(source, faSpan, memberName) };
			if (!out.contains(off)) out.push(off);
		}
		return { offsets: out, error: null };
	}

	/**
	 * The binding-span `from` of the read / write hit at `recvFrom`, or
	 * null when the receiver is unresolved (cross-file / implicit).
	 */
	private static function receiverBinding(hits: Array<RefHit>, recvFrom: Int): Null<Int> {
		for (h in hits) if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.span.from == recvFrom) {
			final b: Null<Span> = h.bindingSpan;
			return b?.from;
		}
		return null;
	}

	/**
	 * Every `X.member` field access whose receiver is a plain identifier
	 * (not `this` / `super`) — the candidate instance accesses whose
	 * receiver type `instanceMemberOffsets` then resolves.
	 */
	private static function memberAccessCandidates(tree: QueryNode, memberName: String): Array<{ recv: QueryNode, fa: QueryNode }> {
		final out: Array<{ recv: QueryNode, fa: QueryNode }> = [];
		function collect(node: QueryNode): Void {
			final children: Array<QueryNode> = node.children;
			if (node.kind == 'FieldAccess' && node.name == memberName && children.length > 0) {
				final recv: QueryNode = children[0];
				final rn: Null<String> = recv.name;
				// A `new T()` receiver carries its type in its own name, so it is a candidate even though it
				// binds nothing - see `receiverIsSourceType`. Without it `new Other().tag()` was never even
				// offered for resolution and the access silently kept the old name.
				final named: Bool = recv.kind == 'IdentExpr' && rn != 'this' && rn != 'super';
				if (rn != null && (named || recv.kind == 'NewExpr')) out.push({ recv: recv, fa: node });
			}
			for (c in children) collect(c);
		}
		collect(tree);
		return out;
	}

	/**
	 * Does `recv` resolve (scope binding + `declared` types) to a
	 * declaration of the source type? Only a receiver this proves is
	 * rewritten; an unresolved one is left alone (advisory / loud-fail).
	 */
	private static function receiverIsSourceType(
		recv: QueryNode, typeName: String, declared: Map<Int, String>, hitsByName: Map<String, Array<RefHit>>, index: SymbolIndex
	): Bool {
		final rn: Null<String> = recv.name;
		final recvSpan: Null<Span> = recv.span;
		if (rn == null || recvSpan == null) return false;
		// A constructor call names the type it builds, so `new Other().tag()` needs no binding at all.
		// Demanding one skipped the site SILENTLY: the declaration was renamed and the access left on
		// the old name, which is a rewrite that does not compile.
		if (recv.kind == 'NewExpr') return rn == typeName || index.isSubtype(rn, typeName);
		final bindingFrom: Null<Int> = receiverBinding(hitsByName[rn] ?? [], recvSpan.from);
		if (bindingFrom == null) return false;
		final from: Int = bindingFrom;
		final declaredType: Null<String> = declared[from];
		if (declaredType == null) return false;
		// A receiver typed as a proven SUBTYPE reaches the same member - whether the subtype overrides it
		// (renamed with the base) or merely inherits it. Requiring an exact type match left every such
		// access spelled the old way, which for an override family is a rename that does not compile.
		final recvType: String = declaredType;
		return recvType == typeName || index.isSubtype(recvType, typeName);
	}

	/**
	 * The refusal diagnostic for a PROVEN access whose member token could
	 * not be located in code — a comment occupied the window instead.
	 * Refusing keeps the rename COMPLETE: renaming the rest would leave the
	 * project uncompilable while the op reported success.
	 */
	private static function unlocatableAccess(source: String, faSpan: Span, memberName: String): String {
		final at: Position = faSpan.lineCol(source);
		return 'cannot locate the "$memberName" token of the proven access at ${at.line}:${at.col}'
			+ ' - refusing rather than renaming part of the scope';
	}


	/**
	 * Every switch in `tree` that spells `memberName` BARE in at least one case pattern,
	 * paired with that switch's SUBJECT and the offsets of those pattern tokens. A nested
	 * switch owns its own branches — the branch walk stops at one, and the outer walk reaches
	 * it as a candidate of its own.
	 */
	private static function switchPatternCandidates(
		tree: QueryNode, memberName: String, refShape: RefShape
	): Array<{ subject: QueryNode, offsets: Array<Int> }> {
		final out: Array<{ subject: QueryNode, offsets: Array<Int> }> = [];
		final switchKinds: Null<Array<String>> = refShape.switchKinds;
		final caseBranchKind: Null<String> = refShape.caseBranchKind;
		if (switchKinds == null || caseBranchKind == null) return out;
		final kinds: Array<String> = switchKinds;
		final branchKind: String = caseBranchKind;
		final identKind: String = refShape.identKind;
		function patternHits(node: QueryNode, hits: Array<Int>): Void {
			final span: Null<Span> = node.span;
			if (node.kind == identKind && node.name == memberName && span != null) hits.push(span.from);
			for (c in node.children) patternHits(c, hits);
		}
		function branchesOf(node: QueryNode, hits: Array<Int>, isRoot: Bool): Void {
			if (!isRoot && kinds.contains(node.kind)) return;
			if (node.kind == branchKind && node.children.length > 0) patternHits(node.children[0], hits);
			for (c in node.children) branchesOf(c, hits, false);
		}
		function collect(node: QueryNode): Void {
			if (kinds.contains(node.kind) && node.children.length > 0) {
				final hits: Array<Int> = [];
				branchesOf(node, hits, true);
				if (hits.length > 0) out.push({ subject: node.children[0], offsets: hits });
			}
			for (c in node.children) collect(c);
		}
		collect(tree);
		return out;
	}

	/**
	 * The member-token offset of every BARE `case <member>:` pattern in one file whose switch
	 * subject is PROVEN to hold a value of the source type. Unqualified, an `enum abstract`
	 * value spelled in a pattern is a reference to the member and never a capture (see
	 * `RefactorSupport.casePatternCaptures`), so renaming the declaration without these
	 * leaves patterns naming a constant that no longer exists — a rewrite that does not
	 * compile, reported as success.
	 *
	 * The subject is proven exactly as an instance receiver is (`receiverIsSourceType`): an
	 * identifier bound to a declaration written of the source type, or of a proven subtype.
	 * A subject whose type does not resolve is left alone — the same loud-fail contract the
	 * unresolved receivers carry, restated in the advisory.
	 */
	private static function patternConstantOffsets(
		source: String, tree: QueryNode, target: MemberTarget, plugin: GrammarPlugin, refShape: RefShape, index: SymbolIndex
	): Array<Int> {
		final candidates: Array<{ subject: QueryNode, offsets: Array<Int> }> = switchPatternCandidates(tree, target.memberName, refShape);
		if (candidates.length == 0) return [];
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final declared: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];
		final subjectNames: Array<String> = [];
		for (candidate in candidates) {
			final name: Null<String> = candidate.subject.name;
			if (name != null && !subjectNames.contains(name)) subjectNames.push(name);
		}
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti(subjectNames, tree, refShape);
		final out: Array<Int> = [];
		for (candidate in candidates) if (receiverIsSourceType(candidate.subject, target.typeName, declared, hitsByName, index))
			for (off in candidate.offsets) if (!out.contains(off)) out.push(off);
		return out;
	}

}

/**
 * The result of parsing the scope: the parsed files, plus a non-null
 * `error` diagnostic when any file skip-parsed (the rename is refused).
 */
private typedef ScopeParse = {
	final parsed: Array<ParsedFile>;
	final error: Null<String>;
};
