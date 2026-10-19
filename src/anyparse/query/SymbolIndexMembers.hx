package anyparse.query;

import anyparse.query.CallGraphNames.DeclaredParams;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndexBuilder.MemberSeams;
import anyparse.runtime.Span;

/**
 * The MEMBER half of `SymbolIndexBuilder`'s extraction: one type body walked into its
 * `MemberInfo` records — every member with its modifier run, annotations, written types and
 * initializer.
 *
 * Its own module because it is the one part of the extraction that reads a type's BODY: the
 * builder decides which declarations a file holds, guarded or not, with which imports and
 * supertypes, and hands each one here once. The kinds it reads arrive pre-resolved as one
 * `MemberSeams` (`memberSeamsOf`, once per run), so nothing here re-reads `RefShape` per type.
 */
@:nullSafety(Strict)
@:access(anyparse.query.SymbolIndexBuilder)
final class SymbolIndexMembers {

	/**
	 * The shorthand anon-structure field forms `name:T` / `?name:T`. Counted as members ONLY
	 * directly under an `Anon` — the same two kinds project a FUNCTION PARAMETER elsewhere, and
	 * a parameter is not a member of anything.
	 */
	private static final ANON_SHORT_FIELD_KINDS: Array<String> = ['Required', 'Optional'];

	/**
	 * The anon-structure field forms `var name:T;` / `final name:T;`, whose DECLARATION sits one
	 * node deeper than the member: the grammar wraps it in an optional-marker node (`var ?name:T`)
	 * that owns the name and the annotation. The span-info walk keys every type map on the node
	 * carrying the `type` field, so a lookup at the MEMBER's own span answers nothing for
	 * these two, and almost every indexed anon-struct member then reads as unannotated.
	 */
	private static final ANON_WRAPPED_FIELD_KINDS: Array<String> = ['VarField', 'FinalField'];

