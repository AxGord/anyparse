package anyparse.query;

import anyparse.query.DeclaredSortedLists.SortedListPart;
import anyparse.query.ImportOrder.ImportLine;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.ModuleMoveBindings.BindingDrift;
import anyparse.query.ModuleMoveBindings.BindingProbe;
import anyparse.query.ModulePathTokens.ModuleRename;
import anyparse.query.ModulePathTokens.TextEdit;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.SymbolIndex.FileInfo;
import anyparse.query.SymbolIndex.ImportKind;
import anyparse.query.TypePathRegistries.TypePathMove;
import anyparse.query.TypePathRegistries.TypePathRegistry;
import anyparse.runtime.Span;
import haxe.ds.ArraySort;
import haxe.ds.Either;
import haxe.io.Path;

using Lambda;

/** One module to relocate: the file it is and the file it becomes (same name, another directory). */
typedef ModuleRelocation = {
	final from: String;
	final to: String;
}

/**
 * A declared test layout: a module under `source` has its tests under `test` at the same relative directory, named
 * after the module plus one of `suffixes`. A relocated module's test relocates with it.
 */
typedef TestMirror = {
	final source: String;
	final test: String;
	final suffixes: Array<String>;
}

/** Everything one relocation reads: the modules to move, the analysed modules, and the declared non-module texts. */
typedef ModuleMoveRequest = {
	final moves: Array<ModuleRelocation>;
	final scopeFiles: Array<{ file: String, source: String }>;
	final textFiles: Array<{ file: String, source: String }>;
	final registries: Array<TypePathRegistry>;
	final sortedLists: Array<Array<SortedListPart>>;
	final mirrors: Array<TestMirror>;
}

/**
 * A performed relocation: every changed file under its NEW path (a relocated module's text included), the paths that stop
 * existing, every relocation (mirrored tests included), the module renames, and the imports written to keep a name's
 * meaning.
 */
typedef ModuleMoveOutcome = {
	final changes: Array<MoveChange>;
	final removed: Array<String>;
	final moves: Array<ModuleRelocation>;
	final renames: Array<ModuleRename>;
	final imports: Array<String>;
}

/**
 * The relocation's outcome: `Moved`, or `Refused` with every reason found, not only the first.
 */
enum ModuleMoveResult {

	Moved(outcome: ModuleMoveOutcome);
	Refused(reasons: Array<String>);

}

/** One validated relocation: the move, the module rename it performs, and the types it carries. */
private typedef PlannedMove = {
	final move: ModuleRelocation;
	final rename: ModuleRename;
	final oldPackage: String;
	final info: FileInfo;
}

/**
 * Relocate whole MODULES to another package — every type of the module, its module-private ones included, travels with
 * the file — and rewrite every reference so that each name means what it meant before.
 *
 * ALL OR NOTHING. The relocation either returns every rewrite it owes or refuses with every reason it found; it never
 * returns a partial rewrite. Three proofs stand behind a `Moved`:
 *
 *  - every SPELLING of a relocated module's path — an import, a `using`, an access grant, a qualified code reference, a
 *    string, a comment, a declared text file or registry — is a bounded token rewritten in place (`ModulePathTokens`); a
 *    spelling no token rewrite can follow (a path composed from its package at run time, a registry glob whose reach
 *    would change, a qualified path whose first segment a local name shadows) is a refusal;
 *  - every simple type NAME a relocated module or one of its readers writes binds the same declaration after the move as
 *    before (`ModuleMoveBindings`); a name that would drift gets the import that restores it, and a name no import
 *    restores is a refusal;
 *  - every rewritten module parses.
 *
 * An import run that was sorted stays sorted, and a declared sorted list stays sorted (`DeclaredSortedLists`). The op is
 * PURE: the caller reads every file and decides whether to write, delete and create.
 */
@:nullSafety(Strict)
final class ModuleMove {

