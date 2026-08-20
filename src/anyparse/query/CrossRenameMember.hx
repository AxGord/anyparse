package anyparse.query;

import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRename.FileChange;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.ModulePath;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.OverrideFamilyMember;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;
using Lambda;

/**
 * One resolved member the cursor sits on: its declaring type name, the
 * member name, whether it is `static` / `override`, whether it is a value
 * of an `enum abstract` (the one member class Haxe resolves from the
 * EXPECTED type), and the enclosing type declaration (for the same-type
 * name-collision check).
 */
private typedef MemberTarget = {
	var typeName: String;
	var memberName: String;
	var isStatic: Bool;
	var isOverride: Bool;
	var isEnumValue: Bool;
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
 * Everything one file's receiver / switch-subject proof needs, threaded as one value the way
 * `ReturnScan` carries the return-position scan. `nominals` and `typeSources` are the two halves
 * of a declared type and are BOTH read: the AST decides whether an annotation is nominal at all,
 * the source text carries the path the AST's simple name drops.
 */
private typedef ReceiverProof = {
	final typeName: String;
	final nominals: Map<Int, String>;
	final typeSources: Map<Int, String>;
	final hitsByName: Map<String, Array<RefHit>>;
	final index: SymbolIndex;
	final file: String;
	final cursorFile: String;
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
 *  - An `enum abstract` VALUE spelled BARE in RETURN position, which Haxe resolves from the
 *    EXPECTED type — proven by the enclosing function's DECLARED return type resolved from
 *    the reading file, and reached through the type-TRANSPARENT slots under a `return`. See
 *    `expectedReturnOffsets` for the whole proof and its residual.
 *  - INSTANCE members: every `obj.member` whose receiver `obj` resolves (through
 *    the scope resolver + `TypeInfoProvider.declaredTypeSources`) to a local /
 *    parameter / field whose WRITTEN annotation names the source type, resolved
 *    from the reading file by the compiler's own rules — so a same-named
 *    `other.Other` of another package is NOT it and a qualified `pkg.Other` is.
 *    A receiver whose type does not resolve is left alone — if it really was the
 *    source type the miss surfaces as a compile error, never a wrong rewrite. A
 *    `new T()` receiver names its type itself and needs no binding at all; that
 *    name is the whole written path, so it resolves the same way.
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
 * An `enum abstract` value the compiler resolves from the EXPECTED TYPE renames in RETURN
 * position only (`expectedReturnOffsets`). The expected-type sites still NOT proven, each
 * measured on this repo: an `x == VALUE` comparison, an annotated assignment, an argument in
 * a typed parameter slot, a function with NO return annotation, and the value slots the
 * descent does not model (a block expression's last statement, a `try` expression).
 *
 * A leftover is USUALLY loud, but calling it always loud would be wrong: `import pkg.Other;`
 * of a second enum abstract brings ITS same-named value into simple-name scope, so an
 * un-annotated `function f() return Seam;` silently returns the OTHER abstract's value after
 * the rename instead of failing (verified on 4.3.7). That import path is also the largest
 * un-modelled reference class overall — 453 of the 461 bare return-position sites in this
 * repo are `ExitCode` values read that way inside `: Int` functions, which no expected type
 * can prove.
 *
 * Coordinate convention: `line` / `col` are 1-based, exactly as
 * `apq refs` prints them — identical to `Rename` / `CrossRename`.
 */
@:nullSafety(Strict)
final class CrossRenameMember {

	/** The advisory appended to every successful member rename. */
	private static final ADVISORY: String = 'member rename resolves instance receivers, switch subjects and expected-type returns via '
		+ 'declared types only — unresolved receivers and subjects ('
		+ 'chained calls, un-annotated locals, casts, a `Null<T>`-wrapped annotation, a type reaching the '
		+ 'file through a per-directory `import.hx`), an expected-type value OUTSIDE return position ('
		+ '`x == VALUE`, an annotated assignment, a typed argument) '
		+ 'or in a function with no return annotation, an enum-abstract value brought into scope by '
		+ 'importing its type, super-access, `using` extension calls, aliased-import homonyms, and '
		+ 'overrides declared outside this scope are left for the compiler to reject; verify by hand.';

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
			'$cursorFile does not parse: $exception'
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
				'member "${t.memberName}" implements a declaration on "$ancestor'
				+ '" — rename that one instead (its implementations rename with it)'
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
		// A member is reachable from any method in any file of the scope, so an unparsed
		// conditional-compilation region ANYWHERE in the scope can hide a qualified access `apply`
		// would then leave on the old name.
		final opaque: Null<String> = RefactorSupport.opaqueCondRegionInAny(
			parse.parsed, t.memberName, refShape, 'rename of "${t.memberName}"'
		);
		return opaque != null
			? Err(opaque)
			: apply(parse.parsed, cursorFile, t, newName, cursor, plugin, refShape, overrides, index, module);
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
						var saysStatic: Bool = false;
						for (j in 0...i) {
							final s: Null<Span> = siblings[j].span;
							if (s == null || s.from < groupSpan.from || s.to > spanNN.from) continue;
							if (siblings[j].kind == 'Static') {
								isStatic = true;
								saysStatic = true;
							}
							if (siblings[j].kind == 'Override') isOverride = true;
						}
						best = {
							typeName: decl.name,
							memberName: name,
							isStatic: isStatic,
							isOverride: isOverride,
							// A VALUE of an `enum abstract` — the exact member class Haxe resolves from the
							// expected type. Measured on 4.3.7, a plain abstract's static is NOT one
							// (`abstract Plain(Int) { public static final PX: Plain; }` with `function f():
							// Plain return PX;` is `Unknown identifier : PX`), so the host kind alone would
							// over-claim and `implicitStaticFieldHostKinds` cannot stand in for it. Neither
							// is an EXPLICIT `static` inside an `enum abstract` — the same probe, one host
							// kind over: `public static final PX: Colour = RED;` is `Identifier 'PX' is not
							// part of Colour`. A value is the member that says no modifier at all.
							isEnumValue: decl.kind == refShape.enumAbstractDeclKind && !saysStatic
							&& RefactorSupport.implicitlyStaticMember(decl.kind, kind, refShape),
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
			final qualified: LocatedOffsets = qualifiedMemberOffsets(
				entry.source, entry.file, entry.tree, target, plugin, refShape, index, module, cursorFile
			);
			if (qualified.error != null) return Err('${entry.file}: ${qualified.error}');
			for (off in qualified.offsets) addOff(off);
			for (off in patternConstantOffsets(entry.source, entry.file, entry.tree, target, plugin, refShape, index, cursorFile))
				addOff(off);
			for (off in expectedReturnOffsets(entry.source, entry.file, entry.tree, target, refShape, index, cursorFile)) addOff(off);
			if (offsets.length == 0) continue;

			final edits: Array<{ span: Span, text: String }> = [
				for (off in offsets) { span: new Span(off, off + target.memberName.length), text: newName }
			];
			final newSource: String = RefactorSupport.applyEdits(entry.source, edits);

			final newTree: QueryNode = try plugin.parseFile(newSource) catch (exception: ParseError) return Err(
				'rewritten ${entry.file} does not parse: $exception'
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
		source: String, file: String, tree: QueryNode, target: MemberTarget, plugin: GrammarPlugin, refShape: RefShape, index: SymbolIndex,
		module: ModulePath, cursorFile: String
	): LocatedOffsets {
		return target.isStatic
			? staticMemberOffsets(source, tree, target.typeName, target.memberName, refShape, module)
			: instanceMemberOffsets(source, file, tree, target, plugin, refShape, index, cursorFile);
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
	 * `TypeInfoProvider.declaredTypeSources`, then `resolvesToSourceType`)
	 * to a declaration of the source type. `this` / `super` receivers are
	 * skipped — the declaring-file
	 * `Rename.renameOccurrences` pass covers `this.member`, and `super`
	 * targets a base member. A receiver whose type does not resolve is
	 * left alone (advisory / loud-fail); a receiver that DOES resolve but
	 * whose member token cannot be located refuses the whole rename.
	 */
	private static function instanceMemberOffsets(
		source: String, file: String, tree: QueryNode, target: MemberTarget, plugin: GrammarPlugin, refShape: RefShape, index: SymbolIndex,
		cursorFile: String
	): LocatedOffsets {
		final memberName: String = target.memberName;
		final candidates: Array<{ recv: QueryNode, fa: QueryNode }> = memberAccessCandidates(tree, memberName);
		if (candidates.length == 0) return { offsets: [], error: null };

		final recvNames: Array<String> = [];
		for (cand in candidates) {
			final rn: Null<String> = cand.recv.name;
			if (rn != null && !recvNames.contains(rn)) recvNames.push(rn);
		}
		final proof: ReceiverProof = receiverProof(recvNames, source, file, tree, target, plugin, refShape, index, cursorFile);
		final out: Array<Int> = [];
		for (cand in candidates) {
			final recvSpan: Null<Span> = cand.recv.span;
			final faSpan: Null<Span> = cand.fa.span;
			if (recvSpan == null || faSpan == null || !receiverIsSourceType(cand.recv, proof)) continue;
			final off: Int = RefactorSupport.activeCodeIdentTokenOffset(source, new Span(recvSpan.to, faSpan.to), memberName);
			if (off < 0) return { offsets: [], error: unlocatableAccess(source, faSpan, memberName) };
			if (!out.contains(off)) out.push(off);
		}
		return { offsets: out, error: null };
	}

	/**
	 * The proof one file's receivers and switch subjects are measured against — the two declared-type
	 * maps, the scope hits for the candidate receiver `names`, and the resolution context. Both
	 * callers need the identical value except for which names they resolved, which is what makes it
	 * one function rather than two literals that must be kept in step.
	 */
	private static function receiverProof(
		names: Array<String>, source: String, file: String, tree: QueryNode, target: MemberTarget, plugin: GrammarPlugin,
		refShape: RefShape, index: SymbolIndex, cursorFile: String
	): ReceiverProof {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		return {
			typeName: target.typeName,
			nominals: provider != null ? provider.declaredTypes(source) : [],
			typeSources: provider != null ? provider.declaredTypeSources(source) : [],
			hitsByName: Refs.findMulti(names, tree, refShape),
			index: index,
			file: file,
			cursorFile: cursorFile
		};
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
	 * Does `recv` resolve — a `new T()` through its own name, an identifier
	 * through its scope binding's WRITTEN annotation — to a declaration of the
	 * source type? Both names go to `resolvesToSourceType`, never to a compare
	 * against the type's simple name. Only a receiver this proves is rewritten;
	 * an unresolved one is left alone (advisory / loud-fail).
	 */
	private static function receiverIsSourceType(recv: QueryNode, proof: ReceiverProof): Bool {
		final rn: Null<String> = recv.name;
		final recvSpan: Null<Span> = recv.span;
		if (rn == null || recvSpan == null) return false;
		// A constructor call names the type it builds, so `new Other().tag()` needs no binding at all.
		// Demanding one skipped the site SILENTLY: the declaration was renamed and the access left on
		// the old name, which is a rewrite that does not compile. The name carries the WHOLE written
		// path (`new pkg.Other()` projects as `NewExpr pkg.Other`), which is why it goes through the
		// same resolution an annotation does instead of being compared to the type's simple name.
		if (recv.kind == 'NewExpr') return resolvesToSourceType(rn, proof);
		final bindingFrom: Null<Int> = receiverBinding(proof.hitsByName[rn] ?? [], recvSpan.from);
		if (bindingFrom == null) return false;
		final from: Int = bindingFrom;
		// The AST decides NOMINALITY, the source text carries the PATH. `declaredTypes` holds a key
		// only where the annotation projects a nominal NAME; `declaredTypeSources` is keyed by every
		// annotation that has a span, a strict SUPERSET whose extra keys are exactly the non-nominal
		// types. Reading the text alone made `pkg.Other<Int> -> Void` — an arrow whose left operand is
		// parameterised — split at its first `<` and pass as the nominal `pkg.Other`.
		if (proof.nominals[from] == null) return false;
		final written: Null<String> = proof.typeSources[from];
		if (written == null) return false;
		return resolvesToSourceType(nominalPathOf(written), proof);
	}

	/**
	 * Does the nominal `path`, read FROM `proof.file`, name the type at the cursor — or a proven
	 * SUBTYPE of it? A subtype receiver reaches the same member whether it overrides it (renamed
	 * with the base) or merely inherits it; requiring an exact match left every such access spelled
	 * the old way, which for an override family is a rename that does not compile.
	 *
	 * The resolver is `SymbolIndex.resolveTypeRefsFrom` — the whole-dotted-path / module-relative /
	 * import / same-package / root-package rules, the same one `expectedReturnOffsets` asks for a
	 * return annotation. It APPROXIMATES the compiler rather than reproducing it, and the residual
	 * list below says in which direction each gap runs. Three deliberate differences from that
	 * sibling proof: it unwraps one nullable wrapper and this does not, it has no subtype arm, and
	 * this one strips type ARGUMENTS off the path while it hands the written text over whole.
	 *
	 * Comparing SIMPLE names instead was wrong in BOTH directions, each measured on 4.3.7: a
	 * receiver written `other.Other` (a same-named module of another package, out of scope) was
	 * rewritten and the tree then failed to compile with `other.Other has no field newTag`, while
	 * `new pkg.Other()` — whose node name is the whole path — matched nothing and left
	 * `pkg.Other has no field tag` behind. That is the last-segment defect the static side removed
	 * twice (`f3b46467`, `64a4ae5a`), on the INSTANCE side.
	 *
	 * Residual, all of them MISSES (a left-behind access is a compile error, never a wrong rewrite):
	 * a reference resolving to nothing proves nothing — a library type, a type outside the scope, an
	 * ALIASED import (the grammar does not expose the original path), a type reaching the file
	 * through a per-directory `import.hx` (`SymbolIndex` reads only a file's own import list), and a
	 * `Null<T>`-wrapped receiver, whose path reduces to `Null`.
	 *
	 * The one arm that can still authorise a rewrite on unproven evidence is the SUBTYPE one:
	 * `isSubtype` walks `TypeDeclInfo.supertypes`, which are SIMPLE names, so a resolved subtype
	 * whose supertype is a same-named type of another package reads as reaching this member.
	 * `supertypesRaw` is what a stricter arm would resolve, the way `overriddenDeclarer` already
	 * does; nothing here does yet.
	 */
	private static function resolvesToSourceType(path: String, proof: ReceiverProof): Bool {
		if (path == '') return false;
		final matches: Array<{ file: FileInfo, type: TypeDeclInfo }> = proof.index.resolveTypeRefsFrom(path, proof.file);
		if (matches.length != 1) return false;
		final resolved: { file: FileInfo, type: TypeDeclInfo } = matches[0];
		return (resolved.type.name == proof.typeName && resolved.file.file == proof.cursorFile)
			|| proof.index.isSubtype(resolved.type.name, proof.typeName);
	}

	/**
	 * `written` reduced to the PATH it names — type ARGUMENTS dropped, the package KEPT:
	 * `pkg.Box<Int>` -> `pkg.Box`. Both halves are load-bearing: resolution needs the whole path,
	 * and it needs the arguments gone, since a generic receiver (`b: Box<Int>`) was already proven
	 * by the simple-name compare and dropping it would be a silent loss.
	 *
	 * Splitting at the first `<` is exact ONLY because the caller has already asked the AST whether
	 * the annotation is nominal at all (`declaredTypes`). Used as the nominality test itself, this
	 * text read accepts an arrow type with a parameterised left operand.
	 */
	private static function nominalPathOf(written: String): String {
		final lt: Int = written.indexOf('<');
		return (lt < 0 ? written : written.substring(0, lt)).trim();
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
		source: String, file: String, tree: QueryNode, target: MemberTarget, plugin: GrammarPlugin, refShape: RefShape, index: SymbolIndex,
		cursorFile: String
	): Array<Int> {
		final candidates: Array<{ subject: QueryNode, offsets: Array<Int> }> = switchPatternCandidates(tree, target.memberName, refShape);
		if (candidates.length == 0) return [];
		final subjectNames: Array<String> = [];
		for (candidate in candidates) {
			final name: Null<String> = candidate.subject.name;
			if (name != null && !subjectNames.contains(name)) subjectNames.push(name);
		}
		final proof: ReceiverProof = receiverProof(subjectNames, source, file, tree, target, plugin, refShape, index, cursorFile);
		final out: Array<Int> = [];
		for (candidate in candidates) if (receiverIsSourceType(candidate.subject, proof)) for (off in candidate.offsets) if (
			!out.contains(off)
		)
			out.push(off);
		return out;
	}

	/**
	 * The member-token offset of every BARE `<member>` in one file that an enclosing function's
	 * DECLARED RETURN TYPE proves to be this value. Haxe resolves an unqualified `enum abstract`
	 * value from the EXPECTED type, so `return Seam;` names `Colour.Seam` when — and only when —
	 * the function returning it is written `: Colour`; a same-named value of a DIFFERENT abstract
	 * in the same file stays untouched because its own function returns that other type.
	 *
	 * Both halves of the proof are POSITIVE — an enumeration of what the operation can prove, not a
	 * list of shapes to avoid, so a construct nobody has thought of yet goes unproven rather than
	 * being claimed. The refusals below are the separate, NEGATIVE half: each names a shape the
	 * positive proof does accept and the language then resolves elsewhere.
	 *
	 *  - The TYPE. The return annotation's VERBATIM source (the projection drops a type's
	 *    arguments from its name, so the span is read, not `QueryNode.name`) with one
	 *    `Null<…>`-style wrapper unwrapped is handed to `SymbolIndex.resolveTypeRefsFrom` FROM THE
	 *    READING FILE — the same whole-dotted-path / import / same-package / root-package rules
	 *    the compiler applies, which is why a last-segment match (the defect `f3b46467` and
	 *    `64a4ae5a` each removed once) cannot creep back in here. It must resolve to exactly ONE
	 *    declaration and that one must be the type at the cursor; a return type resolving to
	 *    nothing (a library type, a wildcard import the index does not model) proves nothing.
	 *  - The POSITION. Only value slots reached from a `return` through TYPE-TRANSPARENT nodes:
	 *    a parenthesis, both arms of a ternary or of an `if` expression, and the last statement of
	 *    each `switch`-expression arm. Each carries the function's return type down unchanged.
	 *
	 * Three refusals sit outside that proof, each measured on 4.3.7 rather than assumed: an
	 * occurrence the file's own scope BINDS (`var Seam = pick(); return Seam;` reads that local); a
	 * file declaring a MODULE-level VALUE binding of the name, which beats the expected type and
	 * which `Refs` does not index — a module-level TYPE of that name does not, being no binding at
	 * all; and a hosting type — or an ancestor of it, or an ancestor the index
	 * cannot even see — that declares the name (`hostShadows`).
	 */
	private static function expectedReturnOffsets(
		source: String, file: String, tree: QueryNode, target: MemberTarget, refShape: RefShape, index: SymbolIndex, cursorFile: String
	): Array<Int> {
		if (!target.isEnumValue) return [];
		// A WHOLE-WORD probe, not a substring one: `RED` occurs inside `COLORED` and inside every
		// comment that mentions it, and the scan below is not free.
		if (RefactorSupport.identTokenOffset(source, new Span(0, source.length), target.memberName) < 0) return [];
		// A MODULE-level VALUE binding of the name shadows the expected type — measured on 4.3.7, a
		// module-level `var same: Colour` (and a `final` one) wins over
		// `function pick(): Colour return same;`, from a module function AND from a class method in
		// the same file. `Refs` binds neither (the read comes back with no binding span), and a
		// hosting TYPE is the wrong question for the second one, so the whole file is refused instead.
		if (declaresModuleBinding(tree, target.memberName, refShape)) return [];
		final seams: Null<ReturnSeams> = returnSeamsOf(target.memberName, refShape);
		if (seams == null) return [];
		// Strict null-safety takes a struct literal's field type from the DECLARED type, not the
		// narrowed one, so the proven-non-null seams need their own binding.
		final grammar: ReturnSeams = seams;
		final scan: ReturnScan = {
			source: source,
			file: file,
			cursorFile: cursorFile,
			target: target,
			seams: grammar,
			index: index,
			tree: tree,
			refShape: refShape,
			bound: null,
			proven: [],
			out: []
		};
		scanReturnPositions(tree, null, null, scan);
		return scan.out;
	}

	/**
	 * Whether the MODULE this file declares carries a top-level VALUE binding of `memberName` — a
	 * Haxe 4.2 module-level `var` / `final` / `function`, which resolves unqualified everywhere in
	 * the module and BEATS the expected type. Its reads are not indexed by `Refs`, so nothing
	 * downstream would exclude them; refusing the file is the positive answer.
	 *
	 * A module-level TYPE of that name is NOT one, which is why the question goes to
	 * `RefShape.moduleValueDeclKinds` and not to `declHostKinds` — that vocabulary names every
	 * type-declaration kind and omits `VarForm` entirely, so neither list contains the other. Compiled and run on 4.3.7: with `class File` in the reading module and
	 * `enum abstract Colour { var File = 3; }`, `function pick(): Colour return File;` prints 3 — the
	 * value wins, and refusing the file threw that rewrite away.
	 *
	 * A child that NAMES NOTHING is descended into, because the binding it holds sits one level down
	 * and both such wrappers are load-bearing. A `#if`-guarded binding is a child of the REGION
	 * (`#if js var same: Colour; #end` projects `(Conditional (VarDecl same …))`) — the
	 * branch-dependent case no single-target compile catches either. A module-level `final` is a child
	 * of the `final` keyword's own dispatch node (`final same: Colour = …;` projects
	 * `(FinalDecl (VarForm same …))`); it slipped the gate entirely while only direct children were
	 * read, and the rewrite then retargeted a read of that binding to the constant with nothing to
	 * reject it — measured on 4.3.7, a program printing 1 printed 3 after the rename and still
	 * compiled.
	 *
	 * Stopping at a NAMED child is PRUNING, not safety. What
	 * makes the descent safe at any depth is that the value kinds are module-EXCLUSIVE in this
	 * grammar: a binding inside a type or a body projects as `VarMember` / `VarStmt` / `LocalFnStmt`,
	 * never as one of these. An unnamed node with a BODY does exist and is reachable — Haxe's
	 * `function #if js m1 #else m2 #end()` projects an unnamed member whose block the walk enters —
	 * and finds nothing there, by that exclusivity rather than by the guard.
	 */
	private static function declaresModuleBinding(node: QueryNode, memberName: String, refShape: RefShape): Bool {
		final valueKinds: Array<String> = refShape.moduleValueDeclKinds;
		for (child in node.children) {
			if (child.name == memberName && valueKinds.contains(child.kind)) return true;
			if (child.name == null && declaresModuleBinding(child, memberName, refShape)) return true;
		}
		return false;
	}

	/**
	 * The offsets this file's own scope BINDS to a local, a parameter or a field — never the
	 * member. Computed on FIRST use: it costs a whole-file resolution pass, and a file that
	 * mentions the name may hold no proven return position at all.
	 */
	private static function boundOffsets(scan: ReturnScan): Array<Int> {
		final memo: Null<Array<Int>> = scan.bound;
		if (memo != null) return memo;
		final hits: Array<Int> = [
			for (h in Refs.find(scan.target.memberName, scan.tree, scan.refShape))
				if ((h.kind == RefKind.Read || h.kind == RefKind.Write) && h.bindingSpan != null) h.span.from
		];
		scan.bound = hits;
		return hits;
	}

	/**
	 * Walk one subtree, carrying the nearest enclosing FUNCTION and the type HOSTING it. A
	 * function's proof is asked only when a `return` under it actually yields candidate offsets,
	 * because asking costs an index resolution; `provenReturnType` then memoizes it per function.
	 */
	private static function scanReturnPositions(node: QueryNode, fn: Null<QueryNode>, host: Null<String>, scan: ReturnScan): Void {
		final s: ReturnSeams = scan.seams;
		if (s.opaqueKinds.contains(node.kind)) return;
		final decl: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
		final owner: Null<String> = decl != null ? decl.name : host;
		final inner: Null<QueryNode> = isFunctionNode(node, s) ? node : fn;
		if (inner != null && s.returnKinds.contains(node.kind) && node.children.length > 0) {
			final candidates: Array<Int> = [];
			collectValueSlots(node.children[0], s, candidates);
			if (candidates.length > 0 && provenReturnType(inner, owner, scan)) {
				final bound: Array<Int> = boundOffsets(scan);
				for (off in candidates) if (!bound.contains(off) && !scan.out.contains(off)) scan.out.push(off);
			}
		}
		for (c in node.children) scanReturnPositions(c, inner, owner, scan);
	}

	/**
	 * Whether `fn`'s declared return type proves this member AND no member of the hosting type
	 * shadows the expected-type reading — memoized on the function's own span, so a function with
	 * several qualifying returns resolves its type once.
	 */
	private static function provenReturnType(fn: QueryNode, host: Null<String>, scan: ReturnScan): Bool {
		final at: Null<Span> = fn.span;
		if (at == null) return false;
		final memo: Null<Bool> = scan.proven[at.from];
		if (memo != null) return memo;
		final answer: Bool = returnsSourceType(fn, scan) && !hostShadows(host, scan.target.memberName, scan.index);
		scan.proven[at.from] = answer;
		return answer;
	}

	/**
	 * The seams `expectedReturnOffsets` reads, or null when the grammar names none of the four
	 * load-bearing ones — identifiers, function bodies, value returns and type annotations. Every
	 * other seam defaults to empty, which NARROWS what the scan proves instead of widening it.
	 */
	private static function returnSeamsOf(memberName: String, refShape: RefShape): Null<ReturnSeams> {
		final bodyKinds: Null<Array<String>> = refShape.functionBodyKinds;
		final returnKinds: Null<Array<String>> = refShape.valueReturnKinds;
		final typeKinds: Null<Array<String>> = refShape.typeAnnotationKinds;
		if (bodyKinds == null || returnKinds == null || typeKinds == null) return null;
		final branchKinds: Array<String> = [];
		final caseBranch: Null<String> = refShape.caseBranchKind;
		if (caseBranch != null) branchKinds.push(caseBranch);
		final defaultBranch: Null<String> = refShape.defaultBranchKind;
		if (defaultBranch != null) branchKinds.push(defaultBranch);
		final armHosts: Array<String> = (refShape.ifExpressionKinds ?? []).copy();
		final ternary: Null<String> = refShape.ternaryKind;
		if (ternary != null) armHosts.push(ternary);
		return {
			memberName: memberName,
			identKind: refShape.identKind,
			functionKinds: (refShape.functionKinds ?? []).concat(refShape.lambdaKinds ?? []).concat(refShape.inlineFunctionKinds ?? []),
			bodyKinds: bodyKinds,
			typeKinds: typeKinds,
			returnKinds: returnKinds,
			parenKind: refShape.parenKind,
			armHostKinds: armHosts,
			switchKinds: refShape.switchKinds ?? [],
			branchKinds: branchKinds,
			exprStatementKind: refShape.exprStatementKind,
			nullableWrappers: refShape.nullableReturnMarkerTypes ?? [],
			opaqueKinds: refShape.opaqueKinds ?? []
		};
	}

	/**
	 * Whether `node` owns a return type of its own: a kind the grammar NAMES as a function or
	 * lambda, or ANY node carrying a function-BODY child — the derivation that also catches a
	 * shape no kind list mentions (Haxe's named function expression `function g(): T …`, which is
	 * in neither `functionKinds` nor `lambdaKinds`). Missing one would attribute an inner
	 * function's `return` to the OUTER function's declared type, which is the one way this scan
	 * could rewrite a value of another abstract.
	 */
	private static function isFunctionNode(node: QueryNode, s: ReturnSeams): Bool {
		// A BODY is never a function: a conditional-compilation body (`CondBody`) holds each
		// branch's own body as a child, so without this it read as a function of its own — with no
		// return type — and silently suppressed every `return` inside a `#if`-bodied function. The
		// conjunct costs nothing on a real function because the two vocabularies are DISJOINT,
		// which `RefShape.functionBodyKinds` states as its own contract — so this can only ever
		// subtract a body, never a function.
		return !s.bodyKinds.contains(node.kind)
			&& (s.functionKinds.contains(node.kind) || node.children.exists(c -> s.bodyKinds.contains(c.kind)));
	}

	/**
	 * Whether `fn`'s DECLARED return type resolves, FROM `file`, to exactly the type the cursor's
	 * member belongs to. One nullable wrapper is unwrapped first: Haxe propagates the expected
	 * type through it, verified by compiling `function nul(): Null<Colour> return SAME;` on 4.3.7.
	 */
	private static function returnsSourceType(fn: QueryNode, scan: ReturnScan): Bool {
		final ret: Null<QueryNode> = returnTypeChild(fn, scan.source, scan.seams);
		if (ret == null) return false;
		final span: Null<Span> = ret.span;
		if (span == null) return false;
		final written: String = unwrapTypeWrapper(scan.source.substring(span.from, span.to).trim(), scan.seams.nullableWrappers);
		if (written == '') return false;
		final matches: Array<{ file: FileInfo, type: TypeDeclInfo }> = scan.index.resolveTypeRefsFrom(written, scan.file);
		return matches.length == 1 && matches[0].type.name == scan.target.typeName && matches[0].file.file == scan.cursorFile;
	}

	/**
	 * `fn`'s return-type annotation node — the child immediately before its BODY, when that child
	 * is a type annotation carrying a name AND the source proves it is not something else. A
	 * PARAMETER never reaches that slot (its own type nests inside the parameter node) but a
	 * TYPE-PARAMETER CONSTRAINT does, so the slot alone is NOT enough; see the guard below. An
	 * anonymous-structure or function return has no name and is left unproven.
	 */
	private static function returnTypeChild(fn: QueryNode, source: String, s: ReturnSeams): Null<QueryNode> {
		final children: Array<QueryNode> = fn.children;
		for (i in 0...children.length) if (s.bodyKinds.contains(children[i].kind)) {
			if (i == 0) return null;
			final candidate: QueryNode = children[i - 1];
			if (!s.typeKinds.contains(candidate.kind) || candidate.name == null) return null;
			final at: Null<Span> = candidate.span;
			final body: Null<Span> = children[i].span;
			// A TYPE-PARAMETER CONSTRAINT projects into the same slot: `function f<T: Colour>()`
			// and `function f(): Colour` give byte-identical trees, and with two constraints the
			// slot holds the LAST one. `RefactorSupport.isReturnTypeSlot` reads the gap between the
			// candidate and the body for the parameter list that only a constraint has — the one
			// predicate `PreferMapType.returnTypeSlot` asks of the type-ref tree.
			return at != null && body != null && RefactorSupport.isReturnTypeSlot(source, at.to, body.from) ? candidate : null;
		}
		return null;
	}

	/**
	 * `written` with ONE outer type-argument wrapper named in `wrappers` removed —
	 * `Null<Colour>` -> `Colour`. Any other parametric type is returned WHOLE and then resolves to
	 * no declaration, which is the conservative answer rather than a guess at its element type.
	 */
	private static function unwrapTypeWrapper(written: String, wrappers: Array<String>): String {
		final open: Int = written.indexOf('<');
		return open <= 0 || !written.endsWith('>') || !wrappers.contains(written.substring(0, open))
			? written
			: written.substring(open + 1, written.length - 1).trim();
	}

	/**
	 * Collect into `out` every bare `<member>` offset reachable from a RETURNED expression through
	 * type-transparent nodes. The accepted set is a whitelist of slots that carry the function's
	 * return type down unchanged; every other node ends the descent. These are CANDIDATES only —
	 * the caller drops the ones this file's own scope binds, once it has a proven function.
	 */
	private static function collectValueSlots(node: QueryNode, s: ReturnSeams, out: Array<Int>): Void {
		final children: Array<QueryNode> = node.children;
		if (node.kind == s.identKind) {
			final span: Null<Span> = node.span;
			if (node.name == s.memberName && span != null && !out.contains(span.from)) out.push(span.from);
			return;
		}
		if (node.kind == s.parenKind) {
			if (children.length > 0) collectValueSlots(children[0], s, out);
			return;
		}
		// Both arms of a ternary / `if` expression ARE the expression's value; child 0 is the
		// condition, a Bool, and never one.
		if (s.armHostKinds.contains(node.kind)) {
			for (i in 1...children.length) collectValueSlots(children[i], s, out);
			return;
		}
		// A `switch` expression's value is the LAST statement of each arm. Child 0 is the subject;
		// an arm's patterns and its optional guard PRECEDE its body, so an arm whose last child is
		// not a statement carries no body at all and contributes nothing.
		final exprStatementKind: Null<String> = s.exprStatementKind;
		if (exprStatementKind == null || !s.switchKinds.contains(node.kind)) return;
		for (i in 1...children.length) {
			final branch: QueryNode = children[i];
			if (!s.branchKinds.contains(branch.kind) || branch.children.length == 0) continue;
			final last: QueryNode = branch.children[branch.children.length - 1];
			if (last.kind == exprStatementKind && last.children.length > 0) collectValueSlots(last.children[0], s, out);
		}
	}

	/**
	 * Whether the type hosting the function — or an ancestor of it — declares a member of this
	 * name, which SHADOWS the expected-type resolution. Verified on Haxe 4.3.7: with
	 * `class Base { public var SAME: Colour; }`, `class Main extends Base` and
	 * `function inherited(): Colour return SAME;`, the program prints the FIELD's value, not
	 * `Colour.SAME` — so a rewrite there would silently retarget the read. `Refs` cannot see an
	 * INHERITED member (it resolves lexically, in one file), which is why the question is asked of
	 * the index instead — and why an ancestor the index CANNOT SEE refuses rather than passing:
	 * with `Base` outside `--scope`, the rewrite silently changed `pick(): Colour return same;`
	 * from the field's value to the constant, compiling clean. Absence of evidence is not proof.
	 */
	private static function hostShadows(host: Null<String>, memberName: String, index: SymbolIndex): Bool {
		// A MODULE-level function has no hosting type, and a module-level field of the name is
		// what would shadow it — the reading file is checked for one before the scan starts.
		if (host == null) return false;
		final owner: String = host;
		// `supertypeDeclaresMember` answers `false` both when no ancestor declares the name and
		// when an ancestor is not in the index, and only the first reading is a proof. Compiled
		// and run: with `Base` OUTSIDE `--scope` declaring `public var same: Colour`, the rewrite
		// changed `pick(): Colour return same;` from the field's value to the constant SILENTLY —
		// the one failure mode this operation forbids. So an unresolvable chain refuses.
		return index.typeDeclaresMember(owner, memberName) || index.supertypeDeclaresMember(owner, memberName)
			|| !index.supertypeChainResolved(owner);
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

/**
 * The grammar seams the EXPECTED-RETURN scan reads, resolved once per rename. Bundled so the
 * recursive descent carries one argument instead of a dozen, exactly as the check layer bundles
 * its own. Only the first four are load-bearing — a grammar that names none of the rest still
 * proves a plain `return VALUE;`, it just proves fewer shapes.
 */
private typedef ReturnSeams = {
	final memberName: String;
	final identKind: String;
	final functionKinds: Array<String>;
	final bodyKinds: Array<String>;
	final typeKinds: Array<String>;
	final returnKinds: Array<String>;
	final parenKind: Null<String>;
	final armHostKinds: Array<String>;
	final switchKinds: Array<String>;
	final branchKinds: Array<String>;
	final exprStatementKind: Null<String>;
	final nullableWrappers: Array<String>;
	final opaqueKinds: Array<String>;
};

/**
 * One expected-return scan in flight: the file being scanned, the member being renamed, the
 * grammar seams, the index the return types resolve through, the offsets the file's own scope
 * BINDS (never the member, filled on first use), the per-function proof memo, and the
 * accumulating result. Threaded so the walk stays a handful of small functions instead of one
 * closure-carrying block.
 */
private typedef ReturnScan = {
	final source: String;
	final file: String;
	final cursorFile: String;
	final target: MemberTarget;
	final seams: ReturnSeams;
	final index: SymbolIndex;
	final tree: QueryNode;
	final refShape: RefShape;
	var bound: Null<Array<Int>>;
	final proven: Map<Int, Bool>;
	final out: Array<Int>;
};
