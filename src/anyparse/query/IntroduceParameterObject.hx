package anyparse.query;

import anyparse.query.CallSites.CollectResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;

/** A resolved parameter to fold into the object: its name, type source, and node. */
private typedef Field = {
	var name: String;
	var type: String;
	var node: QueryNode;
}

/** Everything resolved before edits are built. */
private typedef Prep = {
	var decl: QueryNode;
	var declSpan: Span;
	var params: Array<QueryNode>;
	var rng: { start: Int, end: Int };
	var fields: Array<Field>;
	var obj: String;
	var name: String;
}

/** A computed value or an error message. */
private enum Prepared {

	Ready(prep: Prep);
	Refused(message: String);

}

/**
 * `introduce-parameter-object` — replace a contiguous run of a function's
 * parameters with a single object parameter of a generated typedef, so a
 * clump of positional arguments ("x, y") travels as one value ("point").
 * The signature, the body's references to those parameters, and every
 * resolvable in-file call site are rewritten together; a new module-level
 * `typedef` collects the folded fields.
 *
 *     function move(x: Int, y: Int, dur: Float) { … x … y … }
 *     move(1, 2, 0.5);
 *
 * with `--params x,y --as Point` becomes
 *
 *     function move(point: Point, dur: Float) { … point.x … point.y … }
 *     move({x: 1, y: 2}, 0.5);
 *     typedef Point = { x:Int, y:Int }
 *
 * ## Boundary
 *
 * The chosen parameters must be a CONTIGUOUS run and each must carry an
 * explicit type (the typedef needs field types). Reuses the `CallSites`
 * completeness proof: an unresolvable / receiver-qualified / arity-
 * mismatched call refuses the whole change (like `remove-param`). A
 * parameter used through a short string interpolation is refused (a braced
 * interpolation is rewritten fine). Method call sites in OTHER files are
 * out of scope (advisory).
 */
@:nullSafety(Strict)
final class IntroduceParameterObject {

	/**
	 * Fold `paramNames` of the function at `line:col` in `source` into one
	 * object parameter of a new typedef `typeName` (parameter name
	 * `objName`, defaulting to the lower-camel of `typeName`). Returns
	 * `Ok(rewritten)` or an `Err`. PURE.
	 */
	public static function introduce(
		source: String, line: Int, col: Int, paramNames: Array<String>, typeName: String, objName: Null<String>, plugin: GrammarPlugin,
		shape: RefShape
	): EditResult {
		if (!RefactorSupport.isIdentifier(typeName)) return Err('type name "$typeName" is not a valid identifier');
		if (paramNames.length == 0) return Err('no parameters named — nothing to fold');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final prep: Prep = switch resolvePrep(source, tree, line, col, paramNames, typeName, objName, plugin, shape) {
			case Refused(message): return Err(message);
			case Ready(p): p;
		};

		final edits: Array<{ span: Span, text: String }> = [];
		final sigFrom: Int = firstSpan(prep.params[prep.rng.start]).from;
		final sigTo: Int = firstSpan(prep.params[prep.rng.end]).to;
		edits.push({ span: new Span(sigFrom, sigTo), text: '${prep.obj}:$typeName' });

		bodyRefEdits(tree, source, prep.fields, prep.obj, shape, edits);
		final callErr: Null<String> = callSiteEdits(prep, tree, source, shape, edits);
		if (callErr != null) return Err(callErr);

		final typedefText: String = 'typedef $typeName = { ' + [for (f in prep.fields) '${f.name}:${f.type}'].join(', ') + ' }';
		edits.push({ span: new Span(source.length, source.length), text: '\n\n$typedefText\n' });

		final rewritten: String = collapseBlankRuns(RefactorSupport.applyEdits(source, edits));
		try
			plugin.parseFile(rewritten)
		catch (exception: ParseError)
			return Err('rewritten source does not parse: ${exception.toString()}')
		catch (exception: Exception)
			return Err('rewritten source does not parse: ${exception.message}');
		return Ok(rewritten);
	}

