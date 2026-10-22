package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.ScopeFiles.ParsedFile;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/** Move direction along the inheritance axis. */
private enum Direction {

	Up;
	Down;

}

/** A resolved member: its node, cut span (doc + line included), and flags. */
private typedef Resolved = {
	var node: QueryNode;
	var cut: Span;
	var isStatic: Bool;
	var isOverride: Bool;

	/** Declared inside a `#if` region — present in only SOME builds, so it cannot leave its branch. */
	var guarded: Bool;
}

/**
 * `pull-up` / `push-down` — move an instance member along the inheritance
 * axis. Unlike `move-member` (which moves between sibling types and
 * rewrites call sites through a routing field), an inheritance move needs
 * NO call-site rewrite: a member pulled up to a superclass stays visible
 * to every subclass instance, and a member pushed down to a subclass stays
 * visible on that subclass's instances. The member declaration (with its
 * doc / meta / modifiers) is cut from the source type and appended to the
 * target type verbatim.
 *
 * ## Correctness boundary
 *
 *  - The types must be in a DIRECT sub/superclass relationship (the
 *    source's or target's `extends` clause names the other).
 *  - PULL-UP refuses when the moved body references a member that is
 *    declared on the subclass but not being moved — it would not exist on
 *    the superclass. PUSH-DOWN needs no such check: the subclass inherits
 *    every superclass member the body might reference.
 *  - Only INSTANCE members move (statics are not inherited the same way);
 *    the constructor and `override` members are refused.
 *  - PUSH-DOWN can strand callers that hold a superclass-typed receiver
 *    (`superInstance.member()` no longer compiles) — a LOUD compile error,
 *    never a silent change; the advisory says so.
 *
 * Atomic: both files re-parse before either is returned. Verbatim splice,
 * so the source formatting is preserved (canonical-gate-free).
 */
@:nullSafety(Strict)
final class InheritanceMove {

	/** Move `member` from the subclass `subType` up to its superclass `superType`. */
	public static inline function pullUp(
		srcFile: String, subType: String, member: String, superType: String, scopeFiles: Array<{ file: String, source: String }>,
		plugin: GrammarPlugin
	): MoveResult {
		return move(srcFile, subType, member, superType, Up, scopeFiles, plugin);
	}

	/** Move `member` from the superclass `superType` down to a subclass `subType`. */
	public static inline function pushDown(
		srcFile: String, superType: String, member: String, subType: String, scopeFiles: Array<{ file: String, source: String }>,
		plugin: GrammarPlugin
	): MoveResult {
		return move(srcFile, superType, member, subType, Down, scopeFiles, plugin);
	}