	/** The relocation `request` describes, read through `plugin`. */
	public static function run(request: ModuleMoveRequest, plugin: GrammarPlugin): ModuleMoveResult {
		final sourceOf: Map<String, String> = [for (e in request.scopeFiles) e.file => e.source];
		final pre: SymbolIndex = IndexScope.over(request.scopeFiles, plugin);
		ModuleMoveBindings.attachVirtualAmbient(pre, plugin);
		final skipped: Null<String> = ScopeFiles.unparsedRefusal('move', pre.skippedFiles());
		if (skipped != null) return Refused([skipped]);
		final planned: Array<PlannedMove> = switch planAll(withMirrors(request.moves, request.mirrors, sourceOf), pre, sourceOf, plugin) {
			case Left(reasons): return Refused(reasons);
			case Right(p): p;
		};
		final renames: Array<ModuleRename> = [for (p in planned) p.rename];
		final newPathOf: Map<String, String> = [for (p in planned) p.move.from => p.move.to];
		// Phase 1: every spelling rewritten, the package statements, sorted import runs and declared lists kept sorted.
		final texts: Map<String, String> = switch rewriteAll(request, planned, plugin) {
			case Left(reasons): return Refused(reasons);
			case Right(t): t;
		};
		// Phase 2: every name keeps its meaning — repaired by an import where one restores it, refused where none does.
		final renamed: Map<String, String> = [for (r in renames) r.oldPath => r.newPath];
		final probes: Array<BindingProbe> = bindingProbes(request.scopeFiles, planned, newPathOf, plugin);
		final imports: Array<String> = [];
		switch repairBindings(request.scopeFiles, texts, newPathOf, probes, pre, renamed, plugin, imports) {
			case Left(found):
				return Refused(found);
			case Right(_):
		}
		// Phase 3: the result parses, and the declared texts follow.
		return switch changesOf(request, texts, newPathOf, renames, plugin) {
			case Left(reasons): Refused(reasons);
			case Right(changes): Moved({
				changes: changes,
				removed: [for (p in planned) p.move.from],
				moves: [for (p in planned) p.move],
				renames: renames,
				imports: imports
			});
		};
	}

	/** `moves` plus, for each declared mirror, the moved module's own test when the analysed set holds it. */
	private static function withMirrors(
		moves: Array<ModuleRelocation>, mirrors: Array<TestMirror>, sourceOf: Map<String, String>
	): Array<ModuleRelocation> {
		final out: Array<ModuleRelocation> = moves.copy();
		for (m in moves) for (mirror in mirrors) {
			final fromRel: Null<String> = relativeTo(Path.directory(m.from), mirror.source);
			final toRel: Null<String> = relativeTo(Path.directory(m.to), mirror.source);
			if (fromRel == null || toRel == null) continue;
			final module: String = Path.withoutExtension(Path.withoutDirectory(m.from));
			final ext: String = Path.extension(m.from);
			for (suffix in mirror.suffixes) {
				final testFrom: String = Path.join([mirror.test, fromRel, '$module$suffix.$ext']);
				if (!sourceOf.exists(testFrom) || out.exists(o -> o.from == testFrom)) continue;
				out.push({ from: testFrom, to: Path.join([mirror.test, toRel, '$module$suffix.$ext']) });
			}
		}
		return out;
	}

	/** `dir` relative to `root` (`''` for `root` itself), or null when `dir` is not under it. */
	private static function relativeTo(dir: String, root: String): Null<String> {
		final d: String = Path.removeTrailingSlashes(dir);
		final r: String = Path.removeTrailingSlashes(root);
		if (d == r) return '';
		return d.startsWith('$r/') ? d.substr(r.length + 1) : null;
	}

