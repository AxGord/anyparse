package anyparse.check.haxe.loops;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.common.expressions.PreferBind;
import anyparse.check.haxe.loops.MappedComprehension.ComprehensionSeams;
import anyparse.check.haxe.loops.MappedComprehension.Mapping;
import anyparse.check.scan.RunScan;
import anyparse.query.NominalTypes;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeSyntax;

/**
 * Flags a map that hands every element back unchanged — `xs.map(x -> x)`, `xs.map(x -> (x : T))`, `[for (x in xs) x]`,
 * `[for (x in xs) (x : T)]` — and rewrites it to what it says. `Severity.Info`.
 *
 * A bare binder is a copy of the array: `xs.copy()`. An ascribed binder only widens the element type, so it is the
 * ascription of the array itself, `(xs : Array<T>)`; both stay `Array`-typed and run no closure. A map returns a NEW
 * array, so the result may be mutated without touching `xs`: the rewrite appends `.copy()` unless a call that builds a
 * new array (`concat`, `map`, `filter`, `slice`) or only reads one (`join`, `contains`, `indexOf`, `lastIndexOf`) follows;
 * an iterable that is itself a call keeps it, since a method may hand back an array it holds. The iterable must be an `Array` whose
 * element type is written (`RefShape.arrayTypeNames`), and a comment in the text the rewrite drops keeps the finding report-only.
 *
 * `RiskyFix`: only a typecheck tells a widening from a real conversion. `Array<Sub>` does not unify with `Array<Super>`
 * and an abstract converting through `@:to` is not its target, so the compiler oracle refuses those rewrites. It cannot
 * tell the value types, which Haxe unifies as `Array<Null<Int>>` while a static target lays the two arrays out
 * differently, so a map is left alone, finding and fix, when the iterable's element or the ascribed type is `Int` / `Float`
 * / `Bool` (`RefShape.nonNullableTypeNames`), bare or under `Null<…>`, or an abstract or alias over one (`overValueType`).
 * A type name the index does not hold counts as a reference type.
 * Without an oracle the rule is report-only. `DefaultOff`: opted in with `"identity-map": { "enabled": true }`.
 */
@:nullSafety(Strict)
final class IdentityMap extends HaxeRule implements DefaultOff implements RiskyFix {

	private static inline final RULE_ID: String = 'identity-map';
	private static inline final MAP_METHOD: String = 'map';

	/** How many abstract-over-abstract or alias hops a type is followed through before it counts as unproven. */
	private static inline final ALIAS_HOPS: Int = 8;

	private static final MESSAGE_COPY: String = 'this map hands every element back unchanged — it is a copy of the array';
	private static final MESSAGE_WIDEN: String = 'this map only widens the element type — the array itself can carry the ascription';
	private static final COPY_METHOD: String = 'copy';
	private static final ARRAY_TYPE: String = 'Array';

	/** The array methods whose result is a new array, so a map feeding one needs no copy of its own. */
	private static final NEW_ARRAY_METHODS: Array<String> = ['concat', MAP_METHOD, 'filter', 'slice'];

	/** The array methods that only read the array, so what they read it from cannot be mutated through their result. */
	private static final READING_METHODS: Array<String> = ['join', 'contains', 'indexOf', 'lastIndexOf'];