	/**
	 * The directly-declared members of the type rooted at `node` — every
	 * field-member-kind descendant (a type body's own `var`/`final`/`fn` members;
	 * a method's LOCAL vars are `VarStmt`, a different kind, so excluded) — paired
	 * with its getter-property flag from the `accessors` span map (absent = plain)
	 * and its modifier-run visibility / override / static / inline / macro info. Modifier
	 * siblings precede the member they attach to inside the same parent, so each
	 * visited node scans its CHILDREN with a running modifier state, reset at every
	 * member. The kind seams arrive pre-resolved as `seams`, so nothing here reads
	 * `RefShape` directly.
	 */
	public static function collectMembers(
		node: QueryNode, source: String, accessors: Map<Int, Bool>, writeAccessors: Map<Int, Bool>, returnTypes: Map<Int, String>,
		typeSources: Map<Int, String>, typeParams: Map<Int, Array<String>>, seams: MemberSeams
	): Array<MemberInfo> {
		// noqa: complexity
		final out: Array<MemberInfo> = [];
		MemberKinds.eachMemberHost(node, n -> {
			// `guarded` is a property of the HOST, not of the member's own modifier run:
			// `eachMemberHost` descends INTO a conditional-compilation region, so a member
			// written under `#if` is visited with that region as its host node.
			final guarded: Bool = seams.conditionalKind != null && n.kind == seams.conditionalKind;
			var runVisibility: Null<String> = null;
			var runOverride: Bool = false;
			var runStatic: Bool = false;
			var runInline: Bool = false;
			var runMacro: Bool = false;
			var runOperators: Array<String> = [];
			var runImplicitConversion: Bool = false;
			var runImplicitCall: Bool = false;
			var runImplicitMetas: Array<String> = [];
			var runDynamic: Bool = false;
			var runNoExtension: Bool = false;
			var runOverloadMeta: Bool = false;
			var runExtern: Bool = false;
			var runOverload: Bool = false;
			var runMetaNames: Array<String> = [];
			for (child in n.children) {
				final sp: Null<Span> = child.span;
				// Enum constructors (`SimpleCtor` / `ParamCtor`) are captured as members too, so a bare
				// `import pkg.Enum;` whose constructors are used as bare identifiers is not judged unused.
				// Enum-abstract values are already `FIELD_MEMBER_KINDS`.
				if (
					MemberKinds.isMemberDeclKind(child.kind)
					|| (n.kind == SymbolIndexBuilder.ANON_KIND && ANON_SHORT_FIELD_KINDS.contains(child.kind))
				) {
					final nm: Null<String> = child.name;
					if (nm != null && sp != null) {
						// Re-bind to a non-null local — Strict null-safety takes a struct
						// literal's field type from the declared type, not the narrowed one.
						final memberName: String = nm;
						final typeKey: Int = typeInfoKeyOf(child, sp);
						final init: Null<QueryNode> = initializerOf(child, seams);
						final initSpan: Null<Span> = init?.span;
						final params: DeclaredParams = CallGraphNames.paramsBy(
							child, typeSources, seams.paramKinds, seams.annotationKinds, seams.optionalParamKind, seams.restParamKind
						);
						out.push({
							name: memberName,
							hasGetter: accessors[typeKey] ?? false,
							hasSetter: writeAccessors[typeKey] ?? false,
							returnNominal: returnTypes[typeKey],
							returnSource: seams.functionKinds.contains(child.kind)
								? CallGraphNames.returnSourceOf(child, source, seams.annotationKinds)
								: null,
							typeSource: typeSources[typeKey],
							typeParamNames: typeParams[typeKey] ?? [],
							firstParamTypeSource: firstParamTypeSourceOf(child, typeSources, seams.paramKinds),
							paramTypeSources: params.params,
							paramSkippableFrom: params.skippableFrom,
							paramRest: params.rest,
							visibility: runVisibility,
							isOverride: runOverride,
							kind: child.kind,
							declFrom: sp.from,
							isStatic: runStatic,
							isInline: runInline,
							isMacro: runMacro,
							operatorOverloads: runOperators,
							initializerKind: initSpan == null ? null : init?.kind,
							initializerSource: initSpan == null ? null : source.substring(initSpan.from, initSpan.to),
							isImplicitConversion: runImplicitConversion,
							isImplicitCall: runImplicitCall,
							implicitCallMetas: runImplicitMetas,
							isDynamic: runDynamic,
							isExtern: runExtern,
							isOverload: runOverload,
							metaNames: runMetaNames,
							excludedFromExtensions: runNoExtension,
							hasOverloadMeta: runOverloadMeta,
							guarded: guarded,
							optional: n.kind == SymbolIndexBuilder.ANON_KIND && optionalField(child, runMetaNames, seams)
						});
					}
					runVisibility = null;
					runOverride = false;
					runStatic = false;
					runInline = false;
					runMacro = false;
					runOperators = [];
					runImplicitConversion = false;
					runImplicitCall = false;
					runImplicitMetas = [];
					runDynamic = false;
					runNoExtension = false;
					runOverloadMeta = false;
					runExtern = false;
					runOverload = false;
					runMetaNames = [];
				} else if (sp != null && seams.visibilityKinds.contains(child.kind))
					runVisibility = source.substring(sp.from, sp.to);
				else if (child.kind == seams.overrideKind)
					runOverride = true;
				else if (child.kind == seams.staticKind)
					runStatic = true;
				else if (child.kind == seams.inlineKind)
					runInline = true;
				else if (child.kind == seams.macroKind)
					runMacro = true;
				else if (child.kind == seams.dynamicKind)
					runDynamic = true;
				else if (child.kind == seams.externKind)
					runExtern = true;
				else if (child.kind == seams.overloadKind)
					runOverload = true;
				else {
					if (MemberKinds.META_KINDS.contains(child.kind) && child.name != null) runMetaNames.push(child.name ?? '');
					final operatorKind: Null<String> = operatorKindOf(child, seams);
					if (operatorKind != null) runOperators.push(operatorKind);
					if (isConversionMeta(child, seams)) runImplicitConversion = true;
					if (MemberKinds.META_KINDS.contains(child.kind) && seams.extensionExcludingMetaNames.contains(child.name ?? ''))
						runNoExtension = true;
					if (MemberKinds.META_KINDS.contains(child.kind) && child.name != null && child.name == seams.overloadMetaName)
						runOverloadMeta = true;
					if (isImplicitCallMeta(child, seams)) {
						runImplicitCall = true;
						runImplicitMetas.push(child.name ?? '');
					}
				}
			}
		});
		return out;
	}

	/**
	 * The `RefShape` kinds `collectMembers` reads, resolved ONCE per run rather than per
	 * type: the modifier siblings it recognises and the conditional-compilation host kind
	 * that marks a member `guarded`.
	 */
	public static function memberSeamsOf(shape: RefShape): MemberSeams {
		return {
			visibilityKinds: shape.visibilityModifierKinds ?? [],
			overrideKind: shape.overrideModifierKind,
			staticKind: shape.staticModifierKind,
			inlineKind: shape.inlineModifierKind,
			macroKind: shape.macroModifierKind,
			dynamicKind: shape.dynamicModifierKind,
			externKind: shape.externModifierKind,
			overloadKind: shape.overloadModifierKind,
			operatorMetaName: shape.operatorOverloadMetaName,
			overloadMetaName: shape.signatureOverloadMetaName,
			conversionMetaName: shape.execution?.implicitConversionMetaName,
			implicitCallMetaNames: shape.execution?.implicitCallMetaNames ?? [],
			extensionExcludingMetaNames: shape.execution?.extensionExcludingMetaNames ?? [],
			conditionalKind: shape.conditionalMemberKind,
			paramKinds: shape.paramKinds ?? [],
			optionalParamKind: shape.optionalParamKind,
			restParamKind: shape.restParamKind,
			optionalFieldMetaName: shape.optionalFieldMetaName,
			functionKinds: shape.functionKinds ?? [],
			fieldKinds: shape.fieldDeclKinds ?? [],
			annotationKinds: shape.typeAnnotationKinds ?? []
		};
	}

