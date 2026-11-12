package anyparse.grammar.haxe;

import anyparse.check.scan.CheckScan;
import anyparse.format.OptionsSource;
import anyparse.macro.OptionKnobs;
import anyparse.query.AddImport;
import anyparse.query.CanonicalEdit;
import anyparse.query.CtorFieldFold;
import anyparse.query.ElementSpan;
import anyparse.query.GrammarPlugin;
import anyparse.query.Matcher;
import anyparse.query.NominalTypes;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.Rewrite;
import anyparse.query.SetModifier;
import anyparse.query.SourceSlice;
import anyparse.query.TreePath;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.runtime.Span;
import haxe.Exception;

using anyparse.util.Strings;

/**
 * The one answer to "how does a test's `hxformat.json` call become typed `HxModuleWriteOptions`, by an op rather than by hand": every
 * `HaxeFormatConfigLoader.loadHxFormatJson(<literal>)` / `loadHxFormatJson(<literal>)`, `<kit>.strictJson(<literal>)` and
 * `HxWriteConfig.ofJson(<literal>)` of a Haxe source becomes `<kit>.forkWith(edited -> edited.<knob> = <value>)`
 * over the same baseline, `loadHxFormatJson('{}')`: a block of
 * assignments for several knobs, the baseline call itself for none. A call whose options are the test's subject — only read by field,
 * never handed on — stays on its document and is named, since its typed edit would assert itself.
 * A `HxWriteFixture.triviaWrite` / `plainWrite` call keeps its source argument and
 * has only the configuration replaced, left as it is when it already is the typed edit or a value the file types as the options.
 * An argument naming a `final` that holds a constant string, read by those calls only and by no other module, is rewritten once, at
 * its declaration.
 *
 * An assignment is written for each knob whose value the document changed from that baseline, so a key that fans out over several
 * knobs, or cascades, is rewritten as the knobs it ended up setting and the options stay equal by construction. The rewrite refuses,
 * writing nothing, a document the loader does not act on (`HaxeFormatConfigDiagnostics`, the keys it names), a document that does
 * not load, a knob changed to a value with no source spelling, an argument that is neither a constant string nor such a `final`, and
 * a `final` read anywhere else.
 */
@:nullSafety(Strict)
final class HxTypedOptionsRewrite {

	/** How much of a refused call a message quotes. */
	private static inline final CALL_EXCERPT: Int = 80;

	/**
	 * The name a parse of the source is reported under.
	 */
	private static final PARSED_AS: String = 'source';

	/** The node of `a + b`, which joins two constant strings into one. */
	private static final CONCATENATION_KIND: String = 'Add';

	/** A local `final`, a declaration the rewrite may retype. */
	private static final LOCAL_FINAL_KIND: String = 'FinalStmt';

	/** A member `final`, a declaration the rewrite may retype when no other module can read it. */
	private static final MEMBER_FINAL_KIND: String = 'FinalMember';

	/** The type a retyped `final` is written with, imported where the package differs. */
	private static final OPTIONS_TYPE: String = 'anyparse.grammar.haxe.HxModuleWriteOptions';

	/** The loader whose `loadHxFormatJson('{}')` is the baseline every typed edit forks; a document equal to it is written as that call. */
	private static final LOADER_TYPE: String = 'anyparse.grammar.haxe.HaxeFormatConfigLoader';

	/** A field read, the one use of loaded options that leaves them the test's subject. */
	private static final FIELD_ACCESS_KIND: String = 'FieldAccess';

	/**
	 * `source` with each hxformat.json call turned into the typed edit of `kit` (a qualified type with `forkWith`), the imports that edit
	 * needs added; `Ok(source, 0)` when it holds none.
	 */
	public static function rewrite(
		source: String, kit: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String, ?subjects: Array<String>
	): EditResult {
		final knobs: Array<OptionKnob> = OptionKnobs.of(HxModuleWriteOptions);
		final imports: Array<String> = [];
		final kitName: String = kit.allAfterLast('.');
		var text: String = source;
		final run: Run = {
			source: source,
			kitName: kitName,
			knobs: knobs,
			imports: imports,
			plugin: plugin,
			sites: 0,
			tree: null,
			subjects: subjects ?? []
		};
		switch namedConfigs(source, run, reformat, optsJson) {
			case Err(message):
				return Err(message);
			case Ok(converted, _):
				text = converted;
		}
		for (site in callShapes(kitName)) {
			run.source = text;
			run.tree = null;
			switch Rewrite.rewriteBy(text, site.pattern, reformat, plugin, optsJson, false, m -> replacement(m, run, site)) {
				case Err(message):
					return Err(message);
				case Ok(rewritten, _):
					text = rewritten;
			}
		}
		if (run.sites == 0) return Ok(source, 0);
		if (text.indexOf('$kitName.') >= 0) imports.push(kit);
		return withImports(text, imports, reformat, plugin, optsJson, run.sites);
	}