	/**
	 * Resolve the function, the contiguous parameter run, their typed
	 * fields, and the object parameter name — running every refusal before
	 * any edit is built.
	 */
	private static function resolvePrep(
		source: String, tree: QueryNode, line: Int, col: Int, paramNames: Array<String>, typeName: String, objName: Null<String>,
		plugin: GrammarPlugin, shape: RefShape
	): Prepared {
		final cursor: Int = Span.offsetOf(source, line, col);
		final cursorNode: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (cursorNode == null) return Refused('position $line:$col is not on a function or a call');
		final name: Null<String> = cursorNode.name;
		if (name == null) return Refused('position $line:$col is not on a function or a call');
		final nameNN: String = name;
		final decl: Null<QueryNode> = CallSites.resolveFnDecl(cursorNode, tree, nameNN, shape);
		if (decl == null || !RefactorSupport.FN_DECL_KINDS.contains(decl.kind))
			return Refused('could not resolve a function "$nameNN" at $line:$col');
		final declNN: QueryNode = decl;
		final declSpan: Null<Span> = declNN.span;
		if (declSpan == null) return Refused('"$nameNN" declaration has no source span');
		final declSpanNN: Span = declSpan;

		final params: Array<QueryNode> = CallSites.leadingParams(declNN);
		final rng: Null<{ start: Int, end: Int }> = contiguousRange(params, paramNames);
		if (rng == null) return Refused('parameters ${paramNames.join(', ')} are not a contiguous run of "$nameNN"\'s parameters');
		final rngNN: { start: Int, end: Int } = rng;

		final fields: Array<Field> = [];
		final typeErr: Null<String> = resolveFields(params, rngNN, source, plugin, fields);
		if (typeErr != null) return Refused(typeErr);

		final obj: String = objName ?? lowerCamel(typeName);
		if (!RefactorSupport.isIdentifier(obj)) return Refused('object parameter name "$obj" is not a valid identifier');
		for (p in params) if (p.name == obj && !paramNames.contains(p.name))
			return Refused('object name "$obj" collides with an existing parameter — pass --name');

		final interpErr: Null<String> = interpolationRefusal(source, declSpanNN, fields);
		return interpErr != null
			? Refused(interpErr)
			: Ready({
				decl: declNN,
				declSpan: declSpanNN,
				params: params,
				rng: rngNN,
				fields: fields,
				obj: obj,
				name: nameNN
			});
	}

	/**
	 * The contiguous index range [start, end] of `params` that exactly
	 * covers `paramNames` (order-independent), or null when a name is
	 * missing or the matched indices are not adjacent.
	 */
	private static function contiguousRange(params: Array<QueryNode>, paramNames: Array<String>): Null<{ start: Int, end: Int }> {
		final indices: Array<Int> = [];
		for (want in paramNames) {
			var found: Int = -1;
			for (i => p in params) if (p.name == want) found = i;
			if (found < 0) return null;
			indices.push(found);
		}
		indices.sort((a, b) -> a - b);
		for (i in 1...indices.length) if (indices[i] != indices[i - 1] + 1) return null;
		return { start: indices[0], end: indices[indices.length - 1] };
	}

	/** Resolve each param in the range to a typed field (in signature order). Non-null error on a missing type. */
	private static function resolveFields(
		params: Array<QueryNode>, rng: { start: Int, end: Int }, source: String, plugin: GrammarPlugin, out: Array<Field>
	): Null<String> {
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final types: Map<Int, String> = provider != null ? provider.declaredTypeSources(source) : [];
		for (i in rng.start ... rng.end + 1) {
			final p: QueryNode = params[i];
			final pName: Null<String> = p.name;
			final pSpan: Null<Span> = p.span;
			if (pName == null || pSpan == null) return 'a folded parameter has no name / span';
			final type: Null<String> = types[pSpan.from];
			if (type == null) return 'parameter "$pName" has no explicit type — introduce-parameter-object needs one';
			final pNameNN: String = pName;
			final typeNN: String = type;
			out.push({ name: pNameNN, type: typeNN, node: p });
		}
		return null;
	}

