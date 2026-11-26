package anyparse.check.haxe.expressions;

import anyparse.query.NodeShape;
import anyparse.query.ParseGate;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeSyntax.TypeSyntaxReader;

using anyparse.util.Arrays;

/** The constructor arguments a copy method of a type passes, in order, and the method's name. */
typedef InferredCopy = { final copy: String; final fields: Array<String>; }

/** The node kinds and names the proof reads off the grammar's `RefShape`. */
private typedef Shapes = {
	final classKinds: Array<String>;
	final methodKinds: Array<String>;
	final fieldKinds: Array<String>;
	final paramKinds: Array<String>;
	final constructorName: String;
	final selfName: String;
	final identKind: String;
	final fieldAccessKind: String;
	final newKind: String;
	final blockKind: String;
	final exprStmtKind: String;
	final assignKind: String;
	final returnKind: String;
}

/**
 * The one answer to "which constructor and copy method of a type does its own source prove a copy": the type's only
 * constructor is `this.f_i = p_i` over all its parameters and one method returns `new T(f_1, …, f_n)` over the same fields in
 * the constructor's parameter order, so `t.copy()` and `new T(t.f_1, …, t.f_n)` build the same value.
 *
 * Refused, so the answer is null: a type that is private, extern, generic, guarded by a condition, or touched by a build
 * macro; a constructor that is not alone, has an optional, defaulted or rest parameter, or does anything beyond those
 * assignments; a field that is static, a property, or typed differently from its parameter; a copy method that is not the one
 * proven method (two proven ones leave no single name to rewrite to). A type whose source the index does not retain is not
 * proven.
 */
@:nullSafety(Strict)
final class CopyPairInference {

	private static final PUBLIC_VISIBILITY: String = 'public';

	/** The copy method and constructor fields `type`'s source proves, or null when it proves none. */
	public static function of(type: ResolvedType, plugin: GrammarPlugin, index: SymbolIndex): Null<InferredCopy> {
		final shapes: Null<Shapes> = shapesOf(plugin.refShape());
		final info: TypeDeclInfo = type.type;
		if (shapes == null || !shapes.classKinds.contains(info.kind) || !isPlain(info)) return null;
		final ctors: Array<MemberInfo> = info.members.filter(m -> m.name == shapes.constructorName);
		if (ctors.length != 1 || !isPlainConstructor(ctors[0], shapes)) return null;
		final source: Null<String> = index.sourceOf(type.file.file);
		final root: Null<QueryNode> = source == null ? null : ParseGate.parseOrNull(plugin, source);
		final ctor: Null<QueryNode> = root == null ? null : declAt(root, ctors[0]);
		final fields: Null<Array<String>> = ctor == null ? null : assignedFields(ctor, ctors[0], info, shapes);
		if (root == null || fields == null) return null;
		var found: Null<InferredCopy> = null;
		for (m in info.members) if (
			isCopyOf(m, info.name, shapes.methodKinds, plugin.typeSyntax) && info.members.filter(o -> o.name == m.name).length == 1
		) {
			final node: Null<QueryNode> = declAt(root, m);
			if (node == null || !returnsCopy(node, fields, type, index, shapes)) continue;
			if (found != null) return null;
			found = { copy: m.name, fields: fields };
		}
		return found;
	}

	/** Whether `m` is a public instance method with no parameters returning `type` (or unannotated), nothing that can be another method. */
	public static function isCopyOf(m: MemberInfo, type: String, methods: Array<String>, typeSyntax: TypeSyntaxReader): Bool {
		final returned: Null<String> = m.returnSource;
		return methods.contains(m.kind)
			&& !m.isStatic && m.visibility == PUBLIC_VISIBILITY && !m.guarded && !m.isMacro && !m.isDynamic && !m.isOverload
			&& !m.hasOverloadMeta && m.paramTypeSources.length == 0
			&& (returned == null || NominalTypes.outerNominalOf(returned, typeSyntax) == type);
	}

	private static inline function isPlain(info: TypeDeclInfo): Bool {
		return !info.isPrivate && !info.isExtern && !info.guarded && info.typeParamArity == 0 && !info.hasBuild && !info.hasAutoBuild
			&& !info.isMacroMade;
	}

	private static function isPlainConstructor(m: MemberInfo, shapes: Shapes): Bool {
		final count: Int = m.paramTypeSources.length;
		return shapes.methodKinds.contains(m.kind)
			&& count > 0 && m.paramSkippableFrom == count && !m.paramRest
			&& !m.paramTypeSources.contains(null)
			&& !m.guarded && !m.isMacro && !m.isOverload && !m.hasOverloadMeta && m.typeParamNames.length == 0;
	}

