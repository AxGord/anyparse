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
 *  - `base.underlying`  — underlying type name on `Terminal` nodes
 *                         (`"String"`, `"Float"`, `"Bool"`, …)
 *  - `base.meta`        — raw `Metadata` array attached to the enclosing
 *                         declaration (enum ctor, anon field, abstract) —
 *                         consumed by strategies in pass 2
 */
class ShapeBuilder {

	private final pending:Array<{name:String, type:Type}> = [];
	private final shaped:Map<String, ShapeNode> = new Map();
	private final inFlight:Array<String> = [];
	private final formatInfo:Null<FormatReader.FormatInfo>;

	private var rootName:String = '';

	public function new(?formatInfo:FormatReader.FormatInfo) {
		this.formatInfo = formatInfo;
	}

	public function build(root:Type):ShapeResult {
		rootName = qualifiedName(root);
		enqueue(rootName, root);
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
		if (formatInfo != null) {
			if (formatInfo.anyType != null && formatInfo.onUnknown == UnknownPolicy.Skip) {
				final anyType:String = formatInfo.anyType;
				enqueue(anyType, Context.getType(anyType));
			}
			if (formatInfo.stringType != null) {
				final stringType:String = formatInfo.stringType;
				enqueue(stringType, Context.getType(stringType));
			}
		}
		while (pending.length > 0) {
			final job:{name:String, type:Type} = pending.shift();
			if (shaped.exists(job.name)) continue;
			inFlight.push(job.name);
			final node:ShapeNode = shapeTop(job.type);
			shaped.set(job.name, node);
			inFlight.pop();
		}
		return {root: rootName, rules: shaped};
	}

	private function enqueue(name:String, t:Type):Void {
		if (shaped.exists(name)) return;
		if (inFlight.indexOf(name) != -1) return;
		for (p in pending) if (p.name == name) return;
		pending.push({name: name, type: t});
	}

	private function shapeTop(t:Type):ShapeNode {
		return switch t {
			case TEnum(ref, _): shapeEnum(ref.get());
			case TType(ref, _):
				final td:DefType = ref.get();
				shapeTypedef(td);
			case TAbstract(ref, _):
				shapeAbstract(ref.get());
			case _:
				Context.fatalError('ShapeBuilder: cannot shape top-level type: ${typeToString(t)}', Context.currentPos());
				throw 'unreachable';
		};
	}