	/** The call shapes the rewrite reads; `strictJson` is the kit's own refusing loader, so it is spelled with the kit's simple name. */
	private static function callShapes(kitName: String): Array<Site> {
		return [
			{ pattern: 'HaxeFormatConfigLoader.loadHxFormatJson($$json)', asConfig: false, argumentOnly: false },
			{ pattern: 'loadHxFormatJson($$json)', asConfig: false, argumentOnly: false },
			{ pattern: '$kitName.strictJson($$json)', asConfig: false, argumentOnly: false },
			{ pattern: 'HxWriteConfig.ofJson($$json)', asConfig: true, argumentOnly: false },
			{ pattern: 'HxWriteFixture.triviaWrite($$source, $$json)', asConfig: false, argumentOnly: true },
			{ pattern: 'HxWriteFixture.plainWrite($$source, $$json)', asConfig: false, argumentOnly: true }
		];
	}

	private static function replacement(m: Match, run: Run, site: Site): Replacement {
		final whole: String = SourceSlice.slice(run.source, m.span);
		final at: String = excerpt(whole);
		final argument: Null<QueryNode> = m.bindings['json'];
		if (!site.argumentOnly && subject(m, run, true)) return Spliced(whole, []);
		if (!site.argumentOnly) return switch typedEdit(literalOf(argument), at, run, whole) {
			case Spliced(fork, _): Spliced(site.asConfig ? 'HxWriteConfig.ofOptions($fork)' : fork, []);
			case refused: refused;
		};
		final edits: Array<Edit> = [];
		final source: Null<QueryNode> = m.bindings[PARSED_AS];
		if (source != null) {
			final refusal: Null<String> = nestedEdits(source, run, edits);
			if (refusal != null) return Refused(refusal);
		}
		final replaced: Null<Span> = argument?.span;
		if (
			argument != null && replaced != null && !isTypedConfig(argument, run.kitName, run.plugin) && !typedValue(argument, run)
		) switch typedEdit(literalOf(argument), at, run) {
			case Spliced(fork, _):
				final target: Span = replaced;
				edits.push({ span: target, text: fork });
			case refused:
				return refused;
		}
		return Spliced(applied(whole, m.span.from, edits), []);
	}

	/**
	 * The text of a constant string — a string literal with no interpolation, or a concatenation of them — decoded; null for anything
	 * else.
	 */
	private static function literalOf(node: Null<QueryNode>): Null<String> {
		if (node == null) return null;
		if (node.kind == CONCATENATION_KIND && node.children.length == 2) {
			final left: Null<String> = literalOf(node.children[0]);
			if (left == null) return null;
			final right: Null<String> = literalOf(node.children[1]);
			return right == null ? null : '$left$right';
		}
		final raw: Null<String> = rawOf(node);
		return raw == null || HxStringEscape.carriesEscapedDollar(raw)
			? null
			: HxStringEscape.decode(raw).map(c -> String.fromCharCode(c.code)).join('');
	}

	private static function withImports(
		text: String, wanted: Array<String>, reformat: Bool, plugin: GrammarPlugin, optsJson: Null<String>, total: Int
	): EditResult {
		final tree: QueryNode = switch ParseGate.parse(plugin, text, PARSED_AS) {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};
		final held: Array<String> = [];
		var pack: String = '';
		for (c in tree.children) switch c.kind {
			case 'ImportDecl':
				held.push(c.name ?? '');
			case 'PackageDecl':
				pack = c.name ?? '';
			case _:
		}
		var result: String = text;
		for (path in wanted) if (!held.contains(path) && path.substring(0, path.lastIndexOf('.')) != pack) {
			held.push(path);
			switch AddImport.addImport(result, path, false, reformat, plugin, optsJson) {
				case Err(message):
					return Err(message);
				case Ok(added, _):
					result = added;
			}
		}
		return Ok(result, total);
	}