	/** One relocation checked against the analysed set, or the reason it cannot be made. */
	private static function plan(
		m: ModuleRelocation, moves: Array<ModuleRelocation>, infoOf: Map<String, FileInfo>, sourceOf: Map<String, String>,
		plugin: GrammarPlugin
	): Either<String, PlannedMove> {
		final found: Null<FileInfo> = infoOf[m.from];
		if (found == null) return Left('${m.from} is not a parsed module under the scope');
		final info: FileInfo = found;
		if (plugin.ambientImportSites(m.from, info.pkg).contains(m.from))
			return Left('${m.from} is an ambient import source, not a module — moving one is not supported');
		if (Path.withoutDirectory(m.from) != Path.withoutDirectory(m.to))
			return Left('${m.from} -> ${m.to}: a relocation keeps the module name; renaming a module is a different change');
		if (info.pkg == '') return Left('${m.from} is in the root package, where its path is its bare name — not supported');
		final root: Null<String> = sourceRootOf(Path.directory(m.from), info.pkg);
		if (root == null) return Left('${m.from}: its directory does not spell its package "${info.pkg}"');
		final rel: Null<String> = relativeTo(Path.directory(m.to), root);
		if (rel == null || rel == '') return Left('${m.to} is not in a package under the source root $root');
		final pkg: String = rel.split('/').join('.');
		if (!~/^[a-z_][A-Za-z0-9_]*(\.[a-z_][A-Za-z0-9_]*)*$/.match(pkg)) return Left('${m.to}: "$pkg" is not a package path');
		if (pkg == info.pkg) return Left('${m.from} is already in package $pkg');
		if (sourceOf.exists(m.to) || moves.count(o -> o.to == m.to) > 1) return Left('${m.to} already exists');
		final module: String = Path.withoutExtension(Path.withoutDirectory(m.from));
		return Right({
			move: m,
			rename: { oldPath: info.module, newPath: '$pkg.$module' },
			oldPackage: info.pkg,
			info: info
		});
	}

	/** The source root `dir` sits in when its trailing directories spell `pkg`, else null. */
	private static function sourceRootOf(dir: String, pkg: String): Null<String> {
		var at: String = Path.removeTrailingSlashes(dir);
		final segments: Array<String> = pkg.split('.');
		var i: Int = segments.length - 1;
		while (i >= 0) {
			if (Path.withoutDirectory(at) != segments[i]) return null;
			final up: String = Path.removeTrailingSlashes(Path.directory(at));
			if (up == at) return null;
			at = up;
			i--;
		}
		return at;
	}

	/**
	 * `source` (the module at `file`) with every relocated path rewritten, each sorted import run it rewrote kept sorted,
	 * and — when the module itself moves — its package statement naming the new package; or every reason the rewrite
	 * cannot be proven.
	 */
	private static function rewriteModule(
		file: String, source: String, renames: Array<ModuleRename>, mover: Null<PlannedMove>, plugin: GrammarPlugin
	): Either<Array<String>, String> {
		final tokens: Array<TextEdit> = ModulePathTokens.edits(source, renames);
		if (tokens.length == 0 && mover == null) return Right(source);
		final tree: QueryNode = switch ParseGate.parse(plugin, source, file) {
			case Parsed(t): t;
			case Unparsed(message): return Left([message]);
		};
		final regions: Array<LexRegion> = plugin.lexicalRegions(source);
		final binders: Array<String> = binderNames(tree, plugin.refShape().declHostKinds);
		final reasons: Array<String> = [];
		for (e in tokens) if (!ModulePathTokens.inNonCode(e.span.from, regions)) {
			final head: String = source.substring(e.span.from, e.span.to).split('.')[0];
			if (binders.contains(head))
				reasons.push(
					'$file:${lineOf(source, e.span.from)} spells ${source.substring(e.span.from, e.span.to)} in code, and "$head" is '
					+ 'also a name this file declares — the path may read as a member access on it; qualify it differently first'
				);
		}
		final runs: Array<TextEdit> = resortedRuns(source, tree, renames, plugin);
		final edits: Array<TextEdit> = tokens.filter(e -> !runs.exists(r -> e.span.from >= r.span.from && e.span.to <= r.span.to));
		for (r in runs) edits.push(r);
		if (mover != null) switch packageEdit(source, tree, mover, plugin) {
			case Left(message):
				reasons.push(message);
			case Right(edit):
				edits.push(edit);
		}
		return reasons.length > 0 ? Left(reasons) : Right(ModulePathTokens.apply(source, sorted(edits)));
	}

