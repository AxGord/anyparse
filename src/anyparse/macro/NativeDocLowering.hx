package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.MacroNames;
import haxe.macro.Context;
import haxe.macro.Expr;

using Lambda;

/**
 * The one answer to "what does a by-name schema generate over its format's native door" (`docs/formats.md` § "The native
 * door"). Beside the byte-level parser: a shape check per rule over the value the door's parse hands back, so `parse` costs
 * the engine's parse plus a walk of the record, and every document the check refuses goes to the byte-level parser, which
 * reads it or says what is wrong in its own words. Beside the Doc writer: a compact writer per rule, which where the door
 * is the target's reader too hands the engine's writer a value holding just the record's keys in the schema's order, and
 * elsewhere appends to one buffer.
 *
 * Core names no format here: the door is a class the format names, called by a fixed set of members, and a format that names
 * none generates nothing.
 */
@:nullSafety(Strict)
final class NativeDocLowering {

	private static inline final CHECK_PREFIX: String = 'native';
	private static inline final COMPACT_PREFIX: String = 'compact';
	private static inline final COMPACT_TO_PREFIX: String = 'compactTo';
	private static inline final OUT_PREFIX: String = 'out';

	/** Each rule's verdict; a rule being decided answers yes, so a recursive schema is decided by its other fields. */
	private final _readable: Map<String, Bool> = [];

	private final _writable: Map<String, Bool> = [];
	private final _rules: Map<String, ShapeNode>;
	private final _format: FormatReader.FormatInfo;
	private final _door: Array<String>;

	/** Whether a compact writer appends to a buffer rather than going through the door's writer. */
	private final _direct: Bool;

	/** The next number `nameOf` gives; each generated function starts it again, so its locals stay apart within it. */
	private var _names: Int = 0;

	private function new(rules: Map<String, ShapeNode>, format: FormatReader.FormatInfo, door: String, direct: Bool) {
		_rules = rules;
		_format = format;
		_door = door.split('.');
		_direct = direct || !format.nativeWriteTargets.exists(Context.defined);
	}

	private inline function isScalar(ref: String): Bool {
		return ref == _format.intType || ref == _format.floatType || ref == _format.boolType || ref == _format.stringType;
	}

	private function isStruct(node: ShapeNode): Bool {
		return node.kind == Seq && MetaInspect.isByNameStruct(node, _format);
	}

	private function nameOf(prefix: String): String {
		return '_$prefix${_names++}';
	}

	/** Whether the shape check can read the rule at `path`: a by-name struct all of whose fields it can. */
	private function readable(path: String): Bool {
		final known: Null<Bool> = _readable[path];
		if (known != null) return known;
		_readable[path] = true;
		final node: Null<ShapeNode> = _rules[path];
		final verdict: Bool = node != null && isStruct(node) && node.children.foreach(canRead);
		_readable[path] = verdict;
		return verdict;
	}

	private function canRead(node: ShapeNode): Bool {
		return switch node.kind {
			case Star: canRead(node.children[0]);
			case Ref:
				final ref: String = node.annotations[AnnotationKeys.BASE_REF];
				isScalar(ref) || ref == _format.anyType || stringEnumOf(ref) != null || readable(ref);
			case _: false;
		};
	}

	/** Whether the compact writer can write the rule at `path`: no raw part and no map, which the Doc writer owns or refuses. */
	private function writable(path: String): Bool {
		final known: Null<Bool> = _writable[path];
		if (known != null) return known;
		_writable[path] = true;
		final node: Null<ShapeNode> = _rules[path];
		final verdict: Bool = node != null && isStruct(node) && node.children.foreach(canWrite);
		_writable[path] = verdict;
		return verdict;
	}

	private function canWrite(node: ShapeNode): Bool {
		return switch node.kind {
			case Star:
				!node.annotations.exists(AnnotationKeys.BASE_MAP_VALUE) && canWrite(node.children[0]);
			case Ref:
				final ref: String = node.annotations[AnnotationKeys.BASE_REF];
				isScalar(ref) || stringEnumOf(ref) != null || writable(ref);
			case _: false;
		};
	}

