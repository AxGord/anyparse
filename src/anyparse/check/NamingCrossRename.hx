package anyparse.check;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.Check.RiskyCrossFileEdit;
import anyparse.check.NamingRenames.RenameRefusal;
import anyparse.check.scan.ReflectionScan;
import anyparse.query.CrossRename;
import anyparse.query.CrossRenameMember;
import anyparse.query.IndexScope;
import anyparse.query.Meta;
import anyparse.query.NamingPolicy.ImplicitReach;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingRule;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.OccurrenceScan;
import anyparse.query.ParseGate;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * `naming`'s CROSS-FILE rename arm: a TYPE or an ENUM-ABSTRACT VALUE whose name violates the policy is
 * renamed in every file that names it, through the `rename --scope` engines (`CrossRename`,
 * `CrossRenameMember`) — never a second rename engine. Neither member path owns such a declaration
 * (no confinement proof applies to it), so before this arm the finding was report-only.
 *
 * ## Why it is a RISKY arm
 *
 * The engines' contract is "every miss is LOUD": an occurrence they cannot prove stays spelled the old
 * way and fails to compile. That is exactly what the compiler oracle turns into a revert, so the arm's
 * edit sets reach the tree only through `FixVerifier`'s typecheck-and-revert pipeline, and without a
 * `compilerOracle` the finding stays report-only. What the oracle CANNOT see is a rename that still
 * compiles and means something else, and every gate below exists for one such way.
 *
 * ## The gates — a positive list; anything else is refused with its own reason
 *
 * - The run indexes the WHOLE project (`RefactorSupport.projectIsComplete`): the engines rewrite what
 *   they are handed, so a project file this run never read would keep the old name.
 * - A TYPE only of a kind whose name the compiler erases (`RefShape.compileTimeTypeDeclKinds`: a
 *   typedef, an abstract, an enum abstract). A class, an interface or an enum keeps its name at run
 *   time — `Type.getClassName`, `Type.resolveClass`, serialized data — where no typecheck sees it.
 *   Not a module's MAIN type (the file would have to be renamed with it), no metadata beyond the
 *   name-inert ones the grammar lists (`RefShape.nameInertTypeMetaNames`), not inside a `#if` region.
 * - An ENUM VALUE only of an `enum abstract` (a plain enum constructor's name is printed by
 *   `Std.string` and serialized), and only one whose VALUE does not depend on its name: it has an
 *   initializer, or the abstract's underlying type numbers implicit values
 *   (`RefShape.indexValuedEnumAbstractUnderlyings`). An implicit `String` value IS the name.
 * - For a TYPE, no string spells its name where a lookup could read it: no literal that names it in any
 *   project file (`OccurrenceScan`'s `StringLiteral` class) and no runtime type path in the reflection
 *   surface (`ReflectionScan.runtimeTypePath`). An enum-abstract value has no runtime name — it is its
 *   value, inlined — so a literal spelling its name is data and does not refuse.
 * - The OLD name is declared nowhere else (`SymbolIndex` over the resolution scope): an occurrence the
 *   engine leaves behind would then BIND to the other declaration instead of failing.
 * - The NEW name is declared nowhere and spelled in no project file outside a comment: a reference
 *   that already spells it would be captured by the renamed declaration.
 * - Every file the rename edits is one of this run's files: a narrowed run never writes past its scope.
 */
@:nullSafety(Strict)
@:access(anyparse.check.Naming)
final class NamingCrossRename {

	/** The run does not index the whole project. */
	public static inline final NO_PROJECT: String =
		'the cross-file rename arm needs the WHOLE project indexed (declared `resolutionRoots`, every one matched), and this run does not — a project file it never read would keep the old name';

	/** A class / interface / enum: its name exists at run time. */
	public static inline final RUNTIME_TYPE: String =
		'the type is a class, an interface or an enum, whose NAME exists at run time (`Type.getClassName`, `Type.resolveClass`, serialized data) — a rename can change behaviour no typecheck sees';

	/** A module's main type. */
	public static inline final MAIN_TYPE: String =
		'the type is its module\'s MAIN type, so renaming it renames the module path — the file would have to be renamed with it';

	/** A type carrying metadata a macro / framework may read. */
	public static inline final TYPE_METADATA: String =
		'the type carries metadata a macro, a framework or the runtime may resolve by the type\'s NAME';

	/** A declaration only some builds see. */
	public static inline final GUARDED: String =
		'the declaration sits inside a conditional-compilation region, so other builds may declare the name differently';

	/** A plain enum constructor. */
	public static inline final ENUM_CONSTRUCTOR: String =
		'the value is a constructor of a plain `enum`, whose name exists at run time (`Std.string`, serialization, `Type.enumConstructor`)';

	/** An implicit enum-abstract value derived from its own name. */
	public static inline final IMPLICIT_VALUE: String =
		'the enum-abstract value has no initializer and its underlying type derives an implicit value from the NAME (`String`), so the rename would change the value';

	/** A string spells the old name. */
	public static inline final STRING_LITERAL: String =
		'a string literal in the project names the declaration, or a runtime type path spells it — a lookup by NAME the rename cannot follow';

	/** Another declaration carries the old name. */
	public static inline final OLD_NAME_SHARED: String =
		'another declaration in the resolution scope carries the same name, so an occurrence the rename leaves behind would bind to it instead of failing to compile';

	/** The corrected name is already taken. */
	public static inline final NEW_NAME_TAKEN: String =
		'the corrected name is already declared, or already spelled in a project file, so the renamed declaration could capture a reference meant for something else';

	/** The engine refused. */
	public static inline final ENGINE_REFUSED: String =
		'the `rename --scope` engine refused this rename (an ambiguous or unresolvable declaration, a name the type already declares, an unparsed `#if` region, or a rewrite that does not re-parse)';

	/** The declaration could not be located again. */
	public static inline final UNRESOLVED: String = 'the declaration could not be resolved in the run\'s index, so no gate could be asked';

	/** Whether `decl` is a declaration this arm owns: a type or an enum value the grammar did not mark rename-unsafe. */
	public static inline function isCandidate(decl: NamedDecl): Bool {
		return (decl.category == NamingCategory.Type || decl.category == NamingCategory.EnumValue) && decl.renameUnsafe != true;
	}

	/**
	 * The rename edit set of every finding in `violations` the gates admit; each refused one carries its
	 * reason in `Violation.declineReason`.
	 */
	public static function edits(
		files: Array<{ file: String, source: String }>, violations: Array<Violation>, plugin: GrammarPlugin, support: NamingSupport
	): Array<RiskyCrossFileEdit> {
		final out: Array<RiskyCrossFileEdit> = [];
		if (violations.length == 0) return out;
		final complete: Null<Array<{ file: String, source: String }>> = RefactorSupport.completeProjectSourcesOf(plugin);
		if (complete == null) {
			for (v in violations) RenameRefusal.note(v, NO_PROJECT);
			return out;
		}
		final project: Map<String, String> = [for (entry in complete) entry.file => entry.source];
		// The run's own files win: the verifier hands over what is on disk NOW, after earlier risky edits.
		for (entry in files) project[entry.file] = entry.source;
		final report: SymbolIndex = IndexScope.report(files, plugin);
		final ctx: Context = {
			files: files,
			project: [for (file => source in project) { file: file, source: source }],
			plugin: plugin,
			support: support,
			shape: plugin.refShape(),
			index: IndexScope.resolutionIndexOf(plugin) ?? report,
			surface: ReflectionScan.reflectionSurface(files, plugin)
		};
		for (v in violations) {
			final edit: Null<RiskyCrossFileEdit> = renameFor(v, ctx);
			if (edit != null) out.push(edit);
		}
		return out;
	}

	/** The edit set for `v`, or null with the reason noted on it. */
	private static function renameFor(v: Violation, ctx: Context): Null<RiskyCrossFileEdit> {
		final span: Null<Span> = v.span;
		final source: Null<String> = ctx.files.find(f -> f.file == v.file)?.source;
		if (span == null || source == null) return refuse(v, UNRESOLVED);
		final text: String = source;
		final tree: Null<QueryNode> = ParseGate.parseOrNull(ctx.plugin, text);
		if (tree == null) return refuse(v, RenameRefusal.NO_TREE);
		final at: Int = span.from;
		final decl: Null<NamedDecl> = ctx.support.project(tree, Naming.propertyFacts(ctx.plugin, text)).find(d -> d.span?.from == at);
		if (decl == null || !isCandidate(decl)) return refuse(v, UNRESOLVED);
		final rule: Null<NamingRule> = Naming.applicableRule(decl, ctx.support.policyFor(v.file));
		if (rule == null) return refuse(v, RenameRefusal.NO_RULE);
		final said: Array<String> = [];
		final corrected: Null<String> = Naming.correctedName(decl.name, rule, reason -> said.push(reason));
		if (corrected == null) return refuse(v, said.length == 0 ? RenameRefusal.NORMALIZER_DECLINED : said[0]);
		final newName: String = corrected;
		final isType: Bool = decl.category == NamingCategory.Type;
		final gate: Null<String> = isType ? typeRefusal(decl, v.file, tree, text, newName, ctx) : valueRefusal(decl, v.file, newName, ctx);
		if (gate != null) return refuse(v, gate);
		// A TYPE's name is what a runtime lookup or a macro string spells. An enum-abstract VALUE has no runtime name:
		// it IS its value, inlined, so a literal spelling the name is data (`'vertical'` beside `final vertical = 'vertical'`).
		if (isType && stringNamesIt(decl.name, ctx)) return refuse(v, STRING_LITERAL);
		final pos: Position = new Span(at, at).lineCol(text);
		final scope: Array<{ file: String, source: String }> = [
			for (entry in ctx.project) if (entry.file == v.file || entry.source.indexOf(decl.name) >= 0) entry
		];
		final result: CrossRenameResult = isType
			? CrossRename.crossRenameType(v.file, text, pos.line, pos.col, newName, scope, ctx.plugin, ctx.plugin.typeRefShape(), ctx.shape)
			: CrossRenameMember.crossRenameMember(v.file, text, pos.line, pos.col, newName, scope, ctx.plugin, ctx.shape);
		return switch result {
			case Err(_): refuse(v, ENGINE_REFUSED);
			case Ok(changes, _): slicesOf(v, changes, ctx);
		};
	}

	/** The engine's `changes` as an edit set, or null when one of them lands outside the run's files. */
	private static function slicesOf(v: Violation, changes: Array<FileChange>, ctx: Context): Null<RiskyCrossFileEdit> {
		final slices: Array<CrossFileEdits> = [];
		for (change in changes) {
			if (!ctx.files.exists(f -> f.file == change.file)) return refuse(v, RenameRefusal.crossOutsideScope(change.file));
			slices.push({ file: change.file, edits: change.edits });
		}
		return { violation: v, slices: slices };
	}

	/** Why the TYPE `decl` (declared in `file`) must not be renamed to `newName`, or null. */
	private static function typeRefusal(
		decl: NamedDecl, file: String, tree: QueryNode, source: String, newName: String, ctx: Context
	): Null<String> {
		final declared: Null<TypeDeclInfo> = typeDeclared(ctx, file, decl.name);
		if (declared == null) return UNRESOLVED;
		final type: TypeDeclInfo = declared;
		final kinds: Array<String> = ctx.shape.compileTimeTypeDeclKinds ?? [];
		return if (!kinds.contains(type.kind))
			RUNTIME_TYPE
		else if (type.isMain)
			MAIN_TYPE
		else if (type.guarded)
			GUARDED
		else if (unsafeTypeMeta(tree, source, type, ctx.plugin))
			TYPE_METADATA
		else if (
			ReflectionScan.runtimeTypePath(ctx.surface.whole, decl.name)
			|| ReflectionScan.runtimeTypePathFragment(ctx.surface.fragments, decl.name)
		)
			STRING_LITERAL
		else if (ctx.index.refs.declaringFiles(decl.name).length != 1)
			OLD_NAME_SHARED
		else if (ctx.index.refs.declaringFiles(newName).length > 0 || spelledInProject(newName, ctx))
			NEW_NAME_TAKEN
		else
			null;
	}

	/** Why the enum VALUE `decl` (declared in `file`) must not be renamed to `newName`, or null. */
	private static function valueRefusal(decl: NamedDecl, file: String, newName: String, ctx: Context): Null<String> {
		final ownerName: Null<String> = decl.enclosingType;
		final owner: Null<TypeDeclInfo> = ownerName == null ? null : typeDeclared(ctx, file, ownerName);
		if (owner == null) return UNRESOLVED;
		final type: TypeDeclInfo = owner;
		if (type.kind != ctx.shape.enumAbstractDeclKind) return ENUM_CONSTRUCTOR;
		final member: Null<MemberInfo> = type.members.find(m -> m.name == decl.name && !m.isStatic);
		if (member == null) return UNRESOLVED;
		final reach: Null<ImplicitReach> = decl.implicitReach;
		final indexed: Array<String> = ctx.shape.indexValuedEnumAbstractUnderlyings ?? [];
		return if (member.guarded || type.guarded)
			GUARDED
		else if (member.metaNames.length > 0)
			RenameRefusal.CARRIES_METADATA
		else if (reach != null)
			RenameRefusal.implicitReach(reach)
		else if (member.initializerKind == null && !indexed.contains(type.underlyingRaw ?? ''))
			IMPLICIT_VALUE
		else if (valueDeclaredElsewhere(decl.name, type, ctx))
			OLD_NAME_SHARED
		else if (valueDeclaredElsewhere(newName, type, ctx) || boundWhereRenamed(newName, decl.name, ctx))
			NEW_NAME_TAKEN
		else
			null;
	}

	/** The index record of the type `name` declared in `file`, or null. */
	private static function typeDeclared(ctx: Context, file: String, name: String): Null<TypeDeclInfo> {
		return ctx.index.fileInfo(file)?.types.find(t -> t.name == name);
	}

	/**
	 * Whether `type` carries metadata outside the grammar's name-inert list
	 * (`RefShape.nameInertTypeMetaNames`), or one the projection could not attribute.
	 */
	private static function unsafeTypeMeta(tree: QueryNode, source: String, type: TypeDeclInfo, plugin: GrammarPlugin): Bool {
		if (type.hasBuild || type.hasAutoBuild || type.hasKeep || type.hasRtti || type.isExtern || type.bringsExtensions) return true;
		final inert: Array<String> = plugin.refShape().nameInertTypeMetaNames ?? [];
		for (hit in Meta.find(tree, plugin.metaShape(), source)) {
			final owner: Null<Span> = hit.declSpan;
			if (owner == null) return true;
			if (owner.from <= type.span.from && type.span.from < owner.to && hit.declName == type.name && !inert.contains(hit.annotation))
				return true;
		}
		return false;
	}

	/**
	 * Whether a type of a bare-constructor kind other than `owner` declares a VALUE `name` — an enum constructor,
	 * or an enum-abstract value (a non-static field with no accessor) — that a bare `name` could bind to once
	 * `owner`'s no longer answers to it. An enum abstract's property or method is no such binding.
	 */
	private static function valueDeclaredElsewhere(name: String, owner: TypeDeclInfo, ctx: Context): Bool {
		final kinds: Array<String> = ctx.shape.bareConstructorTypeKinds ?? [];
		final fields: Array<String> = ctx.shape.fieldDeclKinds ?? [];
		inline function isValue(t: TypeDeclInfo, m: MemberInfo): Bool {
			return t.kind != ctx.shape.enumAbstractDeclKind || !m.isStatic && fields.contains(m.kind) && !m.hasGetter && !m.hasSetter;
		}
		for (fi in ctx.index.allFiles())
			for (t in fi.types)
				if (t != owner && kinds.contains(t.kind) && t.members.exists(m -> m.name == name && isValue(t, m))) return true;
		return false;
	}

	/**
	 * Whether `newName` is already a binding in a project file that spells `oldName` — a file the rename
	 * can edit, where a renamed bare occurrence would bind to that binding first.
	 */
	private static function boundWhereRenamed(newName: String, oldName: String, ctx: Context): Bool {
		return ctx.project.exists(
			entry ->
				entry.source.indexOf(oldName) >= 0 && entry.source.indexOf(newName) >= 0
				&& OccurrenceScan.nameBoundInRange(entry.source, newName, 0, entry.source.length, [], ctx.plugin)
		);
	}

	/** Whether `name` occurs in some project file anywhere but a comment or a word of prose inside a string. */
	private static function spelledInProject(name: String, ctx: Context): Bool {
		for (entry in ctx.project) if (entry.source.indexOf(name) >= 0) {
			final found: Null<Array<ClassifiedOccurrence>> = OccurrenceScan.classifyOccurrences(
				entry.source, name, ctx.plugin, 0, entry.source.length, []
			);
			if (found == null) return true;
			for (occ in found) switch occ.kind {
				case OccurrenceClass.CommentTrivia, OccurrenceClass.StringWord:
				case _:
					return true;
			}
		}
		return false;
	}

	/**
	 * Whether a project file holds a string that NAMES `name`
	 * (`OccurrenceClass.StringLiteral`), or a `noqa` naming it, or cannot be read.
	 */
	private static function stringNamesIt(name: String, ctx: Context): Bool {
		for (entry in ctx.project) if (entry.source.indexOf(name) >= 0) {
			final found: Null<Array<ClassifiedOccurrence>> = OccurrenceScan.classifyOccurrences(
				entry.source, name, ctx.plugin, 0, entry.source.length, []
			);
			if (found == null || found.exists(occ ->
				occ.kind == OccurrenceClass.StringLiteral || occ.kind == OccurrenceClass.DirectiveComment
			))
				return true;
		}
		return false;
	}

	/** Note `reason` on `v` and answer no edit set. */
	private static function refuse(v: Violation, reason: String): Null<RiskyCrossFileEdit> {
		RenameRefusal.note(v, reason);
		return null;
	}

}

/** What every gate of one `edits` call reads, gathered once. */
private typedef Context = {
	final files: Array<{ file: String, source: String }>;

	/** Every project source, the run's own files at their current text. */
	final project: Array<{ file: String, source: String }>;
	final plugin: GrammarPlugin;
	final support: NamingSupport;
	final shape: RefShape;

	/** The resolution index (report UNION libraries), or the report index without a scope. */
	final index: SymbolIndex;

	/** The reflection surface over the run's files and the resolution sources. */
	final surface: ReflectionSurface;
};