	/** The edit renaming the package statement of a relocated module, or why its statement cannot be found. */
	private static function packageEdit(
		source: String, tree: QueryNode, mover: PlannedMove, plugin: GrammarPlugin
	): Either<String, TextEdit> {
		final kind: Null<String> = plugin.refShape().packageDeclKind;
		final decl: Null<QueryNode> = kind == null ? null : tree.children.find(c -> c.kind == kind);
		final span: Null<Span> = decl?.span;
		if (span == null) return Left('${mover.move.from}: no package statement to rename');
		final text: String = source.substring(span.from, span.to);
		final at: Array<Int> = ModulePathTokens.occurrences(text, mover.oldPackage, true);
		if (at.length != 1) return Left('${mover.move.from}: its package statement does not spell "${mover.oldPackage}" once');
		final from: Int = span.from + at[0];
		final newPackage: String = mover.rename.newPath.substring(0, mover.rename.newPath.lastIndexOf('.'));
		return Right({ span: new Span(from, from + mover.oldPackage.length), text: newPackage });
	}

	/**
	 * One edit per import run the rename leaves out of the order it carried: the run's lines, rewritten, in that order
	 * again — so a run that was sorted is never handed back unsorted.
	 */
	private static function resortedRuns(
		source: String, tree: QueryNode, renames: Array<ModuleRename>, plugin: GrammarPlugin
	): Array<TextEdit> {
		final out: Array<TextEdit> = [];
		final header: QueryNode = ImportOrder.headerRootOf(tree, source, plugin);
		for (run in ImportOrder.runsOf(source, ImportOrder.slotsOf(header))) {
			final paths: Array<String> = [for (line in run) line.path];
			final order: Int = ImportOrder.orderOf(paths);
			if (order < 0) continue;
			final mapped: Array<String> = [for (p in paths) ModulePathTokens.rewrite(p, renames)];
			if (mapped.join('\n') == paths.join('\n') || ImportOrder.sortedUnder(mapped, order)) continue;
			final idx: Array<Int> = [for (i in 0...run.length) i];
			ArraySort.sort(idx, (a, b) -> ImportOrder.compare(order, mapped[a], mapped[b]));
			final lines: Array<ImportLine> = [for (i in idx) run[i]];
			out.push({
				span: new Span(run[0].chunkFrom, run[run.length - 1].chunkTo),
				text: [
					for (l in lines) ModulePathTokens.rewrite(source.substring(l.chunkFrom, l.chunkTo), renames)
				].join('')
			});
		}
		return out;
	}

	/** The names `tree` declares on a node of one of `kinds` — what a qualified path's first segment could read as. */
	private static function binderNames(tree: QueryNode, kinds: Array<String>): Array<String> {
		final out: Array<String> = [];
		final stack: Array<QueryNode> = [tree];
		while (stack.length > 0) {
			final node: QueryNode = stack.pop() ?? tree;
			final name: Null<String> = node.name;
			if (name != null && kinds.contains(node.kind) && !out.contains(name)) out.push(name);
			for (c in node.children) stack.push(c);
		}
		return out;
	}

	/**
	 * A string literal that ends with a relocated module's OLD package (`'pkg.sub.'`, `'pkg/sub/'`) composes a module path
	 * at run time, which the relocation cannot follow — one refusal per such literal.
	 */
	private static function compositionRefusals(
		files: Array<{ file: String, source: String }>, planned: Array<PlannedMove>, plugin: GrammarPlugin
	): Array<String> {
		final prefixes: Array<String> = [];
		for (p in planned)
			for (prefix in ['${p.oldPackage}.', '${ModulePathTokens.slashPath(p.oldPackage)}/'])
				if (!prefixes.contains(prefix)) prefixes.push(prefix);
		final out: Array<String> = [];
		for (e in files) if (prefixes.exists(prefix -> e.source.indexOf(prefix) >= 0)) {
			final regions: Array<LexRegion> = plugin.lexicalRegions(e.source);
			for (prefix in prefixes) for (at in ModulePathTokens.stringsEndingWith(e.source, regions, prefix))
				out.push(
					'${e.file}:${lineOf(e.source, at)} composes a path from "$prefix" at run time — a module leaving that package '
					+ 'is not followed by it; spell the full path or move the composition first'
				);
		}
		return out;
	}