	/** The values of the string-backed enum abstract at `ref`, null for any other rule. */
	private function stringEnumOf(ref: String): Null<Array<String>> {
		final values: Null<Array<{ name: String, value: String }>> = _rules[ref]?.annotations.get('base.stringEnumValues');
		return values == null ? null : [for (v in values) v.value];
	}

	/**
	 * `native<T>(raw)`: whether `raw` has the shape of the rule, its raw parts and renamed keys made what the record says. A
	 * rule with an optional field visits the keys the object holds rather than ask for a declared one it may lack, an absent
	 * key being the slow lookup; a held key is unique, so counting the required ones met tells whether all are there. A rule
	 * with none asks for each of its keys, every one held in an object it accepts.
	 */
	private function checkField(path: String, node: ShapeNode): Field {
		final doorPath: Array<String> = _door;
		_names = 0;
		final steps: Array<Expr> = [macro if (!$p{doorPath}.isObject(raw)) return false];
		final optional: Array<Bool> = [
			for (child in node.children) child.annotations[AnnotationKeys.BASE_OPTIONAL] == true
		];
		if (optional.contains(true)) {
			final key: String = nameOf('k');
			final value: String = nameOf('v');
			final met: String = nameOf('n');
			final seen: Array<Null<String>> = [for (o in optional) o ? nameOf('s') : null];
			final cases: Array<Case> = [
				for (i => child in node.children) {
					final flag: Null<String> = seen[i];
					checkEntry(child, macro $i{value}, flag == null ? macro $i{met}++ : macro $i{flag} = true);
				}
			];
			final dispatch: Expr = { expr: ESwitch(macro $i{key}, cases, null), pos: Context.currentPos() };
			steps.push(macro var $met: Int = 0);
			for (flag in seen) if (flag != null) steps.push(macro var $flag: Bool = false);
			steps.push(macro for ($i{key} in $p{doorPath}.keys(raw)) {
				final $value: Null<Any> = $p{doorPath}.field(raw, $i{key});
				$dispatch;
			});
			// An absent optional field is null, as the byte-level parser leaves it: a door leaves it undefined on js.
			for (i => flag in seen) if (flag != null) {
				final name: String = fieldNameOf(node.children[i]);
				steps.push(macro if (!$i{flag}) $p{doorPath}.set(raw, $v{name}, null));
			}
			steps.push(macro return $i{met} == $v{optional.filter(o -> !o).length});
		} else {
			for (child in node.children) {
				final value: String = nameOf('v');
				final key: String = MetaInspect.wireKey(child, fieldNameOf(child));
				final isRaw: Bool = child.kind == Ref && child.annotations[AnnotationKeys.BASE_REF] == _format.anyType;
				steps.push(macro {
					final $value: Null<Any> = $p{doorPath}.field(raw, $v{key});
					${isRaw ? macro if (!$p{doorPath}.has(raw, $v{key})) return false : macro {}};
					${checkEntry(child, macro $i{value}, null).expr};
				});
			}
			steps.push(macro return true);
		}
		return field(checkName(path), [APrivate, AStatic], [{ name: 'raw', type: macro : Any }], macro : Bool, macro $b{steps});
	}

	/**
	 * The case of `child`'s key: `value`, the value the object holds under it, checked and stored under the Haxe name, then
	 * `met` when the key is required. A held `null` is refused by every kind but a raw part, so an optional key holding the
	 * format's null literal goes to the byte-level parser, which alone reads it as absent: one mechanism says what `null` means.
	 */
	private function checkEntry(child: ShapeNode, value: Expr, met: Null<Expr>): Case {
		final doorPath: Array<String> = _door;
		final name: String = fieldNameOf(child);
		final key: String = MetaInspect.wireKey(child, name);
		final steps: Array<Expr> = [];
		if (key != name) steps.push(macro $p{doorPath}.set(raw, $v{name}, $value));
		for (step in checkValue(child, value, converted -> macro $p{doorPath}.set(raw, $v{name}, $converted))) steps.push(step);
		if (met != null) steps.push(met);
		return { values: [macro $v{key}], expr: macro $b{steps} };
	}

