package anyparse.check;

import anyparse.query.IndexScope;
import anyparse.query.MemberBranchScan;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags an `inline` instance method that a subtype overrides, at both ends of the pair. The compiler rejects the pair
 * ("Field m is inlined and cannot be overridden") only in a build that compiles the override, so a superclass named in
 * one `#if` branch of an `extends` clause is left for whoever builds that branch. `Severity.Error`; `--fix` drops the
 * `inline` modifier at the inline end, which keeps what every call computes and loses only the inlining (an extern's
 * inline body has no other home, so it is reported only). The relation is the any-build one,
 * `SubtypeGraph.overriddenDeclarations`, asked of the resolution index so an override outside the report still flags the
 * inline method the report holds.
 */
@:nullSafety(Strict)
final class OverriddenInline extends RuleBase {

	/** How the inline end of a finding opens — the end `fix` edits. */
	private static inline final INLINE_END: String = 'inline method ';

	public function new() {
		super(
			'overridden-inline',
			'an inline instance method a subtype overrides through any #if branch of its extends clause, and that override; '
			+ 'Error — the compiler rejects the pair only in a build that compiles the override; --fix drops the inline modifier',
			RuleCategory.Members
		);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final fieldKinds: Array<String> = plugin.refShape().fieldDeclKinds ?? [];
		// The report index answers the local half: a report with no inline method and no override has nothing to pair, and
		// must not pay for the resolution index.
		final local: Array<FileInfo> = IndexScope.report(files, plugin).allFiles();
		if (!local.exists(fi -> fi.types.exists(t -> t.members.exists(m -> isInlineMethod(m, fieldKinds) || isOverride(m))))) return [];
		final index: SymbolIndex = IndexScope.resolution(files, plugin);
		final sources: Map<String, String> = [for (f in files) f.file => f.source];
		final out: Array<Violation> = [];
		for (fi in index.allFiles()) {
			final source: Null<String> = sources[fi.file];
			if (source != null) for (t in fi.types) {
				final owner: ResolvedType = { file: fi, type: t };
				for (m in t.members) {
					final compilerError: String = '"Field ${m.name} is inlined and cannot be overridden"';
					if (isOverride(m)) {
						final inlined: Array<ResolvedType> = index.subtypes.overriddenDeclarations(owner, [m.name])
							.filter(d -> d.type.members.exists(dm -> dm.name == m.name && isInlineMethod(dm, fieldKinds)));
						if (inlined.length > 0)
							out.push(finding(
								fi.file, source, m,
								'\'${m.name}\' overrides inline method ${listed(inlined, m.name)}: every build that compiles this '
								+ 'override fails with $compilerError — drop inline there or this override',
								'the edit is the inline end\'s: --fix drops inline on the overridden method'
							));
					}
					final overriders: Array<ResolvedType> = isInlineMethod(m, fieldKinds) ? overridersOf(index, owner, m.name) : [];
					if (overriders.length > 0)
						out.push(finding(
							fi.file, source, m,
							'$INLINE_END\'${m.name}\' is overridden by ${listed(overriders, null)}: Haxe rejects that override in every '
							+ 'build that compiles it ($compilerError) — drop inline here or the override',
							t.isExtern || m.isExtern ? 'an extern\'s inline body has no other home, so only the override can go' : null
						));
				}
			}
		}
		return out;
	}

	/**
	 * Delete the `inline` modifier of each overridden method — the inline end of a finding; the override end gets no edit.
	 * Removing the modifier keeps what every call computes and loses only the inlining. A modifier only some builds see
	 * (`MemberBranchScan.joinRuns`) is left alone.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final starts: Array<Int> = RunScan.spanStarts(violations.filter(v -> v.declineReason == null && v.message.startsWith(INLINE_END)));
		return starts.length == 0
			? []
			: RunScan.edits(plugin, source, tree -> {
				final shape: RefShape = plugin.refShape();
				final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
				final branch: MemberBranchSeams = MemberBranchScan.seamsOf(shape, source, plugin.lexicalRegions.bind(source));
				final edits: Array<{ span: Span, text: String }> = [];
				for (cls in CheckScan.classBodies(tree))
					MemberBranchScan.eachMember(branch, cls, child -> memberKinds.contains(child.kind), (member, run, certain) -> {
						final at: Null<Span> = member.span;
						if (at == null || !certain) return;
						if (!starts.contains(at.from)) return;
						final modifier: Null<QueryNode> = run.find(n -> n.kind == shape.inlineModifierKind);
						final span: Null<Span> = modifier?.span;
						if (span != null)
							edits.push({ span: new Span(span.from, SourceText.skipSpaces(source, span.to, source.length)), text: '' });
					});
				return edits;
			});
	}

	/** Whether `m` is an instance member carrying the override modifier. */
	private static inline function isOverride(m: MemberInfo): Bool {
		return m.isOverride && !m.isStatic;
	}

	/** Whether `m` is an `inline` instance METHOD — the grammar's field hosts are not methods. */
	private static inline function isInlineMethod(m: MemberInfo, fieldKinds: Array<String>): Bool {
		return m.isInline && !m.isStatic && !fieldKinds.contains(m.kind);
	}

	/** `r`'s package-qualified name, the form a message tells same-named types apart by. */
	private static inline function qualified(r: ResolvedType): String {
		return r.file.pkg == '' ? r.type.name : '${r.file.pkg}.${r.type.name}';
	}

	/**
	 * Every subtype of `owner` whose override of `name` binds to `owner`'s own declaration in some build. The subtype walk
	 * is name-keyed where a link resolves to no declaration, so each candidate is re-proved through the override relation.
	 */
	private static function overridersOf(index: SymbolIndex, owner: ResolvedType, name: String): Array<ResolvedType> {
		final key: String = index.refs.seenKey(owner);
		final seen: Array<String> = [];
		return [
			for (sub in index.subtypes.subtypeDecls(
				owner.type.name, owner.file.file
			)) if (
				sub.type.members.exists(sm -> sm.name == name && isOverride(sm))
				&& index.subtypes.overriddenDeclarations(sub, [name]).exists(d -> index.refs.seenKey(d) == key)
				&& index.refs.markSeen(sub, seen)
			)
				sub
		];
	}

	/** The qualified names of `types`, each followed by `.member` when one is given, comma-joined. */
	private static function listed(types: Array<ResolvedType>, member: Null<String>): String {
		return [for (r in types) member == null ? qualified(r) : '${qualified(r)}.$member'].join(', ');
	}

	/** A finding on the header line of `m`'s declaration, so a `// noqa` inside its body cannot swallow it. */
	private static function finding(file: String, source: String, m: MemberInfo, message: String, declineReason: Null<String>): Violation {
		final end: Int = source.indexOf('\n', m.declFrom);
		return {
			file: file,
			span: new Span(m.declFrom, end < 0 ? source.length : end),
			rule: 'overridden-inline',
			severity: Severity.Error,
			message: message,
			declineReason: declineReason
		};
	}

}
