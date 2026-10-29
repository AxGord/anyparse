package anyparse.check.scan;

import anyparse.check.scan.AccessorClauseText.AccessorClause;
import anyparse.check.scan.ReflectionScan.ScopeFile;
import anyparse.query.CondRegionScan;
import anyparse.query.MemberKinds;
import anyparse.query.OccurrenceScan;
import anyparse.query.ParseGate;
import anyparse.query.RawSourceScan;
import anyparse.query.SourceText;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.WriteSites;

/**
 * Who reaches a property's PHYSICAL field. A plain read of a property whose read slot is `default` / `null`
 * returns that field, while every write outside its own accessors runs the set accessor; so the field holds
 * a value only when an accessor body, an `@:bypassAccessor` construct, target code or a declaration
 * initializer puts one there. `redundant-isvar` asks whether anything reaches the storage at all,
 * `unstored-property` whether anything ever stores it, `scratch-field` whether the setter it is about to
 * rewrite is one that never does.
 */
@:nullSafety(Strict)
final class PropertyStorage {

	/** The metadata that makes a property access reach the physical field directly. */
	private static inline final BYPASS_META: String = '@:bypassAccessor';

	/**
	 * The property of `container` whose set accessor `method` is, when the property's clause gives plain reads
	 * the physical field and routes writes through the setter (`AccessorClauseText.readsFieldWritesThroughSetter`)
	 * and `method` has a body that never names the property — a setter that stores nothing — else null. `propertyKinds` are the
	 * grammar's mutable field declaration kinds; a mention anywhere in the method, parameter list included, counts.
	 * `noBodyKind` is the grammar's bodiless-method kind: a declaration alone shows nothing of what it stores.
	 */
	public static function unstoredBy(
		method: QueryNode, container: QueryNode, source: String, propertyKinds: Array<String>, noBodyKind: Null<String>
	): Null<QueryNode> {
		final methodName: Null<String> = method.name;
		final methodSpan: Null<Span> = method.span;
		if (
			methodName == null || methodSpan == null || !CheckScan.METHOD_KINDS.contains(method.kind)
			|| !methodName.startsWith(CheckScan.SET_PREFIX) || method.children.length == 0
			|| method.children[method.children.length - 1].kind == noBodyKind
		)
			return null;
		final name: String = methodName.substr(CheckScan.SET_PREFIX.length);
		final property: Null<QueryNode> = container.children.find(m -> m.name == name && propertyKinds.contains(m.kind));
		final propertySpan: Null<Span> = property?.span;
		if (property == null || propertySpan == null) return null;
		final clause: Null<AccessorClause> = AccessorClauseText.accessorClause(source, propertySpan);
		return clause != null && AccessorClauseText.readsFieldWritesThroughSetter(clause)
			&& !SourceText.mentionsIdent(source, methodSpan, name)
			? property
			: null;
	}

	/**
	 * Whether any scope file may reach the physical field of the property `name`: a file spelling the
	 * name that does not parse, an unparsed `#if` region spelling it, or a construct `touchesStorage`
	 * reports.
	 */
	public static function storageReachable(ctx: StorageScope, name: String): Bool {
		final accessors: Array<String> = [CheckScan.GET_PREFIX + name, CheckScan.SET_PREFIX + name];
		for (entry in ctx.scope) if (RawSourceScan.mentionsWord(entry.source, name)) {
			final tree: Null<QueryNode> = ParseGate.parseOrNull(ctx.plugin, entry.source);
			if (tree == null) return true;
			if (CondRegionScan.opaqueCondRegionMentioning(tree, entry.source, name, ctx.shape) != null) return true;
			if (touchesStorage(tree, entry.source, name, accessors, ctx)) return true;
		}
		return false;
	}

	/**
	 * Whether any scope file may READ the member `name`: an occurrence of the word outside comments and inert
	 * strings that is neither the target of a plain assignment (`WriteSites`), on any receiver, nor inside `declared` (the
	 * declaration, in `declFile`); a file spelling the name that does not parse, or an unparsed `#if` region
	 * spelling it, may read it too. By name, not by binding, over the whole resolution
	 * scope, std included: an unrelated member or local of that name counts.
	 */
	public static function readAnywhere(ctx: StorageScope, name: String, declFile: String, declared: Span): Bool {
		for (entry in ctx.scope) if (RawSourceScan.mentionsWord(entry.source, name)) {
			final source: String = entry.source;
			final tree: Null<QueryNode> = ParseGate.parseOrNull(ctx.plugin, source);
			if (tree == null) return true;
			if (CondRegionScan.opaqueCondRegionMentioning(tree, source, name, ctx.shape) != null) return true;
			final excluded: Array<Span> = entry.file == declFile ? [declared] : [];
			for (site in WriteSites.of(tree, ctx.shape)) {
				final token: Null<Span> = plainWriteToken(site.node, source, name, ctx.shape);
				if (token != null) excluded.push(token);
			}
			if (OccurrenceScan.referencedInRange(source, name, 0, source.length, excluded, OccurrenceScan.inertMask(source, ctx.plugin)))
				return true;
		}
		return false;
	}

	/**
	 * Whether the subtree under `node` holds a method named one of `accessors`, a construct carrying
	 * `@:bypassAccessor`, or a native-code carrier (`NativeCodeScan.isCarrier`), whose text mentions `name` as a
	 * standalone identifier. Text rather than resolution: inside an accessor body a mention may reach the
	 * field in any spelling — bare, `this.`-qualified, interpolated — and inside target code it is not
	 * Haxe at all; a mention that reaches nothing only costs a finding.
	 */
	private static function touchesStorage(
		node: QueryNode, source: String, name: String, accessors: Array<String>, ctx: StorageScope
	): Bool {
		final span: Null<Span> = node.span;
		final nodeName: Null<String> = node.name;
		final accessor: Bool = nodeName != null && CheckScan.METHOD_KINDS.contains(node.kind) && accessors.contains(nodeName);
		final bypass: Bool = node.children.exists(c -> MemberKinds.META_KINDS.contains(c.kind) && c.name == BYPASS_META);
		if (
			span != null && (accessor || bypass || NativeCodeScan.isCarrier(node, ctx.shape, ctx.fold))
			&& SourceText.mentionsIdent(source, span, name)
		)
			return true;
		return node.children.exists(c -> touchesStorage(c, source, name, accessors, ctx));
	}

	/**
	 * The span of the `name` token the write `node` (a `WriteSites` site) stores into, when it is a plain assignment
	 * to a bare identifier or a member on any receiver — else null: a compound assignment or an increment reads first.
	 */
	private static function plainWriteToken(node: QueryNode, source: String, name: String, shape: RefShape): Null<Span> {
		final target: Null<QueryNode> = node.kind == shape.assignKind && node.children.length > 0 ? node.children[0] : null;
		final span: Null<Span> = target?.span;
		return target != null && span != null && target.name == name
			&& (target.kind == shape.identKind || target.kind == shape.fieldAccessKind) && span.to - name.length >= span.from
			&& source.substring(span.to - name.length, span.to) == name
			? new Span(span.to - name.length, span.to)
			: null;
	}

}

/** The run-wide evidence a storage scan reads. */
typedef StorageScope = {

	/** The grammar plugin, for parsing scope files. */
	final plugin: GrammarPlugin;

	/** The grammar's reference shape, resolved once per run. */
	final shape: RefShape;

	/** Report UNION the resolution sources — every file that may reach the field. */
	final scope: Array<ScopeFile>;

	/** The grammar's string-fold support, which names the target intrinsics; null when it exposes none. */
	final fold: Null<StringFoldSupport>;

};
