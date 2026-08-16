package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

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

		final decl: Null<TypeDeclMatch> = RefactorSupport.uniqueTypeDeclNamed(tree, typeName);
		if (decl == null) return Err('no unique type "$typeName" in the source');
		final declNN: TypeDeclMatch = decl;

		final field: Null<{
			node: QueryNode,
			group: Span,
			isStatic: Bool,
			isVar: Bool
		}> = resolveField(declNN, fieldName, source, plugin.refShape());
		if (field == null) return Err('type "$typeName" has no field "$fieldName"');
		final f: {
			node: QueryNode,
			group: Span,
			isStatic: Bool,
			isVar: Bool
		} = field;
		if (!f.isVar) return Err('"$fieldName" is a final field — it has no setter to encapsulate');
		if (f.isStatic) return Err('"$fieldName" is static — encapsulate covers instance fields');
		final shape: RefShape = plugin.refShape();
		if (
			MemberBranchScan.declaresMemberNamed(declNN, shape, source, 'get_$fieldName')
			|| MemberBranchScan.declaresMemberNamed(declNN, shape, source, 'set_$fieldName')
		)
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

	/**
	 * Resolve the data field `fieldName` of `decl`: its node, group span
	 * (modifiers included), and static / mutable flags. `isVar` is false
	 * for a `final` field. Null when there is no data field of that name.
	 */
	private static function resolveField(decl: TypeDeclMatch, fieldName: String, source: String, shape: RefShape): Null<{
		node: QueryNode,
		group: Span,
		isStatic: Bool,
		isVar: Bool
	}> {
		var hit: Null<{
			node: QueryNode,
			group: Span,
			isStatic: Bool,
			isVar: Bool
		}> = null;
		// Branch-aware: the field may be declared inside a `#if` region, where the direct-children scan
		// never saw it and the op answered "type has no field". The rewrite stays inside that region.
		MemberBranchScan.eachTypeMember(decl, shape, source, n -> DATA_MEMBER_KINDS.contains(n.kind), (child, run) -> {
			final span: Null<Span> = child.span;
			if (hit != null || child.name != fieldName || span == null) return;
			final spanNN: Span = span;
			final kind: String = child.kind;
			hit = {
				node: child,
				group: MemberBranchScan.groupSpanOf(run, spanNN),
				isStatic: run.exists(m -> m.kind == 'Static'),
				isVar: kind == 'VarMember' || kind == 'VarField'
			};
		});
		return hit;
	}

	/**
	 * Is there already an accessor clause `(...)` right after the field
	 * name (within its group)? Skips whitespace from `nameEnd`; a `(` means
	 * the field is already a property.
	 */
	private static function alreadyProperty(source: String, nameEnd: Int, groupTo: Int): Bool {
		var i: Int = nameEnd;
		while (i < groupTo && RefactorSupport.isSpace(source.fastCodeAt(i))) i++;
		return i < groupTo && source.fastCodeAt(i) == '('.code;
	}

	/**
	 * The verbatim source text of the field's declared type via
	 * `TypeInfoProvider.declaredTypeSources`, or null when the plugin does
	 * not expose type info or the field has no explicit annotation.
	 */
	private static function declaredTypeSource(plugin: GrammarPlugin, source: String, fieldFrom: Int): Null<String> {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		return provider?.declaredTypeSources(source)[fieldFrom];
	}


	/** The stored-field kinds `encapsulate-field` can turn into a property. */
	private static final DATA_MEMBER_KINDS: Array<String> = ['VarMember', 'FinalMember', 'VarField', 'FinalField'];

}
