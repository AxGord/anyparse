package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.format.text.UnknownPolicy;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using Lambda;

/**
 * Pass 1 of the macro pipeline — shape analysis. Turns a
 * `haxe.macro.Type` into a map of top-level rule name → `ShapeNode`.
 *
 * The algorithm is a worklist walk: starting from the root type
 * (normally the enum annotated with `@:build`), any referenced named
 * type that we have not shaped yet is enqueued and processed in turn.
 * Self-references (e.g. `Array<JValue>` inside `JValue`) resolve to a
 * `Ref` node so we never recurse into the type currently being built.
 *
 * Shapes produced:
 *
 *  | Haxe form                  | ShapeKind | notes                            |
 *  |----------------------------|-----------|----------------------------------|
 *  | `enum`                     | `Alt`     | one `Seq` child per constructor  |
 *  | `typedef` to anon          | `Seq`     | one child per anonymous field    |
 *  | `abstract` with `@:re`     | `Terminal`| underlying primitive in meta     |
 *  | primitive (`Bool`/`Int`/…) | `Terminal`| type name in `base.underlying`   |
 *  | `Array<T>`                 | `Star`    | one child = shape of `T`         |
 *  | `Map<String, V>`           | `Star`    | value rule in `base.mapValue`    |
 *  | reference to named type    | `Ref`     | name in `base.ref`               |
 *
 * Annotations produced on nodes (always under the `base.*` namespace):
 *
 *  - `base.ctor`        — constructor name on each enum-branch Seq
 *  - `base.typePath`    — full type path of the owning enum/struct
 *  - `base.fieldName`   — field/arg name on each leaf or Ref child
 *  - `base.fieldType`   — the `ComplexType` of the field, for code-
 *                         generation of return-struct literals
 *  - `base.ref`         — referenced rule name on `Ref` nodes
 *  - `base.mapValue`    — value rule name on a `Map<String, V>` Star
 *  - `base.underlying`  — underlying type name on `Terminal` nodes
 *                         (`"String"`, `"Float"`, `"Bool"`, …)
 *  - `base.meta`        — raw `Metadata` array attached to the enclosing
 *                         declaration (enum ctor, anon field, abstract) —
 *                         consumed by strategies in pass 2
 */
class ShapeBuilder {

	private final _pending: Array<{ name: String, type: Type }> = [];
	private final _shaped: Map<String, ShapeNode> = [];
	private final _inFlight: Array<String> = [];
	private final _formatInfo: Null<FormatReader.FormatInfo>;

	private var _rootName: String = '';

	public function new(?formatInfo: FormatReader.FormatInfo) {
		_formatInfo = formatInfo;
	}

	public function build(root: Type): ShapeResult {
		_rootName = qualifiedName(root);
		enqueue(_rootName, root);
		// Format-declared utility types that Lowering emits calls to
		// from generated code — enqueue eagerly so the rules exist
		// even when no user field references them directly:
		//   - `anyType` is called from the ByName loop's unknown-key
		//     branch (when `onUnknown == Skip`).
		//   - `stringType` is called for every mapping key in the
		//     ByName loop, and by `lowerStringEnumTerminal`. Primitive
		//     type mappings for `intType`/`floatType`/`boolType`
		//     enqueue lazily from `shapeFieldType` when a field actually
		//     references them.
		if (_formatInfo != null) {
			if (_formatInfo.anyType != null && _formatInfo.onUnknown == UnknownPolicy.Skip) {
				final anyType: String = _formatInfo.anyType;
				enqueue(anyType, Context.getType(anyType));
			}
			if (_formatInfo.stringType != null) {
				final stringType: String = _formatInfo.stringType;
				enqueue(stringType, Context.getType(stringType));
			}
		}
		while (_pending.length > 0) {
			final job: { name: String, type: Type } = _pending.shift();
			if (_shaped.exists(job.name)) continue;
			_inFlight.push(job.name);
			final node: ShapeNode = shapeTop(job.type);
			_shaped[job.name] = node;
			_inFlight.pop();
		}
		return { root: _rootName, rules: _shaped };
	}

	private function enqueue(name: String, t: Type): Void {
		if (_shaped.exists(name)) return;
		if (_inFlight.indexOf(name) != -1) return;
		for (p in _pending) if (p.name == name) return;
		_pending.push({ name: name, type: t });
	}

