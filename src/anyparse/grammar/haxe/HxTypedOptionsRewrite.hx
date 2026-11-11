package anyparse.grammar.haxe;

import anyparse.format.OptionsSource;
import anyparse.macro.OptionKnobs;
import anyparse.query.AddImport;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin;
import anyparse.query.Matcher;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.Rewrite;
import anyparse.query.SourceSlice;
import anyparse.runtime.Span;
import haxe.Exception;

using anyparse.util.Strings;

/**
 * The one answer to "how does a test's `hxformat.json` call become typed `HxModuleWriteOptions`, by an op rather than by hand": every
 * `HaxeFormatConfigLoader.loadHxFormatJson(<literal>)` / `loadHxFormatJson(<literal>)`, `<kit>.strictJson(<literal>)` and
 * `HxWriteConfig.ofJson(<literal>)` of a Haxe source becomes `<kit>.forkWith(edited -> edited.<knob> = <value>)`
 * over the same baseline, `loadHxFormatJson('{}')`: a block of
 * assignments for several knobs, an empty one for none. A `HxWriteFixture.triviaWrite` / `plainWrite` call keeps its source argument and
 * has only the configuration replaced, left as it is when it already is the typed edit.
 *
 * An assignment is written for each knob whose value the document changed from that baseline, so a key that fans out over several
 * knobs, or cascades, is rewritten as the knobs it ended up setting and the options stay equal by construction. The rewrite refuses,
 * writing nothing, a document the loader does not act on (`HaxeFormatConfigDiagnostics`, the keys it names), a document that does
 * not load, a knob changed to a value with no source spelling, and an argument that is not one plain string literal.
 */
@:nullSafety(Strict)
final class HxTypedOptionsRewrite {

	/** How much of a refused call a message quotes. */
	private static inline final CALL_EXCERPT: Int = 80;

	/**
	 * `source` with each hxformat.json call turned into the typed edit of `kit` (a qualified type with `forkWith`), the imports that edit
	 * needs added; `Ok(source, 0)` when it holds none.
	 */
	public static function rewrite(source: String, kit: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String): EditResult {
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
			sites: 0
		};
		for (site in callShapes(kitName)) {
			run.source = text;
			switch Rewrite.rewriteBy(text, site.pattern, reformat, plugin, optsJson, false, m -> replacement(m, run, site)) {
				case Err(message):
					return Err(message);
				case Ok(rewritten, _):
					text = rewritten;
			}
		}
		if (run.sites == 0) return Ok(source, 0);
		imports.push(kit);
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
		final call: String = whole.firstLine();
		final at: String = call.length > CALL_EXCERPT ? '${call.substring(0, CALL_EXCERPT)}…' : call;
		final argument: Null<QueryNode> = m.bindings['json'];
		if (!site.argumentOnly) return switch typedEdit(argument, at, run) {
			case Spliced(fork, _): Spliced(site.asConfig ? 'HxWriteConfig.ofOptions($fork)' : fork, []);
			case refused: refused;
		};
		final edits: Array<Edit> = [];
		final source: Null<QueryNode> = m.bindings['source'];
		if (source != null) {
			final refusal: Null<String> = nestedEdits(source, run, edits);
			if (refusal != null) return Refused(refusal);
		}
		final replaced: Null<Span> = argument?.span;
		if (argument != null && replaced != null && !isTypedConfig(argument, run.kitName, run.plugin)) switch typedEdit(argument, at, run) {
			case Spliced(fork, _):
				final target: Span = replaced;
				edits.push({ span: target, text: fork });
			case refused:
				return refused;
		}
		return Spliced(applied(whole, m.span.from, edits), []);
	}

	/** The text of a call argument that is one string literal with no interpolation, decoded; null for anything else. */
	private static function literalOf(node: Null<QueryNode>): Null<String> {
		if (node == null) return null;
		final raw: Null<String> = rawOf(node);
		return raw == null || HxStringEscape.carriesEscapedDollar(raw)
			? null
			: HxStringEscape.decode(raw).map(c -> String.fromCharCode(c.code)).join('');
	}

	private static function withImports(
		text: String, wanted: Array<String>, reformat: Bool, plugin: GrammarPlugin, optsJson: Null<String>, total: Int
	): EditResult {
		final tree: QueryNode = switch ParseGate.parse(plugin, text, 'source') {
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
			'HxWriteConfig.ofOptions($$_)'
		]) for (found in Matcher.search(plugin.parsePattern(shape), node)) if (found.node == node) return true;
		return false;
	}

	/** The typed edit of the document `argument` holds, `Spliced` as the text of the call that builds it; counted as one rewritten call. */
	private static function typedEdit(argument: Null<QueryNode>, at: String, run: Run): Replacement {
		final json: Null<String> = literalOf(argument);
		if (json == null) return Refused('$at: the argument is not one plain string literal, so there is no document to read');
		try {
			final ignored: Array<String> = HaxeFormatConfigDiagnostics.ignored(HaxeFormatConfigDiagnostics.diagnose(json));
			if (ignored.length > 0) return Refused('$at: hxformat.json settings the loader does not act on: ${ignored.join('; ')}');
			final base: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
			final edits: Array<String> = OptionsSource.changes(run.knobs, base, HaxeFormatConfigLoader.loadHxFormatJson(json), run.imports)
				.map(c -> 'edited.${c.name} = ${c.source}');
			final body: String = switch edits.length {
				case 0: '{}';
				case 1: edits[0];
				case _: '{ ${edits.map(e -> '$e;').join(' ')} }';
			};
			run.sites++;
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
};

/** A replacement of `span` of the source by `text`. */
private typedef Edit = { span: Span, text: String };
/** A match of a call shape with the shape it matched. */
private typedef Found = { match: Match, site: Site };