	/** The source text between the quotes of a string literal node with no interpolation in it; null for any other node. */
	private static function rawOf(node: QueryNode): Null<String> {
		final name: Null<String> = node.name;
		if (node.kind == 'DoubleStringExpr') return name == null ? null : name.substring(1, name.length - 1);
		if (node.kind != 'SingleStringExpr') return null;
		if (node.children.length == 0) return '';
		return node.children.length == 1 && node.children[0].kind == 'Literal' ? node.children[0].name : null;
	}

	/**
	 * Whether `node` already is a typed configuration (the kit's edit or
	 * its `HxWriteConfig.ofOptions` wrapper), so a second run leaves it.
	 */
	private static function isTypedConfig(node: QueryNode, kitName: String, plugin: GrammarPlugin): Bool {
		for (shape in [
			'$kitName.forkWith($$_)',
			'$kitName.rawWith($$_)',
			'HxWriteConfig.ofOptions($$_)',
			'${LOADER_TYPE.allAfterLast('.')}.loadHxFormatJson($$_)',
			'loadHxFormatJson($$_)'
		]) for (found in Matcher.search(plugin.parsePattern(shape), node)) if (found.node == node) return true;
		return false;
	}

	/**
	 * The typed edit of the document `json` (null when the configuration holds none), `Spliced` as the text of the call that builds it;
	 * counted as one rewritten call.
	 */
	private static function typedEdit(json: Null<String>, at: String, run: Run, ?current: String): Replacement {
		if (json == null)
			return Refused('$at: the argument is not a constant string, nor a `final` holding one, so there is no document to read');
		try {
			final ignored: Array<String> = HaxeFormatConfigDiagnostics.ignored(HaxeFormatConfigDiagnostics.diagnose(json));
			if (ignored.length > 0) return Refused('$at: hxformat.json settings the loader does not act on: ${ignored.join('; ')}');
			final base: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
			final edits: Array<String> = OptionsSource.changes(run.knobs, base, HaxeFormatConfigLoader.loadHxFormatJson(json), run.imports)
				.map(c -> 'edited.${c.name} = ${c.source}');
			if (edits.length == 0) {
				final baseline: String = '${LOADER_TYPE.allAfterLast('.')}.loadHxFormatJson(\'{}\')';
				if (baseline == current) return Spliced(baseline, []);
				run.sites++;
				run.imports.push(LOADER_TYPE);
				return Spliced(baseline, []);
			}
			run.sites++;
			final body: String = edits.length == 1 ? edits[0] : '{ ${edits.map(e -> '$e;').join(' ')} }';
			return Spliced('${run.kitName}.forkWith(edited -> $body)', []);
		} catch (exception: Exception) {
			return Refused('$at: ${exception.message}');
		}
	}

	/**
	 * The edits of the fixture calls inside `node`, a fixture call's source argument, appended to `edits` outermost first: the outer match
	 * of a pass covers them, so they are read here, each through `replacement`. The refusal of one of them, or null.
	 */
	private static function nestedEdits(node: QueryNode, run: Run, edits: Array<Edit>): Null<String> {
		final found: Array<Found> = [
			for (site in callShapes(run.kitName))
				if (site.argumentOnly) for (m in Matcher.search(run.plugin.parsePattern(site.pattern), node)) { match: m, site: site }
		];
		found.sort(outerFirst);
		var reached: Int = -1;
		for (f in found) {
			final span: Span = f.match.span;
			if (span.from < reached) continue;
			reached = span.to;
			switch replacement(f.match, run, f.site) {
				case Refused(message):
					return message;
				case Spliced(text, _):
					if (text != SourceSlice.slice(run.source, span)) edits.push({ span: span, text: text });
			}
		}
		return null;
	}

	/**
	 * `whole`, the source text of a span starting at `from`, with each of
	 * `edits` (inside that span, apart) put in place of what it covers.
	 */
	private static function applied(whole: String, from: Int, edits: Array<Edit>): String {
		var text: String = whole;
		final ordered: Array<Edit> = edits.copy();
		ordered.sort((a, b) -> b.span.from - a.span.from);
		for (e in ordered) text = text.substring(0, e.span.from - from) + e.text + text.substring(e.span.to - from);
		return text;
	}

	/** Document order, an enclosing match before the matches inside it. */
	private static function outerFirst(a: Found, b: Found): Int {
		final left: Span = a.match.span;
		final right: Span = b.match.span;
		return left.from != right.from ? left.from - right.from : right.to - left.to;
	}

