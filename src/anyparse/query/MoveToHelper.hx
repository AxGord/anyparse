package anyparse.query;

import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveMember.MemberGroup;
import anyparse.query.MoveMember.MovePrep;
import anyparse.query.MoveMember.MovedMember;
import anyparse.query.MoveSymbol.MoveResult;
import anyparse.query.MoveToHelperRefs.HelperEdits;
import anyparse.query.MoveToHelperTypes.CarriedType;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.TypeDeclInfo;
import anyparse.runtime.Span;
import haxe.ds.Either;

using Lambda;
using StringTools;

/**
 * `move-to-helper`: move one or more members of a CLASS into a static helper type — a new one, created beside the
 * source, or an existing one — taking the source as an explicit FIRST PARAMETER.
 * (`move-member` refuses a moved `this`; its `--scaffold` would copy the live state.)
 *
 * Every instance member moved becomes `static` with a first parameter `<param>: <Src>`, and its body is rewritten through
 * the shared reference index (`Refs`), never a text scan (`MoveToHelperRefs`):
 *
 *  - a bare read or write of an instance member staying on the source, own or inherited, becomes `<param>.x`; a bare
 *    `this` becomes `<param>`; a static member staying behind becomes `Src.x`;
 *  - a call between moved members, `m2(a)` or `this.m2(a)`, becomes `m2(<param>, a)`;
 *  - every caller of a moved member in scope becomes `Helper.m(this, a)` (a bare call inside the source) or
 *    `Helper.m(recv, a)` (a receiver provably typed as the source, `MoveMemberReceivers`), so the receiver is evaluated
 *    first exactly as before;
 *  - a moved STATIC member is moved as `move-member` moves one (`Src.s` -> `Helper.s` across the scope).
 *
 * What the moved code needs travels with it: a private STATIC FINAL of the source read only by the moved members (a
 * constant) moves into the helper as a static, and a module-PRIVATE type of the source module referenced only by the
 * moved code (and by the other types travelling) moves into the helper's module. A private type the staying code
 * references too is refused — it would have to become visible from two modules.
 *
 * ACCESS: the helper reads the source's private members through ONE `@:access(<pkg>.<Src>)` grant on the moved member
 * (one member needs it) or on the helper type (two or more), `move-member`'s own rule (`MoveMember.applySiblingOutcome`).
 * `@:access` rather than `@:allow(<Helper>)` on the source: the grant sits on the code that needs it, the source's
 * declaration is left as it was, and the same grant covers the inherited private members `g.x` reaches (compile-probed
 * on 4.3.7: `@:access(a.Sub)` lets a helper read `Base`'s private field through a `Sub`). A moved member still called
 * from outside the helper is promoted to `public` (`MoveMember.promotionEdit`).
 *
 * REFUSALS, each with its reason: a source that is not a class, or is generic (the parameter would need its type
 * parameters); a moved member that overrides, is overridden, or implements a supertype's member
 * (`MoveMember.resolutionGuardError`); a `dynamic` / `macro` / `extern` / `overload` member; a property accessor
 * (inside `get_x` the bare `x` is the physical field, outside it `g.x` calls the accessor again); an instance FIELD (a
 * static helper holds no state); a moved member used as a FUNCTION VALUE anywhere (`f = m`, `m.bind(1)`, an interpolated
 * `$m`) — it has no bound form once static; a `super` access; a reference the index cannot resolve (an unbound lower-case
 * name that is no inherited member, no import, no package root); a module-level value of the source module; a parameter
 * name the moved code already spells; and everything `move-member`'s resolution refuses (a `#if`-guarded member, a
 * conditional region it cannot read, a `using` of the source or the helper in scope, a static import of a moved member).
 *
 * Pure like `MoveMember`: every rewritten file (the created helper too) re-parses, or nothing is returned.
 */
@:nullSafety(Strict)
@:access(anyparse.query.MoveMember)
@:access(anyparse.query.AddParam)
final class MoveToHelper {

	/** The member modifiers whose meaning a static helper cannot keep. */
	private static final REFUSED_MODIFIERS: Array<String> = ['Dynamic', 'Macro', 'Extern', 'Overload'];

	/** The metadata spellings of the same. */
	private static final REFUSED_METAS: Array<String> = ['@:macro', '@:overload'];

