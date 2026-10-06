package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.Violation;
import anyparse.check.ConfiguredTypes.OwnedMember;
import anyparse.check.PurityScan.PurityCtx;
import anyparse.check.RuleDeclaration.IdiomSpec;
import anyparse.query.BinderScan;
import anyparse.query.GrammarPlugin;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;

using Lambda;

/**
 * Rewrites consecutive writes of a type's fields into the one method call the PROJECT declares equivalent —
 * `p.x = a; p.y = b;` into `p.setTo(a, b);`, `p.x = q.x; p.y = q.y;` into `p.copyFrom(q);`. `Severity.Info`, with an
 * autofix. Inert until the project declares an idiom in `apqlint.json`:
 *
 *     "prefer-api-idiom": { "idioms": [
 *         { "type": "openfl.geom.Point", "fields": ["x", "y"], "method": "setTo" },
 *         { "type": "openfl.geom.Point", "fields": ["x", "y"], "copy": "copyFrom" }
 *     ] }
 *
 * ## The equivalence is the project's declaration
 *
 * Nothing in the tree says that `setTo(a, b)` writes `x = a` then `y = b` and does nothing else; that knowledge belongs
 * to the framework, and the framework is the PROJECT's to name. An idiom states it: the `method` takes one argument per
 * declared field, in the declared order, and writes each to its field; a `copy` method takes one value of the type and
 * writes every declared field from that value's own. The fix is safe BY DECLARATION, so it is an ordinary fix rather
 * than a `RiskyFix`; what the rule proves itself is everything the declaration does not cover — that the sites really
 * are those writes, on that type, in an order the call cannot change.
 *
 * Each idiom is checked against the resolution index before it is used, and dropped with a stderr line when the
 * declaration cannot be the truth: a `type` naming no single declaration, a declared field that is not a plain
 * instance field (a property whose accessor runs code, a method, a static, or nothing), a `method` that is not an
 * instance method of exactly as many parameters as there are fields, a `copy` that does not take one value of the type.
 * An entry the reader cannot parse at all is dropped the same way.
 *
 * ## What a site must be
 *
 * - **A window of adjacent statements**, each `R.f = rhs;` with plain `=`, all on the SAME receiver path `R` (an
 *   identifier, `this`, or a chain of field reads over one), writing EACH declared field exactly once. A write of only
 *   some of the fields is no finding; a run longer than an idiom is matched window by window, so a third write after a
 *   matched pair stands as it is.
 * - **The receiver is EXACTLY the declared type.** Its static type is resolved through the index — a local's or a
 *   parameter's written annotation, a field's declared type on the enclosing type or its ancestors — and compared by
 *   declaration identity, so a namesake in another package is no match. A SUBTYPE matches only under `"subtypes": true`,
 *   because a subclass may override the method with one that is no longer the declared equivalence. An unannotated local
 *   is unresolved and refused.
 * - **Every receiver hop is a plain read.** The writes read the receiver once each; the call reads it once. A hop that is
 *   a property with a getter (or a member the index cannot place) would run code a different number of times, so it is
 *   refused.
 * - **No right-hand side observes an earlier write.** The original reads each right-hand side AFTER the writes above it,
 *   the call reads every argument BEFORE any write. So no right-hand side may mention, as a field read or an identifier,
 *   a field an earlier statement of the window writes — whatever its receiver, because another path may alias this one
 *   (`p.x = 1; p.y = q.x;` with `q == p` reads the new `x` today). And every right-hand side must be pure
 *   (`PurityScan.isPure`): a call could reach the written fields through any alias, and the call form may evaluate the
 *   arguments in an order other than the statements', which purity makes unobservable.
 * - **A `copy` window** reads, on every line, the SAME field of one value path `Q` whose type is the declared type or a
 *   subtype of it (an argument may be a subtype; only the receiver must be exact), and `Q`'s hops are plain reads too.
 * - **No comment is lost.** The fix keeps each carried right-hand side verbatim and deletes everything else in the window,
 *   so a comment anywhere between the window's first statement and the end of its last line refuses — that reach
 *   includes a trailing comment on the last statement, which would otherwise end up describing the whole call. A
 *   `copy` window carries nothing, so its scan covers the right-hand sides too.
 * - **Not inside the declared type or a subtype.** There the window may BE the method's own body (`setTo` writing
 *   `this.x` then `this.y`), and the rewrite would make it call itself. A host whose ancestry the index cannot
 *   resolve is refused too, since it cannot be proved outside.
 *
 * ## Residuals, named
 *
 * - A right-hand side that THROWS (a null receiver of a field read) leaves the earlier fields written in the original
 *   and none in the call. Only a caller that catches the exception and then inspects the object can tell.
 * - `PurityScan` reads an unresolved deep receiver as a plain field read, so a getter reached through a receiver it
 *   cannot type is not seen; such a getter would have to reach the written fields through an alias to matter.
 *
 * ## Grammar-agnostic
 *
 * Driven by `exprStatementKind`, `assignKind`, `fieldAccessKind`, `identKind`, `ControlFlowSupport.blockKinds`,
 * `fieldDeclKinds` / `memberDeclKinds`, `memberTransparentWrapperTypeNames` and `stringInterpIdentKind`; a missing
 * required seam, or a plugin that is no `TypeInfoProvider`, makes the rule a no-op.
 */