	private function shapeEnum(e:EnumType):ShapeNode {
		final node:ShapeNode = new ShapeNode(Alt);
		node.annotations.set('base.typePath', typePathOfEnum(e));
		node.annotations.set('base.meta', e.meta.get());
		for (name in e.names) {
			final ef:EnumField = e.constructs.get(name);
			final branch:ShapeNode = new ShapeNode(Seq);
			branch.annotations.set('base.ctor', name);
			branch.annotations.set('base.typePath', typePathOfEnum(e));
			branch.annotations.set('base.meta', ef.meta.get());
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

	private function shapeTypedef(td:DefType):ShapeNode {
		final under:Type = Context.follow(td.type, true);
		return switch under {
			case TAnonymous(aref):
				final a:AnonType = aref.get();
				final node:ShapeNode = new ShapeNode(Seq);
				node.annotations.set('base.typePath', typePathOfDef(td));
				node.annotations.set('base.meta', td.meta.get());
				// AnonType.fields is NOT guaranteed to preserve source declaration
				// order — on some Haxe builds it comes back in hash/alphabetical
				// order. The JSON grammar's alphabetical order happened to match
				// its source order (`key` before `value`) so Phase 2 worked, but
				// HxClassDecl exposed the bug (`members` sorts before `name`).
				// Sort by source position explicitly so the parse sequence of
				// a typedef Seq always matches how the user wrote it.
				final sorted:Array<ClassField> = a.fields.copy();
				sorted.sort(function(x:ClassField, y:ClassField):Int {
					final px:Int = Context.getPosInfos(x.pos).min;
					final py:Int = Context.getPosInfos(y.pos).min;
					return px - py;
				});
				for (f in sorted) node.children.push(shapeField(f.name, f.type, f.meta.get()));
				node;
			case _:
				Context.fatalError('ShapeBuilder: typedef ${td.name} does not resolve to an anonymous structure', Context.currentPos());
				throw 'unreachable';
		};
	}

	private function shapeAbstract(a:AbstractType):ShapeNode {
		final node:ShapeNode = new ShapeNode(Terminal);
		node.annotations.set('base.typePath', typePathOfAbstract(a));
		node.annotations.set('base.meta', a.meta.get());
		node.annotations.set('base.underlying', primitiveName(a.type));
		final enumValues:Null<Array<{name:String, value:String}>> = extractStringEnumValues(a);
		if (enumValues != null) {
			node.annotations.set('base.stringEnumValues', enumValues);
			// The string-enum decoder emits a call to the format's
			// `stringType` terminal to consume the literal before
			// dispatching to the matched enum value — enqueue it so
			// the generated parser contains the rule.
			if (formatInfo != null && formatInfo.stringType != null) {
				final st:String = formatInfo.stringType;
				enqueue(st, Context.getType(st));
			}
		}
		return node;
	}

	/**
	 * If `a` is an `enum abstract(String)` (new-style `enum` keyword or
	 * legacy `@:enum` meta), return the declared `name → value` pairs
	 * parsed from the impl class's static final fields. Returns `null`
	 * when the abstract is not an enum abstract or its underlying type
	 * isn't String — callers then fall through to the regex-based
	 * terminal path.
	 */
	private static function extractStringEnumValues(a:AbstractType):Null<Array<{name:String, value:String}>> {
		if (primitiveNameOrNull(a.type) != 'String') return null;
		if (!a.meta.has(':enum')) return null;
		if (a.impl == null) return null;
		final impl:ClassType = a.impl.get();
		final values:Array<{name:String, value:String}> = [];
		for (f in impl.statics.get()) {
			if (f.kind.match(FMethod(_))) continue;
			final texpr:Null<TypedExpr> = f.expr();
			if (texpr == null) continue;
			final s:Null<String> = extractStringConst(texpr);
			if (s == null) continue;
			values.push({name: f.name, value: s});
		}
		return values.length == 0 ? null : values;
	}

	private function primitiveRef(primName:String):Null<String> {
		if (formatInfo == null) return null;
		return switch primName {
			case 'Int': formatInfo.intType;
			case 'Float': formatInfo.floatType;
			case 'Bool': formatInfo.boolType;
			case 'String': formatInfo.stringType;
			case _: null;
		};
	}

	private static function extractStringConst(texpr:TypedExpr):Null<String> {
		return switch texpr.expr {
			case TConst(TString(s)): s;
			case TCast(inner, _): extractStringConst(inner);
			case TParenthesis(inner): extractStringConst(inner);
			case _: null;
		};
	}

	private function shapeField(fieldName:String, t:Type, meta:Null<Metadata>):ShapeNode {
		final child:ShapeNode = shapeFieldType(t);
		child.annotations.set('base.fieldName', fieldName);
		child.annotations.set('base.fieldType', Context.toComplexType(t));
		if (meta != null) child.annotations.set('base.meta', meta);
		// Optionality must be documented on both axes so a reader of the
		// grammar source spots it without cross-referencing — `@:optional`
		// on the field AND `Null<T>` on the type. `shapeFieldType` marks
		// the child node when it unwraps a `Null<T>` wrapper; this check
		// enforces bidirectional agreement.
		final hasOptMeta:Bool = meta != null && meta.exists(e -> e.name == ':optional');
		final hasOptShape:Bool = child.annotations.get('base.optional') == true;
		if (hasOptShape && !hasOptMeta) {
			Context.fatalError(
				'ShapeBuilder: field "$fieldName" has type Null<T> but is missing @:optional meta',
				Context.currentPos()
			);
		}
		if (hasOptMeta && !hasOptShape) {
			Context.fatalError(
				'ShapeBuilder: field "$fieldName" has @:optional but type is not Null<T>',
				Context.currentPos()
			);
		}
		return child;
	}

	private function shapeFieldType(t:Type):ShapeNode {
		// Evaluate lazy types up front so downstream matchers never see
		// a `TLazy` thunk. Lazy resolution happens for fields whose
		// types reference other types in the same module / compilation
		// unit that haven't been fully typed yet — common for
		// forward-declared sibling typedefs under a shared `@:build`
		// invocation.
		switch t {
			case TLazy(f): return shapeFieldType(f());
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
				final a:AbstractType = ref.get();
				if (a.pack.length == 0 && a.name == 'Null' && params.length == 1) {
					final inner:ShapeNode = shapeFieldType(params[0]);
					inner.annotations.set('base.optional', true);
					return inner;
				}
			case TType(ref, params):
				final d:DefType = ref.get();
				if (d.pack.length == 0 && d.name == 'Null' && params.length == 1) {
					final inner:ShapeNode = shapeFieldType(params[0]);
					inner.annotations.set('base.optional', true);
					return inner;
				}
			case _:
		}
		// Array<T> → Star
		switch t {
			case TInst(ref, params):
				final cl:ClassType = ref.get();
				if (cl.name == 'Array' && cl.pack.length == 0 && params.length == 1) {
					final inner:Type = params[0];
					final star:ShapeNode = new ShapeNode(Star);
					star.children.push(shapeFieldType(inner));
					return star;
				}
			case _:
		}
		// Std primitive abstracts (Bool/Int/Float/String) — inline Terminal,
		// do not try to shape them as stand-alone rules. BUT: if the
		// resolved format declares a grammar type for this primitive
		// (e.g. `JsonFormat.intType = anyparse.grammar.json.JIntLit`),
		// route the field through that Ref instead. This reuses the
		// format's decoding logic across every schema bound to the
		// format and keeps the JSON-family primitive decoders in one
		// place (the `@:re`-annotated terminal), rather than
		// duplicating them per generated parser.
		final prim:Null<String> = primitiveNameOrNull(t);
		if (prim != null) {
			final mapped:Null<String> = primitiveRef(prim);
			if (mapped != null) {
				final mappedType:Type = Context.getType(mapped);
				enqueue(mapped, mappedType);
				final node:ShapeNode = new ShapeNode(Ref);
				node.annotations.set('base.ref', mapped);
				return node;
			}
			final term:ShapeNode = new ShapeNode(Terminal);
			term.annotations.set('base.underlying', prim);
			return term;
		}
		// Named types become Ref + enqueue
		final refName:Null<String> = qualifiedNameOrNull(t);
		if (refName != null) {
			enqueue(refName, t);
			final node:ShapeNode = new ShapeNode(Ref);
			node.annotations.set('base.ref', refName);
			return node;
		}
		Context.fatalError('ShapeBuilder: unsupported field type: ${typeToString(t)}', Context.currentPos());
		throw 'unreachable';
	}

	// -------- type-name helpers --------

	private static function qualifiedName(t:Type):String {
		final n:Null<String> = qualifiedNameOrNull(t);
		if (n == null) {
			Context.fatalError('ShapeBuilder: type has no qualified name: ${typeToString(t)}', Context.currentPos());
			throw 'unreachable';
		}
		return n;
	}

	private static function qualifiedNameOrNull(t:Type):Null<String> {
		return switch t {
			case TEnum(ref, _):
				final e:EnumType = ref.get();
				joinPack(e.pack, e.name);
			case TType(ref, _):
				final d:DefType = ref.get();
				joinPack(d.pack, d.name);
			case TAbstract(ref, _):
				final a:AbstractType = ref.get();
				isStdPrimitiveAbstract(a) ? null : joinPack(a.pack, a.name);
			case TInst(ref, _):
				final c:ClassType = ref.get();
				c.pack.length == 0 && c.name == 'String' ? null : joinPack(c.pack, c.name);
			case _: null;
		};
	}

	private static function primitiveName(t:Type):String {
		final n:Null<String> = primitiveNameOrNull(t);
		return n == null ? 'unknown' : n;
	}

	private static function primitiveNameOrNull(t:Type):Null<String> {
		return switch t {
			case TAbstract(ref, _):
				final a:AbstractType = ref.get();
				isStdPrimitiveAbstract(a) ? a.name : null;
			case TInst(ref, _):
				final c:ClassType = ref.get();
				if (c.pack.length == 0 && c.name == 'String') 'String'
				else if (joinPack(c.pack, c.name) == 'haxe.io.Bytes') 'Bytes'
				else null;
			case _: null;
		};
	}

	private static inline function isStdPrimitiveAbstract(a:AbstractType):Bool {
		return a.pack.length == 0
			&& (a.name == 'Bool' || a.name == 'Int' || a.name == 'Float');
	}

	private static function typePathOfEnum(e:EnumType):String return joinPack(e.pack, e.name);
	private static function typePathOfDef(d:DefType):String return joinPack(d.pack, d.name);
	private static function typePathOfAbstract(a:AbstractType):String return joinPack(a.pack, a.name);

	private static function joinPack(pack:Array<String>, name:String):String {
		return pack.length == 0 ? name : '${pack.join('.')}.$name';
	}

	private static function typeToString(t:Type):String {
		return try haxe.macro.TypeTools.toString(t) catch (_:Dynamic) 'unknown';
	}
}

/**
 * Result of a shape-analysis pass: the root rule name and a map of all
 * named rules the worklist discovered.
 */
typedef ShapeResult = {
	root:String,
	rules:Map<String, ShapeNode>,
};
#end
