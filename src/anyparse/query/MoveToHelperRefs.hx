package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MoveMember.MemberGroup;
import anyparse.query.MoveMember.MovePrep;
import anyparse.query.MoveMember.MovedMember;
import anyparse.query.MoveMemberReceivers.ReceiverHit;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.runtime.Span;

using Lambda;

/**
 * The edits one `move-to-helper` run collects (`MoveToHelper`): the source-coordinate edits that travel with the moved
 * text, the per-file edits of every other file, and the bookkeeping the shared `MoveMember` passes read afterwards.
 */
typedef HelperEdits = {
	final prep: MovePrep;
	final plugin: GrammarPlugin;

	/** The source parameter each moved instance member gains. */
	final param: String;

	final helperName: String;
	final editsByFile: Map<String, Array<{ span: Span, text: String }>>;
	final movedTextEdits: Array<{ span: Span, text: String }>;

	/** Files whose rewritten callers name the helper bare and may owe its import. */
	final callerFiles: Array<String>;

	/** Per moved member, how many callers remain outside the helper (`MoveMember.promotionEdit`). */
	final outsideCallersOf: Map<String, Int>;

	/** The moved members whose bodies read a non-public member of the source (`@:access`). */
	final accessMembers: Array<String>;

	final advisory: Array<String>;
}

/**
 * One call to a moved instance member rewritten into a call of the helper's static: the edits, where they go, and the
 * length of the call — two rewrites can insert at one offset (`m2(m1())`, `a.m1().m2()`), and the outer call's text must
 * come first, so the edits are pushed innermost first (`CanonicalEdit.applyEdits` lands insertions at one offset in
 * reverse push order).
 */
private typedef CallRewrite = {
	final file: String;
	final inCut: Bool;
	final length: Int;
	final edits: Array<{ span: Span, text: String }>;
}

/** A node of one file with its parent, the unit `nodeIndex` hands back. */
private typedef Placed = {
	final node: QueryNode;
	final parent: Null<QueryNode>;
}

/** One file's identifiers keyed by where they start, and its member accesses keyed by where they end. */
private typedef NodeIndex = {
	final identsByFrom: Map<Int, Placed>;
	final accessesByTo: Map<Int, Array<Placed>>;
}

/** What the walk over the moved members collects before `Refs` binds it (`scanMoved`). */
private typedef MovedScan = {
	final names: Array<String>;

	/** Identifiers that root a dotted path naming a TYPE (`haxe.Json.parse`), a package rather than a value. */
	final pathRoots: Array<Int>;

	/** Member names reached through any receiver inside the moved members. */
	final accessedNames: Array<{ name: String, at: Int }>;
}

/**
 * The reference rewrites of `move-to-helper`, every one of them read off the shared reference index — `Refs` for the
 * moved bodies and the source's bare callers, `MoveMemberReceivers` for receiver-qualified callers across the scope —
 * and never off the text. See `MoveToHelper` for the rules they implement.
 */
@:nullSafety(Strict)
@:access(anyparse.query.MoveMember)
@:access(anyparse.query.DependencyCarry)
final class MoveToHelperRefs {

	/** What a bare name may mean with nothing in scope binding it: the ambient `trace`, and the pattern wildcard `_`. */
	private static final AMBIENT_VALUES: Array<String> = ['trace', '_'];

	/** A fresh edit set for one move. */
	public static function start(prep: MovePrep, plugin: GrammarPlugin, param: String, helperName: String): HelperEdits {
		return {
			prep: prep,
			plugin: plugin,
			param: param,
			helperName: helperName,
			editsByFile: [],
			movedTextEdits: [],
			callerFiles: [],
			outsideCallersOf: [for (m in prep.moved) m.name => 0],
			accessMembers: [],
			advisory: []
		};
	}