	public function new() {
		super(RULE_ID, 'a map handing every element back unchanged, replaceable with xs.copy() or (xs : Array<T>)', RuleCategory.Loops);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: String -> Null<SymbolIndex> = PreferBind.coveringIndex(files, plugin);
		return RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, violations) -> {
			for (m in matches(tree, entry.file, entry.source, seams, plugin, index)) violations.push({
				file: entry.file,
				span: m.edit.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: m.widens ? MESSAGE_WIDEN : MESSAGE_COPY
			});
		});
	}

	/** Rewrite each flagged map to the array, copied or ascribed. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final file: String = violations[0].file;
		return CheckScan.applyTextMatches(
			plugin, source, violations,
			(tree, text) ->
				matches(tree, file, text, seams, plugin, PreferBind.coveringIndex([{
					file: file,
					source: source
				}], plugin, index)).map(m -> m.edit)
		);
	}

	/** Every identity map under `tree` with its rewrite; one inside a flagged map's iterable is the next `--fix` pass. */
	private static function matches(
		tree: QueryNode, file: String, source: String, seams: Seams, plugin: GrammarPlugin, index: String -> Null<SymbolIndex>
	): Array<Match> {
		final out: Array<Match> = [];
		var typing: Null<Typing> = null;
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			if (seams.opaqueKinds.contains(node.kind)) return;
			final hit: Null<Hit> = identityOf(node, seams);
			final span: Null<Span> = node.span;
			if (hit != null && span != null) {
				final at: Span = span;
				typing ??= typingOf(tree, file, source, plugin, index(file));
				final ty: Null<Typing> = typing;
				if (ty != null && provesIdentity(hit, at, source, ty, seams)) {
					final typeSpan: Null<Span> = hit.typeSpan;
					final iterable: String = source.substring(hit.iterableSpan.from, hit.iterableSpan.to);
					final base: String = typeSpan == null
						? iterable
						: '($iterable : $ARRAY_TYPE<${source.substring(typeSpan.from, typeSpan.to)}>)';
					final held: Bool = copiedByParent(node, parent, seams);
					out.push({ edit: { span: at, text: held ? base : '$base.$COPY_METHOD()' }, widens: typeSpan != null });
					return;
				}
			}
			for (c in node.children) walk(c, node);
		}
		walk(tree, null);
		return out;
	}

	/** The iterable and the ascription when `node` maps each element to itself, or to itself ascribed; else null. */
	private static function identityOf(node: QueryNode, s: Seams): Null<Hit> {
		final loop: Null<Mapping> = MappedComprehension.of(node, s.comprehension);
		if (loop != null) return identityBody(loop.iterable, loop.iterableSpan, loop.body, loop.binder, s);
		if (node.kind != s.callKind || node.children.length != 2) return null;
		final callee: QueryNode = node.children[0];
		final lambda: QueryNode = node.children[1];
		if (
			callee.kind != s.fieldAccessKind
			|| callee.name != MAP_METHOD
			|| callee.children.length != 1
			|| !s.lambdaKinds.contains(lambda.kind)
			|| lambda.children.length != 2
		)
			return null;
		final param: QueryNode = lambda.children[0];
		final binder: Null<String> = param.name;
		final iterable: QueryNode = callee.children[0];
		final iterableSpan: Null<Span> = iterable.span;
		return binder == null
			|| iterableSpan == null
			|| !s.requiredParamKinds.contains(param.kind)
			|| param.children.length > 0
			|| param.type != null
			? null
			: identityBody(iterable, iterableSpan, lambda.children[1], binder, s);
	}

	private static function identityBody(iterable: QueryNode, iterableSpan: Span, body: QueryNode, binder: String, s: Seams): Null<Hit> {
		if (MappedComprehension.isBinder(body, binder, s.comprehension))
			return { iterable: iterable, iterableSpan: iterableSpan, typeSpan: null };
		final typeSpan: Null<Span> = body.type?.span;
		return body.kind == s.checkTypeKind
			&& body.children.length == 1
			&& MappedComprehension.isBinder(body.children[0], binder, s.comprehension)
			&& typeSpan != null
			? { iterable: iterable, iterableSpan: iterableSpan, typeSpan: typeSpan }
			: null;
	}

	/** Whether `node` is the receiver of a call that builds a new array of its own. */
	private static function copiedByParent(node: QueryNode, parent: Null<QueryNode>, s: Seams): Bool {
		return parent != null
			&& parent.kind == s.fieldAccessKind
			&& (NEW_ARRAY_METHODS.contains(parent.name ?? '') || READING_METHODS.contains(parent.name ?? ''))
			&& parent.children.length > 0
			&& parent.children[0] == node;
	}

	/**
	 * Whether the ascribed element type is a value type (`Int`, `Null<Int>`, …) or cannot be read: the compiler unifies
	 * `Array<Int>` with `Array<Null<Int>>`, but the two are laid out differently on a static target.
	 */
	private static function holdsValueType(typeText: String, from: Int, ty: Typing, s: Seams): Bool {
		final syntax: Null<TypeSyntax> = s.typeSyntax(typeText);
		if (syntax == null) return true;
		return switch (syntax.wrapped(s.nullWrapperNames) ?? syntax).shape {
			case Nominal(path, _): overValueType(path, ty.file, from, ty.index, s, ALIAS_HOPS);
			case _: false;
		};
	}

	/** Whether the text the rewrite drops — everything of the map but its iterable and the ascribed type — holds a comment. */
	private static function droppedTextHoldsComment(whole: Span, hit: Hit, source: String): Bool {
		final typeSpan: Null<Span> = hit.typeSpan;
		return CheckScan.regionHoldsComment(source, whole, typeSpan == null ? [hit.iterableSpan] : [hit.iterableSpan, typeSpan]);
	}

	/** The seams the rule reads, or null when one it cannot do without is unset. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final fieldKind: Null<String> = shape.fieldAccessKind;
		final checkKind: Null<String> = shape.checkTypeKind;
		final arrayTypes: Null<Array<String>> = shape.arrayTypeNames;
		final comprehension: Null<ComprehensionSeams> = MappedComprehension.seamsOf(shape);
		final callKind: Null<String> = shape.callKind;
		final lambdaKinds: Null<Array<String>> = shape.lambdaKinds;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		if (
			comprehension == null
			|| callKind == null
			|| fieldKind == null
			|| checkKind == null
			|| arrayTypes == null
			|| lambdaKinds == null
			|| paramKinds == null
		)
			return null;
		final functionForms: Array<Null<String>> = [shape.fnExprKind, shape.namedFnExprKind];
		return {
			comprehension: comprehension,
			callKind: callKind,
			fieldAccessKind: fieldKind,
			checkTypeKind: checkKind,
			arrayTypeNames: arrayTypes,
			opaqueKinds: shape.opaqueKinds ?? [],
			lambdaKinds: lambdaKinds.filter(k -> !functionForms.contains(k)),
			requiredParamKinds: paramKinds.filter(k -> k != shape.optionalParamKind && k != shape.restParamKind),
			valueTypeNames: shape.nonNullableTypeNames ?? [],
			elementParams: shape.indexedElementTypeParams ?? [],
			nullWrapperNames: shape.nullableWrapperTypeNames ?? [],
			typeSyntax: plugin.typeSyntax
		};
	}

	/**
	 * Whether the type `path`, read at `from`, is a value type or an abstract or alias over one. A name the index does not
	 * hold is a built-in or a library type, which the value-type names already cover.
	 */
	private static function overValueType(
		path: String, file: Null<FileInfo>, from: Int, index: Null<SymbolIndex>, s: Seams, hops: Int
	): Bool {
		if (s.valueTypeNames.contains(path)) return true;
		if (file == null || index == null || hops == 0) return true;
		for (r in index.refs.resolveTypeRefAll(path, file, from)) {
			final next: Null<String> = r.type.underlyingRaw ?? r.type.aliasTargetNominal;
			if (next != null && overValueType(next, r.file, r.type.span.from, index, s, hops - 1)) return true;
		}
		return false;
	}

	/**
	 * Whether the map is provably an identity over an `Array` whose elements are not value types: the iterable resolves to an
	 * `Array` whose element type is written and is no value type, the ascribed type is no value type, and the rewrite drops
	 * no comment.
	 */
	private static function provesIdentity(hit: Hit, whole: Span, source: String, ty: Typing, s: Seams): Bool {
		final typeSpan: Null<Span> = hit.typeSpan;
		final written: Null<String> = ty.written(hit.iterable);
		final element: Null<String> = written == null ? null : NominalTypes.elementTypeSourceOf(written, s.elementParams, [], s.typeSyntax);
		return s.arrayTypeNames.contains(ty.nominal(hit.iterable) ?? '')
			&& element != null
			&& !holdsValueType(element, whole.from, ty, s)
			&& (typeSpan == null || !holdsValueType(source.substring(typeSpan.from, typeSpan.to), whole.from, ty, s))
			&& !droppedTextHoldsComment(whole, hit, source);
	}

	/** The typing the rule asks of a file: the nominal and the written type of an expression, and the index its names resolve in. */
	private static function typingOf(
		tree: QueryNode, file: String, source: String, plugin: GrammarPlugin, index: Null<SymbolIndex>
	): Null<Typing> {
		final nominal: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, file, index, true);
		final written: Null<(QueryNode) -> Null<String>> = CheckScan.typeSourceResolver(source, plugin, tree, file, index);
		return nominal == null || written == null ? null : {
			nominal: nominal,
			written: written,
			index: index,
			file: index?.fileInfo(file)
		};
	}

}

