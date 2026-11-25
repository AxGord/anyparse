package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.ExprTools;
#end

using Lambda;

import anyparse.util.Compare;
import haxe.macro.Expr;
import haxe.macro.Type;

/** One built-in lint rule as the registry order reads it: its class path, its class name and its anchors as written. */
typedef RuleRow = {
	final path: String;
	final name: String;
	final after: Array<String>;
	final before: Array<String>;
}

/** The class paths of the built-in lint rules in registry order, or the problem that leaves them without one. */
typedef RuleOrder = { final paths: Array<String>; final problem: Null<String>; }

/**
 * The one answer to "which lint rules are built in, and in what order": every concrete class of the `anyparse.check`
 * packages on the compiler's classpath that extends `RuleBase`, read at compile time, so a new rule needs no `Linter`
 * edit. The order is by class name, then by class path, except where a rule declares `@:lintAfter(Rule, …)` or
 * `@:lintBefore(Rule, …)`: `Cli.computeFileLintEdits` keeps the earlier check's edit where two overlap, so a rule whose
 * fix depends on running first says so on itself. A rule class `new X()` cannot build, an anchor naming no rule or
 * several, and a cycle of anchors are build errors, never a silent skip. A compilation server does not re-run the walk
 * when a rule file appears; the walk and the order need no compiler and stay outside `#if macro`, so the suite types them.
 */
@:nullSafety(Strict)
final class RuleDiscovery {

	/** The package whose subpackages hold every built-in rule. */
	private static final RULE_PACKAGE: Array<String> = ['anyparse', 'check'];

	/** The base every built-in rule extends, by its class path. */
	private static final RULE_BASE: String = 'anyparse.check.RuleBase';

	/** The metadata naming the rules a rule runs after. */
	private static final AFTER: String = ':lintAfter';

	/** The metadata naming the rules a rule runs before. */
	private static final BEFORE: String = ':lintBefore';

	/** Every module path of the `anyparse.check` packages under the directories `roots`, deduped and sorted; an empty root is skipped. */
	public static inline function ruleModules(roots: Array<String>): Array<String> {
		return ClasspathModules.under(roots, RULE_PACKAGE, isModuleName);
	}

	/**
	 * A fresh instance of every built-in rule in registry order, as an array literal: the caller builds it afresh on every
	 * call, so the registry is never process-scoped state (invariant 1).
	 */
	public static macro function builtins(): Expr {
		final rows: Array<RuleRow> = [];
		for (module in ruleModules(Context.getClassPath())) for (type in Context.getModule(module)) switch type {
			case TInst(ref, _) if (isRule(ref.get())):
				rows.push(row(module, ref.get()));
			case _:
		}
		final found: RuleOrder = order(rows);
		final problem: Null<String> = found.problem;
		if (problem != null) Context.error(problem, Context.currentPos());
		final instances: Array<Expr> = found.paths.map(instance);
		return macro $a{instances};
	}

	/**
	 * The class paths of `rows` in registry order: by class name, then by class path, each rule moved behind every rule
	 * its `after` names and ahead of every rule its `before` names. An anchor naming no row or several, or a cycle of
	 * anchors, is the problem instead.
	 */
	public static function order(rows: Array<RuleRow>): RuleOrder {
		final sorted: Array<RuleRow> = rows.copy();
		sorted.sort(byNameThenPath);
		final preceding: Array<Array<Int>> = [ for (_ in sorted) [] ];
		for (index => row in sorted) {
			for (anchor in row.after) {
				final found: Array<Int> = named(sorted, anchor);
				if (found.length != 1) return refused(row, AFTER, anchor, found.length);
				preceding[index].push(found[0]);
			}
			for (anchor in row.before) {
				final found: Array<Int> = named(sorted, anchor);
				if (found.length != 1) return refused(row, BEFORE, anchor, found.length);
				preceding[found[0]].push(index);
			}
		}
		final placed: Array<Bool> = [ for (_ in sorted) false ];
		final paths: Array<String> = [];
		while (paths.length < sorted.length) {
			var next: Int = -1;
			for (index in 0...sorted.length) if (!placed[index] && preceding[index].foreach(before -> placed[before])) {
				next = index;
				break;
			}
			if (next < 0) {
				final cycle: Array<String> = [ for (index in 0...sorted.length) if (!placed[index]) sorted[index].path ];
				return {
					paths: [],
					problem: 'the lint rules '
						+ cycle.join(', ')
						+ ' order each other in a cycle of @$AFTER / @$BEFORE, so no registry order honours them all'
				};
			}
			placed[next] = true;
			paths.push(sorted[next].path);
		}
		return { paths: paths, problem: null };
	}

