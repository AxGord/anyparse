package testkit;

import haxe.Exception;
import haxe.io.Path;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import sys.FileSystem;
import sys.io.File;
import testkit.MutationArms.ArmTable;
import testkit.MutationArms.MutationArm;

using Lambda;
using StringTools;

/**
 * What one discovery pass over the test tree found.
 *
 * `dead` and `bases` are not failures — they are the two ways a
 * test-shaped thing can exist without utest ever running it, and the suite
 * pins both so a new one has to be noticed.
 */
typedef TestCensus = {
	/** Classes that will be registered, sorted by fully-qualified name. */
	registered: Array<ClassType>,

	/** Fixture-named methods utest will never run, each with its reason. */
	dead: Array<String>,

	/** `utest.Test` subclasses carrying no fixture of their own or inherited. */
	bases: Array<String>,

	/** Every `@:pin`ned fixture, rendered for `TestRegistry.pins()`. */
	pins: Array<String>,

	/** Every distinct `@:killer` arm name the tree spells, for the registry cross-check. */
	killers: Array<String>
};

/**
 * Build macro behind `testkit.TestRegistry` — it DISCOVERS the suite's test
 * classes instead of taking a hand-written list.
 *
 * `test/RunTests.hx` used to carry one `addCase(new X())` per class, 758 of
 * them, each needing its own `import`. Two costs came with that: a class
 * whose line was never added ran nowhere and said nothing (S48 found 167
 * test methods dead behind a build guard for the same reason — a
 * registration that nothing cross-checks), and every parallel worker
 * touched the same file, so a wave of slices conflicted on it by
 * construction.
 *
 * **The predicate is utest's own, deliberately.** `utest.utils.TestBuilder`
 * turns a method into a fixture when it is NOT static and its name starts
 * with `test` or `spec`; `utest.Runner.addITest` then runs a case only if
 * it implements `utest.ITest`. This macro asks exactly those two questions,
 * so "discovered" and "run" cannot drift apart. An explicit marker
 * (`@:testCase` on the class) was rejected for the opposite reason: it
 * re-creates the silently-missing-test failure one level up, since a
 * forgotten marker is as invisible as a forgotten `addCase`.
 *
 * **A class that cannot be registered is a build ERROR, never a skip.**
 * Private, abstract, sub-module or constructor-taking test classes are the
 * shapes that would otherwise be dropped in silence; each stops the build
 * naming itself and the fix. The one deliberate SKIP is a `utest.Test`
 * subclass with no fixture at all (a shared base class such as
 * `unit.check.NamingCheckTestBase`): utest registers no fixtures for it either,
 * so registering it would be a no-op — it is reported through
 * `TestRegistry.baseClasses()` rather than assumed.
 *
 * **Scope is a whitelist on both edges, not a skip.** The walk covers every
 * package directory under the test classpath root, minus the two modules
 * asking for which would be circular (`SELF_MODULES`). Root-level modules are
 * not walked either — typing `RunTests` from inside the macro that builds its
 * registry is the same circle — but a root-level module that is not one of the
 * declared entry points STOPS THE BUILD naming itself, so a test class dropped
 * there is loud rather than invisible. A test class lives in a package;
 * `unit`, like every existing one.
 *
 * **The arm registry is checked BOTH ways at build time.**
 * `mutation-arms.json` beside this file declares one record per mutation arm —
 * the layer, the member and the cut — so a `@:killer` naming no declared arm
 * stops the build the way a control naming no arm already did, a declared arm
 * nobody names stops it too, and an arm whose member has been renamed or moved
 * out from under it stops it before anyone runs a sweep. Running one is
 * `tools/mutation-arm.sh <NAME>`.
 *
 * **No state.** Everything the macro emits is a fresh literal built per call
 * (`classNames()` returns a new array each time), so the generated
 * registration holds no `static var` — invariant 1.
 *
 * **No `#if macro` guard, and that is enforced.** The obvious spelling wraps
 * the helpers below in one; this module is only ever typed in macro context
 * (nothing but `@:build` names it), so the guard buys nothing — and
 * `unit.DeadTestGuardTest`, the gate S48 built, fails the suite on a
 * conditional region this build cannot prove live. It caught the first draft
 * of this file.
 */
