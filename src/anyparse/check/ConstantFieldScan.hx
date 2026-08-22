package anyparse.check;

import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.runtime.Span;

using StringTools;

/**
 * The seams and scans the CONSTANT-FIELD pair of checks share — `inline-constant` (`static final`
 * scalar -> `static inline final`) and `static-constant` (instance `final` of a literal ->
 * `static final`). The two ask the same questions of the grammar (which kinds host a `final` field,
 * which modifier means `static`, which literals are compile-time constants), and both act by
 * inserting a keyword before a member's `final`.
 *
 * The other question they share is not here: which names a runtime `Reflect` call might spell is
 * `CheckScan.reflectionSurface`, asked by four checks rather than by this pair alone.
 *
 * They are separate checks because they move a field in opposite directions and gate on completely
 * different soundness proofs; this module is the part that is genuinely one question, resolved once.
 */
@:nullSafety(Strict)
final class ConstantFieldScan {

	/**
	 * Every seam the constant-field checks read, or null when a required one is unset — the
	 * grammar-agnostic gate that makes a check a no-op for a language that does not describe
	 * fields, visibility or compile-time literals. Each consumer then reads the subset it needs.
	 */
	public static function seams(plugin: GrammarPlugin): Null<ConstantFieldSeams> {
		final shape: RefShape = plugin.refShape();
		final containers: Array<String> = shape.visibilityContainerKinds ?? [];
		final members: Array<String> = shape.memberDeclKinds ?? [];
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final mutable: Array<String> = shape.mutableFieldDeclKinds ?? [];
		final visibility: Array<String> = shape.visibilityModifierKinds ?? [];
		final defaultVis: Null<String> = shape.defaultVisibilityModifierText;
		final staticKind: Null<String> = shape.staticModifierKind;
		final literalKinds: Array<String> = shape.inlineConstantLiteralKinds ?? [];
		if (
			containers.length == 0 || members.length == 0 || fieldKinds.length == 0 || visibility.length == 0 || defaultVis == null
			|| staticKind == null || literalKinds.length == 0
		)
			return null;
		final finalFieldKinds: Array<String> = [for (k in fieldKinds) if (!mutable.contains(k)) k];
		return finalFieldKinds.length == 0 ? null : {
			containers: containers,
			classLikeContainers: RefactorSupport.classLikeContainerKinds(shape),
			members: members,
			finalFieldKinds: finalFieldKinds,
			mutableFieldKinds: mutable,
			visibility: visibility,
			defaultVis: defaultVis,
			staticKind: staticKind,
			inlineKind: shape.inlineModifierKind,
			identKind: shape.identKind,
			metaKinds: plugin.metaShape().metaKinds,
			nativeInteropMetaName: shape.nativeInteropDeclMetaName,
			retainedMetaName: shape.retainedDeclMetaName,
			reflectedMetaName: shape.reflectedDeclMetaName,
			implicitConstructorMetaName: shape.implicitConstructorDeclMetaName,
			literalKinds: literalKinds,
			stringLiteralKinds: shape.stringLiteralKinds ?? [],
			numericKinds: shape.numericLiteralKinds ?? [],
			negationKind: shape.negationKind,
			stringFold: plugin.stringFoldSupport()
		};
	}

	/** A member host's initializer — its last child (the value expression; the type annotation is not a child). */
	public static function initializerOf(field: QueryNode): Null<QueryNode> {
		final count: Int = field.children.length;
		return count >= 1 ? field.children[count - 1] : null;
	}

	/** Whether `child` (a visibility modifier) is a non-default (exported) keyword — `public` rather than the private default. */
	public static function isExportedVisibility(source: String, child: QueryNode, defaultVis: String): Bool {
		final span: Null<Span> = child.span;
		return span != null && source.substring(span.from, span.to).trim() != defaultVis;
	}

	/** Whether `init` is a basic scalar literal in `inlineConstantLiteralKinds`, or a negation wrapping a numeric one (`-5`). */
	public static function isScalarLiteral(init: QueryNode, seams: ConstantFieldSeams): Bool {
		return seams.literalKinds.contains(init.kind) || seams.negationKind != null && init.kind == seams.negationKind
			&& init.children.length == 1 && seams.numericKinds.contains(init.children[0].kind);
	}

}

/**
 * The resolved grammar seams the constant-field checks read. A superset — `inline-constant` reads
 * `containers` / `mutableFieldKinds` / `identKind`, `static-constant` reads `classLikeContainers`
 * (an `enum abstract` value is not an instance field) — so one resolution serves both.
 */
typedef ConstantFieldSeams = {
	final containers: Array<String>;
	final classLikeContainers: Array<String>;
	final members: Array<String>;
	final finalFieldKinds: Array<String>;
	final mutableFieldKinds: Array<String>;
	final visibility: Array<String>;
	final defaultVis: String;
	final staticKind: String;
	final inlineKind: Null<String>;
	final identKind: String;
	final metaKinds: Array<String>;

	/** `RefShape.nativeInteropDeclMetaName` — read by `inline-constant` alone; null when the grammar leaves it unset. */
	final nativeInteropMetaName: Null<String>;

	/**
	 * `RefShape.retainedDeclMetaName` — the declaration is pinned against removal, so machinery no
	 * source scan models reaches its members. Both checks decline it.
	 */
	final retainedMetaName: Null<String>;

	/**
	 * `RefShape.reflectedDeclMetaName` — the declaration's member NAMES are runtime data. Both checks
	 * decline it, for a different reason than `retainedMetaName`: retention keeps the member, this
	 * keeps its NAME meaningful, and both rewrites move where the value lives.
	 */
	final reflectedMetaName: Null<String>;

	/**
	 * `RefShape.implicitConstructorDeclMetaName` — the declaration's fields ARE its constructor's
	 * parameters. Read by `static-constant` alone: moving a field off the instance deletes an
	 * argument every construction site is written against. `inline-constant` leaves the field where
	 * it is, so it takes no such gate.
	 */
	final implicitConstructorMetaName: Null<String>;

	final literalKinds: Array<String>;
	final stringLiteralKinds: Array<String>;
	final numericKinds: Array<String>;
	final negationKind: Null<String>;
	final stringFold: Null<StringFoldSupport>;
};