	/** The statements that refuse `value` unless it has the shape of `node`; a value they convert goes to `store`. */
	private function checkValue(node: ShapeNode, value: Expr, store: (Expr) -> Expr): Array<Expr> {
		final doorPath: Array<String> = _door;
		return switch node.kind {
			case Star if (node.annotations.exists(AnnotationKeys.BASE_MAP_VALUE)): checkMap(node.children[0], value, store);
			case Star: checkArray(node.children[0], value);
			case _:
				final ref: String = node.annotations[AnnotationKeys.BASE_REF];
				final values: Null<Array<String>> = stringEnumOf(ref);
				if (ref == _format.intType) {
					[macro if (!$p{doorPath}.isInt($value)) return false];
				} else if (ref == _format.floatType) {
					[macro if (!$p{doorPath}.isFloat($value)) return false];
				} else if (ref == _format.boolType) {
					[macro if (!$p{doorPath}.isBool($value)) return false];
				} else if (ref == _format.stringType) {
					[macro if (!$p{doorPath}.isString($value)) return false];
				} else if (ref == _format.anyType) {
					final converted: String = nameOf('c');
					[
						(macro final $converted: Null<Any> = $p{doorPath}.value($value)),
						macro if ($i{converted} == null) return false,
						store(macro $i{converted})
					];
				} else if (values != null) {
					[macro if (!$p{doorPath}.isString($value) || !$v{values}.contains($value)) return false];
				} else {
					final check: String = checkName(ref);
					[macro if (!$i{check}($value)) return false];
				}
		};
	}

	private function checkArray(element: ShapeNode, value: Expr): Array<Expr> {
		final doorPath: Array<String> = _door;
		final items: String = nameOf('a');
		final index: String = nameOf('i');
		final item: String = nameOf('e');
		final itemValue: Expr = macro $i{item};
		final at: Expr = macro $i{items}[$i{index}];
		final checks: Expr = macro $b{checkValue(element, itemValue, converted -> macro $at = $converted)};
		final body: Expr = element.annotations[AnnotationKeys.BASE_OPTIONAL] == true ? macro if ($itemValue != null) $checks : checks;
		return [
			macro if (!$p{doorPath}.isArray($value)) return false,
			(macro final $items: Array<Any> = cast $value),
			(macro var $index: Int = 0),
			macro while ($i{index} < $i{items}.length) {
				final $item: Any = $at;
				$body;
				$i{index}++;
			}
		];
	}

	private function checkMap(element: ShapeNode, value: Expr, store: (Expr) -> Expr): Array<Expr> {
		final doorPath: Array<String> = _door;
		final map: String = nameOf('m');
		final key: String = nameOf('k');
		final item: String = nameOf('e');
		final itemValue: Expr = macro $i{item};
		final at: Expr = macro $i{map}[$i{key}];
		final checks: Expr = macro $b{checkValue(element, itemValue, converted -> macro $at = $converted)};
		return [
			macro if (!$p{doorPath}.isObject($value)) return false,
			(macro final $map: Map<String, Any> = new Map()),
			macro for ($i{key} in $p{doorPath}.keys($value)) {
				final $item: Null<Any> = $p{doorPath}.field($value, $i{key});
				$at = $itemValue;
				$checks;
			},
			store(macro $i{map})
		];
	}