	/**
	 * Collects every reference rewrite of the move into `edits`: the moved statics' callers (`MoveMember`'s own passes), the
	 * moved bodies' references, and the calls of the moved instance members. Returns the refusal, or null.
	 */
	public static function rewrite(edits: HelperEdits): Null<String> {
		final prep: MovePrep = edits.prep;
		for (m in prep.moved) if (m.isStatic)
			edits.outsideCallersOf[m.name] = MoveMember.collectQualifiedEdits(
				prep, m, edits.editsByFile, edits.movedTextEdits, edits.callerFiles
			);
		MoveMember.collectWildcardBareEdits(prep, edits.editsByFile, edits.callerFiles, edits.outsideCallersOf);
		final bare: Array<{ m: MovedMember, offset: Int, interp: Null<Span> }> = MoveMember.collectBareCallerHits(prep, edits.plugin);
		final staticError: Null<String> = MoveMember.rewireStaticCallers(
			prep, bare.filter(h -> h.m.isStatic), false, edits.plugin, edits.editsByFile, edits.outsideCallersOf, edits.advisory
		);
		if (staticError != null) return staticError;
		final indexes: Map<String, NodeIndex> = [];
		final calls: Array<CallRewrite> = [];
		final inCutError: Null<String> = rewriteMovedBodies(edits, indexes, calls);
		if (inCutError != null) return inCutError;
		for (h in bare) if (!h.m.isStatic) {
			final error: Null<String> = bareCallerRewrite(edits, indexes, h.m, h.offset, h.interp != null, calls);
			if (error != null) return error;
		}
		final subtypeError: Null<String> = subtypeBareCallers(edits, indexes, calls);
		if (subtypeError != null) return subtypeError;
		final receivers: { error: Null<String>, hits: Array<ReceiverHit> } = MoveMemberReceivers.collectReceiverHits(prep, edits.plugin);
		if (receivers.error != null) return receivers.error;
		for (h in receivers.hits) {
			final error: Null<String> = receiverCallRewrite(edits, indexes, h, calls);
			if (error != null) return error;
		}
		calls.sort((a, b) -> a.length - b.length);
		for (c in calls) for (e in c.edits) (c.inCut ? edits.movedTextEdits : ScopeFiles.editsFor(edits.editsByFile, c.file)).push(e);
		return null;
	}

	private static inline function valueUse(srcTypeName: String, name: String, at: String): String {
		return '"$name" is used as a function value at $at — once it is a static of the helper it takes its "$srcTypeName" as '
			+ 'an argument and has no bound form; call it (or wrap it in a lambda) first';
	}

	private static inline function callLength(placed: Placed): Int {
		final span: Null<Span> = placed.parent?.span;
		return span == null ? 0 : span.to - span.from;
	}

	private static inline function where(file: String, source: String, offset: Int): String {
		final at: Position = new Span(offset, offset).lineCol(source);
		return '$file:${at.line}:${at.col}';
	}

	/** Whether `hit` starts inside one of `spans`. */
	private static inline function within(hit: RefHit, spans: Array<Span>): Bool {
		return spans.exists(s -> hit.span.from >= s.from && hit.span.from < s.to);
	}

	/**
	 * Rewrites what the moved bodies reference, each identifier bound by `Refs`: a staying instance member (own or
	 * inherited) is reached through the parameter, a staying static through the source type, `this` IS the parameter, a
	 * call of another moved instance member gains the parameter as its first argument. A local, a moved static, a type and
	 * a package root need nothing. Anything else is a refusal naming the reference.
	 */
	private static function rewriteMovedBodies(
		edits: HelperEdits, indexes: Map<String, NodeIndex>, calls: Array<CallRewrite>
	): Null<String> {
		final prep: MovePrep = edits.prep;
		final members: Array<MemberGroup> = MoveMember.membersOf(prep.srcDecl, prep.srcSource, prep.shape, edits.plugin.lexicalRegions);
		final byFrom: Map<Int, MemberGroup> = [];
		for (g in members) {
			final from: Null<Int> = g.member.span?.from;
			if (from != null) byFrom[from] = g;
		}
		final scan: MovedScan = scanMoved(prep);
		final captured: Array<String> = BinderScan.casePatternCaptures(prep.srcTree, prep.shape);
		final capturedMember: Null<String> = scan.names.find(n -> captured.contains(n) && members.exists(g -> g.member.name == n));
		if (capturedMember != null)
			return 'a switch case pattern in ${prep.srcFile} binds "$capturedMember", a member the moved code reads — reference '
				+ 'resolution cannot tell the capture from the member; rename the capture first';
		grantForPrivateAccesses(edits, members, scan);
		final hits: Map<String, Array<RefHit>> = Refs.findMulti(scan.names, prep.srcTree, prep.shape);
		for (name in scan.names) for (hit in hits[name] ?? []) if (
			hit.kind != RefKind.Decl && MoveMember.insideAnyCut(prep, hit.span.from)
		) {
			final error: Null<String> = rewriteMovedRef(edits, hit, byFrom, scan, indexes, calls);
			if (error != null) return error;
		}
		return null;
	}

