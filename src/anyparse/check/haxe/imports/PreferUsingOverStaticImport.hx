package anyparse.check.haxe.imports;

import anyparse.check.Check.FixEdit;
import anyparse.check.Check.RiskyFix;
import anyparse.check.haxe.expressions.PreferStaticExtension;
import anyparse.check.scan.RunScan;
import anyparse.check.scan.UsingScan;
import anyparse.check.scan.UsingSites;
import anyparse.query.BoolExprShape;
import anyparse.query.CanonicalEdit;
import anyparse.query.IndexScope;
import anyparse.query.MemberLookup;
import anyparse.query.ParseGate;
import anyparse.query.RefactorSupport.TypeDeclMatch;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.query.ValueNameBinding.ImportedStatics;

/**
 * Flags a static import of an extension function that the same file also brings in with `using` —
 * `import StringTools.fastCodeAt;` beside `using StringTools;` — and rewrites each bare call
 * `fastCodeAt(s, i)` to the extension call `s.fastCodeAt(i)`, then deletes the import. The one
 * answer to "can this bare call be the extension call, so the import can go": the per-call gates are
 * `PreferStaticExtension`'s (`judgeSites`), the name binding is `ValueNameBinding.importedStatics`.
 *
 * ## All or nothing per import
 *
 * The import goes only when EVERY use of the bare name is a rewritable call: a use that is not a call
 * with a receiver (`xs.map(fastCodeAt)`, a call with no argument), a call the name binds elsewhere
 * (another import, a member of the enclosing type or its supertypes), a call whose receiver the gates
 * cannot prove, or a comment inside a region the rewrite deletes keeps the import and the finding is
 * report-only, naming why. A local or parameter of the same name is no use of the import.
 *
 * Reported only when the import is plain, unguarded and unaliased, the module is brought in by an
 * unguarded `using`, and the member is one of the module's extension methods. `RiskyFix`: the bare
 * names a call-site scan cannot see (macro reification) are the build's to veto.
 */
@:nullSafety(Strict)
final class PreferUsingOverStaticImport extends HaxeRule implements RiskyFix {

	private static inline final RULE_ID: String = 'prefer-using-over-static-import';

	/** The child index of the receiver in a call node: the callee comes first. */
	private static inline final RECEIVER_INDEX: Int = 1;

	public function new() {
		super(
			RULE_ID,
			'a static import of an extension function the file also `using`s: write the calls as extension calls and drop the import',
			RuleCategory.Imports
		);
	}