	/**
	 * `source` with each `final` that holds a constant string and is read only as the configuration argument of a call shape turned, once,
	 * into the typed options: the declaration holds the typed edit, a loader call reading it becomes the name, a fixture call keeps reading
	 * it. A `final` read anywhere else refuses the source, so no reader is
	 * left expecting the string; `Ok(source, 0)` when no call reads one.
	 */
	private static function namedConfigs(source: String, run: Run, reformat: Bool, optsJson: Null<String>): EditResult {
		final tree: QueryNode = switch ParseGate.parse(run.plugin, source, PARSED_AS) {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};
		final shape: RefShape = run.plugin.refShape();
		final edits: Array<Edit> = [];
		for (entry in namedReads(tree, source, run, shape)) {
			final refusal: Null<String> = namedEdits(entry, source, tree, run, shape, edits);
			if (refusal != null) return Err(refusal);
		}
		if (edits.length == 0) return Ok(source, 0);
		run.imports.push(OPTIONS_TYPE);
		return CanonicalEdit.canonicalize(source, edits, reformat, run.plugin, optsJson);
	}

	/**
	 * Whether the `final` `decl` may be retyped, as the edits of its modifier run — an `inline` dropped, since the retyped value, a call,
	 * is no constant — or why not. A member is retyped only where no other module can read it: in a `final class`, not `public`, and
	 * with no access-granting meta on it or on its type; an access-taking meta in another module stays out of reach.
	 */
	private static function retyping(decl: QueryNode, tree: QueryNode, source: String, run: Run, shape: RefShape): Retyping {
		if (decl.kind == LOCAL_FINAL_KIND) return Open([]);
		final type: Null<QueryNode> = TreePath.parentOf(tree, decl);
		final wrapper: Null<QueryNode> = type == null ? null : TreePath.parentOf(tree, type);
		final declAt: Null<Span> = decl.span;
		if (decl.kind != MEMBER_FINAL_KIND || type == null || wrapper == null || declAt == null)
			return Pinned('is no `final` the rewrite retypes');
		if (wrapper.kind != shape.finalClassDeclKind)
			return Pinned('is a member of a type that is not a `final class`, so a subclass in another module may read it');
		final grants: Null<String> = shape.grantsPrivateAccessMetaName;
		final metaKinds: Array<String> = run.plugin.metaShape().metaKinds;
		final index: Int = type.children.indexOf(decl);
		final module: QueryNode = TreePath.parentOf(tree, wrapper) ?? tree;
		if (
			granted(type.children, index, grants, metaKinds)
			|| granted(module.children, module.children.indexOf(wrapper), grants, metaKinds)
		)
			return Pinned('is opened to another module by `$grants`');
		final modifiers: ModifierRun = SetModifier.modifierRun(
			source, type.children, index, shape, CheckScan.modifierKinds(shape), declAt.from
		);
		final publicName: String = (shape.publicModifierKind ?? '').toLowerCase();
		final inlineName: String = (shape.inlineModifierKind ?? '').toLowerCase();
		if (modifiers.names.contains(publicName) || modifiers.guarded.contains(publicName))
			return Pinned('is public, so another module may read it');
		if (modifiers.guarded.contains(inlineName))
			return Pinned('is `inline` under a conditional region, which the retyped value, a call, cannot keep');
		if (!modifiers.names.contains(inlineName)) return Open([]);
		if (modifiers.split)
			return Pinned('has a modifier run split by a region or a comment, so its `inline` cannot be dropped in one splice');
		final kept: Array<String> = modifiers.names.filter(name -> name != inlineName);
		return Open([
			kept.length == 0
				? { span: new Span(modifiers.from, declAt.from), text: '' }
				: { span: new Span(modifiers.from, modifiers.to), text: kept.join(' ') }
		]);
	}

	/**
	 * Whether `argument` is a value typed as the options — a variable or a parameter written with the type — so a fixture call reading
	 * it already is typed and is left as it is.
	 */
	private static function typedValue(argument: QueryNode, run: Run): Bool {
		final provider: Null<TypeInfoProvider> = run.plugin is TypeInfoProvider ? cast run.plugin : null;
		if (provider == null) return false;
		final tree: Null<QueryNode> = parsed(run);
		if (tree == null) return false;
		final shape: RefShape = run.plugin.refShape();
		final typeSyntax: TypeSyntaxReader = run.plugin.typeSyntax;
		final chain: ChainTypeContext = {
			declaredTypeSources: provider.declaredTypeSources(run.source),
			source: run.source,
			typeSyntax: typeSyntax
		};
		// no index: only what the file itself writes types the value — an annotation, an initializer, a parameter
		final written: Null<String> = NominalTypes.expressionTypeSource(
			argument, tree, shape, provider.declaredTypes(run.source), null, '', chain
		);
		if (written == null) return false;
		final held: String = NominalTypes.unwrapNullable(written, shape.nullableWrapperTypeNames ?? [], typeSyntax);
		return NominalTypes.outerNominalOf(held, typeSyntax) == OPTIONS_TYPE.allAfterLast('.');
	}