	/** The span of a param / arg node (its own span). */
	private static function firstSpan(node: QueryNode): Span {
		return node.span ?? new Span(0, 0);
	}

	/** Lower-camel of a type name (`Point` -> `point`). */
	private static function lowerCamel(name: String): String {
		return name.length == 0 ? name : name.charAt(0).toLowerCase() + name.substr(1);
	}

	/**
	 * Refuse when a folded parameter appears as a SHORT string
	 * interpolation `$param` inside the function body — it would need
	 * `${obj.param}`, which this op does not synthesise (a braced `${param}`
	 * IS handled by the body-reference rewrite).
	 */
	private static function interpolationRefusal(source: String, declSpan: Span, fields: Array<Field>): Null<String> {
		final body: String = source.substring(declSpan.from, declSpan.to);
		for (f in fields) {
			var from: Int = 0;
			while (true) {
				final at: Int = body.indexOf('$' + f.name, from);
				if (at < 0) break;
				final after: Int = at + 1 + f.name.length;
				final nextOk: Bool = after >= body.length || !RefactorSupport.isIdentChar(StringTools.fastCodeAt(body, after));
				if (nextOk)
					return 'parameter "${f.name}" is used in a short string interpolation ($${f.name}) — '
						+ 'rewrite that interpolation with { } braces first, then retry';
				from = at + 1;
			}
		}
		return null;
	}

	/** Prefix each in-body reference to a folded parameter with `obj.`. */
	private static function bodyRefEdits(
		tree: QueryNode, source: String, fields: Array<Field>, obj: String, shape: RefShape, edits: Array<{ span: Span, text: String }>
	): Void {
		for (f in fields) {
			final fSpan: Null<Span> = f.node.span;
			if (fSpan == null) continue;
			final binding: Int = fSpan.from;
			for (hit in Refs.find(f.name, tree, shape)) if (hit.kind != RefKind.Decl) {
				final b: Null<Span> = hit.bindingSpan;
				if (b == null || b.from != binding) continue;
				final at: Int = RefactorSupport.identTokenOffset(source, hit.span, f.name);
				if (at >= 0) edits.push({ span: new Span(at, at), text: '$obj.' });
			}
		}
	}

	/** Replace the folded-argument run at every resolvable call site with an object literal. */
	private static function callSiteEdits(
		prep: Prep, tree: QueryNode, source: String, shape: RefShape, edits: Array<{ span: Span, text: String }>
	): Null<String> {
		final collected: CollectResult = CallSites.collect(prep.decl, tree, source, prep.name, prep.declSpan.from, shape);
		final sites: Array<QueryNode> = switch collected {
			case CErr(message): return message;
			case COk(list): list;
		};
		for (call in sites) {
			final args: Array<QueryNode> = call.children.slice(1);
			if (args.length != prep.params.length)
				return 'call at ${CallSites.posOf(source, call.span)} has ${args.length} args, expected ${prep.params.length} '
					+ '— cannot fold calls with omitted optional arguments';
			final from: Int = firstSpan(args[prep.rng.start]).from;
			final to: Int = firstSpan(args[prep.rng.end]).to;
			final literal: String = '{ '
				+ [
					for (i in prep.rng.start ... prep.rng.end + 1)
						'${prep.fields[i - prep.rng.start].name}: ${source.substring(firstSpan(args[i]).from, firstSpan(args[i]).to)}'
				].join(', ') + ' }';
			edits.push({ span: new Span(from, to), text: literal });
		}
		return null;
	}

	/** Collapse runs of 3+ newlines to a single blank line (typedef-append tidy-up). */
	private static function collapseBlankRuns(source: String): String {
		final buf: StringBuf = new StringBuf();
		var newlines: Int = 0;
		for (i in 0...source.length) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == '\n'.code) {
				newlines++;
				if (newlines <= 2) buf.addChar(c);
			} else {
				newlines = 0;
				buf.addChar(c);
			}
		}
		return buf.toString();
	}

}