class TestDiscovery {

	/** Role metadata on a fixture, e.g. `@:pin('control')`. */
	private static inline final PIN_META: String = ':pin';

	/** Mutation arm that must break a pinned fixture, e.g. `@:killer('M5')`. */
	private static inline final KILLER_META: String = ':killer';

	/** The one `@:pin` role that requires at least one `@:killer`. */
	private static inline final CONTROL_ROLE: String = 'control';

	/** The arm registry, beside this file — every `@:killer` name has to resolve into it. */
	private static inline final ARMS_FILE: String = 'mutation-arms.json';

	/** Method-name prefixes utest treats as fixtures — `TestBuilder.isTestName`. */
	private static final FIXTURE_PREFIXES: Array<String> = ['test', 'spec'];

	/**
	 * This macro's own module and the registry it builds. Asking the compiler
	 * for either from inside the build that produces the registry's fields is
	 * the one circular question here, so they are the only modules skipped.
	 */
	private static final SELF_MODULES: Array<String> = ['testkit.TestDiscovery', 'testkit.TestRegistry'];

	/**
	 * The `-main` modules that legitimately sit at the test ROOT, and the whole
	 * reason root-level modules are not walked: typing `RunTests` from inside
	 * the macro that builds its own registry is circular.
	 *
	 * It is a whitelist, not a skip: any OTHER root-level module stops the
	 * build naming itself. A negative rule ("skip the root") would make a test
	 * class dropped there invisible, which is the failure this layer exists to
	 * remove — moving it one directory down is the fix, and the error says so.
	 */
	private static final ENTRY_POINT_MODULES: Array<String> = ['RunTests', '_ReconSkipParse'];

	/**
	 * Generate the registry members onto the class this is built on:
	 * `addAll`, `classNames`, `deadTests`, `baseClasses` and `pins`.
	 */
	public static macro function build(): Array<Field> {
		final self: ClassType = Context.getLocalClass().get();
		final here: String = Path.directory(Context.getPosInfos(self.pos).file);
		final root: String = Path.directory(here);
		final armsPath: String = Path.join([here, ARMS_FILE]);
		if (!FileSystem.exists(armsPath))
			Context.error(
				'$armsPath is missing, and every @$KILLER_META in the test tree resolves through it'
				+ ' — restore it, or drop the pins it answers for',
				Context.currentPos()
			);
		final table: ArmTable = MutationArms.parse(File.getContent(armsPath));
		for (error in table.errors) Context.error('$ARMS_FILE: $error', Context.currentPos());
		final modules: Array<String> = [];
		collectModules(root, [], modules);
		modules.sort(compareStrings);
		final census: TestCensus = {
			registered: [],
			dead: [],
			bases: [],
			pins: [],
			killers: []
		};
		for (module in modules) if (!SELF_MODULES.contains(module)) for (moduleType in Context.getModule(module)) switch moduleType {
			case TInst(ref, _):
				consider(ref.get(), census, table.arms);
			case _:
		}
		checkArms(table.arms, census.killers);
		census.registered.sort((a, b) -> compareStrings(qualified(a), qualified(b)));
		census.dead.sort(compareStrings);
		census.bases.sort(compareStrings);
		census.pins.sort(compareStrings);
		final adds: Array<Expr> = census.registered.map(newCase);
		final names: Array<String> = census.registered.map(qualified);
		final dead: Array<String> = census.dead;
		final bases: Array<String> = census.bases;
		final pins: Array<String> = census.pins;
		final arms: Array<String> = table.arms.map(MutationArms.render);
		final generated: Array<Field> = (macro class Generated {
			/** Hand every discovered case to `add`, in generation order. */
			public static function addAll(add: (utest.Test) -> Void): Void $b{adds}

			/** Fully-qualified name of every registered case, one per registration. */
			public static function classNames(): Array<String> return $v{names};

			/** Fixture-named methods utest will never run, each with its reason. */
			public static function deadTests(): Array<String> return $v{dead};

			/** `utest.Test` subclasses that carry no fixture, so registering them would be a no-op. */
			public static function baseClasses(): Array<String> return $v{bases};

			/** Every `@:pin`ned fixture as `<class>#<method> :: <role> :: <killers>`. */
			public static function pins(): Array<String> return $v{pins};

			/** Every declared mutation arm as `<name> :: <type>#<method> :: <cut> :: <note>`. */
			public static function arms(): Array<String> return $v{arms};
		}).fields;
		return Context.getBuildFields().concat(generated);
	}