	/**
	 * Whether the options call `m` loads are what its test examines: read only by field — inline, or through the local they
	 * initialise — and never handed on, so a typed edit would make the test assert its own edit. `note` records the method.
	 */
	private static function subject(m: Match, run: Run, note: Bool): Bool {
		final tree: Null<QueryNode> = parsed(run);
		if (tree == null) return false;
		final call: Null<QueryNode> = TreePath.withSpan(tree, m.span);
		if (call == null) return false;
		final path: Array<QueryNode> = TreePath.pathAround(tree, call) ?? [];
		if (path.length < 2) return false;
		final parent: QueryNode = path[path.length - 2];
		final examined: Bool = if (parent.kind == FIELD_ACCESS_KIND)
			parent.children[0] == call;
		else if (parent.kind == LOCAL_FINAL_KIND || parent.kind == 'VarStmt')
			fieldReadOnly(parent, tree, run);
		else
			false;
		if (!examined || !note) return examined;
		var method: String = '';
		for (n in path) if (n.kind == 'FnMember') method = n.name ?? '';
		final line: String = 'loader subject: $method';
		if (!run.subjects.contains(line)) run.subjects.push(line);
		return true;
	}

	/** Whether the local `decl` declares is read at least once and every read is the receiver of a field access. */
	private static function fieldReadOnly(decl: QueryNode, tree: QueryNode, run: Run): Bool {
		final name: Null<String> = decl.name;
		final declAt: Null<Span> = decl.span;
		if (name == null || declAt == null) return false;
		final shape: RefShape = run.plugin.refShape();
		var reads: Int = 0;
		for (hit in Refs.find(name, tree, shape)) if (hit.kind != RefKind.Decl && hit.bindingSpan?.from == declAt.from) {
			final read: Null<QueryNode> = TreePath.withSpan(tree, hit.span, shape.identKind);
			if (read == null) return false;
			final holder: Null<QueryNode> = TreePath.parentOf(tree, read);
			if (holder == null || holder.kind != FIELD_ACCESS_KIND || holder.children[0] != read) return false;
			reads++;
		}
		return reads > 0;
	}

	/** The parse of the run's current source, kept on the run until the source changes. */
	private static function parsed(run: Run): Null<QueryNode> {
		final tree: Null<QueryNode> = run.tree ?? treeOf(run.source, run.plugin);
		run.tree = tree;
		return tree;
	}

	/** The first line of `text`, cut to what a message quotes. */
	private static function excerpt(text: String): String {
		final line: String = text.firstLine();
		return line.length > CALL_EXCERPT ? '${line.substring(0, CALL_EXCERPT)}…' : line;
	}