/** The grammar kinds and readers `IdentityMap` uses; the comprehension's own four are `MappedComprehension`'s. */
private typedef Seams = {
	final comprehension: ComprehensionSeams;
	final callKind: String;
	final fieldAccessKind: String;
	final checkTypeKind: String;
	final arrayTypeNames: Array<String>;
	final opaqueKinds: Array<String>;
	final lambdaKinds: Array<String>;
	final requiredParamKinds: Array<String>;
	final valueTypeNames: Array<String>;
	final elementParams: Map<String, Int>;
	final nullWrapperNames: Array<String>;
	final typeSyntax: TypeSyntaxReader;
};

/** One identity map: the array it copies and, when the body ascribes the element, where that type is written. */
private typedef Hit = { final iterable: QueryNode; final iterableSpan: Span; final typeSpan: Null<Span>; };

/** A finding's edit — its span and the text that replaces it — and whether the map widens a type or only copies. */
private typedef Match = { final edit: FixEdit; final widens: Bool; };
/** What `IdentityMap` asks of one file: the nominal and written type of an expression, and the index its type names resolve in. */
private typedef Typing = {
	final nominal: (QueryNode) -> Null<String>;
	final written: (QueryNode) -> Null<String>;
	final index: Null<SymbolIndex>;
	final file: Null<FileInfo>;
};
