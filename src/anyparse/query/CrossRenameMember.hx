package anyparse.query;

import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
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
 *  - STATIC members: every qualified access `Src.member` /
 *    `pkg.Src.member` across the scope whose receiver is the type used as
 *    a namespace (a receiver shadowed by a value binding of the same name
 *    is excluded, mirroring `CrossRename` / `MoveMember`).
 *  - INSTANCE members: every `obj.member` whose receiver `obj` resolves
 *    (through the scope resolver + `TypeInfoProvider.declaredTypes`) to a
 *    local / parameter / field DECLARED of the source type. A receiver
 *    whose type does not resolve is left alone — if it really was the
 *    source type the miss surfaces as a compile error, never a wrong
 *    rewrite.
 *
 * ## Refusals (correctness boundary)
 *
 *  - The declaring type must be UNIQUE under the scope (a second type of
 *    the same name would make the simple-name receiver match ambiguous).
 *  - An `override` member is refused — it belongs to a base declaration;
 *    renaming it alone would dangle the override AND miss the base.
 *  - A member whose name is also captured by a `case` pattern in the
 *    declaring file is refused: sibling case-branch captures flatten into
 *    one scope frame, so the resolver can mis-attribute a bare reference
 *    (see the `MoveMember` case-capture guard).
 *  - The destination name already declared on the type, a constructor
 *    (`new`), an unparseable scope file, or a post-rewrite parse failure
 *    are all refused; the write is atomic (all files or none).
 *
 * ## Documented residual (loud-fail, not silent)
 *
 * Unresolved instance receivers (chained calls, un-annotated locals,
 * casts), `super`-access, `using`-extension call sites, aliased-import
 * homonyms, and overrides declared OUTSIDE the scope are not rewritten —
 * each dangles into a compile error the user can see. The advisory
 * (always non-null on success) reminds them.
 *
 * Coordinate convention: `line` / `col` are 1-based, exactly as
 * `apq refs` prints them — identical to `Rename` / `CrossRename`.
 */
@:nullSafety(Strict)
final class CrossRenameMember {

	/** The advisory appended to every successful member rename. */
	private static final ADVISORY: String = 'member rename resolves instance receivers via declared types only — unresolved receivers (chained calls, un-annotated locals, casts), super-access, `using` extension calls, aliased-import homonyms, and overrides declared outside this scope are left as loud compile errors; verify by hand.';

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
		final target: Null<MemberTarget> = resolveMemberAtCursor(cursorTree, cursor, cursorSource);
		if (target == null)
			return Err(
				'position $line:$col is not on a member declaration (field / method) — cross-file --scope renames a type or a member'
			);
		final t: MemberTarget = target;
		if (t.memberName == newName) return Err('rename "${t.memberName}" -> "$newName" is a no-op');
		if (t.memberName == 'new') return Err('cannot rename a constructor');
		if (t.isOverride)
			return Err('member "${t.memberName}" is an override — rename the base declaration instead (its overrides rename with it)');
		if (memberExists(t.srcDecl, newName)) return Err('type "${t.typeName}" already declares a member "$newName"');
		if (casePatternCaptures(cursorTree).contains(t.memberName))
			return Err('cannot rename "${t.memberName}": a case-pattern capture in $cursorFile shares its name (would be mis-rewritten)');

		final parse: ScopeParse = parseScopeFiles(scopeFiles, plugin);
		if (parse.error != null) return Err(parse.error);