	/** The names the moved members spell as identifiers, the package roots among them, and the member names they access. */
	private static function scanMoved(prep: MovePrep): MovedScan {
		final scan: MovedScan = { names: ['this'], pathRoots: [], accessedNames: [] };
		final identKinds: Array<String> = [
			for (k in [prep.shape.identKind, prep.shape.stringInterpIdentKind]) if (k != null) k
		];
		final accessKinds: Array<String> = ShapeVocab.memberAccessKinds(prep.shape);
		function walk(node: QueryNode, typePathRoot: Bool): Void {
			final name: Null<String> = node.name;
			final from: Int = node.span?.from ?? -1;
			if (name != null && identKinds.contains(node.kind)) {
				if (!scan.names.contains(name)) scan.names.push(name);
				if (typePathRoot && node.kind == prep.shape.identKind) scan.pathRoots.push(from);
			}
			final isAccess: Bool = accessKinds.contains(node.kind);
			if (isAccess && name != null) scan.accessedNames.push({ name: name, at: from });
			for (i => c in node.children) walk(c, isAccess && i == 0 && (typePathRoot || SourceText.isUpperInitial(name ?? '')));
		}
		for (m in prep.moved) walk(m.group.member, false);
		return scan;
	}

	/**
	 * Every moved member that reaches a NON-public member of the source by name — bare, through `this` or through any other
	 * receiver — takes the `@:access` grant. By name rather than by receiver type: a source method may read the private
	 * field of ANOTHER instance of its own class (`o.x`), which the helper may only with the grant, and a same-named member of
	 * an unrelated type only over-grants. A member the source does not declare may be an inherited private one, which the
	 * same grant covers.
	 */
	private static function grantForPrivateAccesses(edits: HelperEdits, members: Array<MemberGroup>, scan: MovedScan): Void {
		final prep: MovePrep = edits.prep;
		for (access in scan.accessedNames) {
			final declared: Null<MemberGroup> = members.find(g -> g.member.name == access.name);
			final hidden: Bool = declared == null
				? prep.index.subtypes.declaringAncestorOf(prep.srcTypeName, access.name) != null
				: !declared.modifiers.exists(mod -> mod.kind == 'Public');
			if (hidden) grantFor(edits, access.at);
		}
	}

	private static function grantFor(edits: HelperEdits, offset: Int): Void {
		final host: Null<MovedMember> = edits.prep.moved.find(m -> offset >= m.cut.from && offset < m.cut.to);
		if (host != null && !host.isStatic && !edits.accessMembers.contains(host.name)) edits.accessMembers.push(host.name);
	}

