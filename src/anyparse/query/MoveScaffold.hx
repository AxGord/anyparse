package anyparse.query;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.MoveMember.MemberGroup;
import anyparse.query.MoveMember.MovePrep;
import anyparse.query.MoveMember.ScaffoldField;
import anyparse.query.MoveMember.ViaResult;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * The `--scaffold` / `--via` half of `move-member`: everything that decides HOW a moved
 * instance member's remaining callers reach the destination, and everything that GENERATES the
 * wiring when the answer is "nothing here does yet".
 *
 * Split out of `MoveMember` in S90, and not along a reference seam — there is none. `hxq
 * clusters MoveMember` puts 45 of its 51 members in ONE component (92% coverage), and the purity
 * census that decides a state split is vacuous here (53 members, 0 non-static, no instance
 * field), which is why S88 refused the split on all three graph axes. What the graph cannot see
 * is that these ten answer a question the other forty-odd never ask: they run only when a move
 * leaves an instance caller behind (`--via`) or when the destination has no constructor to
 * receive the moved state (`--scaffold`). Twelve call sites reach them, ten distinct edges, and
 * only FOUR come from outside the family — so the seam is the family's own interface, not a cut
 * through it.
 *
 * The four public entry points are exactly those four edges: `resolveViaField` (which field
 * remaining bare instance callers route through), `resolveScaffoldFields` (the destination
 * fields to mirror, with their source-declared types), `applyDestScaffold` (write them plus a
 * constructor into the destination) and `scaffoldViaField` (declare the via field on the source
 * type and wire it in the source constructor).
 *
 * Reaches back into `MoveMember` for the member-group scans and the edit accumulator every op in
 * that file shares (`membersOf`, `memberGroupOf`, `constructorGroupOf`, `editsFor`,
 * `lineStartOf`, `isAllWhitespace`) — a hub set, not a dependency this split could take with it.
 */
@:access(anyparse.query.MoveMember)
@:nullSafety(Strict)
final class MoveScaffold {

	/**
	 * Resolves the source-type instance field of type `destTypeName` that
	 * remaining bare instance callers are rewired through: an explicit
	 * `viaField` is validated, otherwise the unique candidate is picked.
	 */
	public static function resolveViaField(prep: MovePrep, viaField: Null<String>, scaffold: Bool, plugin: GrammarPlugin): ViaResult {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final declared: Map<Int, String> = provider != null ? provider.declaredTypes(prep.srcSource) : [];
		final fields: Array<MemberGroup> = [
			for (g in MoveMember.membersOf(prep.srcDecl, prep.srcSource, prep.shape, plugin.lexicalRegions))
				if (MemberKinds.isDataFieldKind(g.member.kind) && !g.modifiers.exists(mod -> mod.kind == 'Static')) g
		];
		if (viaField != null) {
			final g: Null<MemberGroup> = fields.find(f -> f.member.name == viaField);
			if (g == null)
				return scaffold
					? scaffoldViaResult(prep, viaField, plugin.lexicalRegions)
					: VErr('"${prep.srcTypeName}" has no instance field "$viaField" (--via)');
			final gSpan: Null<Span> = g.member.span;
			final declaredType: Null<String> = gSpan != null ? declared[gSpan.from] : null;
			return declaredType != null && declaredType != prep.destTypeName
				? VErr('--via field "$viaField" is declared as "$declaredType", not "${prep.destTypeName}"')
				: VOk(viaField);
		}
		final candidates: Array<String> = [
			for (g in fields) {
				final gSpan: Null<Span> = g.member.span;
				final name: Null<String> = g.member.name;
				if (gSpan != null && name != null && declared[gSpan.from] == prep.destTypeName) name;
			}
		];
		return switch candidates {
			case [one]: VOk(one);
			case []: scaffold
				? scaffoldViaResult(prep, deriveViaName(prep.destTypeName), plugin.lexicalRegions)
				: VErr(
					'caller(s) of the moved instance member(s) remain in "${prep.srcTypeName}" but it has no field of '
					+ 'type "${prep.destTypeName}" to route them through — add one '
					+ '(e.g. `private final _x: ${prep.destTypeName}`), wire it in the constructor, pass --via <field>, or --scaffold'
				);
			case many: VErr(
				'multiple fields of type "${prep.destTypeName}" on "${prep.srcTypeName}" (${many.join(', ')}) — pass --via <field>'
			);
		};
	}

