package anyparse.query;

import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
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
}

/** One scope file parsed once. */
private typedef Parsed = {
	final file: String;
	final source: String;
	final tree: QueryNode;
};

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

	/** The sibling node kinds a member's modifiers / metadata project to. */
	private static final MODIFIER_META: Array<String> = [
		'Meta',
		'Public',
		'Private',
		'Static',
		'Inline',
		'Override',
		'Macro',
		'Extern',
		'Dynamic'
	];

	/** Move `member` from the subclass `subType` up to its superclass `superType`. */
	public static function pullUp(
		srcFile: String, subType: String, member: String, superType: String, scopeFiles: Array<{ file: String, source: String }>,
		plugin: GrammarPlugin
	): MoveResult {
		return move(srcFile, subType, member, superType, Up, scopeFiles, plugin);
	}

	/** Move `member` from the superclass `superType` down to a subclass `subType`. */
	public static function pushDown(
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

		final scope: { error: Null<String>, parsed: Array<Parsed> } = parseScope(scopeFiles, plugin);
		if (scope.error != null) return Err(scope.error);
		final parsed: Array<Parsed> = scope.parsed;

		final srcEntry: Null<Parsed> = parsed.find(p -> p.file == srcFile);
		if (srcEntry == null) return Err('source file $srcFile is not in the scope file set');
		final src: Parsed = srcEntry;
		final srcDecl: Null<TypeDeclMatch> = uniqueClass(src.tree, srcType);
		if (srcDecl == null) return Err('no unique class "$srcType" in $srcFile');
		final srcDeclNN: TypeDeclMatch = srcDecl;

		final targetHit: Null<Parsed> = parsed.find(p -> uniqueClass(p.tree, targetType) != null);
		if (targetHit == null) return Err('no unique class "$targetType" under scope');
		final target: Parsed = targetHit;
		final targetDeclOpt: Null<TypeDeclMatch> = uniqueClass(target.tree, targetType);
		if (targetDeclOpt == null) return Err('no unique class "$targetType" under scope');
		final targetDecl: TypeDeclMatch = targetDeclOpt;

		// Verify the DIRECT inheritance relationship.
		final subDecl: TypeDeclMatch = dir == Up ? srcDeclNN : targetDecl;
		final expectedSuper: String = dir == Up ? targetType : srcType;
		final actualSuper: Null<String> = superNameOf(subDecl);
		if (actualSuper == null || simpleName(actualSuper) != simpleName(expectedSuper)) {
			final subName: String = dir == Up ? srcType : targetType;
			return Err('"$subName" does not directly extend "$expectedSuper" (extends "${actualSuper ?? 'nothing'}")');
		}

		final resolved: Null<Resolved> = resolveMember(srcDeclNN, memberName, src.source);
		if (resolved == null) return Err('class "$srcType" has no member "$memberName"');
		final m: Resolved = resolved;
		final refusal: Null<String> = memberRefusal(m, memberName, targetType, targetDecl, target.source);
		if (refusal != null) return Err(refusal);

		if (dir == Up) {
			final stranded: Array<String> = referencedSubMembers(srcDeclNN, memberName, m.node);
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
	): { error: Null<String>, parsed: Array<Parsed> } {
		final parsed: Array<Parsed> = [];
		for (entry in scopeFiles) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (exception: Exception) null;
			if (tree == null) return { error: 'cannot move across scope: ${entry.file} does not parse', parsed: [] };
			final treeNN: QueryNode = tree;
			parsed.push({ file: entry.file, source: entry.source, tree: treeNN });
		}
		return { error: null, parsed: parsed };
	}

	/**
	 * The refusal for a member unfit to move along the inheritance axis:
	 * a constructor, a static, an override, or a name already on the
	 * target. Null when the member may move.
	 */
	private static function memberRefusal(
		m: Resolved, memberName: String, targetType: String, targetDecl: TypeDeclMatch, targetSource: String
	): Null<String> {
		return memberName == 'new'
			? 'cannot move a constructor'
			: m.isStatic
				? '"$memberName" is static — inheritance moves cover instance members only'
				: m.isOverride
					? '"$memberName" is an override — move the base declaration instead'
					: resolveMember(targetDecl, memberName, targetSource) != null
						? 'type "$targetType" already declares a member "$memberName"'
						: null;
	}

	/**
	 * Cut the member from the source file and append it to the target
	 * type's body, re-parsing both before returning. When the two types
	 * live in the same file, both edits apply to one source.
	 */
	private static function splice(
		src: Parsed, target: Parsed, srcFile: String, m: Resolved, dir: Direction, memberName: String, targetType: String,
		plugin: GrammarPlugin
	): MoveResult {
		final block: String = trimBlankEdges(src.source.substring(m.cut.from, m.cut.to));
		final bodyClose: Null<Int> = typeBodyClose(target.source, findTargetDecl(target, targetType));
		if (bodyClose == null) return Err('"$targetType" has no brace body to receive the member');
		var wsStart: Int = bodyClose;
		while (wsStart > 0 && RefactorSupport.isSpace(StringTools.fastCodeAt(target.source, wsStart - 1))) wsStart--;
		// Preserve the body's padding style: a class whose closing `}` sits on
		// its own blank-separated line (2+ newlines of trailing whitespace)
		// keeps a blank before `}`; a tightly-closed body does not.
		var newlines: Int = 0;
		for (k in wsStart ... bodyClose) if (StringTools.fastCodeAt(target.source, k) == '\n'.code) newlines++;
		final insertText: String = newlines >= 2 ? '\n\n$block\n\n' : '\n\n$block\n';

		final changes: Array<MoveChange> = [];
		if (srcFile == target.file) {
			final newSource: String = RefactorSupport.applyEdits(src.source, [
				{ span: m.cut, text: '' },
				{ span: new Span(wsStart, bodyClose), text: insertText },
			]);
			changes.push({ file: srcFile, newSource: newSource });
		} else {
			changes.push({ file: srcFile, newSource: RefactorSupport.applyEdits(src.source, [{ span: m.cut, text: '' }]) });
			changes.push({
				file: target.file,
				newSource: RefactorSupport.applyEdits(target.source, [{ span: new Span(wsStart, bodyClose), text: insertText }]),
			});
		}

		for (c in changes) {
			try
				plugin.parseFile(c.newSource)
			catch (exception: ParseError)
				return Err('rewritten ${c.file} does not parse: ${exception.toString()}')
			catch (exception: Exception)
				return Err('rewritten ${c.file} does not parse: ${exception.message}');
		}

		final advisory: String = dir == Up
			? 'pulled "$memberName" up to "$targetType" — subclass access is preserved by inheritance; verify no subclass override collides.'
			: 'pushed "$memberName" down to "$targetType" — callers holding a superclass-typed receiver no longer compile (loud); verify none remain.';
		return Ok(changes, advisory);
	}

	/** Re-resolve the target decl in the (possibly identical) target file. */
	private static function findTargetDecl(target: Parsed, targetType: String): TypeDeclMatch {
		final d: Null<TypeDeclMatch> = uniqueClass(target.tree, targetType);
		if (d == null) throw new Exception('target class "$targetType" vanished');
		return d;
	}

	/** The sole class declaration named `typeName`, or null. Final-aware. */
	private static function uniqueClass(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final t: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (t != null && t.name == typeName && t.kind == 'ClassDecl') matches.push(t);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return matches.length == 1 ? matches[0] : null;
	}

	/** The simple name of a class's direct superclass (`extends X`), or null. */
	private static function superNameOf(decl: TypeDeclMatch): Null<String> {
		for (child in decl.nameNode.children) if (child.kind == 'ExtendsClause') for (gc in child.children) if (gc.kind == 'Named')
			return gc.name;
		return null;
	}

	/** The last dotted segment of a (possibly qualified) type name. */
	private static function simpleName(name: String): String {
		final dot: Int = name.lastIndexOf('.');
		return dot < 0 ? name : name.substr(dot + 1);
	}

	/**
	 * Resolve the member named `name` in `decl`: its node, cut span (doc +
	 * whole line included), and static / override flags. Null when absent.
	 */
	private static function resolveMember(decl: TypeDeclMatch, name: String, source: String): Null<Resolved> {
		final siblings: Array<QueryNode> = decl.nameNode.children;
		for (i => child in siblings) {
			final kind: String = child.kind;
			if (!RefactorSupport.isFieldMemberKind(kind) && !RefactorSupport.FN_DECL_KINDS.contains(kind)) continue;
			if (child.name != name) continue;
			final span: Null<Span> = child.span;
			if (span == null) continue;
			final spanNN: Span = span;
			var isStatic: Bool = false;
			var isOverride: Bool = false;
			var j: Int = i - 1;
			while (j >= 0 && MODIFIER_META.contains(siblings[j].kind)) {
				switch siblings[j].kind {
					case 'Static':
						isStatic = true;
					case 'Override':
						isOverride = true;
					case _:
				}
				j--;
			}
			final groupSpan: Span = RefactorSupport.declGroupSpan(child, decl.nameNode, spanNN);
			return {
				node: child,
				cut: cutSpanOf(source, groupSpan),
				isStatic: isStatic,
				isOverride: isOverride
			};
		}
		return null;
	}

	/**
	 * The member names of `subDecl` (other than `movingName`) that the
	 * moved member's subtree references — they would be stranded on a
	 * superclass. Matches any node whose `name` is a subclass member name
	 * (bare call / read / `this.member`), so a comment or string never
	 * triggers it. Conservative: a local / parameter that shadows a member
	 * name may over-refuse, which only ever keeps a member in place.
	 */
	private static function referencedSubMembers(subDecl: TypeDeclMatch, movingName: String, moved: QueryNode): Array<String> {
		final memberNames: Map<String, Bool> = [];
		for (child in subDecl.nameNode.children) {
			final kind: String = child.kind;
			final nm: Null<String> = child.name;
			if (nm != null && nm != movingName && (RefactorSupport.isFieldMemberKind(kind) || RefactorSupport.FN_DECL_KINDS.contains(kind)))
				memberNames[nm] = true;
		}
		final found: Map<String, Bool> = [];
		function walk(node: QueryNode): Void {
			final nm: Null<String> = node.name;
			if (nm != null && memberNames.exists(nm) && (node.kind == 'IdentExpr' || node.kind == 'FieldAccess' || node.kind == 'Call'))
				found[nm] = true;
			for (c in node.children) walk(c);
		}
		walk(moved);
		return [for (k in found.keys()) k];
	}

	/**
	 * The cut span of a member group: its declaration, leading doc comment,
	 * and whole physical line(s), plus a bounding blank line when the decl
	 * is fenced by blanks on both sides. Mirrors `MoveMember.cutSpanOf`.
	 */
	private static function cutSpanOf(source: String, groupSpan: Span): Span {
		final lineCut: Span = RefactorSupport.lineExtendedSpan(source, RefactorSupport.docExtendedSpan(source, groupSpan));
		final blankBefore: Bool = lineCut.from >= 2 && StringTools.fastCodeAt(source, lineCut.from - 2) == '\n'.code;
		final blankAfter: Bool = lineCut.to < source.length && StringTools.fastCodeAt(source, lineCut.to) == '\n'.code;
		return blankBefore && blankAfter ? new Span(lineCut.from, lineCut.to + 1) : lineCut;
	}

	/** The offset of a type's body-closing `}`, or null. Mirrors `MoveMember`. */
	private static function typeBodyClose(source: String, decl: TypeDeclMatch): Null<Int> {
		final bodySpan: Span = decl.nameNode.span ?? decl.fullSpan;
		var bodyClose: Int = bodySpan.to - 1;
		if (bodyClose >= source.length) bodyClose = source.length - 1;
		while (bodyClose >= bodySpan.from && RefactorSupport.isSpace(StringTools.fastCodeAt(source, bodyClose))) bodyClose--;
		return bodyClose < bodySpan.from || StringTools.fastCodeAt(source, bodyClose) != '}'.code ? null : bodyClose;
	}

	/** Strip leading / trailing newlines from a cut block. Mirrors `MoveMember`. */
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

}