	/** One reference inside a moved body (`rewriteMovedBodies`): the edit it takes, or the refusal. */
	private static function rewriteMovedRef(
		edits: HelperEdits, hit: RefHit, byFrom: Map<Int, MemberGroup>, scan: MovedScan, indexes: Map<String, NodeIndex>,
		calls: Array<CallRewrite>
	): Null<String> {
		final prep: MovePrep = edits.prep;
		final binding: Null<Span> = hit.bindingSpan;
		if (binding != null) {
			final group: Null<MemberGroup> = byFrom[binding.from];
			if (group != null) return memberRef(edits, hit, group, indexes, calls);
			if (MoveMember.insideAnyCut(prep, binding.from) || prep.srcFile == prep.destFile) return null;
			return 'the moved code reads "${hit.name}" at ${where(prep.srcFile, prep.srcSource, hit.span.from)}, a module-level '
				+ 'declaration of ${prep.srcFile} the helper module cannot see bare';
		}
		final name: String = hit.name;
		if (name == 'this') {
			edits.movedTextEdits.push({ span: hit.span, text: hit.interpolated ? '$$${edits.param}' : edits.param });
			return null;
		}
		if (name == 'super')
			return 'the moved code reaches `super` at ${where(prep.srcFile, prep.srcSource, hit.span.from)} — a static helper has '
				+ 'no superclass to call';
		if (SourceText.isUpperInitial(name) || scan.pathRoots.contains(hit.span.from) || AMBIENT_VALUES.contains(name)) return null;
		if (prep.index.subtypes.declaringAncestorOf(prep.srcTypeName, name) != null) {
			edits.movedTextEdits.push(qualifiedRef(hit, '${edits.param}.'));
			grantFor(edits, hit.span.from);
			return null;
		}
		if (wildcardBound(prep, name)) return null;
		if (prep.srcInfo.moduleFields.exists(f -> f.name == name) && prep.srcFile != prep.destFile)
			return 'the moved code reads "$name" at ${where(prep.srcFile, prep.srcSource, hit.span.from)}, a module-level '
				+ 'declaration of ${prep.srcFile} the helper module cannot see bare';
		final how: String = DependencyCarry.importsSimpleName(prep.srcInfo, name)
			? 'it is reached through an import of the field itself, which the carry does not move'
			: 'no local, member, inherited member, import or package path the index can see binds it';
		return 'cannot resolve "$name" at ${where(prep.srcFile, prep.srcSource, hit.span.from)}: $how';
	}

	/** A reference bound to a member of the source (`rewriteMovedRef`). */
	private static function memberRef(
		edits: HelperEdits, hit: RefHit, group: MemberGroup, indexes: Map<String, NodeIndex>, calls: Array<CallRewrite>
	): Null<String> {
		final prep: MovePrep = edits.prep;
		final moved: Null<MovedMember> = prep.moved.find(m -> m.span.from == group.member.span?.from);
		if (moved != null) {
			return moved.isStatic
				? null
				: callRewrite(edits, indexes, prep.srcFile, hit.span.from, moved, hit.interpolated, '', edits.param, true, calls);
		}
		final isStatic: Bool = group.modifiers.exists(mod -> mod.kind == 'Static');
		if (!group.modifiers.exists(mod -> mod.kind == 'Public')) grantFor(edits, hit.span.from);
		edits.movedTextEdits.push(qualifiedRef(hit, isStatic ? '${prep.srcTypeName}.' : '${edits.param}.'));
		return null;
	}

	/** The edit qualifying a bare reference with `qualifier` — the braced form for a braceless `$name` interpolation. */
	private static function qualifiedRef(hit: RefHit, qualifier: String): { span: Span, text: String } {
		return MoveMember.nameQualifyEdit(hit.span.from, hit.interpolated ? hit.span : null, hit.name, qualifier);
	}

	/** Whether a module-static wildcard of the source file binds `name` (`import p.M.*;`), which the carry moves. */
	private static function wildcardBound(prep: MovePrep, name: String): Bool {
		return DependencyCarry.wildcardStaticProviders(prep.srcInfo, prep.index.allFiles(), prep.shape).exists(p -> p.names.contains(name));
	}

	/** A bare call of a moved instance member outside the moved bodies: `m(a)` -> `Helper.m(this, a)`. */
	private static function bareCallerRewrite(
		edits: HelperEdits, indexes: Map<String, NodeIndex>, m: MovedMember, offset: Int, interpolated: Bool, calls: Array<CallRewrite>
	): Null<String> {
		edits.outsideCallersOf[m.name] = (edits.outsideCallersOf[m.name] ?? 0) + 1;
		return callRewrite(edits, indexes, edits.prep.srcFile, offset, m, interpolated, '${edits.helperName}.', 'this', false, calls);
	}