	private function shapeTop(t: Type): ShapeNode {
		return switch t {
			case TEnum(ref, _): shapeEnum(ref.get());
			case TType(ref, _):
				final td: DefType = ref.get();
				shapeTypedef(td);
			case TAbstract(ref, _):
				shapeAbstract(ref.get());
			case _:
				Context.fatalError('ShapeBuilder: cannot shape top-level type: ${typeToString(t)}', Context.currentPos());
				throw 'unreachable';
		};
	}

	private function shapeEnum(e: EnumType): ShapeNode {
		final node: ShapeNode = new ShapeNode(Alt);
		node.annotations.set(AnnotationKeys.BASE_TYPE_PATH, typePathOfEnum(e));
		node.annotations.set(AnnotationKeys.BASE_META, e.meta.get());
		for (name in e.names) {
			final ef: EnumField = e.constructs.get(name);
			final branch: ShapeNode = new ShapeNode(Seq);
			branch.annotations.set(AnnotationKeys.BASE_CTOR, name);
			branch.annotations.set(AnnotationKeys.BASE_TYPE_PATH, typePathOfEnum(e));
			branch.annotations.set(AnnotationKeys.BASE_META, ef.meta.get());
			switch ef.type {
				case TFun(args, _):
					for (arg in args) branch.children.push(shapeField(arg.name, arg.t, null));
				case _:
					// nullary constructor — empty Seq
			}
			node.children.push(branch);
		}
		return node;
	}

	private function shapeTypedef(td: DefType): ShapeNode {
		final under: Type = Context.follow(td.type, true);
		return switch under {
			case TAnonymous(aref):
				final a: AnonType = aref.get();
				final node: ShapeNode = new ShapeNode(Seq);
				node.annotations.set(AnnotationKeys.BASE_TYPE_PATH, typePathOfDef(td));
				node.annotations.set(AnnotationKeys.BASE_META, td.meta.get());
				// AnonType.fields is NOT guaranteed to preserve source declaration
				// order — on some Haxe builds it comes back in hash/alphabetical
				// order. The JSON grammar's alphabetical order happened to match
				// its source order (`key` before `value`) so Phase 2 worked, but
				// HxClassDecl exposed the bug (`members` sorts before `name`).
				// Sort by source position explicitly so the parse sequence of
				// a typedef Seq always matches how the user wrote it.
				final sorted: Array<ClassField> = a.fields.copy();
				sorted.sort(function(x: ClassField, y: ClassField): Int {
					final px: Int = Context.getPosInfos(x.pos).min;
					final py: Int = Context.getPosInfos(y.pos).min;
					return px - py;
				});
				for (f in sorted) node.children.push(shapeField(f.name, f.type, f.meta.get()));
				node;
			case _:
				Context.fatalError('ShapeBuilder: typedef ${td.name} does not resolve to an anonymous structure', Context.currentPos());
				throw 'unreachable';
		};
	}

	private function shapeAbstract(a: AbstractType): ShapeNode {
		final node: ShapeNode = new ShapeNode(Terminal);
		node.annotations.set(AnnotationKeys.BASE_TYPE_PATH, typePathOfAbstract(a));
		node.annotations.set(AnnotationKeys.BASE_META, a.meta.get());
		node.annotations.set('base.underlying', primitiveName(a.type));
		final enumValues: Null<Array<{ name: String, value: String }>> = extractStringEnumValues(a);
		if (enumValues != null) {
			node.annotations.set('base.stringEnumValues', enumValues);
			// The string-enum decoder emits a call to the format's
			// `stringType` terminal to consume the literal before
			// dispatching to the matched enum value — enqueue it so
			// the generated parser contains the rule.
			if (_formatInfo != null && _formatInfo.stringType != null) {
				final st: String = _formatInfo.stringType;
				enqueue(st, Context.getType(st));
			}
		}
		return node;
	}

	private function primitiveRef(primName: String): Null<String> {
		return _formatInfo == null
			? null
			: switch primName {
				case 'Int': _formatInfo.intType;
				case 'Float': _formatInfo.floatType;
				case 'Bool': _formatInfo.boolType;
				case 'String': _formatInfo.stringType;
				case _: null;
			};
	}