	private function compactFields(): Array<Field> {
		final out: Array<Field> = [];
		final doorPath: Array<String> = _door;
		for (path => node in _rules) if (isStruct(node) && writable(path)) {
			final ct: ComplexType = TPath({ pack: MacroNames.packOf(path), name: MacroNames.simpleName(path), params: [] });
			_names = 0;
			final valueArg: FunctionArg = { name: 'value', type: ct };
			if (_direct) {
				final inner: String = compactToName(path);
				out.push(field(
					compactName(path), [APublic, AStatic], [valueArg], macro : String, macro {
						final out: StringBuf = new StringBuf();
						$i{inner}(value, out);
						return out.toString();
					}
				));
				out.push(
					field(inner, [APrivate, AStatic], [valueArg, { name: 'out', type: macro : StringBuf }], macro : Void, compactBody(node))
				);
			} else {
				final inner: String = outName(path);
				out.push(field(
					compactName(path), [APublic, AStatic], [valueArg], macro : String, macro {
						return $p{doorPath}.stringify($i{inner}(value));
					}
				));
				out.push(field(inner, [APrivate, AStatic], [valueArg], macro : Any, outBody(node)));
			}
		}
		return out;
	}

	private function compactBody(node: ShapeNode): Expr {
		final bare: Null<ShapeNode> = MetaInspect.bareField(node);
		if (bare != null) {
			final bareAccess: Expr = { expr: EField(macro value, fieldNameOf(bare)), pos: Context.currentPos() };
			return macro $b{compactValue(bare, bareAccess)};
		}
		final steps: Array<Expr> = [macro out.add($v{_format.mappingOpen})];
		// Whether a key is known to be written already: a required one is; after only optional ones `_some` knows at run time.
		var written: Bool = false;
		var tracked: Bool = false;
		final tracks: Bool = node.children.length > 1 && leftOutWhenNull(node.children[0]);
		if (tracks) steps.push(macro var _some: Bool = false);
		for (child in node.children) {
			final name: String = fieldNameOf(child);
			final optional: Bool = leftOutWhenNull(child);
			final access: Expr = { expr: EField(macro value, name), pos: Context.currentPos() };
			final key: String = '"${MetaInspect.wireKey(child, name)}"${_format.keyValueSep}';
			final lead: Array<Expr> = written
				? [macro out.add($v{_format.entrySep + key})]
				: tracked ? [macro if (_some) out.add($v{_format.entrySep}), macro out.add($v{key})] : [macro out.add($v{key})];
			if (optional) {
				final local: String = nameOf('v');
				final fieldCT: Null<ComplexType> = child.annotations.get(AnnotationKeys.BASE_FIELD_TYPE);
				final body: Array<Expr> = lead.concat(compactValue(child, macro $i{local}));
				if (tracks && !written) body.push(macro _some = true);
				steps.push(macro if ($access != null) {
					final $local: $fieldCT = $access;
					$b{body};
				});
				if (!written) tracked = true;
			} else if (MetaInspect.writesNull(child)) {
				final local: String = nameOf('v');
				final fieldCT: Null<ComplexType> = child.annotations.get(AnnotationKeys.BASE_FIELD_TYPE);
				for (step in lead) steps.push(step);
				steps.push(macro if ($access == null)
					out.add($v{_format.nullLiteral})
				else {
					final $local: $fieldCT = $access;
					$b{compactValue(child, macro $i{local})};
				});
				written = true;
			} else {
				for (step in lead) steps.push(step);
				for (step in compactValue(child, access)) steps.push(step);
				written = true;
			}
		}
		steps.push(macro out.add($v{_format.mappingClose}));
		return macro $b{steps};
	}

	/** Whether the by-name field `child` is left out of the document when it holds null: optional, and no `@:writeNull`. */
	private function leftOutWhenNull(child: ShapeNode): Bool {
		return child.annotations[AnnotationKeys.BASE_OPTIONAL] == true && !MetaInspect.writesNull(child);
	}

	private function compactValue(node: ShapeNode, value: Expr): Array<Expr> {
		final doorPath: Array<String> = _door;
		if (node.kind == Star) return compactArray(node.children[0], value);
		final ref: String = node.annotations[AnnotationKeys.BASE_REF];
		if (ref == _format.intType || ref == _format.floatType) return [macro out.add($value)];
		if (ref == _format.boolType) return [macro out.add($value ? 'true' : 'false')];
		if (ref == _format.stringType || stringEnumOf(ref) != null) return [macro out.add($p{doorPath}.quote(cast $value))];
		final inner: String = compactToName(ref);
		return [macro $i{inner}($value, out)];
	}