	/**
	 * Move `memberNames` of `srcTypeName` (declared in `srcFile`) into the static helper `helperName`: the type of that
	 * name under scope when there is one, else a new `final class` created at `helperFile` (default: beside the source).
	 * `param` names the source parameter every moved instance member gains (default: the source type's name with a
	 * lower-case initial). Returns every rewritten file plus an advisory, or the refusal.
	 */
	public static function move(
		srcFile: String, srcTypeName: String, memberNames: Array<String>, helperName: String, helperFile: Null<String>,
		param: Null<String>, scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin, typeRefShape: TypeRefShape
	): MoveResult {
		if (srcTypeName == helperName) return Err('the helper must be another type than "$srcTypeName"');
		if (memberNames.length == 0) return Err('no members named — nothing to move');
		final scope: Array<{ file: String, source: String }> = switch helperScope(
			srcFile, srcTypeName, helperName, helperFile, scopeFiles, plugin
		) {
			case Left(message): return Err(message);
			case Right(files): files;
		};
		final prep: MovePrep = switch resolveWithConstants(srcFile, srcTypeName, memberNames, helperName, scope, plugin) {
			case Left(message): return Err(message);
			case Right(p): p;
		};
		final paramName: String = param ?? srcTypeName.charAt(0).toLowerCase() + srcTypeName.substr(1);
		final refusal: Null<String> = refusalOf(prep, paramName);
		if (refusal != null) return Err(refusal);
		final edits: HelperEdits = MoveToHelperRefs.start(prep, plugin, paramName, helperName);
		final carriedNames: Array<String> = [for (m in prep.moved) if (!memberNames.contains(m.name)) m.name];
		if (carriedNames.length > 0)
			edits.advisory.push('moved along the private constant(s) ${quoted(carriedNames)}, which only the moved members read');
		final types: Array<CarriedType> = switch MoveToHelperTypes.carriedTypes(prep, plugin, typeRefShape) {
			case Left(message): return Err(message);
			case Right(t): t;
		};
		final rewriteError: Null<String> = MoveToHelperRefs.rewrite(edits);
		if (rewriteError != null) return Err(rewriteError);
		for (m in prep.moved) if (!m.isStatic) signatureEdits(prep, m, paramName, edits.movedTextEdits);
		MoveMember.applySiblingOutcome(prep, edits.accessMembers, [], edits.movedTextEdits, edits.editsByFile, edits.advisory);
		for (m in prep.moved) MoveMember.promotionEdit(prep, m, edits.outsideCallersOf[m.name] ?? 0, edits.movedTextEdits, edits.advisory);
		MoveToHelperTypes.relocate(prep, types, edits.editsByFile, edits.advisory);
		final destError: Null<String> = MoveMember.assembleDestination(
			prep, [], edits.movedTextEdits, edits.editsByFile, edits.advisory, plugin.lexicalRegions
		);
		if (destError != null) return Err(destError);
		final carryError: Null<String> = MoveMember.pushImportEdits(
			prep, typeRefShape, edits.callerFiles, plugin, edits.editsByFile, [for (t in types) { span: t.group, name: t.name }],
			[for (t in types) t.name]
		);
		if (carryError != null) return Err(carryError);
		MoveMember.pushEndpointImports(prep, edits.editsByFile, edits.movedTextEdits, plugin);
		parameterTypeImport(prep, edits, plugin);
		return MoveMember.applyAndValidate(edits.editsByFile, prep.sourceOf, plugin, memberNames.join(', '), edits.advisory);
	}

	private static inline function quoted(names: Array<String>): String {
		return names.map(n -> '"$n"').join(', ');
	}

	private static inline function metaText(prep: MovePrep, node: QueryNode): String {
		final span: Null<Span> = node.span;
		return span == null ? node.kind : prep.srcSource.substring(span.from, span.to);
	}