	public function run(files: Array<SourceEntry>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = PreferStaticExtension.readSeams(plugin);
		if (seams == null) return [];
		final symbols: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final index: Null<SymbolIndex> = symbols();
			final info: Null<FileInfo> = index?.fileInfo(entry.file);
			final tree: Null<QueryNode> = info == null ? null : ParseGate.parseOrNull(plugin, entry.source);
			if (index == null || info == null || tree == null) continue;
			for (finding in findingsOf(info, tree, entry.source, plugin, seams, index, symbols)) violations.push({
				file: entry.file,
				span: finding.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'import \'${finding.path}\' duplicates `using ${finding.module}`: call it as an extension, '
				+ '`recv.${finding.member}(…)`, and drop the import',
				declineReason: finding.decline
			});
		}
		return violations;
	}

	/** Rewrite every call and delete the import of each finding that is fully rewritable; the gates run again on `source`. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		final seams: Null<Seams> = PreferStaticExtension.readSeams(plugin);
		if (seams == null || violations.length == 0) return [];
		final file: String = violations[0].file;
		// the scope `run` proved the verdicts on, not the narrower report index `Cli` hands over
		final resolution: Null<SymbolIndex> = IndexScope.resolutionIndexOf(plugin) ?? index;
		final info: Null<FileInfo> = resolution?.fileInfo(file);
		if (resolution == null || info == null) return [];
		final known: SymbolIndex = resolution;
		final declared: FileInfo = info;
		return RunScan.edits(plugin, source, root -> {
			final edits: Array<FixEdit> = [];
			for (finding in findingsOf(declared, root, source, plugin, seams, known, () -> known)) {
				final own: Null<Array<FixEdit>> = finding.edits;
				if (own == null || !violations.exists(v -> v.span != null && v.span.from == finding.span.from)) continue;
				if (!CanonicalEdit.editsOverlapAny(own, edits)) for (edit in own) edits.push(edit);
			}
			return edits;
		});
	}

	/** Whether `node` reads the bare name `member`: an identifier, or a `$member` interpolated into a string. */
	private static inline function namesMember(node: QueryNode, member: String, seams: Seams): Bool {
		return node.name == member && (node.kind == seams.identKind || node.kind == seams.shape.stringInterpIdentKind);
	}

	/** Every import of `info` this rule reports, each with its edits when every use of the name is rewritable. */
	private static function findingsOf(
		info: FileInfo, tree: QueryNode, source: String, plugin: GrammarPlugin, seams: Seams, index: SymbolIndex,
		symbols: () -> Null<SymbolIndex>
	): Array<Finding> {
		final out: Array<Finding> = [];
		final header: UsingHeader = UsingScan.headerOf(tree, source, plugin);
		var membersByModule: Null<Map<String, Array<String>>> = null;
		for (imp in info.imports) {
			final module: String = SourceText.parentPath(imp.raw);
			final member: String = SourceText.lastSegment(imp.raw);
			if (imp.kind != ImportKind.Import || imp.guarded || module == '' || SourceText.isUpperInitial(member)) continue;
			if (!SourceText.isUpperInitial(SourceText.lastSegment(module)) || !UsingScan.hasUsingModule(header, module)) continue;
			var known: Null<Array<String>> = plugin.knownExtensionMethods(module);
			if (known == null) {
				membersByModule ??= UsingSites.membersByModule(index);
				known = membersByModule[module];
			}
			if (known == null || !known.contains(member)) continue;
			final target: StaticImport = {
				path: imp.raw,
				module: module,
				member: member,
				span: imp.span
			};
			final finding: Null<Finding> = judge(target, info, tree, source, header, plugin, seams, index, symbols);
			if (finding != null) out.push(finding);
		}
		return out;
	}

	/** The finding for `target`, or null when the file never uses the name (`unused-import`'s). */
	private static function judge(
		target: StaticImport, info: FileInfo, tree: QueryNode, source: String, header: UsingHeader, plugin: GrammarPlugin, seams: Seams,
		index: SymbolIndex, symbols: () -> Null<SymbolIndex>
	): Null<Finding> {
		final uses: Uses = { calls: [], other: false };
		collectUses(tree, target.member, tree, seams, uses);
		if (uses.calls.length == 0 && !uses.other) return null;
		final base: Finding = {
			path: target.path,
			module: target.module,
			member: target.member,
			span: target.span,
			decline: null,
			edits: null
		};
		if (uses.other) return declined(base, '`${target.member}` is also used other than as a call with a receiver');
		final typeName: String = SourceText.lastSegment(target.module);
		final sites: Array<ExtensionSite> = [];
		for (call in uses.calls) {
			final site: Null<ExtensionSite> = siteOf(call, target, typeName, seams);
			if (site == null) return declined(base, 'a call of `${target.member}` has no argument to be the receiver');
			final reason: Null<String> = bindingDecline(site, info, tree, header, index, target);
			if (reason != null) return declined(base, reason);
			sites.push(site);
		}
		final candidates: Array<Null<Candidate>> = PreferStaticExtension.judgeSites(sites, tree, source, info.file, seams, plugin, symbols);
		final edits: Array<FixEdit> = [{ span: target.span, text: '' }];
		for (candidate in candidates) {
			if (candidate == null) return declined(base, 'the extension form of a call could bind another function than `${target.path}`');
			if (candidate.verdict != Verdict.Fixable)
				return declined(base, PreferStaticExtension.declineReasonFor(candidate.verdict) ?? 'a call is not provably rewritable');
			final pair: Null<Array<FixEdit>> = PreferStaticExtension.rewriteEdits(candidate, source);
			if (pair == null) return declined(base, 'a comment sits inside the region the rewrite of a call deletes');
			if (CanonicalEdit.editsOverlapAny(pair, edits)) return declined(base, 'two calls overlap, so they converge on a later pass');
			for (edit in pair) edits.push(edit);
		}
		return {
			path: base.path,
			module: base.module,
			member: base.member,
			span: base.span,
			decline: null,
			edits: edits
		};
	}

	private static function declined(base: Finding, reason: String): Finding {
		return {
			path: base.path,
			module: base.module,
			member: base.member,
			span: base.span,
			decline: reason,
			edits: null
		};
	}

	/** `call` as the site of a static call `Module.member(recv, …)`, or null when it carries no receiver. */
	private static function siteOf(call: QueryNode, target: StaticImport, typeName: String, seams: Seams): Null<ExtensionSite> {
		final span: Null<Span> = call.span;
		if (span == null || call.children.length <= RECEIVER_INDEX) return null;
		final recv: QueryNode = BoolExprShape.unwrapParens(call.children[RECEIVER_INDEX], seams.parenKind);
		return recv.span == null ? null : {
			call: call,
			typeName: typeName,
			module: target.module,
			method: target.member,
			recv: recv,
			callSpan: span
		};
	}

	/**
	 * Why the bare name at `site` may not mean `target` (or the `using` may not reach it), or null when it provably does:
	 * the imports bind it to exactly this static, no member of the enclosing type or its supertypes carries the name — a
	 * member outranks an import — and the module's `using` is in force there.
	 */
	private static function bindingDecline(
		site: ExtensionSite, info: FileInfo, tree: QueryNode, header: UsingHeader, index: SymbolIndex, target: StaticImport
	): Null<String> {
		final at: Int = site.callSpan.from;
		final bound: ImportedStatics = index.values.importedStatics(info, target.member, at);
		if (bound.unknown || bound.statics.length != 1 || bound.statics[0].owner != site.typeName)
			return 'the name `${target.member}` may mean another declaration where it is called';
		final host: Null<TypeDeclMatch> = TypeResolver.enclosingTypeDecl(tree, site.callSpan);
		if (host != null) {
			final members: MemberLookup = index.typing.members;
			if (
				members.memberShadowsExtension(host.name, target.member)
				|| !members.typeProvablyLacksMember(host.name, target.member, info.file, at)
			)
				return 'a member of `${host.name}` or of its supertypes may carry the name `${target.member}`, which outranks the import';
		}
		return UsingScan.usingScopeAt(header, target.module, [at]) == UsingScope.InScope
			? null
			: 'the `using ${target.module}` does not cover this call';
	}

	/**
	 * Sort every unbound use of `member` under `node` into `uses`: a call whose callee is the bare name is a CALL, any other
	 * read — and anything under a reification — is OTHER, which keeps the import. A local or parameter of the name is neither.
	 */
	private static function collectUses(node: QueryNode, member: String, tree: QueryNode, seams: Seams, uses: Uses): Void {
		if (seams.opaqueKinds.contains(node.kind)) {
			if (mentions(node, member, seams)) uses.other = true;
			return;
		}
		final callee: Null<QueryNode> = node.kind == seams.callKind && node.children.length > 0 ? node.children[0] : null;
		if (callee != null && isUse(callee, member, tree, seams)) {
			uses.calls.push(node);
			for (i in 1...node.children.length) collectUses(node.children[i], member, tree, seams, uses);
			return;
		}
		if (isUse(node, member, tree, seams)) {
			uses.other = true;
			return;
		}
		for (child in node.children) collectUses(child, member, tree, seams, uses);
	}

	private static function isUse(node: QueryNode, member: String, tree: QueryNode, seams: Seams): Bool {
		final span: Null<Span> = node.span;
		return namesMember(node, member, seams) && span != null && TypeResolver.resolveBindingFrom(member, span, tree, seams.shape) == null;
	}

	private static function mentions(node: QueryNode, member: String, seams: Seams): Bool {
		return namesMember(node, member, seams) || node.children.exists(child -> mentions(child, member, seams));
	}

}

/** A plain static import `path` = `module`.`member` and the span of its statement. */
private typedef StaticImport = {
	final path: String;
	final module: String;
	final member: String;
	final span: Span;
}

/** The use sites of a bare name: calls with the name as callee, and whether any other use exists. */
private typedef Uses = {
	final calls: Array<QueryNode>;
	var other: Bool;
}

/** One reported import: the reason it is report-only, or the full edit set (call rewrites plus the import's deletion). */
private typedef Finding = {
	final path: String;
	final module: String;
	final member: String;
	final span: Span;
	final decline: Null<String>;
	final edits: Null<Array<FixEdit>>;
}