	private function compactArray(element: ShapeNode, value: Expr): Array<Expr> {
		final open: Null<String> = _format.sequenceOpen;
		final close: Null<String> = _format.sequenceClose;
		final nullLiteral: Null<String> = _format.nullLiteral;
		final item: String = nameOf('e');
		final first: String = nameOf('f');
		final itemValue: Expr = macro $i{item};
		final body: Expr = macro $b{compactValue(element, itemValue)};
		final each: Expr = element.annotations[AnnotationKeys.BASE_OPTIONAL] == true
			? macro if ($itemValue == null)
				out.add($v{nullLiteral})
			else
				$body
			: body;
		return [
			macro out.add($v{open}),
			(macro var $first: Bool = true),
			macro for ($i{item} in $value) {
				if ($i{first})
					$i{first} = false
				else
					out.add($v{_format.entrySep});
				$each;
			},
			macro out.add($v{close})
		];
	}

	/** The value the door's writer spells as the record: only its declared keys, in the schema's order, the absent ones held as nothing. */
	private function outBody(node: ShapeNode): Expr {
		final doorPath: Array<String> = _door;
		final bare: Null<ShapeNode> = MetaInspect.bareField(node);
		if (bare != null)
			return macro return ${outValue(bare, { expr: EField(macro value, fieldNameOf(bare)), pos: Context.currentPos() })};
		final entries: Array<ObjectField> = [];
		for (child in node.children) {
			final name: String = fieldNameOf(child);
			final access: Expr = { expr: EField(macro value, name), pos: Context.currentPos() };
			final optional: Bool = child.annotations.get(AnnotationKeys.BASE_OPTIONAL) == true;
			final held: Expr = MetaInspect.writesNull(child) ? macro null : macro $p{doorPath}.absent();
			entries.push({
				field: MetaInspect.wireKey(child, name),
				quotes: Quoted,
				expr: optional
					? macro if ($access == null)
						$held
					else
						${outValue(child, access)}
					: outValue(child, access)
			});
		}
		final literal: Expr = { expr: EObjectDecl(entries), pos: Context.currentPos() };
		return macro return $literal;
	}

	/** `value` as the door's writer takes it: a scalar and an array of scalars as they are, a struct through its own rule. */
	private function outValue(node: ShapeNode, value: Expr): Expr {
		if (node.kind == Star) {
			if (isLeafTree(node)) return value;
			final item: String = nameOf('e');
			final element: ShapeNode = node.children[0];
			final each: Expr = outValue(element, macro $i{item});
			final held: Expr = element.annotations[AnnotationKeys.BASE_OPTIONAL] == true
				? macro if ($i{item} == null)
					null
				else
					$each
				: each;
			return macro [for ($i{item} in $value) ($held: Any)];
		}
		final ref: String = node.annotations[AnnotationKeys.BASE_REF];
		if (isScalar(ref) || stringEnumOf(ref) != null) return value;
		final inner: String = outName(ref);
		return macro $i{inner}($value);
	}

	/** Whether every leaf under `node` is a scalar, so the door's writer can take the array as it is. */
	private function isLeafTree(node: ShapeNode): Bool {
		return switch node.kind {
			case Star: isLeafTree(node.children[0]);
			case Ref:
				final ref: String = node.annotations[AnnotationKeys.BASE_REF];
				isScalar(ref) || stringEnumOf(ref) != null;
			case _: false;
		};
	}