@:nullSafety(Strict)
final class PreferApiIdiom implements Check implements ConfigAware implements FileGated {

	/** The rule id, also the `apqlint.json` option key. */
	private static inline final RULE_ID: String = 'prefer-api-idiom';

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'consecutive writes of every field an apqlint.json idiom declares, on one receiver of the declared type, replaceable '
			+ 'with the declared method call (p.x = a; p.y = b; -> p.setTo(a, b))';
	}

	/** `needs-config` while the file's config declares no idiom the reader can parse. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return RuleDeclaration.idioms(config, RULE_ID, []).length == 0 ? 'needs-config' : null;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final symbols: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final validated: Map<String, Array<Idiom>> = [];
		final out: Array<Violation> = [];
		for (entry in files) {
			final specs: Array<IdiomSpec> = specsFor(entry.file);
			if (specs.length == 0) continue;
			final index: Null<SymbolIndex> = symbols();
			if (index == null) return out;
			final idioms: Array<Idiom> = validatedFor(specs, index, seams, validated);
			if (idioms.length == 0) continue;
			for (m in matchesIn(entry.file, entry.source, idioms, index, seams, plugin)) out.push({
				file: entry.file,
				span: m.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: m.message
			});
		}
		return out;
	}

	/**
	 * Re-derive every site against the plugin's resolution index — the scope `run` proved the gates on — and rewrite the
	 * ones a violation names. The narrower report index `index` is the fallback for a plugin carrying no resolution scope.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		if (violations.length == 0) return [];
		final file: String = RunScan.oneFile(violations, RULE_ID);
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final resolved: SymbolIndex = RefactorSupport.resolutionIndexOf(plugin) ?? index ?? SymbolIndex.build(
			[{ file: file, source: source }], plugin
		);
		final idioms: Array<Idiom> = validatedFor(specsFor(file), resolved, seams, []);
		final wanted: Array<String> = RunScan.spanKeys(violations);
		return ([
			for (m in matchesIn(
				file, source, idioms, resolved, seams, plugin
			)) if (wanted.contains('${m.span.from}:${m.span.to}')) { span: m.span, text: m.text }
		]: Array<FixEdit>);
	}

	/** The idiom specs `file`'s config declares, printing every reader problem once. */
	private function specsFor(file: String): Array<IdiomSpec> {
		final problems: Array<String> = [];
		final specs: Array<IdiomSpec> = RuleDeclaration.idioms(LintConfig.resolveWith(_resolveConfig, file), RULE_ID, problems);
		for (p in problems) ConfiguredTypes.warn(RULE_ID, p);
		return specs;
	}

	/**
	 * The idioms of `specs` the resolution index confirms, in declared order: the type resolves to one declaration, every
	 * field is a plain instance field of it, and the method takes what the idiom hands it. A spec failing any of these is
	 * dropped and named in `problems`.
	 */
	public static function validate(
		specs: Array<IdiomSpec>, index: SymbolIndex, fieldKinds: Array<String>, memberKinds: Array<String>, typeSyntax: TypeSyntaxReader,
		problems: Array<String>
	): Array<Idiom> {
		final out: Array<Idiom> = [];
		for (spec in specs) {
			final type: Null<ResolvedType> = ConfiguredTypes.resolve(index, spec.type);
			if (type == null) {
				problems.push('"${spec.type}" names no single type in the resolution scope — idiom dropped');
				continue;
			}
			final declared: ResolvedType = type;
			final badField: Null<String> = spec.fields.find(f -> !isPlainField(ConfiguredTypes.memberOf(index, declared, f), fieldKinds));
			if (badField != null) {
				problems.push(
					'"${spec.type}.$badField" is not a plain instance field (a property with an accessor, a method, a static, or '
					+ 'nothing) — idiom dropped'
				);
				continue;
			}
			final method: String = spec.method ?? spec.copy ?? '';
			final arity: Int = spec.copy != null ? 1 : spec.fields.length;
			final owned: Null<OwnedMember> = ConfiguredTypes.memberOf(index, declared, method);
			if (!isMethodOf(owned, arity, fieldKinds, memberKinds)) {
				problems.push('"${spec.type}.$method" is not an instance method of $arity parameter(s) — idiom dropped');
				continue;
			}
			if (spec.copy != null && !copiesFrom(owned, declared, index, typeSyntax)) {
				problems.push('"${spec.type}.$method" does not take a "${spec.type}" — copy idiom dropped');
				continue;
			}
			out.push({ spec: spec, type: declared });
		}
		return out;
	}

	/** `validate` memoised per distinct spec list, printing every problem once. */
	private static function validatedFor(
		specs: Array<IdiomSpec>, index: SymbolIndex, seams: Seams, memo: Map<String, Array<Idiom>>
	): Array<Idiom> {
		final key: String = [
			for (s in specs) '${s.type}|${s.fields.join(',')}|${s.method}|${s.copy}|${s.subtypes}'
		].join(';');
		final known: Null<Array<Idiom>> = memo[key];
		if (known != null) return known;
		final problems: Array<String> = [];
		final idioms: Array<Idiom> = validate(specs, index, seams.fieldKinds, seams.memberKinds, seams.typeSyntax, problems);
		for (p in problems) ConfiguredTypes.warn(RULE_ID, p);
		// Longest first, and a copy before a method of the same width: the sliding match takes the first idiom that fits.
		idioms.sort((a, b) ->
			b.spec.fields.length - a.spec.fields.length != 0
				? b.spec.fields.length - a.spec.fields.length
				: (a.spec.copy != null ? 0 : 1) - (b.spec.copy != null ? 0 : 1)
		);
		memo[key] = idioms;
		return idioms;
	}

	/** Whether `owned` is a plain INSTANCE field: a field kind, no accessor that runs code, not static, not `#if`-guarded. */
	private static function isPlainField(owned: Null<OwnedMember>, fieldKinds: Array<String>): Bool {
		if (owned == null) return false;
		final m: MemberInfo = owned.member;
		return fieldKinds.contains(m.kind) && !m.hasGetter && !m.hasSetter && !m.isStatic && !m.guarded;
	}

	/** Whether `owned` is an instance method of exactly `arity` parameters with one signature. */
	private static function isMethodOf(owned: Null<OwnedMember>, arity: Int, fieldKinds: Array<String>, memberKinds: Array<String>): Bool {
		if (owned == null) return false;
		final m: MemberInfo = owned.member;
		return memberKinds.contains(m.kind) && !fieldKinds.contains(m.kind) && !m.isStatic && !m.isOverload && !m.hasOverloadMeta
			&& !m.isMacro && m.paramTypeSources.length == arity;
	}

	/** Whether the copy method `owned`'s one parameter is written as the idiom type, read in the declaring file's scope. */
	private static function copiesFrom(
		owned: Null<OwnedMember>, type: ResolvedType, index: SymbolIndex, typeSyntax: TypeSyntaxReader
	): Bool {
		if (owned == null) return false;
		final param: Null<String> = owned.member.paramTypeSources[0];
		if (param == null) return false;
		final resolved: Null<ResolvedType> = ConfiguredTypes.resolveWritten(index, param, owned.owner.file, [], typeSyntax);
		return resolved != null && ConfiguredTypes.same(index, resolved, type);
	}

	/** The seams the rule reads, or null when a required one is unset or the plugin types nothing. */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final exprStmtKind: Null<String> = shape.exprStatementKind;
		final assignKind: Null<String> = shape.assignKind;
		final fieldKind: Null<String> = shape.fieldAccessKind;
		final identKind: Null<String> = shape.identKind;
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final memberKinds: Array<String> = shape.memberDeclKinds ?? [];
		final typed: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final blockKinds: Array<String> = plugin.controlFlowSupport()?.blockKinds() ?? [];
		return exprStmtKind == null || assignKind == null || fieldKind == null || identKind == null || fieldKinds.length == 0
			|| memberKinds.length == 0 || typed == null || blockKinds.length == 0
			? null
			: {
				shape: shape,
				typed: typed,
				exprStmtKind: exprStmtKind,
				assignKind: assignKind,
				fieldKind: fieldKind,
				identKind: identKind,
				interpIdentKind: shape.stringInterpIdentKind,
				blockKinds: blockKinds,
				opaqueKinds: shape.opaqueKinds ?? [],
				fieldKinds: fieldKinds,
				memberKinds: memberKinds,
				wrappers: shape.memberTransparentWrapperTypeNames ?? [],
				selfText: shape.selfReferenceText,
				typeSyntax: plugin.typeSyntax
			};
	}

	/** Every idiom site in `source`, gates applied, each with its replacement. */
	private static function matchesIn(
		file: String, source: String, idioms: Array<Idiom>, index: SymbolIndex, seams: Seams, plugin: GrammarPlugin
	): Array<Match> {
		if (idioms.length == 0) return [];
		final info: Null<FileInfo> = index.fileInfo(file);
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (info == null || tree == null) return [];
		final root: QueryNode = tree;
		final fileInfo: FileInfo = info;
		final purity: Null<PurityCtx> = PurityScan.contextOf(plugin, source, root, index);
		if (purity == null) return [];
		final readPurity: PurityCtx = purity;
		final ctx: Ctx = {
			source: source,
			file: file,
			info: fileInfo,
			root: root,
			index: index,
			seams: seams,
			idioms: idioms,
			purity: readPurity,
			declaredTypeSources: seams.typed.declaredTypeSources(source),
			invisibleBinders: BinderScan.resolverInvisibleBinderNames(root, seams.shape)
		};
		final out: Array<Match> = [];
		walk(root, ctx, out);
		return out;
	}

	/** Descend `node`, scanning every statement list; a reification subtree is skipped wholesale. */
	private static function walk(node: QueryNode, ctx: Ctx, out: Array<Match>): Void {
		if (ctx.seams.opaqueKinds.contains(node.kind)) return;
		if (ctx.seams.blockKinds.contains(node.kind)) scanStatements(node.children, ctx, out);
		for (child in node.children) walk(child, ctx, out);
	}

	/** Split `kids` into maximal runs of field writes on one receiver path and match each run. */
	private static function scanStatements(kids: Array<QueryNode>, ctx: Ctx, out: Array<Match>): Void {
		var i: Int = 0;
		while (i < kids.length) {
			final head: Null<Write> = writeOf(kids[i], ctx.seams);
			if (head == null) {
				i++;
				continue;
			}
			final run: Array<Write> = [head];
			var j: Int = i + 1;
			while (j < kids.length) {
				final next: Null<Write> = writeOf(kids[j], ctx.seams);
				if (next == null || next.recvKey != head.recvKey) break;
				run.push(next);
				j++;
			}
			matchRun(run, ctx, out);
			i = j;
		}
	}

	/** `stmt` as a plain `R.f = rhs;` over a receiver PATH, or null. */
	private static function writeOf(stmt: QueryNode, seams: Seams): Null<Write> {
		if (stmt.kind != seams.exprStmtKind || stmt.children.length != 1) return null;
		final assign: QueryNode = stmt.children[0];
		if (assign.kind != seams.assignKind || assign.children.length != 2) return null;
		final lhs: QueryNode = assign.children[0];
		final field: Null<String> = lhs.name;
		final stmtSpan: Null<Span> = stmt.span;
		if (lhs.kind != seams.fieldKind || lhs.children.length != 1 || field == null || stmtSpan == null) return null;
		final recv: QueryNode = lhs.children[0];
		final path: Null<Array<String>> = NominalTypes.pathOf(recv, seams.identKind, seams.fieldKind);
		final rhs: QueryNode = assign.children[1];
		return path == null || recv.span == null || rhs.span == null ? null : {
			span: stmtSpan,
			field: field,
			recv: recv,
			recvPath: path,
			recvKey: path.join('.'),
			rhs: rhs
		};
	}

	/** Slide over `run` and emit each window an idiom of the receiver's type claims. */
	private static function matchRun(run: Array<Write>, ctx: Ctx, out: Array<Match>): Void {
		final candidates: Array<Idiom> = [for (idiom in ctx.idioms) if (idiom.spec.fields.length <= run.length) idiom];
		if (candidates.length == 0) return;
		final recvType: Null<ResolvedType> = pathType(run[0].recv, run[0].recvPath, ctx);
		if (recvType == null) return;
		final applicable: Array<Idiom> = [for (idiom in candidates) if (receiverMatches(recvType, idiom, ctx.index)) idiom];
		var s: Int = 0;
		while (s < run.length) {
			var matched: Null<Match> = null;
			for (idiom in applicable) if (s + idiom.spec.fields.length <= run.length) {
				matched = windowMatch(run.slice(s, s + idiom.spec.fields.length), idiom, ctx);
				if (matched != null) break;
			}
			if (matched == null) {
				s++;
				continue;
			}
			out.push(matched);
			s += matched.width;
		}
	}

	/** Whether a receiver of type `recvType` is one `idiom` speaks for: the declared type, or a subtype when it opts in. */
	private static function receiverMatches(recvType: ResolvedType, idiom: Idiom, index: SymbolIndex): Bool {
		return ConfiguredTypes.same(index, recvType, idiom.type) || idiom.spec.subtypes
			&& ConfiguredTypes.inherits(index, recvType, idiom.type) == true;
	}

	/** `window` as a site of `idiom`, with its replacement, or null when a gate refuses. */
	private static function windowMatch(window: Array<Write>, idiom: Idiom, ctx: Ctx): Null<Match> {
		final fields: Array<String> = idiom.spec.fields;
		final written: Array<String> = [for (w in window) w.field];
		if (fields.exists(f -> !written.contains(f)) || written.exists(f -> !fields.contains(f))) return null;
		// inside the type itself or a subtype, the window may BE the method's own body: rewriting it would recurse
		final host: Null<ResolvedType> = enclosingType(window[0].span, ctx);
		if (host == null || ConfiguredTypes.inherits(ctx.index, host, idiom.type) != false) return null;
		final copy: Null<String> = idiom.spec.copy;
		final from: Int = window[0].span.from;
		final last: Write = window[window.length - 1];
		final lineEnd: Int = endOfLine(ctx.source, last.span.to);
		final recvSpan: Null<Span> = window[0].recv.span;
		if (recvSpan == null) return null;
		final recvText: String = ctx.source.substring(recvSpan.from, recvSpan.to);
		final text: String = if (copy != null) {
			if (CheckScan.hasCommentMarker(ctx.source, from, lineEnd)) return null;
			final value: Null<QueryNode> = copySource(window, idiom, ctx);
			final valueSpan: Null<Span> = value?.span;
			if (valueSpan == null) return null;
			'$recvText.$copy(${ctx.source.substring(valueSpan.from, valueSpan.to)});';
		} else {
			if (!carriedOnly(window, ctx.source, lineEnd)) return null;
			for (k in 0...window.length) {
				final earlier: Array<String> = [for (w in window.slice(0, k)) w.field];
				if (!PurityScan.isPure(window[k].rhs, ctx.purity) || mentionsAny(window[k].rhs, earlier, ctx.seams)) return null;
			}
			final args: Array<String> = [for (f in fields) rhsText(window.find(w -> w.field == f), ctx.source)];
			'$recvText.${idiom.spec.method}(${args.join(', ')});';
		};
		final method: String = copy ?? idiom.spec.method ?? '';
		return {
			span: new Span(from, last.span.to),
			text: text,
			width: window.length,
			message: 'writes of $recvText.' + fields.join(', $recvText.')
				+ ' are one ${idiom.spec.type}.$method call — write $recvText.$method(…)'
		};
	}

	/**
	 * The one value path every line of a `copy` window reads its own field from — `q` in `p.x = q.x; p.y = q.y;` — when
	 * its type is the idiom's or a subtype of it and its hops are plain reads; null otherwise.
	 */
	private static function copySource(window: Array<Write>, idiom: Idiom, ctx: Ctx): Null<QueryNode> {
		var value: Null<QueryNode> = null;
		var key: Null<String> = null;
		for (k in 0...window.length) {
			final rhs: QueryNode = window[k].rhs;
			if (rhs.kind != ctx.seams.fieldKind || rhs.name != window[k].field || rhs.children.length != 1) return null;
			final path: Null<Array<String>> = NominalTypes.pathOf(rhs.children[0], ctx.seams.identKind, ctx.seams.fieldKind);
			if (path == null || key != null && path.join('.') != key) return null;
			// a hop of the value path named after a field written above would read the NEW value there
			if (path.exists(seg -> window.slice(0, k).exists(w -> w.field == seg))) return null;
			key = path.join('.');
			value = rhs.children[0];
		}
		final source: Null<QueryNode> = value;
		if (source == null) return null;
		final path: Null<Array<String>> = NominalTypes.pathOf(source, ctx.seams.identKind, ctx.seams.fieldKind);
		if (path == null) return null;
		final type: Null<ResolvedType> = pathType(source, path, ctx);
		return type != null
			&& (ConfiguredTypes.same(ctx.index, type, idiom.type) || ConfiguredTypes.inherits(ctx.index, type, idiom.type) == true)
			? source
			: null;
	}

	/**
	 * Whether every byte the method rewrite DELETES is free of a comment: the window from its first statement to the end
	 * of its last line, minus the right-hand sides it carries verbatim.
	 */
	private static function carriedOnly(window: Array<Write>, source: String, lineEnd: Int): Bool {
		var cursor: Int = window[0].span.from;
		for (w in window) {
			final rhsSpan: Null<Span> = w.rhs.span;
			if (rhsSpan == null || CheckScan.hasCommentMarker(source, cursor, rhsSpan.from)) return false;
			cursor = rhsSpan.to;
		}
		return !CheckScan.hasCommentMarker(source, cursor, lineEnd);
	}

	/** The verbatim text of the right-hand side of `w`. */
	private static function rhsText(w: Null<Write>, source: String): String {
		final span: Null<Span> = w?.rhs.span;
		return span == null ? '' : source.substring(span.from, span.to);
	}

	/** Whether `node`'s subtree names one of `names` as a field read, an identifier or an interpolated identifier. */
	private static function mentionsAny(node: QueryNode, names: Array<String>, seams: Seams): Bool {
		if (names.length == 0) return false;
		final name: Null<String> = node.name;
		if (
			name != null && names.contains(name)
			&& (node.kind == seams.fieldKind || node.kind == seams.identKind || node.kind == seams.interpIdentKind)
		)
			return true;
		return node.children.exists(c -> mentionsAny(c, names, seams));
	}

	/**
	 * The resolved static type of the PATH `node` (`path` its segments), proving every hop a plain read — a local's or
	 * parameter's written annotation for the root, or a field of the enclosing type for `this` and for a bare member name,
	 * then one field per segment. Null on any unresolved link, any getter or setter property, any `#if`-guarded member.
	 */
	private static function pathType(node: QueryNode, path: Array<String>, ctx: Ctx): Null<ResolvedType> {
		var rootNode: QueryNode = node;
		while (rootNode.kind == ctx.seams.fieldKind && rootNode.children.length == 1) rootNode = rootNode.children[0];
		final rootSpan: Null<Span> = rootNode.span;
		if (rootSpan == null) return null;
		var current: Null<ResolvedType> = if (path[0] == ctx.seams.selfText) {
			enclosingType(rootSpan, ctx);
		} else if (TypeResolver.bindsToValueDeclaration(path[0], rootSpan, ctx.root, ctx.seams.shape)) {
			final written: Null<String> = TypeResolver.identDeclaredTypeSource(
				rootNode, ctx.seams.shape, ctx.root, () -> ctx.declaredTypeSources, false
			);
			written == null ? null : ConfiguredTypes.resolveWritten(ctx.index, written, ctx.info, ctx.seams.wrappers, ctx.seams.typeSyntax);
		} else {
			// a bare member name: refused when a binder the resolver cannot see might shadow it
			final hidden: Null<Array<String>> = ctx.invisibleBinders;
			final owner: Null<ResolvedType> = hidden == null || hidden.contains(path[0]) ? null : enclosingType(rootSpan, ctx);
			owner == null ? null : fieldType(owner, path[0], ctx);
		};
		for (i in 1...path.length) {
			final cur: Null<ResolvedType> = current;
			if (cur == null) return null;
			current = fieldType(cur, path[i], ctx);
		}
		return current;
	}

	/** The type of `cur`'s plain field `name`, resolved where it is written; null for anything but a plain unguarded field. */
	private static function fieldType(cur: ResolvedType, name: String, ctx: Ctx): Null<ResolvedType> {
		final owned: Null<OwnedMember> = ConfiguredTypes.memberOf(ctx.index, cur, name);
		if (owned == null) return null;
		final m: MemberInfo = owned.member;
		final written: Null<String> = m.typeSource;
		return !ctx.seams.fieldKinds.contains(m.kind) || m.hasGetter || m.guarded || written == null
			? null
			: ConfiguredTypes.resolveWritten(ctx.index, written, owned.owner.file, ctx.seams.wrappers, ctx.seams.typeSyntax);
	}

	/** The resolved type whose declaration encloses `span` in the linted file, or null. */
	private static function enclosingType(span: Span, ctx: Ctx): Null<ResolvedType> {
		final name: Null<String> = TypeResolver.enclosingTypeName(ctx.root, span);
		return name == null ? null : ctx.index.refs.findDeclaredType(ctx.file, name);
	}

	/** The offset of the line break ending the line `pos` sits on, or the source end. */
	private static function endOfLine(source: String, pos: Int): Int {
		final nl: Int = source.indexOf('\n', pos);
		return nl < 0 ? source.length : nl;
	}

}