	/**
	 * Every module under `dir` that lives in a package, as dotted paths.
	 *
	 * Root-level modules (`pack` still empty) are entry points, not cases —
	 * see the class doc.
	 */
	private static function collectModules(dir: String, pack: Array<String>, out: Array<String>): Void {
		for (entry in FileSystem.readDirectory(dir)) {
			final full: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(full)) {
				collectModules(full, pack.concat([entry]), out);
			} else if (entry.endsWith('.hx')) {
				final module: String = pack.concat([entry.substr(0, entry.length - '.hx'.length)]).join('.');
				if (pack.length > 0)
					out.push(module);
				else if (!ENTRY_POINT_MODULES.contains(module))
					Context.error(
						'$full is a root-level module under the test root, where only the $ENTRY_POINT_MODULES entry points live'
						+ ' — a test class there is discovered by nobody; move it into a package (unit/), or name it an entry point',
						Context.currentPos()
					);
			}
		}
	}

	/** Classify one class: register it, refuse it by name, or record why it is not a case. */
	private static function consider(c: ClassType, census: TestCensus, arms: Array<MutationArm>): Void {
		if (c.isExtern || c.isInterface) return;
		final fq: String = qualified(c);
		final statics: Array<String> = [for (f in c.statics.get()) if (isFixtureMethod(f)) f.name];
		if (!isUtestCase(c)) {
			for (f in c.fields.get()) if (isFixtureMethod(f)) census.dead.push('$fq#${f.name} :: the class does not implement utest.ITest');
			for (name in statics) census.dead.push('$fq#$name :: the class does not implement utest.ITest');
			return;
		}
		for (name in statics) census.dead.push('$fq#$name :: static, and utest discovers instance methods only');
		collectPins(c, census, arms);
		if (fixtureNames(c).length == 0) {
			census.bases.push(fq);
			return;
		}
		if (c.isPrivate)
			Context.error(
				'$fq carries fixtures but is private, so no generated registration can name it'
				+ ' — make it public or move it to its own module',
				c.pos
			);
		if (c.isAbstract)
			Context.error(
				'$fq carries fixtures but is abstract, so utest cannot instantiate it — move the fixtures down to a concrete subclass',
				c.pos
			);
		if (moduleName(c) != c.name)
			Context.error(
				'$fq carries fixtures but is a sub-module type, and Type.getClassName does not spell it'
				+ ' the way an APQ_TEST filter does — move it to its own module',
				c.pos
			);
		if (!hasNullaryConstructor(c))
			Context.error(
				'$fq carries fixtures but has no argument-less constructor, so the generated registration cannot build it', c.pos
			);
		census.registered.push(c);
	}

	/** `add(new pack.Name())` for one discovered case. */
	private static function newCase(c: ClassType): Expr {
		final path: TypePath = { pack: c.pack, name: c.name };
		final construct: Expr = { expr: ENew(path, []), pos: c.pos };
		return macro add($construct);
	}

	/** Does `c` or any ancestor implement `utest.ITest` — the interface `Runner.addCase` dispatches on. */
	private static function isUtestCase(c: ClassType): Bool {
		var cursor: Null<ClassType> = c;
		while (cursor != null) {
			for (implemented in cursor.interfaces) {
				final iface: ClassType = implemented.t.get();
				if (iface.name == 'ITest' && iface.pack.length == 1 && iface.pack[0] == 'utest') return true;
			}
			cursor = superOf(cursor);
		}
		return false;
	}

	/** Fixture method names visible on `c`, own and inherited, deduplicated by override. */
	private static function fixtureNames(c: ClassType): Array<String> {
		final out: Array<String> = [];
		var cursor: Null<ClassType> = c;
		while (cursor != null) {
			for (f in cursor.fields.get()) if (isFixtureMethod(f) && !out.contains(f.name)) out.push(f.name);
			cursor = superOf(cursor);
		}
		return out;
	}

	/** `TestBuilder.isTestName` applied to a method field — a prefix test, not an exact one. */
	private static function isFixtureMethod(f: ClassField): Bool {
		return isMethod(f) && FIXTURE_PREFIXES.exists(prefix -> f.name.startsWith(prefix));
	}

	/** Can `new C()` be written — the nearest constructor in the chain takes no required argument. */
	private static function hasNullaryConstructor(c: ClassType): Bool {
		var cursor: Null<ClassType> = c;
		while (cursor != null) {
			final ctor: Null<Ref<ClassField>> = cursor.constructor;
			if (ctor != null) return switch Context.follow(ctor.get().type) {
				case TFun(args, _): args.foreach(a -> a.opt);
				case _: false;
			};
			cursor = superOf(cursor);
		}
		return false;
	}

	/**
	 * Validate and record the `@:pin` / `@:killer` pair on each fixture of `c`.
	 *
	 * A `@:pin('control')` with no `@:killer` is a build error: a control whose
	 * killing arm nobody names is a claim the reviewer has to take on trust, which
	 * is the state this metadata exists to end. A `@:killer` naming an arm
	 * `mutation-arms.json` does not declare is the same error one level down — the
	 * name was free text until the registry existed, so nothing said the arm could
	 * be found, let alone run.
	 */
	private static function collectPins(c: ClassType, census: TestCensus, arms: Array<MutationArm>): Void {
		final fq: String = qualified(c);
		for (f in c.fields.get()) if (isFixtureMethod(f)) {
			final roles: Array<MetadataEntry> = f.meta.extract(PIN_META);
			final killers: Array<String> = [for (entry in f.meta.extract(KILLER_META)) for (arg in metaArgs(entry)) arg];
			if (roles.length == 0) {
				if (killers.length > 0)
					Context.error(
						'$fq#${f.name} carries @$KILLER_META without @$PIN_META — a killer names the arm that must break a PINNED fixture',
						f.pos
					);
				continue;
			}
			if (roles.length > 1) Context.error('$fq#${f.name} carries @$PIN_META more than once', f.pos);
			final args: Array<String> = metaArgs(roles[0]);
			if (args.length != 1)
				Context.error(
					'$fq#${f.name}: @$PIN_META expects exactly one role string, e.g. @$PIN_META(\'$CONTROL_ROLE\')', roles[0].pos
				);
			final role: String = args[0];
			if (role == CONTROL_ROLE && killers.length == 0)
				Context.error(
					'$fq#${f.name} is @$PIN_META(\'$CONTROL_ROLE\') with no @$KILLER_META'
					+ ' — a control no arm kills proves nothing; name the arm or drop the pin',
					f.pos
				);
			for (killer in killers) {
				if (MutationArms.find(arms, killer) == null)
					Context.error(
						'$fq#${f.name} names @$KILLER_META(\'$killer\'), which $ARMS_FILE declares no arm for'
						+ ' — declare the arm (layer, member, cut) or fix the name; an arm nobody can run is prose retyped as metadata',
						f.pos
					);
				if (!census.killers.contains(killer)) census.killers.push(killer);
			}
			census.pins.push('$fq#${f.name} :: $role :: ${killers.join(',')}');
		}
	}

	/**
	 * Cross-check the registry against the tree in the direction `collectPins`
	 * cannot: every declared arm must still be NAMED by a `@:killer`, and must
	 * still ADDRESS a member that exists.
	 *
	 * The second half is what makes the registry more than a name list. An arm is
	 * a recipe against one member; a slice that renames or moves that member
	 * leaves the recipe pointing at nothing, and until somebody RUNS the arm
	 * nothing says so — four of the `trivial-getter` lines S94's arm depends on had
	 * already been moved into another file by S74, before the pin naming that arm
	 * was ever read back. Asking the
	 * compiler costs nothing here: every module an arm names is in the test build
	 * already.
	 */
	private static function checkArms(arms: Array<MutationArm>, killers: Array<String>): Void {
		for (arm in arms) {
			if (!killers.contains(arm.name))
				Context.error(
					'$ARMS_FILE declares "${arm.name}", which no @$KILLER_META in the test tree names'
					+ ' — an arm exists to kill a pin, so give it one or drop it',
					Context.currentPos()
				);
			final owner: Null<ClassType> = classNamed(arm.type);
			if (owner == null)
				Context.error('$ARMS_FILE: "${arm.name}" names the type ${arm.type}, which resolves to no class', Context.currentPos());
			else if (!declaresMethod(owner, arm.method))
				Context.error(
					'$ARMS_FILE: "${arm.name}" cuts ${arm.type}#${arm.method}, and ${arm.type} declares no such method'
					+ ' — a rename or a move left the arm behind; re-point it at the member the cut belongs to now',
					Context.currentPos()
				);
		}
	}

	/** The class a dotted module path names, or null when nothing of that name resolves. */
	private static function classNamed(path: String): Null<ClassType> {
		final parts: Array<String> = path.split('.');
		var moduleTypes: Array<Type> = [];
		try
			moduleTypes = Context.getModule(path)
		catch (exception: Exception)
			return null;
		for (moduleType in moduleTypes) switch moduleType {
			case TInst(ref, _):
				final c: ClassType = ref.get();
				if (c.name == parts[parts.length - 1]) return c;
			case _:
		}
		return null;
	}

	/** Does `c` declare a method called `name` — static or instance, private or public. */
	private static function declaresMethod(c: ClassType, name: String): Bool {
		return c.fields.get().exists(f -> f.name == name && isMethod(f)) || c.statics.get().exists(f -> f.name == name && isMethod(f));
	}

	/** Is this field a method rather than a variable or a property. */
	private static function isMethod(f: ClassField): Bool {
		return switch f.kind {
			case FMethod(_): true;
			case _: false;
		};
	}

	/** The string arguments of one metadata entry; anything else is a build error. */
	private static function metaArgs(entry: MetadataEntry): Array<String> {
		final params: Null<Array<Expr>> = entry.params;
		return params == null ? [] : [
			for (param in params) switch param.expr {
				case EConst(CString(s, _)): s;
				case _: Context.error('@${entry.name} expects string arguments', param.pos);
			}
		];
	}

	/** The superclass of `c`, or `null` at the top of the chain. */
	private static function superOf(c: ClassType): Null<ClassType> {
		final parent: Null<{ t: Ref<ClassType>, params: Array<Type> }> = c.superClass;
		return parent?.t.get();
	}

	/** `pack.Name`, the spelling `Type.getClassName` produces at runtime. */
	private static function qualified(c: ClassType): String return c.pack.length == 0 ? c.name : '${c.pack.join('.')}.${c.name}';

	/** Last segment of the module `c` was declared in. */
	private static function moduleName(c: ClassType): String {
		final parts: Array<String> = c.module.split('.');
		return parts[parts.length - 1];
	}

	/** Code-unit order, so the generated registration does not depend on the machine's locale. */
	private static function compareStrings(a: String, b: String): Int return if (a < b)
		-1
	else if (a > b)
		1
	else
		0;

}