		final uniqueErr: Null<String> = checkTypeUniqueness(parse.parsed, cursorFile, t.typeName);
		return uniqueErr != null ? Err(uniqueErr) : apply(parse.parsed, cursorFile, t, newName, cursor, plugin, refShape);
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
	private static function resolveMemberAtCursor(tree: QueryNode, cursor: Int, source: String): Null<MemberTarget> {
		var best: Null<MemberTarget> = null;
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null) {
				final decl: TypeDeclMatch = m;
				final siblings: Array<QueryNode> = decl.nameNode.children;
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
					final groupSpan: Span = RefactorSupport.declGroupSpan(childNN, decl.nameNode, spanNN);
					var isStatic: Bool = false;
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
			}
			for (c in node.children) walk(c);
		}
		walk(tree);
		return best;
	}

	/**
	 * Does `decl` already declare a field / method named `name`? Drives the
	 * destination-name collision refusal.
	 */
	private static function memberExists(decl: TypeDeclMatch, name: String): Bool {
		for (child in decl.nameNode.children) {
			final kind: String = child.kind;
			if ((RefactorSupport.isFieldMemberKind(kind) || RefactorSupport.FN_DECL_KINDS.contains(kind)) && child.name == name)
				return true;
		}
		return false;
	}

	/**
	 * Every identifier captured by a `case` pattern anywhere in `tree` —
	 * the pattern wrapper is `CaseBranch.children[0]`. Sibling case-branch
	 * captures flatten into one scope frame, so a capture sharing the
	 * member name would be mis-attributed by the resolver; the op refuses
	 * when the member name is in this set. Mirrors `MoveMember`.
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
		return declCount == 0
			? 'no type "$typeName" declared under scope'
			: declCount > 1
				? 'type "$typeName" is declared in $declCount files under scope — ambiguous, refusing'
				: !declInCursorFile ? 'the type "$typeName" at the cursor is not the one declared under scope — refusing' : null;
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
		refShape: RefShape
	): CrossRenameResult {
		final changes: Array<FileChange> = [];
		for (entry in parsed) {
			final offsets: Array<Int> = [];
			final seen: Array<Int> = [];
			inline function addOff(off: Int): Void if (off >= 0 && !seen.contains(off)) {
				seen.push(off);
				offsets.push(off);
			}
			if (entry.file == cursorFile) for (occ in Rename.renameOccurrences(entry.source, entry.tree, cursor, refShape))
				addOff(occ.from);
			for (off in qualifiedMemberOffsets(entry.source, entry.tree, target, plugin, refShape)) addOff(off);
			if (offsets.length == 0) continue;

			final edits: Array<{ span: Span, text: String }> = [
				for (off in offsets) { span: new Span(off, off + target.memberName.length), text: newName }
			];
			final newSource: String = RefactorSupport.applyEdits(entry.source, edits);

			try
				plugin.parseFile(newSource)
			catch (exception: ParseError)
				return Err('rewritten ${entry.file} does not parse: ${exception.toString()}')
			catch (exception: Exception)
				return Err('rewritten ${entry.file} does not parse: ${exception.message}');

			changes.push({ file: entry.file, newSource: newSource, count: offsets.length });
		}
		return changes.length == 0 ? Err('rename "${target.memberName}" -> "$newName" changed nothing') : Ok(changes, ADVISORY);
	}

	/**
	 * The member-name-token offsets of every QUALIFIED access of `target`
	 * in one file: `Src.member` for a static member, `obj.member` (with
	 * `obj` typed as the source type) for an instance member.
	 */
	private static function qualifiedMemberOffsets(
		source: String, tree: QueryNode, target: MemberTarget, plugin: GrammarPlugin, refShape: RefShape
	): Array<Int> {
		return target.isStatic
			? staticMemberOffsets(source, tree, target.typeName, target.memberName, refShape)
			: instanceMemberOffsets(source, tree, target.typeName, target.memberName, plugin, refShape);
	}

	/**
	 * Static member: the `member`-token offset of every `Src.member` /
	 * `pkg.Src.member` whose receiver is the type used as a namespace. A
	 * receiver ident shadowed by an in-file value binding is excluded
	 * (mirrors `MoveMember.qualifiedReceiverOffsets`). The member token is
	 * located AFTER the receiver span so a receiver that contains the
	 * member name as a substring is never mistaken for it.
	 */
	private static function staticMemberOffsets(
		source: String, tree: QueryNode, typeName: String, memberName: String, refShape: RefShape
	): Array<Int> {
		final valueResolved: Array<Int> = [
			for (h in Refs.find(typeName, tree, refShape))
				if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.bindingSpan != null) h.span.from
		];
		final out: Array<Int> = [];
		function walk(node: QueryNode): Void {
			final children: Array<QueryNode> = node.children;
			if (node.kind == 'FieldAccess' && node.name == memberName && children.length > 0) {
				final recv: QueryNode = children[0];
				final recvSpan: Null<Span> = recv.span;
				final faSpan: Null<Span> = node.span;
				if (recvSpan != null && faSpan != null) {
					final isNamespace: Bool = (recv.kind == 'IdentExpr' && recv.name == typeName && !valueResolved.contains(recvSpan.from))
						|| (recv.kind == 'FieldAccess' && recv.name == typeName);
					if (isNamespace) {
						final off: Int = RefactorSupport.identTokenOffset(source, new Span(recvSpan.to, faSpan.to), memberName);
						if (off >= 0 && !out.contains(off)) out.push(off);
					}
				}
			}
			for (c in children) walk(c);
		}
		walk(tree);
		return out;
	}

	/**
	 * Instance member: the `member`-token offset of every `obj.member`
	 * whose receiver `obj` is an identifier resolving (scope binding +
	 * `TypeInfoProvider.declaredTypes`) to a declaration of the source
	 * type. `this` / `super` receivers are skipped — the declaring-file
	 * `Rename.renameOccurrences` pass covers `this.member`, and `super`
	 * targets a base member. A receiver whose type does not resolve is
	 * left alone (advisory / loud-fail).
	 */
	private static function instanceMemberOffsets(
		source: String, tree: QueryNode, typeName: String, memberName: String, plugin: GrammarPlugin, refShape: RefShape
	): Array<Int> {
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final declared: Map<Int, String> = provider != null ? provider.declaredTypes(source) : [];
		final candidates: Array<{ recv: QueryNode, fa: QueryNode }> = memberAccessCandidates(tree, memberName);
		if (candidates.length == 0) return [];

		final recvNames: Array<String> = [];
		for (cand in candidates) {
			final rn: Null<String> = cand.recv.name;
			if (rn != null && !recvNames.contains(rn)) recvNames.push(rn);
		}
		final hitsByName: Map<String, Array<RefHit>> = Refs.findMulti(recvNames, tree, refShape);
		final out: Array<Int> = [];
		for (cand in candidates) {
			final off: Int = resolvedMemberOffset(source, cand, typeName, memberName, declared, hitsByName);
			if (off >= 0 && !out.contains(off)) out.push(off);
		}
		return out;
	}

	/**
	 * The binding-span `from` of the read / write hit at `recvFrom`, or
	 * null when the receiver is unresolved (cross-file / implicit).
	 */
	private static function receiverBinding(hits: Array<RefHit>, recvFrom: Int): Null<Int> {
		for (h in hits) if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.span.from == recvFrom) {
			final b: Null<Span> = h.bindingSpan;
			return b == null ? null : b.from;
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
				if (recv.kind == 'IdentExpr' && rn != null && rn != 'this' && rn != 'super') out.push({ recv: recv, fa: node });
			}
			for (c in children) collect(c);
		}
		collect(tree);
		return out;
	}

	/**
	 * The `member`-token offset of one candidate `obj.member` when `obj`
	 * resolves (scope binding + `declared` types) to the source type, else
	 * -1. The token is located AFTER the receiver span so a receiver that
	 * contains the member name as a substring is never mistaken for it.
	 */
	private static function resolvedMemberOffset(
		source: String, cand: { recv: QueryNode, fa: QueryNode }, typeName: String, memberName: String, declared: Map<Int, String>,
		hitsByName: Map<String, Array<RefHit>>
	): Int {
		final recv: QueryNode = cand.recv;
		final rn: Null<String> = recv.name;
		final recvSpan: Null<Span> = recv.span;
		final faSpan: Null<Span> = cand.fa.span;
		if (rn == null || recvSpan == null || faSpan == null) return -1;
		final bindingFrom: Null<Int> = receiverBinding(hitsByName[rn] ?? [], recvSpan.from);
		if (bindingFrom == null || declared[bindingFrom] != typeName) return -1;
		return RefactorSupport.identTokenOffset(source, new Span(recvSpan.to, faSpan.to), memberName);
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