/** An idiom the resolution index confirmed, with its type resolved. */
typedef Idiom = {
	final spec: IdiomSpec;
	final type: ResolvedType;
}

/** One `R.f = rhs;` statement. */
private typedef Write = {
	final span: Span;
	final field: String;
	final recv: QueryNode;
	final recvPath: Array<String>;
	final recvKey: String;
	final rhs: QueryNode;
}

/** One matched window: the span it replaces, the call that replaces it, how many statements it took, and the message. */
private typedef Match = {
	final span: Span;
	final text: String;
	final width: Int;
	final message: String;
}

/** The seams the rule reads, resolved once per run. */
private typedef Seams = {
	final shape: RefShape;
	final typed: TypeInfoProvider;
	final exprStmtKind: String;
	final assignKind: String;
	final fieldKind: String;
	final identKind: String;
	final interpIdentKind: Null<String>;
	final blockKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final fieldKinds: Array<String>;
	final memberKinds: Array<String>;
	final wrappers: Array<String>;
	final selfText: Null<String>;
	final typeSyntax: TypeSyntaxReader;
}

/** Per-file state of one scan. */
private typedef Ctx = {
	final source: String;
	final file: String;
	final info: FileInfo;
	final root: QueryNode;
	final index: SymbolIndex;
	final seams: Seams;
	final idioms: Array<Idiom>;
	final purity: PurityCtx;
	final declaredTypeSources: Map<Int, String>;
	final invisibleBinders: Null<Array<String>>;
}