	/** Each retypable `final` a call shape of `tree` reads as its configuration, in the order the shapes first read them. */
	private static function namedReads(tree: QueryNode, source: String, run: Run, shape: RefShape): Array<Named> {
		final byDeclaration: Map<Int, Named> = [];
		final named: Array<Named> = [];
		for (site in callShapes(run.kitName)) for (m in Matcher.search(run.plugin.parsePattern(site.pattern), tree)) {
			final argument: Null<QueryNode> = m.bindings['json'];
			final name: Null<String> = argument?.name;
			final at: Null<Span> = argument?.span;
			if (argument == null || name == null || at == null || argument.kind != shape.identKind || subject(m, run, false)) continue;
			final decl: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, at, tree, shape);
			if (decl == null) continue;
			final declAt: Null<Span> = decl.span;
			final init: Null<QueryNode> = CtorFieldFold.declInitializer(decl, shape);
			if (declAt == null || init == null || literalOf(init) == null) continue;
			final entry: Named = byDeclaration[declAt.from] ?? {
				name: name,
				span: declAt,
				init: init,
				retyping: retyping(decl, tree, source, run, shape),
				readers: []
			};
			if (!byDeclaration.exists(declAt.from)) {
				byDeclaration[declAt.from] = entry;
				named.push(entry);
			}
			if (!entry.readers.exists(at.from)) entry.readers[at.from] = { match: m, site: site };
		}
		return named;
	}

	/**
	 * The edits that retype `entry`, appended to `edits`: its declaration holds the typed edit, each loader call reading it becomes the
	 * name. The refusal when a read of it is not a configuration call, or its document is refused; null otherwise.
	 */
	private static function namedEdits(
		entry: Named, source: String, tree: QueryNode, run: Run, shape: RefShape, edits: Array<Edit>
	): Null<String> {
		final at: String = excerpt(SourceSlice.slice(source, entry.span));
		final cuts: Array<Edit> = switch entry.retyping {
			case Pinned(why): return '$at: `${entry.name}` cannot hold the typed options: it $why';
			case Open(modifierEdits): modifierEdits;
		};
		for (hit in Refs.find(entry.name, tree, shape))
			if (hit.kind != RefKind.Decl && hit.bindingSpan?.from == entry.span.from && !entry.readers.exists(hit.span.from))
				return '$at: `${entry.name}` is read where no configuration call reads it, so it cannot hold the typed options';
		if (Matcher.search(run.plugin.parsePattern('$$_.${entry.name}'), tree).length > 0)
			return '$at: `${entry.name}` is read as a field, a read the rewrite does not follow, so it cannot hold the typed options';
		final initAt: Null<Span> = entry.init.span;
		if (initAt == null) return '$at: the initializer has no position to rewrite';
		switch typedEdit(literalOf(entry.init), at, run) {
			case Refused(message):
				return message;
			case Spliced(fork, _):
				edits.push(
					{ span: new Span(entry.span.from, initAt.to), text: 'final ${entry.name}: ${OPTIONS_TYPE.allAfterLast('.')} = $fork' }
				);
		}
		for (cut in cuts) edits.push(cut);
		for (reader in entry.readers) if (!reader.site.argumentOnly)
			edits.push({ span: reader.match.span, text: reader.site.asConfig ? 'HxWriteConfig.ofOptions(${entry.name})' : entry.name });
		return null;
	}

	/** The parse of `source`; null when it does not parse. */
	private static function treeOf(source: String, plugin: GrammarPlugin): Null<QueryNode> {
		return switch ParseGate.parse(plugin, source, PARSED_AS) {
			case Unparsed(_): null;
			case Parsed(parsed): parsed;
		};
	}

	/** Whether the prefix run before `siblings[index]` holds the meta `grants`, one of `metaKinds`; never for a grammar with none. */
	private static function granted(siblings: Array<QueryNode>, index: Int, grants: Null<String>, metaKinds: Array<String>): Bool {
		if (grants == null) return false;
		var k: Int = index - 1;
		while (k >= 0 && ElementSpan.isDeclPrefixSibling(siblings[k])) {
			if (metaKinds.contains(siblings[k].kind) && siblings[k].name == grants) return true;
			k--;
		}
		return false;
	}

}

private typedef Site = { pattern: String, asConfig: Bool, argumentOnly: Bool };

/** One rewrite: the source it reads, the kit and the knobs it spells, the imports it collects, how many calls it converted so far. */
private typedef Run = {

	var source: String;
	final kitName: String;
	final knobs: Array<OptionKnob>;
	final imports: Array<String>;
	final plugin: GrammarPlugin;
	var sites: Int;

	/** The parse of `source`, read when an argument is typed; null until then. */
	var tree: Null<QueryNode>;

	/** A note per call left on its document because the options it loads are the test's subject. */
	final subjects: Array<String>;

};

/** A replacement of `span` of the source by `text`. */
private typedef Edit = { span: Span, text: String };
/** A match of a call shape with the shape it matched. */
private typedef Found = { match: Match, site: Site };
/**
 * A `final` the rewrite retypes: its name, its declaration, the constant it holds, whether its modifiers let it be retyped, and each
 * configuration call reading it, by argument.
 */
private typedef Named = {
	name: String,
	span: Span,
	init: QueryNode,
	retyping: Retyping,
	readers: Map<Int, Reader>
};

/** A call shape's match reading a retyped `final` as its configuration. */
private typedef Reader = { match: Match, site: Site };
/** Whether a `final` may be retyped: with the edits of its modifier run, or pinned, with why not. */
private enum Retyping {
	Open(cuts: Array<Edit>);
	Pinned(why: String);
}