	/**
	 * The scope the move runs over: the given one when it declares `helperName` already, else the given one plus the NEW
	 * helper module — `package <src pkg>;`, the source type's `@:nullSafety` grant if it has one, an empty `final class`.
	 * A new helper lands at `helperFile`, or beside the source as `<Helper>.hx`; a path the scope already holds is refused,
	 * since that module exists and does not declare the helper.
	 */
	private static function helperScope(
		srcFile: String, srcTypeName: String, helperName: String, helperFile: Null<String>,
		scopeFiles: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): Either<String, Array<{ file: String, source: String }>> {
		final trees: Map<String, QueryNode> = [];
		for (entry in scopeFiles) switch ParseGate.parse(plugin, entry.source, entry.file) {
			case Unparsed(message):
				return Left(message);
			case Parsed(tree):
				trees[entry.file] = tree;
		}
		switch MoveMember.findTypeAcrossScope(scopeFiles, trees, helperName) {
			case FErr(message):
				return Left(message);
			case FOk(hit):
				if (hit != null) return Right(scopeFiles);
		}
		final srcTree: Null<QueryNode> = trees[srcFile];
		final srcSource: Null<String> = scopeFiles.find(e -> e.file == srcFile)?.source;
		if (srcTree == null || srcSource == null) return Left('source file $srcFile is not in the scope file set');
		final srcDecl: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(srcTree, srcTypeName);
		if (srcDecl == null) return Left('no unique type "$srcTypeName" in $srcFile');
		final cut: Int = srcFile.lastIndexOf('/');
		final path: String = helperFile ?? (cut < 0 ? '$helperName.hx' : '${srcFile.substring(0, cut)}/$helperName.hx');
		if (scopeFiles.exists(e -> e.file == path)) return Left('$path exists and declares no type "$helperName"');
		final pkg: String = ModuleScan.packageOf(srcTree);
		final header: String = pkg == '' ? 'package;' : 'package $pkg;';
		final nullSafety: Null<String> = nullSafetyGrant(srcSource, srcTree, srcDecl);
		final meta: String = nullSafety == null ? '' : '$nullSafety\n';
		final doc: String =
			'/**\n * Static helpers taken out of `$srcTypeName`: each reads the `$srcTypeName` it is handed as its first parameter.\n */\n';
		return Right(scopeFiles.concat([{ file: path, source: '$header\n\n$doc${meta}final class $helperName {}\n' }]));
	}

	/** The source text of the `@:nullSafety(...)` entry the source type carries, or null. */
	private static function nullSafetyGrant(source: String, tree: QueryNode, decl: TypeDeclMatch): Null<String> {
		final declSpan: Null<Span> = decl.declNode.span;
		if (declSpan == null) return null;
		final runStart: Int = ElementSpan.declRunStart(decl.declNode, tree, declSpan);
		for (c in tree.children) {
			final span: Null<Span> = c.span;
			if (span != null && span.from >= runStart && span.to <= declSpan.from && MemberKinds.META_KINDS.contains(c.kind)) {
				final text: String = source.substring(span.from, span.to);
				if (text.startsWith('@:nullSafety')) return text;
			}
		}
		return null;
	}

	/**
	 * `MoveMember.resolveMove` in its `helper` mode, re-run until the move set holds every private constant only the moved
	 * members read (`onlyMovedConstants`) — a constant's own initializer may name another, hence the fixpoint.
	 */
	private static function resolveWithConstants(
		srcFile: String, srcTypeName: String, memberNames: Array<String>, helperName: String,
		scope: Array<{ file: String, source: String }>, plugin: GrammarPlugin
	): Either<String, MovePrep> {
		final names: Array<String> = memberNames.copy();
		while (true) {
			final prep: MovePrep = switch MoveMember.resolveMove(srcFile, srcTypeName, names, helperName, false, scope, plugin, true) {
				case PErr(message): return Left(message);
				case POk(p): p;
			};
			final more: Array<String> = onlyMovedConstants(prep, plugin);
			if (more.length == 0) return Right(prep);
			for (name in more) names.push(name);
		}
	}

	/**
	 * The non-public `static final` (or `static inline var`) members of the source that the moved members read and nothing
	 * else does — no reference outside the moved cuts in the source file, no `Src.c` anywhere else in scope.
	 */
	private static function onlyMovedConstants(prep: MovePrep, plugin: GrammarPlugin): Array<String> {
		final candidates: Array<MemberGroup> = MoveMember.membersOf(prep.srcDecl, prep.srcSource, prep.shape, plugin.lexicalRegions)
			.filter(g -> isPrivateConstant(g) && !prep.moved.exists(m -> m.name == g.member.name));
		if (candidates.length == 0) return [];
		final hits: Map<String, Array<RefHit>> = Refs.findMulti([for (c in candidates) c.member.name ?? ''], prep.srcTree, prep.shape);
		return [
			for (c in candidates) {
				final name: String = c.member.name ?? '';
				final declFrom: Int = c.member.span?.from ?? -1;
				final refs: Array<RefHit> = (hits[name] ?? []).filter(h -> h.kind != RefKind.Decl && h.bindingSpan?.from == declFrom);
				if (refs.length > 0 && refs.foreach(h -> MoveMember.insideAnyCut(prep, h.span.from)) && !qualifiedOutsideCuts(prep, name))
					name;
			}
		];
	}