	/**
	 * Resolves the verbatim declared type of each named source field via
	 * `TypeInfoProvider.declaredTypeSources`. Returns an error when a field
	 * has no explicit nominal annotation to mirror onto the destination.
	 */
	public static function resolveScaffoldFields(
		prep: MovePrep, names: Array<String>, plugin: GrammarPlugin
	): { error: Null<String>, fields: Array<ScaffoldField> } {
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		if (provider == null) return { error: 'cannot --scaffold: the grammar does not expose declared field types', fields: [] };
		final typeSources: Map<Int, String> = provider.declaredTypeSources(prep.srcSource);
		final members: Array<MemberGroup> = MoveMember.membersOf(prep.srcDecl, prep.srcSource, prep.shape, plugin.lexicalRegions);
		final fields: Array<ScaffoldField> = [];
		for (name in names) {
			final g: Null<MemberGroup> = members.find(mm -> mm.member.name == name);
			final gSpan: Null<Span> = g?.member.span;
			final type: Null<String> = gSpan != null ? typeSources[gSpan.from] : null;
			if (type == null) return {
				error: 'cannot --scaffold field "$name": its type on "${prep.srcTypeName}" is not an explicit nominal annotation',
				fields: []
			};
			final typeNN: String = type;
			fields.push({ name: name, type: typeNN });
		}
		return { error: null, fields: fields };
	}

	/**
	 * Emits the mirrored final fields + constructor onto the destination.
	 * With no destination constructor the block is returned to prepend to
	 * the moved-member insert; with a trivial `new() {}` the block replaces
	 * it in place; a real constructor is refused.
	 */
	public static function applyDestScaffold(
		prep: MovePrep, fields: Array<ScaffoldField>, editsByFile: Map<String, Array<{ span: Span, text: String }>>,
		lexicalRegions: (String) -> Array<LexRegion>
	): { error: Null<String>, prependBlock: String } {
		final block: String = scaffoldDestBlock(fields);
		final ctor: Null<MemberGroup> = MoveMember.constructorGroupOf(prep.destDecl, prep.destSource, prep.shape, lexicalRegions);
		if (ctor == null) return { error: null, prependBlock: block };
		if (!isTrivialCtor(prep.destSource, ctor)) return {
			error: '"${prep.destTypeName}" already has a constructor — --scaffold targets an empty destination '
				+ '(a bare `new() {}` or no constructor)',
			prependBlock: ''
		};
		final from: Int = MoveMember.lineStartOf(prep.destSource, ctor.groupSpan.from);
		MoveMember.editsFor(editsByFile, prep.destFile).push({ span: new Span(from, ctor.groupSpan.to), text: block });
		return { error: null, prependBlock: '' };
	}

	/**
	 * Adds the via field to the source type and wires
	 * `<via> = new <Dest>(<fields>);` at the end of its constructor. Refuses
	 * when the source type has no constructor to wire into.
	 */
	public static function scaffoldViaField(
		prep: MovePrep, viaName: String, fields: Array<ScaffoldField>, editsByFile: Map<String, Array<{ span: Span, text: String }>>,
		lexicalRegions: (String) -> Array<LexRegion>
	): Null<String> {
		final ctor: Null<MemberGroup> = MoveMember.constructorGroupOf(prep.srcDecl, prep.srcSource, prep.shape, lexicalRegions);
		if (ctor == null) return 'cannot --scaffold via field "$viaName": "${prep.srcTypeName}" has no constructor to wire it in';
		final fieldFrom: Int = MoveMember.lineStartOf(prep.srcSource, ctor.groupSpan.from);
		MoveMember.editsFor(editsByFile, prep.srcFile).push({
			span: new Span(fieldFrom, fieldFrom),
			text: '\tprivate final $viaName: ${prep.destTypeName};\n\n'
		});
		final bodyClose: Null<Int> = ctorBodyClose(prep.srcSource, ctor.member);
		if (bodyClose == null) return 'cannot --scaffold via field "$viaName": could not locate the "${prep.srcTypeName}" constructor body';
		var wsStart: Int = bodyClose;
		while (wsStart > 0 && SourceText.isSpace(StringTools.fastCodeAt(prep.srcSource, wsStart - 1))) wsStart--;
		final args: String = [for (f in fields) f.name].join(', ');
		MoveMember.editsFor(editsByFile, prep.srcFile).push({
			span: new Span(wsStart, bodyClose),
			text: '\n\t\t$viaName = new ${prep.destTypeName}($args);\n\t'
		});
		return null;
	}