	/**
	 * `fields` of a generated parser with `parse` reading through the door, when the format declares one for this target and
	 * the root is a by-name struct: `parseNative` answers null for what the door or the shape check refuses, and `parse`
	 * then runs the byte-level parser as before.
	 */
	public static function overParser(
		fields: Array<Field>, shape: ShapeBuilder.ShapeResult, format: FormatReader.FormatInfo, rootCT: ComplexType
	): Void {
		final door: Null<String> = format.nativeDoor;
		if (door == null || !format.nativeTargets.exists(Context.defined)) return;
		final self: NativeDocLowering = new NativeDocLowering(shape.rules, format, door, false);
		final root: Null<ShapeNode> = shape.rules[shape.root];
		if (root == null || !self.isStruct(root) || !self.readable(shape.root)) return;
		final doorPath: Array<String> = self._door;
		final check: String = checkName(shape.root);
		fields.push(field(
			'parseNative', [APublic, AStatic], [{ name: 'source', type: macro : String }], macro : Null<$rootCT>, macro {
				final raw: Any = try $p{doorPath}.parse(source) catch (exception: haxe.Exception) return null;
				return $i{check}(raw) ? cast raw : null;
			}
		));
		for (path => node in shape.rules) if (self.isStruct(node) && self.readable(path)) fields.push(self.checkField(path, node));
		for (f in fields) if (f.name == 'parse') f.kind = FFun({
			args: [{ name: 'source', type: macro : String }],
			ret: rootCT,
			expr: macro {
				final read: Null<$rootCT> = parseNative(source);
				return read ?? parseWith(new anyparse.runtime.Parser(new anyparse.runtime.StringInput(source)));
			}
		});
	}

	/**
	 * `fields` of a generated writer with `write` taking the door's compact options to the direct writer, when the format
	 * declares a door and the root can be written that way; any other options keep the Doc writer. `direct` takes the buffer
	 * path on every target.
	 */
	public static function overWriter(
		fields: Array<Field>, shape: ShapeBuilder.ShapeResult, format: FormatReader.FormatInfo, direct: Bool
	): Void {
		final door: Null<String> = format.nativeDoor;
		if (door == null) return;
		final self: NativeDocLowering = new NativeDocLowering(shape.rules, format, door, direct);
		if (!self.writable(shape.root)) return;
		final doorPath: Array<String> = self._door;
		final compact: String = compactName(shape.root);
		for (f in fields) if (f.name == 'write') switch f.kind {
			case FFun(fn):
				final doc: Null<Expr> = fn.expr;
				fn.expr = macro {
					if ($p{doorPath}.isCompact(options)) return $i{compact}(value);
					$doc;
				};
			case _:
		}
		for (compactField in self.compactFields()) fields.push(compactField);
	}

	/**
	 * The compact writer of every rule of `shape` that can be written that way, for a marker class that wants the text of
	 * its records and no document (`Build.buildCompactWriter`).
	 */
	public static function compactOnly(shape: ShapeBuilder.ShapeResult, format: FormatReader.FormatInfo): Array<Field> {
		final door: Null<String> = format.nativeDoor;
		return door != null
			? new NativeDocLowering(shape.rules, format, door, false).compactFields()
			: Context.fatalError('Build.buildCompactWriter: format ${format.schemaTypePath} declares no nativeDoor', Context.currentPos());
	}

	private static inline function checkName(path: String): String {
		return CHECK_PREFIX + MacroNames.simpleName(path);
	}

	private static inline function compactName(path: String): String {
		return COMPACT_PREFIX + MacroNames.simpleName(path);
	}

	private static inline function compactToName(path: String): String {
		return COMPACT_TO_PREFIX + MacroNames.simpleName(path);
	}

	private static inline function outName(path: String): String {
		return OUT_PREFIX + MacroNames.simpleName(path);
	}

	private static function field(name: String, access: Array<Access>, args: Array<FunctionArg>, ret: ComplexType, body: Expr): Field {
		return {
			name: name,
			access: access,
			kind: FFun({ args: args, ret: ret, expr: body }),
			pos: Context.currentPos()
		};
	}

	private static function fieldNameOf(child: ShapeNode): String {
		final name: Null<String> = child.annotations[AnnotationKeys.BASE_FIELD_NAME];
		return name ?? Context.fatalError('NativeDocLowering: a by-name field has no base.fieldName', Context.currentPos());
	}

}
#end