	private function shapeField(fieldName: String, t: Type, meta: Null<Metadata>): ShapeNode {
		final child: ShapeNode = shapeFieldType(t);
		child.annotations.set(AnnotationKeys.BASE_FIELD_NAME, fieldName);
		child.annotations.set(AnnotationKeys.BASE_FIELD_TYPE, Context.toComplexType(t));
		if (meta != null) child.annotations.set(AnnotationKeys.BASE_META, meta);
		// Optionality must be documented on both axes so a reader of the
		// grammar source spots it without cross-referencing — `@:optional`
		// on the field AND `Null<T>` on the type. `shapeFieldType` marks
		// the child node when it unwraps a `Null<T>` wrapper; this check
		// enforces bidirectional agreement.
		final hasOptMeta: Bool = meta != null && meta.exists(e -> e.name == ':optional');
		final hasOptShape: Bool = child.annotations.get(AnnotationKeys.BASE_OPTIONAL) == true;
		if (hasOptShape && !hasOptMeta) {
			Context.fatalError('ShapeBuilder: field "$fieldName" has type Null<T> but is missing @:optional meta', Context.currentPos());
		}
		if (hasOptMeta && !hasOptShape) {
			Context.fatalError('ShapeBuilder: field "$fieldName" has @:optional but type is not Null<T>', Context.currentPos());
		}
		return child;
	}

	private function shapeFieldType(t: Type): ShapeNode {
		// Evaluate lazy types up front so downstream matchers never see
		// a `TLazy` thunk. Lazy resolution happens for fields whose
		// types reference other types in the same module / compilation
		// unit that haven't been fully typed yet — common for
		// forward-declared sibling typedefs under a shared `@:build`
		// invocation.
		switch t {
			case TLazy(f):
				return shapeFieldType(f());
			case _:
		}
		// Null<T> → unwrap + optional marker. `Null<T>` appears either
		// as `TAbstract(Null, [inner])` or `TType(Null, [inner])` in
		// macro types depending on Haxe version and context; unwrap
		// either form here so the rest of `shapeFieldType` sees the
		// inner type normally. The optionality is surfaced via a
		// `base.optional=true` annotation on the resulting node,
		// paired with the `@:optional` meta check in `shapeField`.
		switch t {
			case TAbstract(ref, params):
				final a: AbstractType = ref.get();
				if (a.pack.length == 0 && a.name == 'Null' && params.length == 1) {
					final inner: ShapeNode = shapeFieldType(params[0]);
					inner.annotations.set(AnnotationKeys.BASE_OPTIONAL, true);
					return inner;
				}
			case TType(ref, params):
				final d: DefType = ref.get();
				if (d.pack.length == 0 && d.name == 'Null' && params.length == 1) {
					final inner: ShapeNode = shapeFieldType(params[0]);
					inner.annotations.set(AnnotationKeys.BASE_OPTIONAL, true);
					return inner;
				}
			case _:
		}
		// Array<T> → Star
		switch t {
			case TInst(ref, params):
				final cl: ClassType = ref.get();
				if (cl.name == 'Array' && cl.pack.length == 0 && params.length == 1) {
					final inner: Type = params[0];
					final star: ShapeNode = new ShapeNode(Star);
					star.children.push(shapeFieldType(inner));
					return star;
				}
			case _:
		}
		// Map<String, V> → Star + `base.mapValue`. Modelled as a Star
		// (no new ShapeKind) so the exhaustive `case Star` sites across
		// the passes need no new arms. TriviaAnalysis and the strategy
		// annotate pass DO walk this node on every schema build — they
		// are harmless because every one of their marks gates on
		// `base.meta` tags a schema field never carries, not because
		// they skip it. The passes that would mis-handle a Map-marked
		// Star (transform / query-walker / plain writer Star paths) are
		// never pointed at ByName schemas today, and if one ever is,
		// the failure is LOUD: their generated code indexes the
		// String-keyed Map with an Int, a compile error — not silent
		// wrong output. Only the ByName parse lowering reads the mark
		// (key-value loop instead of a sequence loop); the ByName write
		// lowering fatal-errors on it (parse-only).
		final mapParams: Null<Array<Type>> = mapTypeParams(t);
		if (mapParams != null) return shapeMap(mapParams[0], mapParams[1]);
		// Std primitive abstracts (Bool/Int/Float/String) — inline Terminal,
		// do not try to shape them as stand-alone rules. BUT: if the
		// resolved format declares a grammar type for this primitive
		// (e.g. `JsonFormat.intType = anyparse.grammar.json.JIntLit`),
		// route the field through that Ref instead. This reuses the
		// format's decoding logic across every schema bound to the
		// format and keeps the JSON-family primitive decoders in one
		// place (the `@:re`-annotated terminal), rather than
		// duplicating them per generated parser.
		final prim: Null<String> = primitiveNameOrNull(t);
		if (prim != null) {
			final mapped: Null<String> = primitiveRef(prim);
			if (mapped != null) {
				final mappedType: Type = Context.getType(mapped);
				enqueue(mapped, mappedType);
				final node: ShapeNode = new ShapeNode(Ref);
				node.annotations.set(AnnotationKeys.BASE_REF, mapped);
				return node;
			}
			final term: ShapeNode = new ShapeNode(Terminal);
			term.annotations.set('base.underlying', prim);
			return term;
		}
		// Named types become Ref + enqueue
		final refName: Null<String> = qualifiedNameOrNull(t);
		if (refName != null) {
			enqueue(refName, t);
			final node: ShapeNode = new ShapeNode(Ref);
			node.annotations.set(AnnotationKeys.BASE_REF, refName);
			return node;
		}
		Context.fatalError('ShapeBuilder: unsupported field type: ${typeToString(t)}', Context.currentPos());
		throw 'unreachable';
	}