	/**
	 * The BARE calls of a moved instance member inside a SUBTYPE of the source declared in scope, which inherits the member
	 * and names it with no receiver: `m(a)` -> `Helper.m(this, a)`. `Refs` binds none of them — the member is declared in
	 * another type — so they are the unbound occurrences inside the subtype's declaration. A subtype OUTSIDE the scope is
	 * out of reach, as for every caller.
	 */
	private static function subtypeBareCallers(
		edits: HelperEdits, indexes: Map<String, NodeIndex>, calls: Array<CallRewrite>
	): Null<String> {
		final prep: MovePrep = edits.prep;
		final instance: Array<MovedMember> = prep.moved.filter(m -> !m.isStatic);
		if (instance.length == 0) return null;
		for (file => tree in prep.trees) {
			final info: Null<FileInfo> = prep.index.fileInfo(file);
			if (info == null) continue;
			final subtypes: Array<Span> = [];
			final maybe: Array<Span> = [];
			sortSubtypeSpans(prep, info, subtypes, maybe);
			if (subtypes.length == 0 && maybe.length == 0) continue;
			final hits: Map<String, Array<RefHit>> = Refs.findMulti([for (m in instance) m.name], tree, prep.shape);
			for (m in instance) for (hit in hits[m.name] ?? []) if (hit.kind != RefKind.Decl && hit.bindingSpan == null) {
				// A type that MAY extend the source without proof could inherit the member: its bare call is refused, not left.
				if (within(hit, maybe))
					return 'a type in $file may extend "${prep.srcTypeName}" and calls "${m.name}" bare, and nothing proves it inherits it';
				if (!within(hit, subtypes)) continue;
				edits.outsideCallersOf[m.name] = (edits.outsideCallersOf[m.name] ?? 0) + 1;
				if (file != prep.destFile && !edits.callerFiles.contains(file)) edits.callerFiles.push(file);
				final error: Null<String> = callRewrite(
					edits, indexes, file, hit.span.from, m, hit.interpolated, '${edits.helperName}.', 'this', false, calls
				);
				if (error != null) return error;
			}
		}
		return null;
	}

	/**
	 * A receiver-qualified call of a moved instance member, the receiver provably a source (`MoveMemberReceivers`):
	 * `r.m(a)` -> `Helper.m(r, a)` — or, inside a moved body, `m(r, a)` (the helper's own static; a `this` receiver is then
	 * the parameter).
	 */
	private static function receiverCallRewrite(
		edits: HelperEdits, indexes: Map<String, NodeIndex>, h: ReceiverHit, calls: Array<CallRewrite>
	): Null<String> {
		final prep: MovePrep = edits.prep;
		final source: String = prep.sourceOf[h.file] ?? '';
		final index: NodeIndex = indexOf(edits, indexes, h.file);
		final placed: Null<Placed> = (index.accessesByTo[h.at + h.m.name.length] ?? []).find(p -> p.node.name == h.m.name);
		final recvSpan: Null<Span> = placed?.node.children[0]?.span;
		if (placed == null || recvSpan == null) return 'cannot place the call of "${h.m.name}" at ${where(h.file, source, h.at)}';
		final open: Int = openParen(edits, source, placed);
		if (open < 0) return valueUse(edits.prep.srcTypeName, h.m.name, where(h.file, source, h.at));
		if (!h.inCut) {
			edits.outsideCallersOf[h.m.name] = (edits.outsideCallersOf[h.m.name] ?? 0) + 1;
			if (h.file != prep.srcFile && h.file != prep.destFile && !edits.callerFiles.contains(h.file)) edits.callerFiles.push(h.file);
		}
		final prefix: String = h.inCut ? '' : '${edits.helperName}.';
		final hasArgs: Bool = (placed.parent?.children.length ?? 0) > 1;
		calls.push({
			file: h.file,
			inCut: h.inCut,
			length: callLength(placed),
			edits: [
				{ span: new Span(recvSpan.from, recvSpan.from), text: '$prefix${h.m.name}(' },
				{ span: new Span(recvSpan.to, open + 1), text: hasArgs ? ', ' : '' }
			]
		});
		return null;
	}

