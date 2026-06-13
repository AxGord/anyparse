package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * Backend for `apq new` — deterministic file CREATION, the create-side
 * counterpart of the writer-emit mutation ops. Where those rewrite an
 * existing canonical file, this assembles a brand-new module from a compact
 * spec and runs it through the SAME writer round-trip, so the result is
 * parses-or-fails + byte-canonical + atomic by construction: the model
 * supplies only the irreducible parts (which interface, the method bodies,
 * the fields) and the deterministic scaffold / formatting / validation is
 * the tool's job. No LLM in the loop — the writer is the validator.
 *
 * Two shapes:
 * - `--class`: a bare `final class` carrying the verbatim `--field` members.
 * - `--implements <iface>`: every interface method stubbed with the right
 *   signature (sliced from the interface source), each body filled from a
 *   `@@ <method>` section or left as a `NotImplementedException` stub. The
 *   imports the signatures need are carried over deterministically — the
 *   interface file's own imports plus an import per sibling sub-module type
 *   it declares (e.g. a `Violation` typedef next to a `Check` interface) —
 *   so the result type-checks, not just parses.
 *
 * Assembly is intentionally loose (the writer canonicalises spacing / blank
 * lines / wrapping); the only hard requirement is that the assembled text
 * PARSES — `writeRoundTrip` is what turns a parse failure into an `Err` with
 * the file never written.
 */
@:nullSafety(Strict)
final class NewFile {

	/** Body emitted for an interface method the caller left unfilled. */
	private static inline final STUB: String = 'throw new haxe.exceptions.NotImplementedException();';

	/** Import-declaration kinds carried verbatim from the interface file. */
	private static final IMPORT_KINDS: Array<String> = ['ImportDecl', 'UsingDecl', 'ImportWildDecl', 'ImportAliasDecl'];

	/** Top-level type-declaration kinds (for the interface module's sibling sub-types). */
	private static final DECL_KINDS: Array<String> = ['ClassDecl', 'InterfaceDecl', 'EnumDecl', 'TypedefDecl', 'AbstractDecl', 'FinalDecl'];

	/**
	 * Assemble + canonicalise a new module from `spec`. Returns the canonical
	 * source in `result` (`Ok`) plus the method names that received the
	 * default stub (`stubbed`, for the caller to warn about), or an `Err`
	 * describing a parse failure / a `@@` section naming an unknown method,
	 * with `stubbed` empty.
	 */
	public static function create(spec: NewFileSpec, plugin: GrammarPlugin, ?optsJson: String): NewFileResult {
		final bodies: Map<String, String> = new Map();
		final imports: Array<String> = [];
		final bodiesRaw: Null<String> = spec.bodiesRaw;
		if (bodiesRaw != null) parseSections(bodiesRaw, bodies, imports);

		final members: Array<String> = [];
		final stubbed: Array<String> = [];
		final ifaceSimple: Null<String> = spec.ifaceSimple;
		final ifaceSource: Null<String> = spec.ifaceSource;
		final ifaceModule: Null<String> = spec.ifaceModule;
		if (ifaceSimple != null && ifaceSource != null && ifaceModule != null) {
			final tree: Null<QueryNode> = try plugin.parseFile(ifaceSource) catch (exception: Exception) null;
			if (tree == null) return err('could not parse the resolved interface source');
			final iface: Null<QueryNode> = findInterface(tree, ifaceSimple);
			if (iface == null) return err('no interface "$ifaceSimple" in the resolved source');

			carryImports(tree, ifaceSource, ifaceModule, ifaceSimple, spec.pkg, imports);

			final methodNames: Array<String> = [];
			for (member in iface.children) if (member.kind == 'FnMember') {
				final sig: Null<String> = signatureOf(member, ifaceSource);
				final name: Null<String> = member.name;
				if (sig == null || name == null) continue;
				methodNames.push(name);
				final body: Null<String> = bodies[name];
				if (body == null) {
					stubbed.push(name);
					members.push('public $sig {\n$STUB\n}');
				} else
					members.push('public $sig {\n$body\n}');
			}
			for (key in bodies.keys()) if (!methodNames.contains(key))
				return err('@@ $key names no method on $ifaceSimple (have: ${methodNames.join(", ")})');
		}
		for (field in spec.fields) members.push(field);

		final source: String = assemble(spec, members, dedup(imports));
		final canonical: Null<String> = try plugin.writeRoundTrip(source, optsJson) catch (exception: ParseError) {
			return err('assembled source does not parse: ${exception.message}');
		} catch (exception: Exception) {
			return err('assembled source does not parse: ${exception.message}');
		};
		if (canonical == null) return err('no writer for this grammar');
		return { result: EditResult.Ok(canonical), stubbed: stubbed };
	}

	/** Wrap an error message as a stub-free `NewFileResult`. */
	private static inline function err(message: String): NewFileResult {
		return { result: EditResult.Err(message), stubbed: [] };
	}

	/**
	 * Collect into `imports` the import lines the implementing class needs to
	 * type-check: (1) the interface file's own import declarations, sliced
	 * verbatim — the external types its signatures reference; (2) an
	 * `import <ifaceModule>.<T>;` for every OTHER top-level type the interface
	 * module declares (its sibling sub-module types — same-package visibility
	 * does not extend to sub-module types); (3) `import <ifaceModule>;` for the
	 * interface itself when it lives in a different package than the new file.
	 */
	private static function carryImports(
		tree: QueryNode, ifaceSource: String, ifaceModule: String, ifaceSimple: String, newPkg: String, imports: Array<String>
	): Void {
		for (node in topLevel(tree)) {
			if (IMPORT_KINDS.contains(node.kind)) {
				final span: Null<Span> = node.span;
				if (span != null) imports.push(ifaceSource.substring(span.from, span.to).trim());
			} else if (DECL_KINDS.contains(node.kind)) {
				final name: Null<String> = node.name;
				if (name != null && name != ifaceSimple) imports.push('import $ifaceModule.$name;');
			}
		}
		final dot: Int = ifaceModule.lastIndexOf('.');
		final ifacePkg: String = dot >= 0 ? ifaceModule.substr(0, dot) : '';
		if (ifacePkg != newPkg) imports.push('import $ifaceModule;');
	}