	private static function isPrivateConstant(g: MemberGroup): Bool {
		final kinds: Array<String> = g.modifiers.map(m -> m.kind);
		return kinds.contains('Static') && !kinds.contains('Public')
			&& (MoveMember.FINAL_FIELD_KINDS.contains(g.member.kind) || (g.member.kind == 'VarMember' && kinds.contains('Inline')));
	}

	/** Whether a `Src.<name>` access sits anywhere in scope outside the moved cuts. */
	private static function qualifiedOutsideCuts(prep: MovePrep, name: String): Bool {
		for (file => tree in prep.trees) {
			final source: String = prep.sourceOf[file] ?? '';
			if (source.indexOf(name) < 0) continue;
			for (hit in MoveMember.qualifiedReceiverEdits(source, tree, prep, name)) if (
				file != prep.srcFile || !MoveMember.insideAnyCut(prep, hit.span.from)
			)
				return true;
		}
		return false;
	}

	/**
	 * Why the resolved move cannot be expressed as a static helper, or null. The member-level refusals are listed in the
	 * class doc; the reference-level ones (`super`, an unresolved name, a function value) come from `MoveToHelperRefs`.
	 */
	private static function refusalOf(prep: MovePrep, paramName: String): Null<String> {
		final srcKind: String = prep.srcDecl.kind;
		if (!(prep.shape.classDeclKinds ?? ['ClassDecl']).contains(srcKind))
			return '"${prep.srcTypeName}" is not a class — only a class hands its members a `this` a helper can take as a parameter';
		final info: Null<TypeDeclInfo> = prep.srcInfo.types.find(t -> t.name == prep.srcTypeName);
		if (info != null && info.typeParamArity > 0)
			return '"${prep.srcTypeName}" is generic — the helper\'s parameter would need its type parameters, which is not wired';
		for (m in prep.moved) {
			final memberRefusal: Null<String> = memberRefusalOf(prep, m);
			if (memberRefusal != null) return memberRefusal;
		}
		final captures: Array<String> = BinderScan.casePatternCaptures(prep.srcTree, prep.shape);
		final guard: Null<String> = MoveMember.resolutionGuardError(prep, captures);
		if (guard != null) return guard;
		final clash: Null<String> = parameterClash(prep, paramName);
		return clash == null ? null : '$clash — pass another name with --param';
	}

	/** Why one moved member cannot become a static of the helper, or null. */
	private static function memberRefusalOf(prep: MovePrep, m: MovedMember): Null<String> {
		final head: String = 'cannot move "${m.name}" into a static helper';
		final refusedModifier: Null<QueryNode> = m.group.modifiers.find(
			mod ->
				REFUSED_MODIFIERS.contains(mod.kind)
				|| (MemberKinds.META_KINDS.contains(mod.kind) && REFUSED_METAS.exists(meta -> metaText(prep, mod).startsWith(meta)))
		);
		if (refusedModifier != null)
			return '$head: it is declared `${metaText(prep, refusedModifier)}`, a meaning a static member does not keep';
		if (m.isStatic) return null;
		if (MemberKinds.isDataFieldKind(m.group.member.kind))
			return '$head: it is an instance field — a static helper holds no state; move the methods that use it instead';
		if (m.group.member.kind != 'FnMember') return '$head: only a plain method is moved (it is a ${m.group.member.kind})';
		final property: Null<String> = accessedProperty(prep, m.name);
		return property == null
			? null
			: '$head: it is an accessor of the property "$property" — inside it the bare "$property" is the physical field, while '
				+ 'the helper\'s `<param>.$property` would call the accessor again';
	}