	/**
	 * A BARE call of moved member `m` at `offset` of `file`: `m(a)` -> `<prefix>m(<first>, a)`. Refused when the name is not
	 * the callee of a call — a static helper method has no bound form, so `f = m` / `m.bind(1)` / `'$m'` cannot follow it.
	 */
	private static function callRewrite(
		edits: HelperEdits, indexes: Map<String, NodeIndex>, file: String, offset: Int, m: MovedMember, interpolated: Bool, prefix: String,
		first: String, inCut: Bool, calls: Array<CallRewrite>
	): Null<String> {
		final source: String = edits.prep.sourceOf[file] ?? '';
		final placed: Null<Placed> = interpolated ? null : indexOf(edits, indexes, file).identsByFrom[offset];
		final open: Int = placed == null ? -1 : openParen(edits, source, placed);
		if (placed == null || open < 0) return valueUse(edits.prep.srcTypeName, m.name, where(file, source, offset));
		final hasArgs: Bool = (placed.parent?.children.length ?? 0) > 1;
		calls.push({
			file: file,
			inCut: inCut,
			length: callLength(placed),
			edits: [
				{ span: new Span(offset, open + 1), text: '$prefix${m.name}($first${hasArgs ? ', ' : ''}' }
			]
		});
		return null;
	}

	/**
	 * The offset of the `(` that opens the call `placed.node` is the callee of, or -1 when it is no callee: its parent is
	 * not a call, it is not the call's first child, or something other than whitespace stands between it and the `(`.
	 */
	private static function openParen(edits: HelperEdits, source: String, placed: Placed): Int {
		final parent: Null<QueryNode> = placed.parent;
		final span: Null<Span> = placed.node.span;
		final callKind: Null<String> = edits.prep.shape.callKind;
		if (parent == null || span == null || callKind == null || parent.kind != callKind || parent.children[0] != placed.node) return -1;
		var i: Int = span.to;
		while (i < source.length && SourceText.isSpace(source.fastCodeAt(i))) i++;
		return i < source.length && source.fastCodeAt(i) == '('.code ? i : -1;
	}

	private static function indexOf(edits: HelperEdits, indexes: Map<String, NodeIndex>, file: String): NodeIndex {
		final known: Null<NodeIndex> = indexes[file];
		if (known != null) return known;
		final built: NodeIndex = { identsByFrom: [], accessesByTo: [] };
		final shape: RefShape = edits.prep.shape;
		final accessKinds: Array<String> = ShapeVocab.memberAccessKinds(shape);
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			final span: Null<Span> = node.span;
			final placed: Placed = { node: node, parent: parent };
			if (span != null && node.kind == shape.identKind) built.identsByFrom[span.from] = placed;
			if (span != null && accessKinds.contains(node.kind)) {
				final list: Array<Placed> = built.accessesByTo[span.to] ?? [];
				list.push(placed);
				built.accessesByTo[span.to] = list;
			}
			for (c in node.children) walk(c, node);
		}
		final tree: Null<QueryNode> = edits.prep.trees[file];
		if (tree != null) walk(tree, null);
		indexes[file] = built;
		return built;
	}

	/** The spans of `info`'s types that are proven subtypes of the source into `proven`, and of those that only may be into `maybe`. */
	private static function sortSubtypeSpans(prep: MovePrep, info: FileInfo, proven: Array<Span>, maybe: Array<Span>): Void {
		for (t in info.types) if (t.name != prep.srcTypeName) {
			final verdict: Null<Bool> = prep.index.subtypes.subtypeVerdict(t.name, prep.srcTypeName, prep.srcFile);
			if (verdict != false) (verdict == true ? proven : maybe).push(t.span);
		}
	}

}