	/** Every declared registry's refusal: unreadable, or a glob whose reach over a relocated type flips. */
	private static function registryRefusals(
		registries: Array<TypePathRegistry>, textOf: Map<String, String>, planned: Array<PlannedMove>
	): Array<String> {
		final moved: Array<TypePathMove> = [];
		for (p in planned) for (t in p.info.types) if (!t.isPrivate) {
			final suffix: String = t.isMain ? '' : '.${t.name}';
			moved.push({ oldPath: p.rename.oldPath + suffix, newPath: p.rename.newPath + suffix });
		}
		final out: Array<String> = [];
		for (registry in registries) {
			final json: Null<String> = textOf[registry.file];
			if (json == null) {
				out.push('declared type-path registry ${registry.file} was not read');
				continue;
			}
			for (r in TypePathRegistries.globRefusals(registry, json, moved)) out.push(r);
		}
		return out;
	}

	/**
	 * The names whose meaning each file's relocation may change: in a relocated module every bare upper-initial name it
	 * writes, in any other module the names the relocated modules declare that it writes.
	 */
	private static function bindingProbes(
		files: Array<{ file: String, source: String }>, planned: Array<PlannedMove>, newPathOf: Map<String, String>, plugin: GrammarPlugin
	): Array<BindingProbe> {
		final declared: Array<String> = [];
		for (p in planned) for (t in p.info.types) if (!declared.contains(t.name)) declared.push(t.name);
		final out: Array<BindingProbe> = [];
		for (e in files) {
			final moved: Bool = newPathOf.exists(e.file);
			if (!moved && !declared.exists(name -> e.source.indexOf(name) >= 0)) continue;
			final names: Array<String> = [];
			for (o in ModulePathTokens.bareUpperNames(e.source, plugin.lexicalRegions(e.source))) if (
				(moved || declared.contains(o.name)) && !names.contains(o.name)
			)
				names.push(o.name);
			if (names.length > 0) out.push({ before: e.file, after: newPathOf[e.file] ?? e.file, names: names });
		}
		return out;
	}

	/**
	 * Compare every probed name before and after; write the import each drifted name's old meaning needs (dropping the
	 * sub-type imports of the same module it makes redundant), compare again, and answer every drift that remains — `Right`
	 * when none does. `imports` collects what was written.
	 */
	private static function repairBindings(
		files: Array<{ file: String, source: String }>, texts: Map<String, String>, newPathOf: Map<String, String>,
		probes: Array<BindingProbe>, pre: SymbolIndex, renamed: Map<String, String>, plugin: GrammarPlugin, imports: Array<String>
	): Either<Array<String>, Bool> {
		final before: Map<String, String> = [for (e in files) e.file => e.source];
		final post: SymbolIndex = postIndex(files, texts, newPathOf, plugin);
		final first: Array<BindingDrift> = driftsIn(post, files, texts, newPathOf, probes, pre, renamed, plugin, before);
		if (first.length == 0) return Right(true);
		final unrepaired: Array<String> = [for (d in first) if (d.repair == null) describeDrift(d)];
		if (unrepaired.length > 0) return Left(unrepaired);
		final oldPathOf: Map<String, String> = [for (old => now in newPathOf) now => old];
		final byFile: Map<String, Array<String>> = [];
		for (d in first) {
			final paths: Array<String> = byFile[d.file] ?? [];
			final repair: String = d.repair ?? '';
			if (!paths.contains(repair)) paths.push(repair);
			byFile[d.file] = paths;
		}
		final infoOf: Map<String, FileInfo> = [for (fi in post.allFiles()) fi.file => fi];
		for (file => paths in byFile) {
			final key: String = oldPathOf[file] ?? file;
			texts[key] = withImports(texts[key] ?? '', paths, infoOf[file], plugin);
			for (p in paths) imports.push('$file: import $p;');
		}
		final second: Array<BindingDrift> = driftsIn(
			postIndex(files, texts, newPathOf, plugin), files, texts, newPathOf, probes, pre, renamed, plugin, before
		);
		return second.length == 0 ? Right(true) : Left([for (d in second) describeDrift(d)]);
	}