	/**
	 * `Map<String, V>` → a `Star` node carrying `base.mapValue` (the value
	 * rule's path) with the value's shape as its single child — the
	 * arbitrary-key counterpart of the `Array<T>` Star, consumed by the
	 * ByName lowering.
	 *
	 * String keys only: the mapping key is decoded by the format's
	 * `stringType` terminal, so a key of any other type has no decoder. The
	 * value must resolve to a named rule (`Ref`) for the same reason a
	 * ByName `Array<T>` element must — the loop body is a call to that
	 * rule's generated parse function.
	 */
	private function shapeMap(keyType: Type, valueType: Type): ShapeNode {
		if (primitiveNameOrNull(keyType) != 'String') {
			Context.fatalError('ShapeBuilder: Map key type must be String, got ${typeToString(keyType)}', Context.currentPos());
			throw 'unreachable';
		}
		final value: ShapeNode = shapeFieldType(valueType);
		final ref: Null<String> = value.kind == ShapeKind.Ref ? value.annotations.get(AnnotationKeys.BASE_REF) : null;
		if (ref == null) {
			Context.fatalError(
				'ShapeBuilder: Map value type must be a named grammar rule, got ${typeToString(valueType)}', Context.currentPos()
			);
			throw 'unreachable';
		}
		// The marker is a plain Bool — the value rule is single-sourced
		// from the Star's Ref child (`base.ref`), exactly where the
		// Array flavour reads its element. Parse-only for now: the
		// ByName WRITER path fatal-errors on a Map field, so declaring
		// one in a schema forecloses generating a writer for it until
		// that lands.
		final node: ShapeNode = new ShapeNode(Star);
		node.annotations.set(AnnotationKeys.BASE_MAP_VALUE, true);
		node.children.push(value);
		return node;
	}

	/**
	 * The `[K, V]` type parameters when `t` is a `Map`, else null. Matches both
	 * forms the compiler hands out: the top-level `Map` alias is a `typedef`
	 * (`TType`) over the `haxe.ds.Map` abstract (`TAbstract`), and an unfollowed
	 * field annotation arrives as the former.
	 */
	/**
	 * The `[K, V]` type params when `t` is a DIRECT `Map<K, V>`
	 * spelling — matched as BOTH `TType` (the top-level `Map` is a
	 * typedef alias over `haxe.ds.Map`, so a field annotation arrives
	 * that way) and `TAbstract` (`haxe.ds.Map` itself). A user typedef
	 * over Map (`typedef Bag = Map<String, JValue>`) has no params at
	 * the field and is NOT recognised — it falls through to the Ref
	 * path and fails on `haxe.ds.Map` there, same latent class as a
	 * typedef over `Array<T>`.
	 */
	private static function mapTypeParams(t: Type): Null<Array<Type>> {
		return switch t {
			case TType(ref, params) if (params.length == 2 && isMapPath(joinPack(ref.get().pack, ref.get().name))): params;
			case TAbstract(ref, params) if (params.length == 2 && isMapPath(joinPack(ref.get().pack, ref.get().name))): params;
			case _: null;
		};
	}