	private static inline function deriveViaName(destTypeName: String): String {
		return destTypeName == '' ? '_via' : '_${destTypeName.charAt(0).toLowerCase()}${destTypeName.substr(1)}';
	}

	private static inline function paramNameOf(fieldName: String): String {
		return fieldName.startsWith('_') ? fieldName.substr(1) : fieldName;
	}

	/**
	 * A `new() {}` with no parameters and an empty body — the auto-emitted
	 * constructor of a fresh `hxq new` class, safe for `--scaffold` to
	 * replace with a real one.
	 */
	private static function isTrivialCtor(source: String, group: MemberGroup): Bool {
		final hasParam: Bool = group.member.children.exists(c -> c.kind == 'Required' || c.kind == 'Optional');
		if (hasParam) return false;
		final body: Null<QueryNode> = group.member.children.find(c -> c.kind == 'BlockBody');
		if (body == null || body.children.length > 0) return false;
		final bodySpan: Null<Span> = body.span;
		// No parameters, no statement children, and nothing but whitespace
		// between the braces — a comment is trivia (not a child) and must
		// not be silently clobbered.
		return bodySpan != null && MoveMember.isAllWhitespace(source.substring(bodySpan.from + 1, bodySpan.to - 1));
	}

	private static function ctorBodyClose(source: String, ctorMember: QueryNode): Null<Int> {
		final span: Null<Span> = ctorMember.span;
		if (span == null) return null;
		var close: Int = span.to - 1;
		if (close >= source.length) close = source.length - 1;
		while (close >= span.from && SourceText.isSpace(source.fastCodeAt(close))) close--;
		return close < span.from || source.fastCodeAt(close) != '}'.code ? null : close;
	}

	/**
	 * The `private final <name>: <type>;` declarations plus a constructor
	 * assigning each, ready to splice into an empty destination.
	 */
	private static function scaffoldDestBlock(fields: Array<ScaffoldField>): String {
		final fieldLines: String = [for (f in fields) '\tprivate final ${f.name}: ${f.type};'].join('\n');
		final params: String = [for (f in fields) '${paramNameOf(f.name)}: ${f.type}'].join(', ');
		final assigns: String = [
			for (f in fields) {
				final p: String = paramNameOf(f.name);
				'\t\t${p == f.name ? 'this.${f.name} = $p;' : '${f.name} = $p;'}';
			}
		].join('\n');
		return '$fieldLines\n\n\tpublic function new($params) {\n$assigns\n\t}';
	}

	/**
	 * Wraps a scaffold via name in a `VScaffold`, refusing when the name
	 * already collides with a source member (a duplicate field or an
	 * ambiguous reference would otherwise be generated silently).
	 */
	private static function scaffoldViaResult(prep: MovePrep, name: String, lexicalRegions: (String) -> Array<LexRegion>): ViaResult {
		return MoveMember.memberGroupOf(prep.srcDecl, name, prep.srcSource, prep.shape, lexicalRegions) != null
			? VErr(
				'cannot --scaffold via field "$name": "${prep.srcTypeName}" already declares a member with that name '
				+ '— pass a different --via'
			)
			: VScaffold(name);
	}

}