	/**
	 * The property `name` is the accessor of (`get_x` of a `var x(get, …)`, `set_x` of a `var x(…, set)`), or null —
	 * read off the index's member record, which carries the accessor clause the projection drops.
	 */
	private static function accessedProperty(prep: MovePrep, name: String): Null<String> {
		final isGet: Bool = name.startsWith('get_');
		if (!isGet && !name.startsWith('set_')) return null;
		final property: String = name.substr(4);
		final info: Null<TypeDeclInfo> = prep.srcInfo.types.find(t -> t.name == prep.srcTypeName);
		final member: Null<MemberInfo> = info?.members.find(mi -> mi.name == property);
		if (member == null) return null;
		return (isGet ? member.hasGetter : member.hasSetter) ? property : null;
	}

	/**
	 * What already spells `paramName` where the parameter would bind it, or null: a moved member of that name, or any
	 * identifier or declaration inside the moved members — a local of that name would shadow the parameter, and a read of
	 * a same-named member would be taken for it.
	 */
	private static function parameterClash(prep: MovePrep, paramName: String): Null<String> {
		if (prep.moved.exists(m -> m.name == paramName)) return 'a moved member is itself named "$paramName"';
		final accessKinds: Array<String> = ShapeVocab.memberAccessKinds(prep.shape);
		function walk(node: QueryNode): Null<QueryNode> {
			if (node.name == paramName && !accessKinds.contains(node.kind)) return node;
			for (c in node.children) {
				final found: Null<QueryNode> = walk(c);
				if (found != null) return found;
			}
			return null;
		}
		for (m in prep.moved) {
			final found: Null<QueryNode> = walk(m.group.member);
			if (found != null) {
				final at: Position = (found.span ?? new Span(0, 0)).lineCol(prep.srcSource);
				return 'the moved code already spells "$paramName" at ${prep.srcFile}:${at.line}:${at.col}';
			}
		}
		return null;
	}

	/**
	 * Turns a moved INSTANCE method into the helper's static: `static` after its visibility (or ahead of its first
	 * modifier), and `<param>: <Src>` as its first parameter. Pushed BEFORE the promotion edit: two insertions at one offset
	 * land in reverse push order, and `public static` is the order the project writes.
	 */
	private static function signatureEdits(
		prep: MovePrep, m: MovedMember, paramName: String, movedTextEdits: Array<{ span: Span, text: String }>
	): Void {
		final visibility: Null<QueryNode> = m.group.modifiers.find(mod -> mod.kind == 'Public' || mod.kind == 'Private');
		final visibilityEnd: Null<Int> = visibility?.span?.to;
		if (visibilityEnd != null)
			movedTextEdits.push({ span: new Span(visibilityEnd, visibilityEnd), text: ' static' });
		else {
			final at: Int = m.group.modifiers.find(mod -> !MemberKinds.META_KINDS.contains(mod.kind))?.span?.from ?? m.span.from;
			movedTextEdits.push({ span: new Span(at, at), text: 'static ' });
		}
		final params: Array<QueryNode> = [for (c in m.group.member.children) if (AddParam.PARAM_KINDS.contains(c.kind)) c];
		final first: Null<Int> = params.length > 0 ? params[0].span?.from : null;
		final declared: String = '$paramName: ${prep.srcTypeName}';
		if (first != null)
			movedTextEdits.push({ span: new Span(first, first), text: '$declared, ' });
		else {
			final open: Int = AddParam.emptyParenInsertOffset(prep.srcSource, m.span);
			if (open >= 0) movedTextEdits.push({ span: new Span(open, open), text: declared });
		}
	}

	/**
	 * The import the helper module owes for the parameter type `<Src>` itself, when the bare name does not resolve there and
	 * `MoveMember.pushEndpointImports` has not already added it for a `Src.x` the moved bodies spell.
	 */
	private static function parameterTypeImport(prep: MovePrep, edits: HelperEdits, plugin: GrammarPlugin): Void {
		if (prep.srcFile == prep.destFile || !prep.moved.exists(m -> !m.isStatic)) return;
		if (edits.movedTextEdits.exists(e -> e.text.contains('${prep.srcTypeName}.'))) return;
		if (RefactorSupport.bareNameResolves(prep.srcTypeName, prep.srcModule, prep.destInfo.pkg)) return;
		final srcPath: String = RefactorSupport.rootQualifiedPath(prep.srcTypeName, prep.srcModule);
		final edit: Null<{ span: Span, text: String }> = MoveSymbol.addImportEdit(prep.destSource, prep.destInfo, plugin, srcPath);
		if (edit != null) ScopeFiles.editsFor(edits.editsByFile, prep.destFile).push(edit);
	}

}
