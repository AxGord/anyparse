package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * `encapsulate-field` — turn a stored `var` field into a property with
 * `get` / `set` accessors, so reads and writes route through methods that
 * can later add validation, laziness, or logging. Uses Haxe's `@:isVar`
 * so the field itself stays the backing storage — no separate `_field`
 * and no rename of existing references (they keep the same name and now
 * flow through the accessors).
 *
 *     public var x: Int = 0;
 *
 * becomes
 *
 *     @:isVar public var x(get, set): Int = 0;
 *     function get_x(): Int { return x; }
 *     function set_x(value: Int): Int { return x = value; }
 *
 * ## Boundary
 *
 * Requires a plain, non-`final`, non-`static` instance `var` with an
 * EXPLICIT type (the accessors need a return type). Refuses a field that
 * is already a property (an accessor clause after its name), or one whose
 * `get_<field>` / `set_<field>` accessor already exists. Writer-emitted
 * and canonical-gated (like the other structural-insert ops).
 */
@:nullSafety(Strict)
final class EncapsulateField {

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

	/**
	 * Encapsulate the field `fieldName` of `typeName` in `source`. `reformat`
	 * canonicalises a drifted file. Returns `Ok(rewritten)` or an `Err`.
	 */
	public static function encapsulate(
		source: String, typeName: String, fieldName: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final decl: Null<TypeDeclMatch> = uniqueType(tree, typeName);
		if (decl == null) return Err('no unique type "$typeName" in the source');
		final declNN: TypeDeclMatch = decl;

		final field: Null<{
			node: QueryNode,
			group: Span,
			isStatic: Bool,
			isVar: Bool
		}> = resolveField(declNN, fieldName);
		if (field == null) return Err('type "$typeName" has no field "$fieldName"');
		final f: {
			node: QueryNode,
			group: Span,
			isStatic: Bool,
			isVar: Bool
		} = field;
		if (!f.isVar) return Err('"$fieldName" is a final field — it has no setter to encapsulate');
		if (f.isStatic) return Err('"$fieldName" is static — encapsulate covers instance fields');
		if (memberNamed(declNN, 'get_$fieldName') || memberNamed(declNN, 'set_$fieldName'))
			return Err('an accessor "get_$fieldName" / "set_$fieldName" already exists');

		final fieldSpan: Null<Span> = f.node.span;
		if (fieldSpan == null) return Err('field "$fieldName" carries no span');
		final fieldSpanNN: Span = fieldSpan;
		final nameOffset: Int = RefactorSupport.identTokenOffset(source, fieldSpanNN, fieldName);
		if (nameOffset < 0) return Err('could not locate the name of field "$fieldName"');
		final nameEnd: Int = nameOffset + fieldName.length;
		if (alreadyProperty(source, nameEnd, f.group.to)) return Err('"$fieldName" is already a property (it has an accessor clause)');

		final typeSrc: Null<String> = declaredTypeSource(plugin, source, fieldSpanNN.from);
		if (typeSrc == null) return Err('"$fieldName" needs an explicit type to encapsulate (the accessors need a return type)');
		final typeSrcNN: String = typeSrc;

		final groupText: String = source.substring(f.group.from, f.group.to);
		final relNameEnd: Int = nameEnd - f.group.from;
		final newField: String = '@:isVar ${groupText.substr(0, relNameEnd)}(get, set)${groupText.substr(relNameEnd)}';
		// The setter parameter must not shadow the field itself (with @:isVar
		// the bare field name is the physical storage), else the assignment is
		// a self-assign.
		final param: String = fieldName == 'value' ? 'newValue' : 'value';
		final getter: String = 'function get_$fieldName():$typeSrcNN {\n\treturn $fieldName;\n}';
		final setter: String = 'function set_$fieldName($param:$typeSrcNN):$typeSrcNN {\n\treturn $fieldName = $param;\n}';
		final replacement: String = '$newField\n\n$getter\n\n$setter';

		return RefactorSupport.canonicalize(source, [{ span: f.group, text: replacement }], reformat, plugin, optsJson);
	}

	/** The sole type declaration named `typeName`, or null. Final-aware. */
	private static function uniqueType(tree: QueryNode, typeName: String): Null<TypeDeclMatch> {
		final matches: Array<TypeDeclMatch> = [];
		function walk(node: QueryNode): Void {
			final m: Null<TypeDeclMatch> = RefactorSupport.typeDeclOf(node);
			if (m != null && m.name == typeName) matches.push(m);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return matches.length == 1 ? matches[0] : null;
	}

	/**
	 * Resolve the data field `fieldName` of `decl`: its node, group span
	 * (modifiers included), and static / mutable flags. `isVar` is false
	 * for a `final` field. Null when there is no data field of that name.
	 */
	private static function resolveField(decl: TypeDeclMatch, fieldName: String): Null<{
		node: QueryNode,
		group: Span,
		isStatic: Bool,
		isVar: Bool
	}> {
		final siblings: Array<QueryNode> = decl.nameNode.children;
		for (i => child in siblings) {
			final kind: String = child.kind;
			if (child.name != fieldName) continue;
			final isData: Bool = kind == 'VarMember' || kind == 'FinalMember' || kind == 'VarField' || kind == 'FinalField';
			if (!isData) continue;
			final span: Null<Span> = child.span;
			if (span == null) continue;
			final spanNN: Span = span;
			var isStatic: Bool = false;
			var j: Int = i - 1;
			while (j >= 0 && MODIFIER_META.contains(siblings[j].kind)) {
				if (siblings[j].kind == 'Static') isStatic = true;
				j--;
			}
			final isVar: Bool = kind == 'VarMember' || kind == 'VarField';
			return {
				node: child,
				group: RefactorSupport.declGroupSpan(child, decl.nameNode, spanNN),
				isStatic: isStatic,
				isVar: isVar
			};
		}
		return null;
	}

	/** Does `decl` declare a member named `name` (any field / method)? */
	private static function memberNamed(decl: TypeDeclMatch, name: String): Bool {
		for (child in decl.nameNode.children) {
			final kind: String = child.kind;
			if ((RefactorSupport.isFieldMemberKind(kind) || RefactorSupport.FN_DECL_KINDS.contains(kind)) && child.name == name)
				return true;
		}
		return false;
	}

	/**
	 * Is there already an accessor clause `(...)` right after the field
	 * name (within its group)? Skips whitespace from `nameEnd`; a `(` means
	 * the field is already a property.
	 */
	private static function alreadyProperty(source: String, nameEnd: Int, groupTo: Int): Bool {
		var i: Int = nameEnd;
		while (i < groupTo && RefactorSupport.isSpace(StringTools.fastCodeAt(source, i))) i++;
		return i < groupTo && StringTools.fastCodeAt(source, i) == '('.code;
	}

	/**
	 * The verbatim source text of the field's declared type via
	 * `TypeInfoProvider.declaredTypeSources`, or null when the plugin does
	 * not expose type info or the field has no explicit annotation.
	 */
	private static function declaredTypeSource(plugin: GrammarPlugin, source: String, fieldFrom: Int): Null<String> {
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		return provider == null ? null : provider.declaredTypeSources(source)[fieldFrom];
	}

}