	private static inline function isMapPath(path: String): Bool {
		return path == 'Map' || path == 'haxe.ds.Map';
	}

	/**
	 * If `a` is an `enum abstract(String)` (new-style `enum` keyword or
	 * legacy `@:enum` meta), return the declared `name → value` pairs
	 * parsed from the impl class's static final fields. Returns `null`
	 * when the abstract is not an enum abstract or its underlying type
	 * isn't String — callers then fall through to the regex-based
	 * terminal path.
	 */
	private static function extractStringEnumValues(a: AbstractType): Null<Array<{ name: String, value: String }>> {
		if (primitiveNameOrNull(a.type) != 'String') return null;
		if (!a.meta.has(':enum')) return null;
		if (a.impl == null) return null;
		final impl: ClassType = a.impl.get();
		final values: Array<{ name: String, value: String }> = [];
		for (f in impl.statics.get()) if (!f.kind.match(FMethod(_))) {
			final texpr: Null<TypedExpr> = f.expr();
			if (texpr == null) continue;
			final s: Null<String> = extractStringConst(texpr);
			if (s == null) continue;
			values.push({ name: f.name, value: s });
		}
		return values.length == 0 ? null : values;
	}

	private static function extractStringConst(texpr: TypedExpr): Null<String> {
		return switch texpr.expr {
			case TConst(TString(s)): s;
			case TCast(inner, _): extractStringConst(inner);
			case TParenthesis(inner): extractStringConst(inner);
			case _: null;
		};
	}

	// -------- type-name helpers --------

	private static function qualifiedName(t: Type): String {
		final n: Null<String> = qualifiedNameOrNull(t);
		if (n == null) {
			Context.fatalError('ShapeBuilder: type has no qualified name: ${typeToString(t)}', Context.currentPos());
			throw 'unreachable';
		}
		return n;
	}

	private static function qualifiedNameOrNull(t: Type): Null<String> {
		return switch t {
			case TEnum(ref, _):
				final e: EnumType = ref.get();
				joinPack(e.pack, e.name);
			case TType(ref, _):
				final d: DefType = ref.get();
				joinPack(d.pack, d.name);
			case TAbstract(ref, _):
				final a: AbstractType = ref.get();
				isStdPrimitiveAbstract(a) ? null : joinPack(a.pack, a.name);
			case TInst(ref, _):
				final c: ClassType = ref.get();
				c.pack.length == 0 && c.name == 'String' ? null : joinPack(c.pack, c.name);
			case _: null;
		};
	}

	private static function primitiveName(t: Type): String {
		final n: Null<String> = primitiveNameOrNull(t);
		return n ?? 'unknown';
	}

	private static function primitiveNameOrNull(t: Type): Null<String> {
		return switch t {
			case TAbstract(ref, _):
				final a: AbstractType = ref.get();
				isStdPrimitiveAbstract(a) ? a.name : null;
			case TInst(ref, _):
				final c: ClassType = ref.get();
				if (c.pack.length == 0 && c.name == 'String')
					'String'
				else if (joinPack(c.pack, c.name) == 'haxe.io.Bytes')
					'Bytes'
				else
					null;
			case _: null;
		};
	}

	private static inline function isStdPrimitiveAbstract(a: AbstractType): Bool {
		return a.pack.length == 0 && (a.name == 'Bool' || a.name == 'Int' || a.name == 'Float');
	}

	private static function typePathOfEnum(e: EnumType): String return joinPack(e.pack, e.name);

	private static function typePathOfDef(d: DefType): String return joinPack(d.pack, d.name);

	private static function typePathOfAbstract(a: AbstractType): String return joinPack(a.pack, a.name);

	private static function joinPack(pack: Array<String>, name: String): String {
		return pack.length == 0 ? name : '${pack.join('.')}.$name';
	}

	private static function typeToString(t: Type): String {
		return try haxe.macro.TypeTools.toString(t) catch (_: haxe.Exception) 'unknown';
	}

}

/**
 * Result of a shape-analysis pass: the root rule name and a map of all
 * named rules the worklist discovered.
 */
typedef ShapeResult = {
	root: String,
	rules: Map<String, ShapeNode>
};
#end
