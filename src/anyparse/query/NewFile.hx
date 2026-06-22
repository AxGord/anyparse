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
 * the fields, the doc) and the deterministic scaffold / formatting /
 * validation is the tool's job. No LLM in the loop — the writer is the
 * validator.
 *
 * Type shapes (`spec.kind`, default `class`):
 * - `class`: `[final ]class N [extends E] [implements I]` — `final` unless
 *   `spec.isFinal == false`; `--implements` additionally stubs every interface
 *   method with the right signature (sliced from the interface source) and
 *   carries the imports the signatures need (the interface file's own imports
 *   + an import per sibling sub-module type, e.g. `Violation` next to `Check`)
 *   so the result type-checks. Bodies fill from `@@ <method>` sections; an
 *   unfilled method → a `NotImplementedException` stub.
 * - `interface`: `interface N [extends I, …]` — members from `--field`.
 * - `enum`: `enum N` — members (constructors) from `--field`.
 * - `typedef`: `typedef N = { [> Base, …] … }` — anon-struct fields from
 *   `--field`, `--extends` emitting struct extensions (`> Base`).
 * - `abstract`: `abstract N(Underlying) [from T] [to T]` — `--underlying`
 *   required; members from `--field`.
 *
 * A no-arg `public function new() {}` is auto-emitted ONLY for a `class` with
 * no `extends` and no caller-supplied constructor — a subclass inherits its
 * super's constructor (auto-emitting one would skip a parameterised
 * `super(...)`), and interfaces / enums / typedefs / abstracts have none.
 *
 * The `@@` payload also recognises three reserved sections: `@@ imports`
 * (extra imports, one per line), `@@ doc` (the type's doc-comment), and
 * `@@ members` (a free-form member block).
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

	/** Reserved `@@` section name carrying the type doc-comment. */
	private static inline final DOC_SECTION: String = 'doc';

	/** Reserved `@@` section name carrying a raw block of free-form members. */
	private static inline final MEMBERS_SECTION: String = 'members';

	/** Type kinds that carry a `@:nullSafety(Strict)` meta (class / interface). */
	private static final NULL_SAFE_KINDS: Array<String> = ['class', 'interface'];

	/** Type kinds for which `--extends` is meaningful (class superclass / interface + typedef structural extension). */
	private static final EXTENDABLE_KINDS: Array<String> = ['class', 'interface', 'typedef'];

	/** Import-declaration kinds carried verbatim from the interface file. */
	private static final IMPORT_KINDS: Array<String> = ['ImportDecl', 'UsingDecl', 'ImportWildDecl', 'ImportAliasDecl'];

	/** Top-level type-declaration kinds (for the interface module's sibling sub-types). */
	private static final DECL_KINDS: Array<String> = [
		'ClassDecl',
		'InterfaceDecl',
		'EnumDecl',
		'TypedefDecl',
		'AbstractDecl',
		'FinalDecl'
	];

	/**
	 * Assemble + canonicalise a new module from `spec`. Returns the canonical
	 * source in `result` (`Ok`) plus the method names that received the
	 * default stub (`stubbed`, for the caller to warn about), or an `Err`
	 * describing a parse failure / a `@@` section naming an unknown method /
	 * an option that does not apply to the chosen kind, with `stubbed` empty.
	 */
	public static function create(spec: NewFileSpec, plugin: GrammarPlugin, ?optsJson: String): NewFileResult {
		final kind: String = spec.kind ?? 'class';
		final extendsList: Array<String> = spec.extendsList ?? [];
		final specError: Null<String> = validateSpec(spec, kind, extendsList);
		if (specError != null) return err(specError);

		final bodies: Map<String, String> = [];
		final imports: Array<String> = [];
		final bodiesRaw: Null<String> = spec.bodiesRaw;
		if (bodiesRaw != null) parseSections(bodiesRaw, bodies, imports);
		final classDoc: Null<String> = bodies[DOC_SECTION];
		if (classDoc != null) bodies.remove(DOC_SECTION);
		final freeMembers: Null<String> = bodies[MEMBERS_SECTION];
		if (freeMembers != null) bodies.remove(MEMBERS_SECTION);

		final extendsSimple: Array<String> = [for (e in extendsList) simpleNameWithImport(e, spec.pkg, imports)];
		final abstractClause: String = kind == 'abstract' ? abstractHeader(spec, imports) : '';

		final members: Array<String> = [];
		final stubbed: Array<String> = [];
		final ifaceError: Null<String> = implementInterface(spec, plugin, bodies, imports, members, stubbed);
		if (ifaceError != null) return err(ifaceError);

		for (field in spec.fields) members.push(field);
		if (freeMembers != null) members.push(freeMembers);

		// A class with no superclass and no constructor cannot be `new`'d (Haxe
		// has no implicit constructor); auto-emit one. A subclass inherits its
		// super's constructor, so do NOT auto-emit when `extends` is present.
		if (kind == 'class' && extendsList.length == 0 && !members.exists(m -> m.indexOf('function new(') >= 0))
			members.unshift('public function new() {}');

		final source: String = assemble(spec, kind, extendsSimple, abstractClause, members, dedup(imports), classDoc);
		final canonical: Null<String> = try plugin.writeRoundTrip(source, optsJson) catch (exception: ParseError) {
			return err('assembled source does not parse: ${exception.message}');
		} catch (exception: Exception) {
			return err('assembled source does not parse: ${exception.message}');
		};
		return canonical == null ? err('no writer for this grammar') : { result: EditResult.Ok(canonical), stubbed: stubbed };
	}

	/** Wrap an error message as a stub-free `NewFileResult`. */
	private static inline function err(message: String): NewFileResult {
		return { result: EditResult.Err(message), stubbed: [] };
	}

	/**
	 * The `(Underlying) [from T]… [to T]…` header of an abstract — each type
	 * reference resolved to its simple name with a carried import when
	 * qualified. `underlying` is guaranteed non-null by the caller's guard; the
	 * `?? 'Dynamic'` only satisfies null-safety.
	 */
	private static function abstractHeader(spec: NewFileSpec, imports: Array<String>): String {
		final buf: StringBuf = new StringBuf();
		buf.add('(${simpleNameWithImport(spec.underlying ?? 'Dynamic', spec.pkg, imports)})');
		for (from in spec.fromList ?? []) buf.add(' from ${simpleNameWithImport(from, spec.pkg, imports)}');
		for (to in spec.toList ?? []) buf.add(' to ${simpleNameWithImport(to, spec.pkg, imports)}');
		return buf.toString();
	}

	/**
	 * Resolve a possibly-qualified type reference to the simple name to write
	 * in the source, pushing `import <ref>;` when `ref` is qualified and lives
	 * in a different package than `newPkg`. A simple name is returned as-is
	 * (assumed same-package, or the caller adds an `@@ imports` line).
	 */
	private static function simpleNameWithImport(ref: String, newPkg: String, imports: Array<String>): String {
		final dot: Int = ref.lastIndexOf('.');
		if (dot < 0) return ref;
		final simple: String = ref.substr(dot + 1);
		final pkg: String = ref.substr(0, dot);
		if (pkg != newPkg) imports.push('import $ref;');
		return simple;
	}

	/**
	 * Glue the doc-comment, package line, imports, the type header (varying by
	 * `kind` — `@:nullSafety(Strict)` for class/interface; `extends` /
	 * `implements` clauses; the abstract `(Underlying) from/to` header), and the
	 * members into a parseable module. Spacing is deliberately rough —
	 * `writeRoundTrip` canonicalises it.
	 */
	private static function assemble(
		spec: NewFileSpec, kind: String, extendsSimple: Array<String>, abstractClause: String, members: Array<String>,
		imports: Array<String>, classDoc: Null<String>
	): String {
		final buf: StringBuf = new StringBuf();
		if (spec.pkg != '') buf.add('package ${spec.pkg};\n');
		buf.add('\n');
		for (imp in imports) buf.add('$imp\n');
		if (imports.length > 0) buf.add('\n');
		if (classDoc != null) buf.add('${RefactorSupport.docComment(classDoc)}\n');

		if (NULL_SAFE_KINDS.contains(kind)) buf.add('@:nullSafety(Strict)\n');

		final ext: String = extendsSimple.length > 0 ? ' extends ${extendsSimple.join(', ')}' : '';
		final body: String = members.join('\n\n');
		switch kind {
			case 'interface':
				buf.add('interface ${spec.className}$ext {\n\n$body\n}\n');
			case 'enum':
				buf.add('enum ${spec.className} {\n\n$body\n}\n');
			case 'abstract':
				buf.add('abstract ${spec.className}$abstractClause {\n\n$body\n}\n');
			case 'typedef':
				final structLines: Array<String> = [for (e in extendsSimple) '> $e,'].concat(members);
				buf.add('typedef ${spec.className} = {\n\n${structLines.join('\n')}\n}\n');

			case _:
				final finalKw: String = spec.isFinal == false ? '' : 'final ';
				final ifaceSimple: Null<String> = spec.ifaceSimple;
				final impl: String = ifaceSimple != null ? ' implements $ifaceSimple' : '';
				buf.add('${finalKw}class ${spec.className}$ext$impl {\n\n$body\n}\n');
		}
		return buf.toString();
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

	/** Wrap `text` as a `/** … *\/` doc-comment, one ` * ` per line. */
	/**
	 * Parse the `--bodies` payload into method bodies and extra imports. A
	 * line `@@ <name>` opens a section; lines until the next `@@` (or EOF) are
	 * its content. The reserved section `@@ imports` contributes one
	 * `import <line>;` per non-blank line; `@@ doc` is the type doc-comment;
	 * every other section is a method body (leading / trailing blank lines
	 * trimmed). Content before the first `@@` is ignored.
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
			} else if (section != null) buf.push(line);
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

	/**
	 * Validate + canonicalise an arbitrary whole-file `content` — the validated,
	 * atomic equivalent of a raw write (`apq new --raw`): parse-or-`Err`,
	 * canonicalise, `Ok`. For files no `--kind` spec shape covers (multi-type
	 * modules, free-form layouts) so creation can still go through the tooling.
	 */
	public static function createRaw(content: String, plugin: GrammarPlugin, ?optsJson: String): EditResult {
		final canonical: Null<String> = try plugin.writeRoundTrip(content, optsJson) catch (exception: ParseError) {
			return EditResult.Err('source does not parse: ${exception.message}');
		} catch (exception: Exception) {
			return EditResult.Err('source does not parse: ${exception.message}');
		};
		return canonical == null ? EditResult.Err('no writer for this grammar') : EditResult.Ok(canonical);
	}

	/**
	 * Validate that the chosen `kind` is compatible with the supplied options:
	 * `--implements` requires a class, `--extends` applies only to extendable
	 * kinds and a class extends at most one type, and `--kind abstract` requires
	 * an `--underlying`. Returns the refusal message, or null when the spec is
	 * consistent.
	 */
	private static function validateSpec(spec: NewFileSpec, kind: String, extendsList: Array<String>): Null<String> {
		return spec.ifaceSimple != null && kind != 'class'
			? '--implements requires --kind class'
			: extendsList.length > 0 && !EXTENDABLE_KINDS.contains(kind)
				? '--extends does not apply to a $kind'
				: kind == 'class' && extendsList.length > 1
					? 'a class extends at most one type (got ${extendsList.length})'
					: kind == 'abstract' && spec.underlying == null ? '--kind abstract requires --underlying <T>' : null;
	}

	/**
	 * When `spec` carries a resolved interface (`--implements`), stub every
	 * interface method into `members` with the right signature — filling from a
	 * matching `@@ <method>` body in `bodies`, else the default `STUB` (recorded
	 * in `stubbed`) — and carry the imports the signatures need into `imports`. A
	 * no-op when no interface is resolved. Returns a refusal when the interface
	 * source does not parse, the interface is absent, or a `@@` section names no
	 * method on it; null otherwise.
	 */
	private static function implementInterface(
		spec: NewFileSpec, plugin: GrammarPlugin, bodies: Map<String, String>, imports: Array<String>, members: Array<String>,
		stubbed: Array<String>
	): Null<String> {
		final ifaceSimple: Null<String> = spec.ifaceSimple;
		final ifaceSource: Null<String> = spec.ifaceSource;
		final ifaceModule: Null<String> = spec.ifaceModule;
		if (ifaceSimple == null || ifaceSource == null || ifaceModule == null) return null;

		final tree: Null<QueryNode> = try plugin.parseFile(ifaceSource) catch (exception: Exception) null;
		if (tree == null) return 'could not parse the resolved interface source';
		final iface: Null<QueryNode> = findInterface(tree, ifaceSimple);
		if (iface == null) return 'no interface "$ifaceSimple" in the resolved source';

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
			return '@@ $key names no method on $ifaceSimple (have: ${methodNames.join(', ')})';
		return null;
	}

}

/**
 * Compact creation spec. `className` / `pkg` are derived by the caller from
 * the target path (`pkg == ''` for a package-less root file). `kind`
 * (default `class`), `isFinal` (class only, default true) and `extendsList`
 * (qualified or simple type refs) shape the declaration; `underlying` /
 * `fromList` / `toList` shape an `abstract`. `ifaceSimple` / `ifaceModule` /
 * `ifaceSource` are set together for `--implements` on a class. `fields` are
 * verbatim `--field` member texts; `bodiesRaw` is the raw `--bodies` payload
 * (method bodies + the reserved `@@ imports` / `@@ doc`).
 */
typedef NewFileSpec = {
	var className: String;
	var pkg: String;
	var fields: Array<String>;
	@:optional var kind: String;
	@:optional var isFinal: Bool;
	@:optional var extendsList: Array<String>;
	@:optional var underlying: String;
	@:optional var fromList: Array<String>;
	@:optional var toList: Array<String>;
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