	/** The index of the tree after the relocation: every module under its new path, with its rewritten text. */
	private static function postIndex(
		files: Array<{ file: String, source: String }>, texts: Map<String, String>, newPathOf: Map<String, String>, plugin: GrammarPlugin
	): SymbolIndex {
		final index: SymbolIndex = IndexScope.over([
			for (e in files) { file: newPathOf[e.file] ?? e.file, source: texts[e.file] ?? e.source }
		], plugin);
		ModuleMoveBindings.attachVirtualAmbient(index, plugin);
		return index;
	}

	/** One drift as a refusal line. */
	private static function describeDrift(d: BindingDrift): String {
		return '${d.file}: "${d.name}" means ${d.before} before the move and ${d.after} after it'
			+ (d.repair == null ? ', and no import gives it back' : ' even with import ${d.repair}');
	}

	/** `edits` in ascending order of their start. */
	private static function sorted(edits: Array<TextEdit>): Array<TextEdit> {
		final out: Array<TextEdit> = edits.copy();
		ArraySort.sort(out, (a, b) -> a.span.from - b.span.from);
		return out;
	}

	/** The 1-based line of `offset` in `source`. */
	private static function lineOf(source: String, offset: Int): Int {
		return source.substring(0, offset).split('\n').length;
	}

	/** The drifts of `probes` between `pre` and `post`, the index of the tree `texts` describe now. */
	private static function driftsIn(
		post: SymbolIndex, files: Array<{ file: String, source: String }>, texts: Map<String, String>, newPathOf: Map<String, String>,
		probes: Array<BindingProbe>, pre: SymbolIndex, renamed: Map<String, String>, plugin: GrammarPlugin, before: Map<String, String>
	): Array<BindingDrift> {
		final after: Map<String, String> = [for (e in files) newPathOf[e.file] ?? e.file => texts[e.file] ?? e.source];
		return ModuleMoveBindings.drifts(pre, post, probes, renamed, plugin, before, after);
	}

	/** Whether `path` imports a sub-type of the module `module` — `module.Sub`, upper-initial — which `import module;` binds. */
	private static function isSubTypeOf(path: String, module: String): Bool {
		if (!path.startsWith('$module.')) return false;
		final rest: String = path.substr(module.length + 1);
		return rest.indexOf('.') < 0 && rest.length > 0 && rest.charAt(0) == rest.charAt(0).toUpperCase() && rest.charAt(0) != '_';
	}

	/** `span` widened to its whole line, newline included, when nothing else shares the line; else `span` itself. */
	private static function wholeLine(text: String, span: Span): Span {
		var from: Int = span.from;
		while (from > 0 && (text.charAt(from - 1) == ' ' || text.charAt(from - 1) == '\t')) from--;
		var to: Int = span.to;
		while (to < text.length && (text.charAt(to) == ' ' || text.charAt(to) == '\t')) to++;
		final lineStart: Bool = from == 0 || text.charAt(from - 1) == '\n';
		final lineEnd: Bool = to >= text.length || text.charAt(to) == '\n';
		return lineStart && lineEnd ? new Span(from, to < text.length ? to + 1 : to) : span;
	}

	/** Every relocation of `moves` planned against the analysed set `pre`, or every reason one cannot be. */
	private static function planAll(
		moves: Array<ModuleRelocation>, pre: SymbolIndex, sourceOf: Map<String, String>, plugin: GrammarPlugin
	): Either<Array<String>, Array<PlannedMove>> {
		final infoOf: Map<String, FileInfo> = [for (fi in pre.allFiles()) fi.file => fi];
		final reasons: Array<String> = [];
		final planned: Array<PlannedMove> = [];
		for (m in moves) switch plan(m, moves, infoOf, sourceOf, plugin) {
			case Left(message):
				reasons.push(message);
			case Right(p):
				planned.push(p);
		}
		return reasons.length > 0 ? Left(reasons) : Right(planned);
	}