	/**
	 * The interface file's top-level nodes: the module's direct children plus
	 * one level into any `Conditional` (`#if`) wrapper, so imports / sibling
	 * types guarded by conditional compilation are still seen.
	 */
	private static function topLevel(tree: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		for (child in tree.children) {
			out.push(child);
			if (child.kind == 'Conditional') for (inner in child.children) out.push(inner);
		}
		return out;
	}

	private static function findInterface(node: QueryNode, name: String): Null<QueryNode> {
		if (node.kind == 'InterfaceDecl' && node.name == name) return node;
		for (child in node.children) {
			final found: Null<QueryNode> = findInterface(child, name);
			if (found != null) return found;
		}
		return null;
	}

	/**
	 * The signature text of an interface `FnMember`, sliced from `source` and
	 * trimmed: `[member.from, NoBody.from)` drops the trailing `;` exactly (the
	 * `NoBody` child spans only that terminator), leaving e.g.
	 * `function run(files, plugin): Array<Violation>`. Returns null for an
	 * unspanned member.
	 */
	private static function signatureOf(member: QueryNode, source: String): Null<String> {
		final span: Null<Span> = member.span;
		if (span == null) return null;
		final noBody: Null<QueryNode> = member.children.find(c -> c.kind == 'NoBody');
		final cut: Int = noBody != null && noBody.span != null ? noBody.span.from : span.to;
		var sig: String = source.substring(span.from, cut).trim();
		if (sig.endsWith(';')) sig = sig.substr(0, sig.length - 1).trim();
		return sig;
	}

	/**
	 * Glue the package line, imports, the `@:nullSafety(Strict) final class`
	 * header with its `implements` clause, and the members into a parseable
	 * module. Spacing is deliberately rough — `writeRoundTrip` canonicalises it.
	 */
	private static function assemble(spec: NewFileSpec, members: Array<String>, imports: Array<String>): String {
		final ifaceSimple: Null<String> = spec.ifaceSimple;
		final implClause: String = ifaceSimple != null ? ' implements $ifaceSimple' : '';

		final buf: StringBuf = new StringBuf();
		if (spec.pkg != '') buf.add('package ${spec.pkg};\n');
		buf.add('\n');
		for (imp in imports) buf.add('$imp\n');
		if (imports.length > 0) buf.add('\n');
		buf.add('@:nullSafety(Strict)\n');
		buf.add('final class ${spec.className}$implClause {\n');
		buf.add('\n');
		buf.add(members.join('\n\n'));
		buf.add('\n}\n');
		return buf.toString();
	}

	/**
	 * Parse the `--bodies` payload into method bodies and extra imports. A
	 * line `@@ <name>` opens a section; lines until the next `@@` (or EOF) are
	 * its content. The reserved section `@@ imports` contributes one
	 * `import <line>;` per non-blank line; every other section is a method
	 * body (leading / trailing blank lines trimmed). Content before the first
	 * `@@` is ignored.
	 */
	private static function parseSections(raw: String, bodies: Map<String, String>, imports: Array<String>): Void {
		final lines: Array<String> = raw.split('\n');
		var section: Null<String> = null;
		final buf: Array<String> = [];
		inline function flush(): Void {
			if (section == null) return;
			if (section == 'imports') {
				for (line in buf) if (line.trim() != '') imports.push('import ${line.trim()};');
			} else
				bodies[section] = trimBlankEdges(buf);
		}
		for (line in lines) {
			if (line.startsWith('@@ ')) {
				flush();
				section = line.substr(3).trim();
				buf.resize(0);
			} else if (section != null)
				buf.push(line);
		}
		flush();
	}

	/** Join `lines` with `\n`, dropping leading and trailing all-blank lines. */
	private static function trimBlankEdges(lines: Array<String>): String {
		var from: Int = 0;
		var to: Int = lines.length;
		while (from < to && lines[from].trim() == '') from++;
		while (to > from && lines[to - 1].trim() == '') to--;
		return lines.slice(from, to).join('\n');
	}

	/** Order-preserving de-duplication of import lines. */
	private static function dedup(lines: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (line in lines) if (!out.contains(line)) out.push(line);
		return out;
	}

}

/**
 * Compact creation spec. `className` / `pkg` are derived by the caller from
 * the target path (`pkg == ''` for a package-less root file). `ifaceSimple`
 * / `ifaceModule` / `ifaceSource` are set together for `--implements`
 * (`ifaceModule` is the interface's fully-qualified module path, used both to
 * decide the interface import and to address its sibling sub-types).
 * `fields` are verbatim `--field` member texts; `bodiesRaw` is the raw
 * `--bodies` stdin payload.
 */
typedef NewFileSpec = {
	var className: String;
	var pkg: String;
	var fields: Array<String>;
	@:optional var ifaceSimple: String;
	@:optional var ifaceModule: String;
	@:optional var ifaceSource: String;
	@:optional var bodiesRaw: String;
}

/** `create` outcome: the edit (Ok canonical source / Err) plus the interface methods left as stubs. */
typedef NewFileResult = {
	var result: EditResult;
	var stubbed: Array<String>;
}