	/**
	 * The span offset the four type maps are keyed on for `member` — its own declaration span,
	 * except for the anon-structure `var` / `final` field kinds, whose declaration sits one node
	 * deeper (`ANON_WRAPPED_FIELD_KINDS`). The inner node must re-declare the SAME name, so an
	 * initializer or any other single child can never stand in for the declaration.
	 *
	 * `declFrom` deliberately keeps the MEMBER's own offset: it is a rename cursor, not a key
	 * into a type map.
	 */
	private static function typeInfoKeyOf(member: QueryNode, own: Span): Int {
		if (!ANON_WRAPPED_FIELD_KINDS.contains(member.kind)) return own.from;
		final decl: Null<QueryNode> = member.children[0];
		if (decl == null || decl.name != member.name) return own.from;
		final declSpan: Null<Span> = decl.span;
		return declSpan == null ? own.from : declSpan.from;
	}

	/**
	 * Whether the structure field `member` is optional: an `optionalParamKind` node itself (`?a: T`), or wrapping one that
	 * carries its name (`var ?a: T`, `ANON_WRAPPED_FIELD_KINDS`), or under the optional annotation among `metas`.
	 */
	private static function optionalField(member: QueryNode, metas: Array<String>, seams: MemberSeams): Bool {
		final kind: Null<String> = seams.optionalParamKind;
		final meta: Null<String> = seams.optionalFieldMetaName;
		if (kind == null) return meta != null && metas.contains(meta);
		final decl: Null<QueryNode> = ANON_WRAPPED_FIELD_KINDS.contains(member.kind) ? member.children[0] : member;
		return decl != null && decl.kind == kind && decl.name == member.name || meta != null && metas.contains(meta);
	}

	/** Whether `node` is an annotation under which the language calls the member implicitly (`MemberSeams.implicitCallMetaNames`). */
	private static function isImplicitCallMeta(node: QueryNode, seams: MemberSeams): Bool {
		return MemberKinds.META_KINDS.contains(node.kind) && seams.implicitCallMetaNames.contains(node.name ?? '');
	}

	/**
	 * The VERBATIM `:Type` source of `member`'s FIRST parameter — the type a `using` static
	 * extension accepts as its receiver — or null when it declares no parameter, the first one
	 * carries no annotation, or the member is not a function at all.
	 *
	 * Read off the SAME `declaredTypeSources` map the member's own `typeSource` comes from: a
	 * parameter is an ordinary typed binding, keyed by its declaration span. Only the first
	 * parameter is captured, because that is the only one a `using` gives a meaning to; the rest
	 * stay ordinary call arguments no cross-file query has ever asked about.
	 */
	private static function firstParamTypeSourceOf(
		member: QueryNode, typeSources: Map<Int, String>, paramKinds: Array<String>
	): Null<String> {
		for (child in member.children) if (paramKinds.contains(child.kind)) {
			final sp: Null<Span> = child.span;
			return sp == null ? null : typeSources[sp.from];
		}
		return null;
	}

	/**
	 * The node KIND the argument of the operator-overload annotation `meta` projects as —
	 * `@:op(A + B)` gives the grammar addition kind — or null when `meta` is not that annotation
	 * or does not carry exactly one argument.
	 *
	 * The KIND is what a consumer can compare against an operator node it is already holding, so
	 * neither the index nor the check ever spells an operator symbol; the grammar decides which
	 * form is which, including the two that share a symbol (`A - B` against `-A`).
	 */
	private static function operatorKindOf(meta: QueryNode, seams: MemberSeams): Null<String> {
		final metaName: Null<String> = seams.operatorMetaName;
		return metaName == null || meta.name != metaName || !SymbolIndexBuilder.isMetaNodeKind(meta.kind) || meta.children.length != 1
			? null
			: meta.children[0].kind;
	}

	/**
	 * Whether `meta` is the implicit-conversion annotation the grammar names — a `@:from` on an
	 * abstract member. Unlike `operatorKindOf` the ARGUMENT carries nothing a consumer needs: the
	 * question is only whether a conversion exists at all, so a bare tag and an argument-bearing
	 * one answer alike.
	 */
	private static function isConversionMeta(meta: QueryNode, seams: MemberSeams): Bool {
		final metaName: Null<String> = seams.conversionMetaName;
		return metaName != null && meta.name == metaName && SymbolIndexBuilder.isMetaNodeKind(meta.kind);
	}

	/**
	 * The initializer of the FIELD member `member` — its last child when that child is not a type
	 * annotation — or null for a field written without one and for every non-field member (a function's
	 * last child is its body, an enum constructor's its last parameter).
	 */
	private static function initializerOf(member: QueryNode, seams: MemberSeams): Null<QueryNode> {
		if (!seams.fieldKinds.contains(member.kind) || member.children.length == 0) return null;
		final last: QueryNode = member.children[member.children.length - 1];
		return seams.annotationKinds.contains(last.kind) ? null : last;
	}

}