	/** The field each constructor parameter is stored in, in parameter order, or null when the body is anything but those stores. */
	private static function assignedFields(ctor: QueryNode, m: MemberInfo, info: TypeDeclInfo, shapes: Shapes): Null<Array<String>> {
		final params: Array<QueryNode> = ctor.children.filter(c -> shapes.paramKinds.contains(c.kind));
		final stmts: Array<QueryNode> = ctor.children.find(c -> c.kind == shapes.blockKind)?.children ?? [];
		if (params.length != m.paramTypeSources.length || stmts.length != params.length) return null;
		final byParam: Map<String, String> = [];
		for (stmt in stmts) {
			final assign: Null<QueryNode> = NodeShape.assignmentOf(stmt, shapes.exprStmtKind, shapes.assignKind);
			final field: Null<String> = assign == null ? null : selfField(assign.children[0], shapes);
			final value: Null<QueryNode> = assign?.children[1];
			final param: Null<String> = value == null || value.kind != shapes.identKind ? null : value.name;
			if (field == null || param == null) return null;
			byParam[param] = field;
		}
		final fields: Array<String> = [];
		for (i => param in params) {
			final field: Null<String> = byParam[param.name ?? ''];
			if (field == null || fields.contains(field) || !isPlainField(info, field, m.paramTypeSources[i], shapes)) return null;
			fields.push(field);
		}
		return fields;
	}

	/** Whether `info` declares `name` once, as an instance field with no accessor code and the written type `written`. */
	private static function isPlainField(info: TypeDeclInfo, name: String, written: Null<String>, shapes: Shapes): Bool {
		final found: Array<MemberInfo> = info.members.filter(m -> m.name == name);
		return found.length == 1
			&& shapes.fieldKinds.contains(found[0].kind)
			&& !found[0].hasGetter
			&& !found[0].hasSetter
			&& !found[0].guarded
			&& written != null
			&& found[0].typeSource == written;
	}

	/** Whether the method body is the one statement `return new T(f_1, …, f_n)` over `fields`, each read bare or off `this`. */
	private static function returnsCopy(
		method: QueryNode, fields: Array<String>, type: ResolvedType, index: SymbolIndex, shapes: Shapes
	): Bool {
		final stmts: Array<QueryNode> = method.children.find(c -> c.kind == shapes.blockKind)?.children ?? [];
		final made: Null<QueryNode> = stmts.length == 1 ? NodeShape.returnValueOf(stmts[0], shapes.returnKind) : null;
		final span: Null<Span> = made?.span;
		if (
			made == null || span == null || made.kind != shapes.newKind || made.name != type.type.name
			|| made.children.length != fields.length
		)
			return false;
		final named: Null<ResolvedType> = index.refs.resolveTypeRef(type.type.name, type.file, span.from);
		if (named == null || index.refs.seenKey(named) != index.refs.seenKey(type)) return false;
		for (i => field in fields) {
			final arg: QueryNode = made.children[i];
			if ((arg.kind == shapes.identKind ? arg.name : selfField(arg, shapes)) != field) return false;
		}
		return true;
	}

	/** The field a `this.f` access names, or null for anything else. */
	private static function selfField(node: QueryNode, shapes: Shapes): Null<String> {
		final owner: Null<QueryNode> = node.children[0];
		return node.kind == shapes.fieldAccessKind && node.children.length == 1 && owner != null && owner.kind == shapes.identKind
			&& owner.name == shapes.selfName
			? node.name
			: null;
	}

	private static function declAt(node: QueryNode, member: MemberInfo): Null<QueryNode> {
		return node.kind == member.kind && node.name == member.name && node.span?.from == member.declFrom
			? node
			: node.children.findMap(c -> declAt(c, member));
	}

	private static function shapesOf(shape: RefShape): Null<Shapes> {
		final classKinds: Null<Array<String>> = shape.classDeclKinds;
		final fieldKinds: Null<Array<String>> = shape.fieldDeclKinds;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final constructorName: Null<String> = shape.constructorName;
		final selfName: Null<String> = shape.selfReferenceText;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final newKind: Null<String> = shape.newExprKind;
		final blockKind: Null<String> = shape.blockBodyKind;
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		final returnKind: Null<String> = shape.returnStatementKind;
		return classKinds == null || fieldKinds == null || paramKinds == null || constructorName == null || selfName == null
			|| fieldAccessKind == null || newKind == null || blockKind == null || exprStmtKind == null || assignKind == null
			|| returnKind == null
			? null
			: {
				classKinds: classKinds,
				methodKinds: ShapeVocab.methodDeclKinds(shape),
				fieldKinds: fieldKinds,
				paramKinds: paramKinds,
				constructorName: constructorName,
				selfName: selfName,
				identKind: shape.identKind,
				fieldAccessKind: fieldAccessKind,
				newKind: newKind,
				blockKind: blockKind,
				exprStmtKind: exprStmtKind,
				assignKind: assignKind,
				returnKind: returnKind
			};
	}

}