	private static function move(
		srcFile: String, srcType: String, memberName: String, targetType: String, dir: Direction,
		scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): MoveResult {
		if (srcType == targetType) return Err('source and target type are the same — nothing to move');

		final scope: { error: Null<String>, parsed: Array<ParsedFile> } = parseScope(scopeFiles, plugin);
		if (scope.error != null) return Err(scope.error);
		final parsed: Array<ParsedFile> = scope.parsed;

		final srcEntry: Null<ParsedFile> = parsed.find(p -> p.file == srcFile);
		if (srcEntry == null) return Err('source file $srcFile is not in the scope file set');
		final src: ParsedFile = srcEntry;
		final srcDecl: Null<TypeDeclMatch> = TypeExtraction.uniqueClass(src.tree, srcType);
		if (srcDecl == null) return Err('no unique class "$srcType" in $srcFile');
		final srcDeclNN: TypeDeclMatch = srcDecl;

		final targetHit: Null<ParsedFile> = parsed.find(p -> TypeExtraction.uniqueClass(p.tree, targetType) != null);
		if (targetHit == null) return Err('no unique class "$targetType" under scope');
		final target: ParsedFile = targetHit;
		final targetDeclOpt: Null<TypeDeclMatch> = TypeExtraction.uniqueClass(target.tree, targetType);
		if (targetDeclOpt == null) return Err('no unique class "$targetType" under scope');
		final targetDecl: TypeDeclMatch = targetDeclOpt;

		// Verify the DIRECT inheritance relationship.
		final subDecl: TypeDeclMatch = dir == Up ? srcDeclNN : targetDecl;
		final expectedSuper: String = dir == Up ? targetType : srcType;
		final actualSuper: Null<String> = TypeExtraction.superNameOf(subDecl);
		if (actualSuper == null || SourceText.lastSegment(actualSuper) != SourceText.lastSegment(expectedSuper)) {
			final subName: String = dir == Up ? srcType : targetType;
			return Err('"$subName" does not directly extend "$expectedSuper" (extends "${actualSuper ?? 'nothing'}")');
		}

		final shape: RefShape = plugin.refShape();
		final resolved: Null<Resolved> = resolveMember(srcDeclNN, memberName, src.source, shape, plugin.lexicalRegions(src.source));
		if (resolved == null) return Err('class "$srcType" has no member "$memberName"');
		final m: Resolved = resolved;
		final refusal: Null<String> = memberRefusal(
			m, memberName, targetType, targetDecl, target.source, shape, plugin.lexicalRegions(target.source)
		);
		if (refusal != null) return Err(refusal);

		if (dir == Up) {
			final stranded: Array<String> = TypeExtraction.referencedMembers(
				srcDeclNN, [memberName], [m.node], src.source, shape, plugin.lexicalRegions.bind(src.source)
			);
			if (stranded.length > 0)
				return Err(
					'"$memberName" references subclass member(s) not present on "$targetType": ${stranded.join(', ')} '
					+ '— move them together or refactor first'
				);
		}

		return splice(src, target, srcFile, m, dir, memberName, targetType, plugin);
	}

	/** Parse every scope file once; a skip-parse becomes a refusal (atomicity). */
	private static function parseScope(
		scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): { error: Null<String>, parsed: Array<ParsedFile> } {
		final parsed: Array<ParsedFile> = [];
		for (entry in scopeFiles) {
			final tree: QueryNode = switch ParseGate.parse(plugin, entry.source, entry.file) {
				case Unparsed(_): return { error: 'cannot move across scope: ${entry.file} does not parse', parsed: [] };
				case Parsed(read): read;
			};
			parsed.push({ file: entry.file, source: entry.source, tree: tree });
		}
		return { error: null, parsed: parsed };
	}

	/**
	 * The refusal for a member unfit to move along the inheritance axis:
	 * a constructor, a static, an override, or a name already on the
	 * target. Null when the member may move.
	 */
	private static function memberRefusal(
		m: Resolved, memberName: String, targetType: String, targetDecl: TypeDeclMatch, targetSource: String, shape: RefShape,
		regions: Array<LexRegion>
	): Null<String> {
		return if (memberName == 'new')
			'cannot move a constructor'
		else if (m.isStatic)
			'"$memberName" is static — inheritance moves cover instance members only'
		else if (m.isOverride)
			'"$memberName" is an override — move the base declaration instead'
		else if (m.guarded)
			'"$memberName'
				+ '" is declared inside a conditional-compilation region — moving it out of its branch would change which builds declare it'
		else if (resolveMember(targetDecl, memberName, targetSource, shape, regions) != null)
			'type "$targetType" already declares a member "$memberName"'
		else
			null;
	}