	/** The default registry order of two rule rows: by class name, then by class path. */
	private static function byNameThenPath(a: RuleRow, b: RuleRow): Int {
		return a.name == b.name ? Compare.compareString(a.path, b.path) : Compare.compareString(a.name, b.name);
	}

	/** The indices of the rows of `sorted` whose class path or class name is `anchor`. */
	private static function named(sorted: Array<RuleRow>, anchor: String): Array<Int> {
		return [ for (index => row in sorted) if (row.path == anchor || row.name == anchor) index ];
	}

	/** The order refused because the anchor `anchor` of `row`'s metadata `meta` names `count` rules instead of one. */
	private static function refused(row: RuleRow, meta: String, anchor: String, count: Int): RuleOrder {
		final names: String = count == 0 ? 'no built-in lint rule' : 'several built-in lint rules, so spell its class path';
		return { paths: [], problem: '${row.path} declares @$meta($anchor), but $anchor names $names' };
	}

	/** Whether the file name `entry` names a module: a module name opens with an upper-case letter, which `import.hx` does not. */
	private static function isModuleName(entry: String): Bool {
		final first: Int = entry.charCodeAt(0) ?? 0;
		return first >= 'A'.code && first <= 'Z'.code;
	}

	#if macro
	/** Whether `c` is a concrete class extending `RuleBase`. */
	private static function isRule(c: ClassType): Bool {
		return !c.isInterface && !c.isAbstract && extendsRuleBase(c);
	}

	/** Whether a superclass of `c` is `RuleBase`. */
	private static function extendsRuleBase(c: ClassType): Bool {
		final superClass: Null<{ t: Ref<ClassType>, params: Array<Type> }> = c.superClass;
		if (superClass == null) return false;
		final parent: ClassType = superClass.t.get();
		return parent.pack.concat([parent.name]).join('.') == RULE_BASE || extendsRuleBase(parent);
	}

	/** The order row of the rule class `c` of `module`; a class `new X()` cannot build is a build error. */
	private static function row(module: String, c: ClassType): RuleRow {
		final path: String = c.pack.concat([c.name]).join('.');
		if (c.isPrivate || path != module)
			Context.error(
				'$path extends RuleBase, so Linter registers it as a built-in lint rule, but it is not the public main type'
				+ ' of its module — make it one, or make it abstract',
				c.pos
			);
		final ctor: Null<ClassField> = c.constructor?.get();
		if (ctor == null || !ctor.isPublic || !takesNoArgument(ctor.type))
			Context.error(
				'$path extends RuleBase, so Linter registers it as a built-in lint rule with `new $path()`, but it declares'
				+ ' no public constructor taking no argument',
				c.pos
			);
		return {
			path: path,
			name: c.name,
			after: anchors(c, AFTER),
			before: anchors(c, BEFORE)
		};
	}

	/** Whether the constructor type `type` can be called with no argument. */
	private static function takesNoArgument(type: Type): Bool {
		return switch Context.follow(type) {
			case TFun(args, _): args.foreach(arg -> arg.opt);
			case _: false;
		}
	}

	/** The rules the metadata `meta` of `c` names, each as written. */
	private static function anchors(c: ClassType, meta: String): Array<String> {
		return [ for (entry in c.meta.extract(meta)) for (param in entry.params ?? []) ExprTools.toString(param) ];
	}

	/** `new <path>()` for the class path `path`. */
	private static function instance(path: String): Expr {
		final segments: Array<String> = path.split('.');
		final type: TypePath = { pack: segments.slice(0, segments.length - 1), name: segments[segments.length - 1] };
		return { expr: ENew(type, []), pos: Context.currentPos() };
	}
	#end

}