	/**
	 * Every module of the request with each relocated path rewritten (and a relocated module's package statement), keyed by
	 * its OLD path, the declared sorted lists put back in order; or every reason the rewrite cannot be proven.
	 */
	private static function rewriteAll(
		request: ModuleMoveRequest, planned: Array<PlannedMove>, plugin: GrammarPlugin
	): Either<Array<String>, Map<String, String>> {
		final renames: Array<ModuleRename> = [for (p in planned) p.rename];
		final reasons: Array<String> = [];
		final texts: Map<String, String> = [];
		for (e in request.scopeFiles) switch rewriteModule(e.file, e.source, renames, planned.find(p -> p.move.from == e.file), plugin) {
			case Left(found):
				for (r in found) reasons.push(r);
			case Right(text):
				texts[e.file] = text;
		}
		for (r in compositionRefusals(request.scopeFiles, planned, plugin)) reasons.push(r);
		final textOf: Map<String, String> = [for (e in request.textFiles) e.file => e.source];
		for (r in registryRefusals(request.registries, textOf, planned)) reasons.push(r);
		if (reasons.length > 0) return Left(reasons);
		final sourceOf: Map<String, String> = [for (e in request.scopeFiles) e.file => e.source];
		for (parts in request.sortedLists) switch DeclaredSortedLists.resort(parts, sourceOf, texts, plugin) {
			case Left(message):
				reasons.push(message);
			case Right(edits):
				for (file => list in edits) texts[file] = ModulePathTokens.apply(texts[file] ?? '', sorted(list));
		}
		return reasons.length > 0 ? Left(reasons) : Right(texts);
	}

	/** Every changed file under its new path — each rewritten module re-parsed — and every declared text rewritten. */
	private static function changesOf(
		request: ModuleMoveRequest, texts: Map<String, String>, newPathOf: Map<String, String>, renames: Array<ModuleRename>,
		plugin: GrammarPlugin
	): Either<Array<String>, Array<MoveChange>> {
		final reasons: Array<String> = [];
		final changes: Array<MoveChange> = [];
		for (e in request.scopeFiles) {
			final text: String = texts[e.file] ?? e.source;
			final target: String = newPathOf[e.file] ?? e.file;
			if (text == e.source && target == e.file) continue;
			final refusal: Null<String> = ParseGate.refusal(plugin, text, 'rewritten $target');
			if (refusal != null) reasons.push(refusal);
			changes.push({ file: target, newSource: text });
		}
		for (e in request.textFiles) {
			final text: String = ModulePathTokens.rewrite(e.source, renames);
			if (text != e.source) changes.push({ file: e.file, newSource: text });
		}
		return reasons.length > 0 ? Left(reasons) : Right(changes);
	}

	/**
	 * `text` (the module `info` indexes) with an import of each of `paths` written into its import run, and every plain
	 * import of a sub-type of one of them removed — the module import binds it already.
	 */
	private static function withImports(text: String, paths: Array<String>, info: Null<FileInfo>, plugin: GrammarPlugin): String {
		final edits: Array<{ span: Span, text: String }> = [];
		final insert: Null<{ span: Span, text: String }> = MoveSymbol.carriedImportEdit(text, [for (p in paths) 'import $p;'], plugin);
		if (insert != null) edits.push(insert);
		if (info != null)
			for (imp in info.imports)
				if (!imp.guarded && imp.kind == ImportKind.Import && imp.alias == null && paths.exists(p -> isSubTypeOf(imp.raw, p)))
					edits.push({ span: wholeLine(text, imp.span), text: '' });
		return CanonicalEdit.applyEdits(text, edits);
	}

}