	/**
	 * Cut the member from the source file and append it to the target
	 * type's body, re-parsing both before returning. When the two types
	 * live in the same file, both edits apply to one source.
	 */
	private static function splice(
		src: ParsedFile, target: ParsedFile, srcFile: String, m: Resolved, dir: Direction, memberName: String, targetType: String,
		plugin: GrammarPlugin
	): MoveResult {
		final block: String = SourceText.trimNewlineEdges(src.source.substring(m.cut.from, m.cut.to));
		final bodyClose: Null<Int> = RefactorSupport.typeBodyCloseOffset(target.source, findTargetDecl(target, targetType));
		if (bodyClose == null) return Err('"$targetType" has no brace body to receive the member');
		var wsStart: Int = bodyClose;
		while (wsStart > 0 && SourceText.isSpace(target.source.fastCodeAt(wsStart - 1))) wsStart--;
		// Preserve the body's padding style: a class whose closing `}` sits on
		// its own blank-separated line (2+ newlines of trailing whitespace)
		// keeps a blank before `}`; a tightly-closed body does not.
		var newlines: Int = 0;
		for (k in wsStart ... bodyClose) if (target.source.fastCodeAt(k) == '\n'.code) newlines++;
		final insertText: String = newlines >= 2 ? '\n\n$block\n\n' : '\n\n$block\n';

		final changes: Array<MoveChange> = [];
		if (srcFile == target.file) {
			final newSource: String = CanonicalEdit.applyEdits(src.source, [
				{ span: m.cut, text: '' },
				{ span: new Span(wsStart, bodyClose), text: insertText }
			]);
			changes.push({ file: srcFile, newSource: newSource });
		} else {
			changes.push({ file: srcFile, newSource: CanonicalEdit.applyEdits(src.source, [{ span: m.cut, text: '' }]) });
			changes.push({
				file: target.file,
				newSource: CanonicalEdit.applyEdits(target.source, [{ span: new Span(wsStart, bodyClose), text: insertText }])
			});
		}

		for (c in changes) {
			final refusal: Null<String> = ParseGate.refusal(plugin, c.newSource, 'rewritten ${c.file}');
			if (refusal != null) return Err(refusal);
		}

		final advisory: String = dir == Up
			? 'pulled "$memberName" up to "$targetType'
				+ '" — subclass access is preserved by inheritance; verify no subclass override collides.'
			: 'pushed "$memberName" down to "$targetType'
				+ '" — callers holding a superclass-typed receiver no longer compile (loud); verify none remain.';
		return Ok(changes, advisory);
	}

	/** Re-resolve the target decl in the (possibly identical) target file. */
	private static function findTargetDecl(target: ParsedFile, targetType: String): TypeDeclMatch {
		final d: Null<TypeDeclMatch> = TypeExtraction.uniqueClass(target.tree, targetType);
		if (d == null) throw new Exception('target class "$targetType" vanished');
		return d;
	}

	/**
	 * Resolve the member named `name` in `decl`: its node, cut span (doc +
	 * whole line included), and static / override flags. Null when absent.
	 */
	private static function resolveMember(
		decl: TypeDeclMatch, name: String, source: String, shape: RefShape, regions: Array<LexRegion>
	): Null<Resolved> {
		var hit: Null<Resolved> = null;
		// Branch-aware, so a member a `#if` region declares is found rather than reported absent. It is
		// still refused as a MOVE (`guarded`) — cutting it out of its branch would change which builds
		// declare it — but the refusal now names the real reason.
		MemberBranchScan.eachTypeMember(
			decl, shape, source, n -> MemberKinds.isFieldMemberKind(n.kind) || MemberKinds.FN_DECL_KINDS.contains(n.kind),
			(child, run) -> {
				final span: Null<Span> = child.span;
				if (hit != null || child.name != name || span == null) return;
				final spanNN: Span = span;
				hit = {
					node: child,
					cut: ElementSpan.memberCutSpan(source, MemberBranchScan.groupSpanOf(run, spanNN), regions),
					isStatic: run.exists(m -> m.kind == 'Static'),
					isOverride: run.exists(m -> m.kind == 'Override'),
					guarded: MemberBranchScan.isGuardedMember(decl, shape, source, child, () -> regions)
				};
			},
			() -> regions
		);
		return hit;
	}

}
